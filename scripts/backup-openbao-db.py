#!/usr/bin/env python3
"""Create a Neon point-in-time export of OpenBao's database and verify it in R2."""

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


RETENTION_DAYS = 14
API_BASE = "https://console.neon.tech/api/v2"


class BackupError(RuntimeError):
    pass


def load_config(source=None):
    env = dict(os.environ if source is None else source)
    required = (
        "NEON_API_KEY",
        "NEON_PROJECT_ID",
        "NEON_PARENT_BRANCH_ID",
        "NEON_DATABASE",
        "NEON_USERNAME",
        "NEON_PASSWORD",
        "R2_ENDPOINT",
        "R2_BUCKET",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
    )
    missing = [key for key in required if not env.get(key)]
    if missing:
        raise BackupError("missing required environment fields: " + ", ".join(missing))
    if not re.fullmatch(r"[a-z0-9-]{1,60}", env["NEON_PROJECT_ID"]):
        raise BackupError("invalid Neon project ID format")
    if not re.fullmatch(r"br-[a-z0-9-]+", env["NEON_PARENT_BRANCH_ID"]):
        raise BackupError("invalid Neon parent branch ID format")
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", env["NEON_DATABASE"]):
        raise BackupError("invalid database name format")
    if env["NEON_DATABASE"] != "openbao":
        raise BackupError("this backup is restricted to the openbao database")
    env.setdefault("BACKUP_PREFIX", "openbao")
    env.setdefault("PG_DUMP_BIN", "/usr/lib/postgresql/18/bin/pg_dump")
    env.setdefault("PG_ISREADY_BIN", "/usr/lib/postgresql/18/bin/pg_isready")
    return env


def api_request(config, method, path, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        API_BASE + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Bearer " + config["NEON_API_KEY"],
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        raise BackupError(f"Neon API {method} failed with HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError):
        raise BackupError(f"Neon API {method} request failed") from None
    if not payload:
        return {}
    try:
        return json.loads(payload)
    except (TypeError, json.JSONDecodeError):
        raise BackupError("Neon API returned invalid JSON") from None


def wait_for_endpoint(config, host):
    env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}
    env["PGPASSWORD"] = config["NEON_PASSWORD"]
    env["PGSSLMODE"] = "require"
    for attempt in range(60):
        result = subprocess.run(
            [
                config["PG_ISREADY_BIN"],
                "--quiet",
                "--host",
                host,
                "--port",
                "5432",
                "--username",
                config["NEON_USERNAME"],
                "--dbname",
                config["NEON_DATABASE"],
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode == 0:
            return
        if attempt < 59:
            time.sleep(2)
    raise BackupError("temporary Neon compute did not become ready")


def run_pg_dump(config, host, destination):
    env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}
    env["PGPASSWORD"] = config["NEON_PASSWORD"]
    env["PGSSLMODE"] = "require"
    try:
        subprocess.run(
            [
                config["PG_DUMP_BIN"],
                "--format=custom",
                "--no-password",
                "--host",
                host,
                "--port",
                "5432",
                "--username",
                config["NEON_USERNAME"],
                "--dbname",
                config["NEON_DATABASE"],
                "--file",
                str(destination),
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
    except (subprocess.CalledProcessError, OSError):
        raise BackupError("pg_dump failed") from None
    if not destination.is_file() or destination.stat().st_size == 0:
        raise BackupError("pg_dump produced an empty backup")
    return destination


def _aws(config, *args):
    command = ["aws", "--endpoint-url", config["R2_ENDPOINT"], *args]
    env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}
    env.update(
        AWS_ACCESS_KEY_ID=config["AWS_ACCESS_KEY_ID"],
        AWS_SECRET_ACCESS_KEY=config["AWS_SECRET_ACCESS_KEY"],
        AWS_DEFAULT_REGION=os.environ.get("AWS_DEFAULT_REGION", "auto"),
    )
    try:
        return subprocess.run(
            command,
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )
    except (subprocess.CalledProcessError, OSError):
        raise BackupError("R2 operation failed") from None


def upload_and_verify(config, key, source):
    cleanup = None
    if isinstance(source, dict):
        cleanup = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False)
        json.dump(source, cleanup, sort_keys=True, separators=(",", ":"))
        cleanup.write("\n")
        cleanup.close()
        local = Path(cleanup.name)
    else:
        local = Path(source)
    try:
        expected_bytes = local.stat().st_size
        expected_sha = _sha256(local)
        remote = f"s3://{config['R2_BUCKET']}/{key}"
        _aws(config, "s3", "cp", str(local), remote, "--only-show-errors")
        head = _aws(
            config,
            "s3api",
            "head-object",
            "--bucket",
            config["R2_BUCKET"],
            "--key",
            key,
            "--query",
            "ContentLength",
            "--output",
            "text",
        )
        try:
            actual_bytes = int(head.stdout.strip())
        except ValueError:
            raise BackupError("R2 returned an invalid object size") from None
        if actual_bytes != expected_bytes:
            raise BackupError("R2 object size does not match the local backup")
        with tempfile.TemporaryDirectory(prefix="openbao-r2-verify-") as temp_dir:
            downloaded = Path(temp_dir) / "verify"
            _aws(
                config,
                "s3api",
                "get-object",
                "--bucket",
                config["R2_BUCKET"],
                "--key",
                key,
                str(downloaded),
            )
            if downloaded.stat().st_size != expected_bytes or _sha256(downloaded) != expected_sha:
                raise BackupError("R2 object checksum does not match the local backup")
        return {"bytes": expected_bytes, "sha256": expected_sha}
    finally:
        if cleanup is not None:
            os.unlink(cleanup.name)


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prune_backups(config, now=None):
    cutoff = (now or dt.datetime.now(dt.timezone.utc)) - dt.timedelta(days=RETENTION_DAYS)
    prefix = config["BACKUP_PREFIX"].strip("/") + "/"
    result = _aws(
        config,
        "s3api",
        "list-objects-v2",
        "--bucket",
        config["R2_BUCKET"],
        "--prefix",
        prefix,
        "--output",
        "json",
    )
    try:
        contents = json.loads(result.stdout or "{}").get("Contents", [])
    except json.JSONDecodeError:
        raise BackupError("R2 returned an invalid object listing") from None
    for item in contents:
        key = item.get("Key", "")
        modified = item.get("LastModified")
        if not key.startswith(prefix) or not key.endswith((".dump", ".json")) or not modified:
            continue
        try:
            uploaded = dt.datetime.fromisoformat(modified.replace("Z", "+00:00"))
        except ValueError:
            continue
        if uploaded < cutoff:
            _aws(config, "s3api", "delete-object", "--bucket", config["R2_BUCKET"], "--key", key)


def create_backup(config, now=None):
    instant = now or dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    stamp = instant.replace(":", "").replace("-", "").replace("T", "T").replace("Z", "Z")
    branch_name = f"openbao-backup-{stamp}-{uuid.uuid4().hex[:8]}"
    prefix = config["BACKUP_PREFIX"].strip("/")
    object_key = f"{prefix}/{instant[:10].replace('-', '/')}/{branch_name}.dump"
    branch_id = None
    dump_info = None
    with tempfile.TemporaryDirectory(prefix="openbao-db-backup-") as temp_dir:
        dump_path = Path(temp_dir) / "openbao.dump"
        try:
            response = api_request(
                config,
                "POST",
                f"/projects/{config['NEON_PROJECT_ID']}/branches",
                {
                    "branch": {
                        "name": branch_name,
                        "parent_id": config["NEON_PARENT_BRANCH_ID"],
                        "parent_timestamp": instant,
                    },
                    "endpoints": [{"type": "read_write"}],
                },
            )
            branch_id = response.get("branch", {}).get("id")
            endpoints = response.get("endpoints", [])
            host = endpoints[0].get("host") if endpoints else None
            if not branch_id or not host:
                raise BackupError("Neon did not return a branch ID and compute host")
            wait_for_endpoint(config, host)
            run_pg_dump(config, host, dump_path)
            dump_info = upload_and_verify(config, object_key, dump_path)
        finally:
            if branch_id:
                api_request(config, "DELETE", f"/projects/{config['NEON_PROJECT_ID']}/branches/{branch_id}")

        manifest = {
            "format": 1,
            "database": config["NEON_DATABASE"],
            "project_id": config["NEON_PROJECT_ID"],
            "parent_branch_id": config["NEON_PARENT_BRANCH_ID"],
            "branch_id": branch_id,
            "parent_timestamp": instant,
            "branch_deleted": True,
            "object_key": object_key,
            **dump_info,
        }
        manifest_key = object_key[:-5] + ".json"
        upload_and_verify(config, manifest_key, manifest)

    prune_backups(config)
    return {**manifest, "manifest_key": manifest_key}


def main():
    try:
        config = load_config()
        result = create_backup(config)
    except BackupError as error:
        print(f"BACKUP_FAILED reason={error}", file=sys.stderr)
        return 1
    print(
        "BACKUP_OK "
        f"object={result['object_key']} bytes={result['bytes']} "
        f"sha256={result['sha256']} branch_deleted=true retention_days={RETENTION_DAYS}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
