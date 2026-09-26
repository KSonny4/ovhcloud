import importlib.util
import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch


SCRIPT = Path(__file__).parents[1] / "backup-openbao-db.py"
SPEC = importlib.util.spec_from_file_location("backup_openbao_db", SCRIPT)
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


class BackupOpenBaoDbTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = {
            "NEON_API_KEY": "api-key",
            "NEON_PROJECT_ID": "project-id",
            "NEON_PARENT_BRANCH_ID": "br-main",
            "NEON_DATABASE": "openbao",
            "NEON_USERNAME": "openbao",
            "NEON_PASSWORD": "db-password",
            "R2_ENDPOINT": "https://r2.example",
            "R2_BUCKET": "private-backups",
            "AWS_ACCESS_KEY_ID": "access-key",
            "AWS_SECRET_ACCESS_KEY": "secret-key",
        }

    @patch.dict("os.environ", {}, clear=True)
    def test_missing_environment_fails_closed(self):
        with self.assertRaisesRegex(backup.BackupError, "NEON_API_KEY"):
            backup.load_config()

    def test_refuses_to_export_sibling_database(self):
        env = {**self.env, "NEON_DATABASE": "neondb"}
        with self.assertRaisesRegex(backup.BackupError, "restricted to the openbao database"):
            backup.load_config(env)

    @patch.object(backup, "prune_backups")
    @patch.object(backup, "upload_and_verify")
    @patch.object(backup, "run_pg_dump")
    @patch.object(backup, "wait_for_endpoint")
    @patch.object(backup, "api_request")
    def test_success_dumps_only_openbao_and_deletes_branch_before_manifest(
        self, api_request, wait_for_endpoint, run_pg_dump, upload_and_verify, prune
    ):
        config = backup.load_config(self.env)
        dump_file = Path(self.temp.name) / "openbao.dump"
        dump_file.write_bytes(b"opaque postgres dump")
        api_request.side_effect = [
            {"branch": {"id": "br-temp"}, "endpoints": [{"host": "ep-temp.neon.tech"}]},
            {},
        ]
        run_pg_dump.return_value = dump_file
        upload_and_verify.side_effect = lambda _config, _key, source: (
            {"bytes": dump_file.stat().st_size, "sha256": "a" * 64}
            if not isinstance(source, dict)
            else {"bytes": 100, "sha256": "b" * 64}
        )

        result = backup.create_backup(config, now="2026-09-25T02:00:00Z")

        self.assertEqual(result["database"], "openbao")
        self.assertEqual(result["bytes"], len(b"opaque postgres dump"))
        self.assertEqual(api_request.call_args_list[-1], call(config, "DELETE", "/projects/project-id/branches/br-temp"))
        manifest = upload_and_verify.call_args_list[-1].args[2]
        self.assertEqual(manifest["branch_deleted"], True)
        self.assertEqual(manifest["sha256"], result["sha256"])
        self.assertEqual(api_request.call_count, 2)
        self.assertEqual(upload_and_verify.call_count, 2)
        prune.assert_called_once_with(config)

    @patch.object(backup, "upload_and_verify")
    @patch.object(backup, "run_pg_dump", side_effect=backup.BackupError("pg_dump failed"))
    @patch.object(backup, "wait_for_endpoint")
    @patch.object(backup, "api_request")
    def test_dump_failure_deletes_temporary_branch_and_publishes_no_manifest(
        self, api_request, wait_for_endpoint, run_pg_dump, upload_and_verify
    ):
        config = backup.load_config(self.env)
        api_request.return_value = {
            "branch": {"id": "br-temp"},
            "endpoints": [{"host": "ep-temp.neon.tech"}],
        }

        with self.assertRaisesRegex(backup.BackupError, "pg_dump failed"):
            backup.create_backup(config, now="2026-09-25T02:00:00Z")

        self.assertEqual(api_request.call_count, 2)
        self.assertEqual(api_request.call_args_list[-1], call(config, "DELETE", "/projects/project-id/branches/br-temp"))
        upload_and_verify.assert_not_called()

    @patch.object(backup, "prune_backups")
    @patch.object(backup, "upload_and_verify")
    @patch.object(backup, "run_pg_dump")
    @patch.object(backup, "wait_for_endpoint")
    @patch.object(backup, "api_request")
    def test_failed_branch_cleanup_prevents_complete_manifest(
        self, api_request, wait_for_endpoint, run_pg_dump, upload_and_verify, prune
    ):
        config = backup.load_config(self.env)
        dump_file = Path(self.temp.name) / "openbao.dump"
        dump_file.write_bytes(b"dump")
        api_request.side_effect = [
            {"branch": {"id": "br-temp"}, "endpoints": [{"host": "ep-temp.neon.tech"}]},
            backup.BackupError("branch cleanup failed"),
        ]
        run_pg_dump.return_value = dump_file

        with self.assertRaisesRegex(backup.BackupError, "branch cleanup failed"):
            backup.create_backup(config, now="2026-09-25T02:00:00Z")

        self.assertEqual(upload_and_verify.call_count, 1)
        self.assertTrue(upload_and_verify.call_args.args[1].endswith(".dump"))
        prune.assert_not_called()

    def test_r2_upload_checks_object_size_and_readback_checksum(self):
        local = Path(self.temp.name) / "openbao.dump"
        local.write_bytes(b"test backup bytes")
        bin_dir = Path(self.temp.name) / "bin"
        bin_dir.mkdir()
        aws = bin_dir / "aws"
        aws.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, shutil, sys\n"
            "args = sys.argv[1:]\n"
            "idx = args.index('s3') if 's3' in args else args.index('s3api')\n"
            "op = args[idx + 1]\n"
            "store = pathlib.Path(__file__).parent / 'remote-object'\n"
            "if op == 'cp': shutil.copyfile(args[idx + 2], store)\n"
            "elif op == 'head-object': print(store.stat().st_size)\n"
            "elif op == 'get-object':\n"
            " shutil.copyfile(store, args[-1])\n"
            " if (pathlib.Path(__file__).parent / 'corrupt').exists():\n"
            "  with open(args[-1], 'ab') as f: f.write(b'x')\n"
            "else: raise SystemExit(2)\n",
            encoding="utf-8",
        )
        aws.chmod(0o700)
        config = backup.load_config(self.env)

        with patch.dict(
            os.environ,
            {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
            },
        ):
            verified = backup.upload_and_verify(config, "openbao/test.dump", local)
            self.assertEqual(verified["bytes"], len(b"test backup bytes"))
            self.assertEqual(verified["sha256"], hashlib.sha256(b"test backup bytes").hexdigest())
            (bin_dir / "corrupt").touch()
            with self.assertRaisesRegex(backup.BackupError, "checksum"):
                backup.upload_and_verify(config, "openbao/corrupt.dump", local)


if __name__ == "__main__":
    unittest.main()
