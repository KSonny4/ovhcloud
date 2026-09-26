"""Contract test for the Slice 4 Nomad ACL (KSonny4/platform#26).

Asserts the watcher-only boundary over the committed artifacts:
namespace names come from acl/namespaces.json (policies never invent
them), no submit capability outside deployer/agent-sandbox (narrow
per-project deploy tokens live in their app repos, not here), no
`policy = "write"` anywhere, agent-sandbox capabilities only in sandbox,
plus the sandbox namespace spec and sweep-job structure.

Stdlib only. No cluster contact. Run from the repo root:

    python3.14 -m unittest discover -s tests -p 'test_acl_*.py'
    # or directly:
    python3.14 tests/test_acl_s4.py
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ACL_DIR = REPO_ROOT / "acl"
DATA_FILE = ACL_DIR / "namespaces.json"
DEPLOYER_POLICY = ACL_DIR / "deployer.policy.hcl"
SANDBOX_POLICY = ACL_DIR / "agent-sandbox.policy.hcl"
NAMESPACE_SPEC = ACL_DIR / "namespace-sandbox.hcl"
SWEEP_SPEC = REPO_ROOT / "jobs" / "sandbox-sweep.nomad.hcl"

DEPLOYER_CAPABILITIES = {"list-jobs", "read-job", "parse-job", "submit-job", "read-logs"}
SANDBOX_CAPABILITIES = {"submit-job", "dispatch-job", "read-job", "list-jobs", "read-logs"}

# Policy FILES under acl/ that may grant submit-job. Narrow per-project
# deploy/dispatch tokens (graph-prep-dispatch, trading-*, traefik, the
# control-panel reader) live in their app repos, not here; if one is ever
# added under acl/, its filename must be added here deliberately — a new
# submit grant anywhere else fails this test.
KNOWN_SUBMIT_POLICIES = {"deployer.policy.hcl", "agent-sandbox.policy.hcl"}

# Top-level HCL blocks that must not appear in the Slice 4 policies (a
# Variables read would leak secrets; the rest are never deploy/sandbox
# business). Checked across every acl/*.policy.hcl.
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


def _policy_files() -> list[Path]:
    return sorted(ACL_DIR.glob("*.policy.hcl"))


class Slice4DataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(DATA_FILE.read_text())

    def test_data_file_has_production_and_sandbox(self) -> None:
        self.assertTrue(self.data["production"], "production namespace list must not be empty")
        self.assertTrue(all(isinstance(n, str) for n in self.data["production"]))
        self.assertIsInstance(self.data["sandbox"], str)
        self.assertNotIn(self.data["sandbox"], self.data["production"], "sandbox must not be a production namespace")

    def test_sandbox_constraints_are_data(self) -> None:
        self.assertEqual(self.data["sandbox_node_pool"], "home")
        self.assertGreater(self.data["sandbox_memory_cap_mb"], 0)
        self.assertGreater(self.data["sandbox_max_age_hours"], 0)


class Slice4PolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(DATA_FILE.read_text())
        cls.production = set(cls.data["production"])
        cls.sandbox = cls.data["sandbox"]
        cls.policies = {path.name: path.read_text() for path in _policy_files()}
        assert cls.policies, "no acl/*.policy.hcl found"

    def test_slice4_policy_files_exist(self) -> None:
        self.assertIn("deployer.policy.hcl", self.policies)
        self.assertIn("agent-sandbox.policy.hcl", self.policies)

    def test_no_write_policy_anywhere(self) -> None:
        for name, text in self.policies.items():
            self.assertIsNone(
                re.search(r'policy\s*=\s*"write"', _strip_comments(text)),
                f'{name}: policy = "write" must not appear anywhere',
            )

    def test_no_namespace_shorthand_anywhere(self) -> None:
        # The `policy = "read"` shorthand inside a namespace block would
        # additionally grant Nomad Variables read/list.
        for name, text in self.policies.items():
            for kind, label, body in _top_level_blocks(text):
                if kind != "namespace":
                    continue
                self.assertIn("capabilities", body, f"{name}: namespace {label!r} has no explicit capabilities list")
                self.assertIsNone(
                    re.search(r"^\s*policy\s*=", body, re.MULTILINE),
                    f"{name}: namespace {label!r} uses the policy shorthand",
                )

    def test_no_forbidden_block_type(self) -> None:
        for name, text in self.policies.items():
            kinds = {kind for kind, _, _ in _top_level_blocks(text)}
            self.assertEqual(kinds & FORBIDDEN_BLOCKS, set(), f"{name}: forbidden blocks present")

    def test_submit_only_in_known_policies(self) -> None:
        for name, text in self.policies.items():
            if '"submit-job"' in _strip_comments(text):
                self.assertIn(
                    name,
                    KNOWN_SUBMIT_POLICIES,
                    f"{name} grants submit-job; add it to KNOWN_SUBMIT_POLICIES deliberately or remove the grant",
                )

    def test_namespace_labels_come_from_the_data_file(self) -> None:
        allowed = self.production | {self.sandbox}
        # A `"*"` glob is allowed only for a read-only block (the
        # agent-reader precedent): it cannot escalate without a write-shaped
        # capability, and any submit grant is gated separately by
        # test_submit_only_in_known_policies.
        write_shaped = {"submit-job", "dispatch-job", "scale-job"}
        for name, text in self.policies.items():
            for kind, label, body in _top_level_blocks(text):
                if kind != "namespace":
                    continue
                if label == "*":
                    self.assertTrue(
                        write_shaped.isdisjoint(_capabilities(body)),
                        f"{name}: namespace \"*\" must stay read-only",
                    )
                else:
                    self.assertIn(label, allowed, f"{name}: namespace {label!r} is not in acl/namespaces.json")

    def test_deployer_covers_exactly_the_production_namespaces(self) -> None:
        blocks = _top_level_blocks(self.policies["deployer.policy.hcl"])
        self.assertLessEqual({kind for kind, _, _ in blocks}, {"namespace", "node"})
        namespaces = {label: body for kind, label, body in blocks if kind == "namespace"}
        self.assertEqual(set(namespaces), self.production, "deployer must cover exactly the production namespaces")
        for label, body in namespaces.items():
            self.assertEqual(
                _capabilities(body), DEPLOYER_CAPABILITIES, f"deployer namespace {label!r} capability drift"
            )

    def test_deployer_has_no_dispatch(self) -> None:
        # Dispatching a registered parameterized job stays with narrow
        # per-project tokens; the watcher registers specs via submit.
        self.assertNotIn('"dispatch-job"', _strip_comments(self.policies["deployer.policy.hcl"]))

    def test_deployer_node_is_read_only(self) -> None:
        nodes = [body for kind, _, body in _top_level_blocks(self.policies["deployer.policy.hcl"]) if kind == "node"]
        self.assertEqual(len(nodes), 1, "expected exactly one node block in deployer")
        self.assertIsNotNone(re.fullmatch(r'\s*policy\s*=\s*"read"\s*', nodes[0]))

    def test_agent_sandbox_is_sandbox_only(self) -> None:
        blocks = _top_level_blocks(self.policies["agent-sandbox.policy.hcl"])
        self.assertEqual([kind for kind, _, _ in blocks], ["namespace"], "agent-sandbox must hold only namespace blocks")
        namespaces = {label: body for kind, label, body in blocks if kind == "namespace"}
        self.assertEqual(set(namespaces), {self.sandbox}, "agent-sandbox capabilities only in sandbox")
        self.assertEqual(_capabilities(namespaces[self.sandbox]), SANDBOX_CAPABILITIES)

    def test_agent_reader_stays_submit_and_dispatch_free(self) -> None:
        # The lane must not change existing policies; the global gate spans
        # every acl/*.policy.hcl, this names the one that must stay read-only.
        reader = self.policies.get("agent-reader.policy.hcl", "")
        self.assertTrue(reader, "agent-reader policy missing")
        body = _strip_comments(reader)
        self.assertNotIn('"submit-job"', body)
        self.assertNotIn('"dispatch-job"', body)

    def test_headers_name_holders_and_escrow_paths(self) -> None:
        deployer = self.policies["deployer.policy.hcl"]
        sandbox = self.policies["agent-sandbox.policy.hcl"]
        self.assertIn("secret/projects/nomad/WATCHER_DEPLOY_TOKEN", deployer)
        self.assertIn("secret/projects/nomad/AGENT_SANDBOX_TOKEN", sandbox)
        self.assertIn("watcher", deployer.lower())
        self.assertIn("agent", sandbox.lower())


class SandboxNamespaceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(DATA_FILE.read_text())
        cls.text = NAMESPACE_SPEC.read_text()

    def test_name_matches_data_file(self) -> None:
        self.assertIsNotNone(re.search(rf'^name\s*=\s*"{re.escape(self.data["sandbox"])}"\s*$', self.text, re.MULTILINE))

    def test_no_quota_line(self) -> None:
        # Quotas are Enterprise-only; this cluster takes the documented
        # memory-cap branch instead (see docs/acl-cutover-runbook.md).
        self.assertIsNone(re.search(r"(?m)^\s*quota\s*=", _strip_comments(self.text)))

    def test_no_node_pool_config_block(self) -> None:
        # node_pool_config is likewise Enterprise-only; the home pin is
        # enforced per job spec instead.
        kinds = {kind for kind, _, _ in _top_level_blocks(self.text)}
        self.assertNotIn("node_pool_config", kinds)

    def test_meta_carries_the_documented_constraints(self) -> None:
        pool = re.escape(self.data["sandbox_node_pool"])
        self.assertIsNotNone(re.search(rf'node_pool\s*=\s*"{pool}"', self.text))
        self.assertIsNotNone(
            re.search(rf'memory_cap_mb\s*=\s*"{self.data["sandbox_memory_cap_mb"]}"', self.text)
        )
        self.assertIsNotNone(
            re.search(rf'max_age_hours\s*=\s*"{self.data["sandbox_max_age_hours"]}"', self.text)
        )


class SweepJobTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(DATA_FILE.read_text())
        cls.text = SWEEP_SPEC.read_text()

    def test_batch_periodic_job_in_a_production_namespace(self) -> None:
        self.assertIsNotNone(re.search(r'^job\s+"sandbox-sweep"', self.text, re.MULTILINE))
        self.assertIsNotNone(re.search(r'type\s*=\s*"batch"', self.text))
        self.assertIsNotNone(re.search(r"cron\s*=", self.text), "sweep must be periodic")
        ns = re.search(r'^\s*namespace\s*=\s*"([^"]+)"', self.text, re.MULTILINE)
        self.assertIsNotNone(ns, "sweep job must pin its namespace explicitly")
        assert ns is not None
        self.assertIn(ns.group(1), self.data["production"])
        self.assertNotEqual(ns.group(1), self.data["sandbox"], "sweep must not run inside sandbox")

    def test_targets_sandbox_with_the_data_file_threshold(self) -> None:
        max_age_s = self.data["sandbox_max_age_hours"] * 3600
        self.assertIn(f'NS="{self.data["sandbox"]}"', self.text)
        self.assertIn(f"MAX_AGE_S={max_age_s}", self.text)
        self.assertIn("nomad job stop", self.text)

    def test_committed_only_marker(self) -> None:
        self.assertIn("committed only", self.text.lower())
        self.assertIn("nomad job run", self.text)

    def test_fails_closed_without_injected_auth(self) -> None:
        self.assertIn("NOMAD_TOKEN", self.text)


if __name__ == "__main__":
    unittest.main()
