"""Contract test for the home Nomad client configs (#27, Slice P repo part).

Asserts each file in config/clients/*.hcl mirrors the single inventory data
file config/clients/inventory.json (node pool/class, ZeroTier bind +
advertise IPs, server_join target, reservations), that no client enables
host-path mounts, and that scripts/provision-client.sh is dry-run by
default (behavioral: it exits 0 printing DRY-RUN without --apply).

Stdlib only. No host/SSH/Nomad/Bao contact. Run from the repo root:

    /opt/homebrew/bin/python3.14 -m unittest discover -s tests -p 'test_nomad_clients.py' -v
    # or directly:
    python3 tests/test_nomad_clients.py
"""

from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY = REPO_ROOT / "config" / "clients" / "inventory.json"
CLIENTS_DIR = REPO_ROOT / "config" / "clients"
PROVISION = REPO_ROOT / "scripts" / "provision-client.sh"
SERVER_PROVISION = REPO_ROOT / "scripts" / "provision-nomad.sh"


def _strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


class ClientInventoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inventory = json.loads(INVENTORY.read_text())
        cls.hosts = cls.inventory["hosts"]
        cls.configs = {name: (CLIENTS_DIR / f"{name}.hcl").read_text() for name in cls.hosts}

    def test_inventory_has_required_facts(self) -> None:
        for name, facts in self.hosts.items():
            for key in ("arch", "zerotier_ip", "node_pool", "node_class", "reserved_memory_mb"):
                self.assertIn(key, facts, f"{name}: inventory missing {key}")

    def test_nomad_version_matches_server_provision_default(self) -> None:
        """The version lives in one place (inventory); the server default must agree."""
        match = re.search(r'NOMAD_VERSION="\$\{NOMAD_VERSION:-(.+?)\}"', SERVER_PROVISION.read_text())
        self.assertIsNotNone(match, "could not find NOMAD_VERSION default in provision-nomad.sh")
        assert match is not None
        self.assertEqual(self.inventory["nomad_version"], match.group(1))

    def test_node_pool_and_class(self) -> None:
        for name, facts in self.hosts.items():
            text = _strip_comments(self.configs[name])
            self.assertIn(f'node_pool  = "{facts["node_pool"]}"', text, f"{name}: node_pool drift")
            self.assertIn(f'node_class = "{facts["node_class"]}"', text, f"{name}: node_class drift")
            self.assertEqual(facts["node_pool"], "home", f"{name}: pool must be home")

    def test_zerotier_bind_and_advertise(self) -> None:
        for name, facts in self.hosts.items():
            text = _strip_comments(self.configs[name])
            ip = facts["zerotier_ip"]
            self.assertIn(f'bind_addr  = "{ip}"', text, f"{name}: bind_addr must be the ZeroTier IP")
            for port in ("4646", "4647", "4648"):
                self.assertIn(f"{ip}:{port}", text, f"{name}: advertise must use the ZeroTier IP")

    def test_server_join_mirrors_inventory(self) -> None:
        expected = self.inventory["server_join_ip"]
        for name in self.hosts:
            text = _strip_comments(self.configs[name])
            match = re.search(r"retry_join\s*=\s*\[(.*?)\]", text, re.DOTALL)
            self.assertIsNotNone(match, f"{name}: server_join.retry_join missing")
            assert match is not None
            self.assertIn(f'"{expected}"', match.group(1), f"{name}: retry_join must mirror inventory")

    def test_reservations_present(self) -> None:
        for name, facts in self.hosts.items():
            text = _strip_comments(self.configs[name])
            match = re.search(r"reserved\s*\{\s*memory\s*=\s*(\d+)", text)
            self.assertIsNotNone(match, f"{name}: reserved memory block missing")
            assert match is not None
            self.assertEqual(int(match.group(1)), facts["reserved_memory_mb"], f"{name}: reservation drift")
        self.assertGreaterEqual(self.hosts["pi"]["reserved_memory_mb"], 2048, "Pi must keep >= 2 GB")

    def test_no_bind_mounts(self) -> None:
        for name in self.hosts:
            text = _strip_comments(self.configs[name])
            self.assertNotIn("host_volume", text, f"{name}: host volumes must stay off")
            match = re.search(r"volumes\s*\{\s*enabled\s*=\s*(\w+)", text)
            self.assertIsNotNone(match, f"{name}: docker volumes block missing")
            assert match is not None
            self.assertEqual(match.group(1), "false", f"{name}: docker volumes must be disabled")


class ProvisionClientTest(unittest.TestCase):
    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(PROVISION), *args],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            timeout=120,
        )

    def test_dry_run_by_default(self) -> None:
        for host in ("pi", "fujitsu"):
            proc = self._run("--host", host)
            self.assertEqual(proc.returncode, 0, f"{host}: default run must succeed without changes")
            self.assertIn("DRY-RUN", proc.stdout, f"{host}: default run must print DRY-RUN plan")

    def test_dry_run_names_arch_binary(self) -> None:
        arch = {"pi": "arm64", "fujitsu": "amd64"}
        for host, want in arch.items():
            proc = self._run("--host", host)
            self.assertIn(f"linux_{want}.zip", proc.stdout, f"{host}: must fetch the {want} binary")

    def test_host_required(self) -> None:
        proc = self._run()
        self.assertNotEqual(proc.returncode, 0, "missing --host must fail")
        proc = self._run("--host", "ovh")
        self.assertNotEqual(proc.returncode, 0, "unknown host must fail")


if __name__ == "__main__":
    unittest.main()
