"""Contract test for the agent-reader Nomad ACL policy (#16).

Asserts the read-only baseline contract: namespace `*` carries exactly the
four read capabilities (list-jobs, read-job, read-logs, read-fs), node is
read-only, and no submit/write/operator-shaped grant exists anywhere.

Stdlib only. No cluster contact. Run from the repo root:

    python3.14 -m unittest discover -s tests -p 'test_acl_*.py'
    # or directly:
    python3 tests/test_acl_agent_reader.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
POLICY = REPO_ROOT / "acl" / "agent-reader.policy.hcl"

ALLOWED_NAMESPACE_CAPABILITIES = {"list-jobs", "read-job", "read-logs", "read-fs"}

# Capabilities that would let a holder change cluster state or run code.
FORBIDDEN_CAPABILITIES = {
    "submit-job",
    "dispatch-job",
    "scale-job",
    "alloc-lifecycle",
    "alloc-exec",
    "alloc-node-exec",
    "gc-allocation",
    "sentinel-override",
}

# Top-level HCL blocks that must not appear at all (even a read grant on
# variables would leak secrets; operator/agent/quota/plugin are never
# reader business).
FORBIDDEN_BLOCKS = {"operator", "agent", "quota", "plugin", "host_volume", "variables", "sentinel"}


def _strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def _top_level_blocks(text: str) -> list[tuple[str, str | None, str]]:
    """(type, label, body) for every depth-0 block of a small HCL policy."""
    text = _strip_comments(text)
    blocks: list[tuple[str, str | None, str]] = []
    depth = 0
    start = 0
    head = ""
    body_start = 0
    for match in re.finditer(r"[{}]", text):
        if match.group() == "{":
            if depth == 0:
                head = text[start : match.start()].strip().splitlines()[-1].strip()
                body_start = match.end()
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                parts = re.fullmatch(r'(\w+)(?:\s+"([^"]*)")?', head)
                assert parts, f"unparseable block head {head!r}"
                blocks.append((parts.group(1), parts.group(2), text[body_start : match.start()]))
                start = match.end()
    assert depth == 0, "unbalanced braces"
    return blocks


def _capabilities(body: str) -> set[str]:
    match = re.search(r"capabilities\s*=\s*\[([^\]]*)\]", body)
    return set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()


class AgentReaderPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = POLICY.read_text()
        cls.blocks = _top_level_blocks(cls.text)

    def test_policy_file_exists(self) -> None:
        self.assertTrue(POLICY.is_file(), f"missing {POLICY}")

    def test_no_forbidden_capability_appears(self) -> None:
        body = _strip_comments(self.text)
        for forbidden in sorted(FORBIDDEN_CAPABILITIES):
            self.assertNotIn(f'"{forbidden}"', body, f"policy grants {forbidden}")

    def test_no_write_policy_anywhere(self) -> None:
        body = _strip_comments(self.text)
        self.assertIsNone(
            re.search(r'policy\s*=\s*"write"', body),
            'policy = "write" must not appear anywhere',
        )

    def test_no_forbidden_block_type(self) -> None:
        kinds = {kind for kind, _, _ in self.blocks}
        self.assertEqual(kinds & FORBIDDEN_BLOCKS, set(), f"forbidden blocks present: {kinds & FORBIDDEN_BLOCKS}")

    def test_every_namespace_block_uses_an_explicit_capabilities_list(self) -> None:
        namespaces = [(label, body) for kind, label, body in self.blocks if kind == "namespace"]
        self.assertTrue(namespaces, "no namespace block found")
        for label, body in namespaces:
            self.assertIn("capabilities", body, f'namespace "{label}" has no explicit capabilities list')
            self.assertIsNone(
                re.search(r'^\s*policy\s*=', body, re.MULTILINE),
                f'namespace "{label}" uses the policy shorthand (would also grant Nomad Variables read)',
            )

    def test_namespace_star_grants_exactly_the_read_set(self) -> None:
        namespaces = {label: body for kind, label, body in self.blocks if kind == "namespace"}
        self.assertEqual(set(namespaces), {"*"}, f"expected only namespace \"*\", got {sorted(namespaces)}")
        self.assertEqual(
            _capabilities(namespaces["*"]),
            ALLOWED_NAMESPACE_CAPABILITIES,
            "namespace * must grant exactly list-jobs/read-job/read-logs/read-fs",
        )

    def test_node_is_read_only(self) -> None:
        nodes = [body for kind, _, body in self.blocks if kind == "node"]
        self.assertEqual(len(nodes), 1, "expected exactly one node block")
        self.assertIsNotNone(
            re.fullmatch(r'\s*policy\s*=\s*"read"\s*', nodes[0]),
            "node block must be exactly policy = \"read\" (node has no capability list)",
        )

    def test_header_documents_holders_and_escrow_path(self) -> None:
        match = re.search(r'(?m)^namespace\s+"', self.text)
        assert match, "no namespace block found"
        header = self.text[: match.start()]
        self.assertIn("agent", header.lower(), "header must name the intended holders (agents)")
        self.assertIn("human", header.lower(), "header must name the intended holders (humans)")
        self.assertIn("AGENT_READ_TOKEN", header, "header must name the Bao escrow entry")
        self.assertIn("secret/projects/nomad/AGENT_READ_TOKEN", header, "header must give the full Bao escrow path")


if __name__ == "__main__":
    unittest.main()
