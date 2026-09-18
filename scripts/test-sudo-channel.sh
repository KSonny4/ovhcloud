#!/usr/bin/env bash
# Clean-host regression test for the first-stage sudo boundary.
#
# Reproduces the auditor-found chicken-and-egg on a DISPOSABLE Ubuntu
# 26.04 container (sudo-rs, the same sudo as the preserved host and fresh
# 26.04 installs: NOPASSWD without SETENV, `sudo -E` ignored). Without the
# step-0 channel policy, `sudo -E` strips the stage blob
# (BOOTSTRAP_TARGET_HOST lost, bootstrap would refuse); with the policy
# installed exactly as run-remote-provision.sh step 0 does it, the blob
# survives. (Classic sudo on 24.04 honors -E, so the 26.04 pin is what
# makes this a true regression test.) The container is destroyed on every
# exit path.
#
# Runs against the preserved host's Docker (orchestration only, no host
# mutation): [--ssh-key PATH] [--host USER@HOST]
set -euo pipefail

ssh_key="${HOME}/.ssh/ovh_nomad_ed25519"
host='ubuntu@57.129.155.203'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --ssh-key=*) ssh_key="${1#--ssh-key=}"; shift ;;
    --host) host="$2"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    -h|--help) echo 'usage: test-sudo-channel.sh [--ssh-key PATH] [--host USER@HOST]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo_root="$(cd "$(dirname "$0")" && pwd)"
channel_file="$repo_root/lib/sudoers-automation-env"
[ -f "$channel_file" ] || { echo 'channel content missing.' >&2; exit 2; }
[ -f "$ssh_key" ] || { echo "SSH key not found: ${ssh_key}." >&2; exit 2; }
ssh="ssh -i $ssh_key -o BatchMode=yes -o ConnectTimeout=20 $host"

# Fresh userland, fresh sudo config (NOPASSWD, no SETENV, no channel).
ctr="sudochannel-test-$$"
sudo_impl="$($ssh 'sudo -V 2>&1 | head -n1')"
log() { printf '%s\n' "$*"; }
log "host sudo implementation: ${sudo_impl} (container pins ubuntu:26.04/sudo-rs to match)."
ready_out="$($ssh "docker run -d --name $ctr ubuntu:26.04 sleep 600 >/dev/null && docker exec $ctr bash -c 'apt-get update -qq && apt-get install -y -qq sudo >/dev/null 2>&1 && (id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu) && echo \"ubuntu ALL=(ALL) NOPASSWD:ALL\" >/etc/sudoers.d/ubuntu-nopasswd && chmod 440 /etc/sudoers.d/ubuntu-nopasswd && sudo -U ubuntu -l >/dev/null && echo CONTAINER_READY'" 2>&1 | tail -n1)"
printf '%s' "$ready_out" | grep -q CONTAINER_READY || { echo "clean container setup failed: ${ready_out}." >&2; exit 1; }
cleanup() { $ssh "docker rm -f $ctr >/dev/null 2>&1 || true"; }
trap cleanup EXIT
# NOTE: $ctr expands locally (container name), \$BLOB_* must reach the
# container: single-quoted remote layers protect them; only the outer
# docker-exec argument is double-quoted for the local ctr expansion.
# The probe uses BOOTSTRAP_TARGET_HOST itself (the exact first-stage
# variable): the channel policy preserves listed vars and still strips
# everything else, so an unlisted marker would prove nothing.
prove() { $ssh "docker exec --user ubuntu $ctr bash -c 'export BOOTSTRAP_TARGET_HOST=freshhost; sudo -E bash -c '\''echo stripped=\${BOOTSTRAP_TARGET_HOST:-GONE}'\'''"; }
echo "--- without channel policy (must reproduce the bug: stripped=GONE):"
without="$(prove)"
printf '%s\n' "$without" | grep -q 'stripped=GONE' || { echo "unexpected: bootstrap var survived without policy: $without." >&2; exit 1; }
echo 'reproduced: sudo -E strips the blob on a clean host (bootstrap would refuse).'
# Step 0 exactly as the runner does it (same content file, same tee/chmod/visudo).
scp -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$channel_file" "$host:/tmp/99-automation-env" >/dev/null \
  || { echo 'channel staging failed.' >&2; exit 2; }
$ssh "docker cp /tmp/99-automation-env $ctr:/tmp/99-automation-env && rm -f /tmp/99-automation-env && docker exec $ctr bash -c 'cp /tmp/99-automation-env /etc/sudoers.d/99-automation-env && chmod 440 /etc/sudoers.d/99-automation-env && visudo -cf /etc/sudoers.d/99-automation-env'" 2>&1 | tail -n1
echo "--- with channel policy (must preserve: stripped=freshhost):"
with="$(prove)"
printf '%s\n' "$with" | grep -q 'stripped=freshhost' || { echo "channel failed to preserve bootstrap var: $with." >&2; exit 1; }
echo 'CHANNEL_OK: step-0 policy carries the stage blob across sudo -E on a clean host.'
