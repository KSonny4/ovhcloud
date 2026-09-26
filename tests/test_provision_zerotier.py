"""Contract test for scripts/provision-zerotier.sh (#27, OVH ZeroTier join).

Asserts the script parses, is dry-run by default (changes nothing, exit 0),
takes the network ID from config/clients/inventory.json (never hardcoded),
names the manual Central-authorize owner step, and never touches Nomad, ufw
or Docker.

Stdlib only. No host/SSH/Nomad/Bao/ZeroTier contact. Run from the repo root:

    /opt/homebrew/bin/python3.14 -m unittest discover -s tests -v
    # or directly:
    python3 tests/test_provision_zerotier.py
"""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY = REPO_ROOT / "config" / "clients" / "inventory.json"
PROVISION_ZT = REPO_ROOT / "scripts" / "provision-zerotier.sh"


def _strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


class ProvisionZerotierTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inventory = json.loads(INVENTORY.read_text())
        cls.source = PROVISION_ZT.read_text()
        cls.code = _strip_comments(cls.source)

    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(PROVISION_ZT), *args],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            timeout=120,
        )

    def test_script_parses(self) -> None:
        proc = subprocess.run(
            ["bash", "-n", str(PROVISION_ZT)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, f"bash -n failed: {proc.stderr}")

    def test_dry_run_by_default(self) -> None:
        for args in ((), ("--dry-run",)):
            proc = self._run(*args)
            self.assertEqual(proc.returncode, 0, f"{args}: default run must succeed without changes")
            self.assertIn("DRY-RUN", proc.stdout, f"{args}: default run must print a DRY-RUN plan")

    def test_dry_run_makes_no_changes(self) -> None:
        proc = self._run()
        # Dry-run is pure print: plan lines only, nothing applied.
        self.assertEqual(proc.stderr, "")
        for marker in ("NETWORK_OK", "ALREADY_JOINED", "node ID:", "already installed"):
            self.assertNotIn(marker, proc.stdout, "dry-run must not apply anything")
        self.assertIn("zerotier-cli join", proc.stdout, "dry-run must describe the join it would do")

    def test_network_id_comes_from_inventory(self) -> None:
        network_id = self.inventory["zerotier_network_id"]
        self.assertRegex(network_id, r"^[0-9a-f]{16}$", "inventory network ID must be 16 hex digits")
        self.assertIn('["zerotier_network_id"]', self.source, "script must read the network ID from inventory")
        self.assertNotIn(network_id, self.code, "network ID must not be hardcoded in the script")
        proc = self._run()
        self.assertIn(network_id, proc.stdout, "dry-run must name the inventory network ID")

    def test_names_manual_authorize_step(self) -> None:
        proc = self._run()
        self.assertIn("MANUAL", proc.stdout, "dry-run must state the manual Central-authorize owner step")
        self.assertIn("ZeroTier Central", proc.stdout)

    def test_touches_neither_nomad_nor_firewall_nor_docker(self) -> None:
        for word in ("nomad", "ufw", "docker", "iptables", "4647", "4648"):
            self.assertNotIn(word, self.code.lower(), f"script code must not touch {word}")

    def test_help_and_bad_args(self) -> None:
        proc = self._run("--help")
        self.assertEqual(proc.returncode, 0, "--help must succeed")
        proc = self._run("--host", "pi")
        self.assertNotEqual(proc.returncode, 0, "unknown argument must fail")


if __name__ == "__main__":
    unittest.main()
