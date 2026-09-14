#!/usr/bin/env bash
# Verify Coolify onboarding noninteractively (operator side, read-only).
#
# Proves the instance state that the dashboard onboarding wizard establishes,
# with no dashboard session: admin user present, localhost server registered
# and reachable (unreachable_count == 0), at least one project with at least
# one environment. Fails closed naming the missing piece. Reads only — the
# coolify-db database is never written.
#
# Usage:
#   bash scripts/verify-coolify-onboarding.sh [--ssh-key PATH] [--host USER@HOST] [--admin-email ADDR]
set -euo pipefail

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --ssh-key=*) ssh_key="${1#--ssh-key=}"; shift ;;
    --host) host="$2"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    --admin-email) admin_email="$2"; shift 2 ;;
    --admin-email=*) admin_email="${1#--admin-email=}"; shift ;;
    -h|--help) echo 'usage: verify-coolify-onboarding.sh [--ssh-key PATH] [--host USER@HOST] [--admin-email ADDR]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
ssh_key="${ssh_key:-$HOME/.ssh/ovh_coolify_ed25519}"
host="${host:-ubuntu@57.129.155.203}"
admin_email="${admin_email:-ksonny4@gmail.com}"
[ -f "$ssh_key" ] || { echo "SSH key not found: ${ssh_key}." >&2; exit 2; }

probe="$(mktemp /tmp/coolify-onboard-probe.XXXXXX.py)"
trap 'rm -f "$probe"' EXIT
cat >"$probe" <<'PYEOF'
import json, subprocess, os, sys
e = dict(x.split("=", 1) for x in json.load(sys.stdin) if "=" in x)
o = dict(os.environ)
o["PGPASSWORD"] = e["DB_PASSWORD"]
u = e["DB_USERNAME"]
fails = []


def q(s):
    r = subprocess.run(["docker", "exec", "coolify-db", "psql", "-U", u,
                        "-d", "coolify", "-tAc", s],
                       capture_output=True, text=True, env=o)
    return (r.stdout or "").strip()


def check(name, cond, detail=""):
    print(("ONBOARD_OK " if cond else "ONBOARD_MISS ") + name + ("" if cond else " " + detail))
    if not cond:
        fails.append(name)


want_admin = os.environ.get("WANT_ADMIN_EMAIL", "ksonny4@gmail.com")
admin = q("SELECT email FROM users;")
check("admin-user", admin == want_admin, "users=" + q("SELECT count(*) FROM users;"))
check("localhost-server", q("SELECT count(*) FROM servers WHERE name='localhost';") == "1", "no localhost row")
check("localhost-reachable", q("SELECT unreachable_count FROM servers WHERE name='localhost';") == "0", "unreachable")
projs = [l for l in q("SELECT id || '/' || name FROM projects;").splitlines() if l]
check("project-exists", len(projs) >= 1, "no projects")
envs = [l for l in q("SELECT project_id || '/' || name FROM environments;").splitlines() if l]
check("environment-exists", len(envs) >= 1, "no environments")
for p in projs:
    print("ONBOARD project: " + p)
for ev in envs:
    print("ONBOARD environment: " + ev)
sys.exit(1 if fails else 0)
PYEOF
remote_probe="/tmp/coolify-onboard-probe-$(date +%s).py"
scp -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$probe" "${host}:${remote_probe}" >/dev/null || { echo 'probe staging failed.' >&2; exit 2; }
ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$host" \
  "docker inspect coolify --format '{{json .Config.Env}}' 2>/dev/null | WANT_ADMIN_EMAIL='$admin_email' python3 '$remote_probe'; rm -f '$remote_probe'" 2>/dev/null > /tmp/coolify-onboard-out.txt || ssh_rc=$?
cat /tmp/coolify-onboard-out.txt
if [ "${ssh_rc:-0}" -ne 0 ]; then
  echo "onboarding probe transport failed (SSH exit ${ssh_rc}); refusing to report success." >&2
  rm -f /tmp/coolify-onboard-out.txt
  exit 2
fi
if [ ! -s /tmp/coolify-onboard-out.txt ]; then
  echo 'onboarding probe returned no output; refusing to report success.' >&2
  rm -f /tmp/coolify-onboard-out.txt
  exit 2
fi
if ! grep -q ONBOARD_OK /tmp/coolify-onboard-out.txt; then
  echo 'onboarding probe returned no passing checks; refusing to report success.' >&2
  rm -f /tmp/coolify-onboard-out.txt
  exit 2
fi
if grep -q ONBOARD_MISS /tmp/coolify-onboard-out.txt; then
  echo 'onboarding incomplete (fail closed).' >&2
  rm -f /tmp/coolify-onboard-out.txt
  exit 2
fi
rm -f /tmp/coolify-onboard-out.txt
trap - EXIT
rm -f "$probe"
echo 'onboarding verified: admin + reachable localhost + project/environment, no dashboard session.'
