# Secret rotation and replacement paths

Every derived credential in this platform has a complete replacement path.
Paths marked **proven** were executed live; paths marked **operator** need one
dashboard action each (the corresponding APIs return 403/404 under the
deployment token) and are otherwise fully scripted. No path uses browser login
beyond the named dashboard step, and verification never prints secret values.

## Proven paths

### OpenBao runner credential (proven 2026-09-14)

The exposed root token was replaced without loss of capability:

```bash
export BAO_ADDR=https://secrets.pkubelka.cz
# 1. Mint a revocable root-policy service token (value to file, never printed).
bao token create -policy=root -ttl=768h -renewable -orphan \
  -display-name=ovhcloud-operator-2026-09 -format=json \
  | python3 -c 'import json,os,sys; d=json.load(sys.stdin);
open(os.path.expanduser("~/.vault-token.new"),"w").write(d["auth"]["client_token"])'
chmod 600 ~/.vault-token.new
# 2. Verify capability before trusting it.
VAULT_TOKEN=$(cat ~/.vault-token.new) bao kv get -field=bucket secret/projects/ovhcloud/BACKUP_R2
VAULT_TOKEN=$(cat ~/.vault-token.new) bao kv put -mount=secret projects/ovhcloud/ROTATION_PROBE probe_field=probe_value
VAULT_TOKEN=$(cat ~/.vault-token.new) bao kv metadata delete -mount=secret projects/ovhcloud/ROTATION_PROBE
# 3. Swap and revoke the old accessor (look it up first: bao token lookup).
mv ~/.vault-token.new ~/.vault-token
bao token revoke -accessor <OLD_ACCESSOR>
bao token lookup -accessor <OLD_ACCESSOR>   # must fail
```

Renew before the 768h TTL elapses (`bao token renew`), or re-mint.

### Cloudflare Access service-token secret (proven 2026-09-14, v4 -> v5)

```bash
BAO_ADDR=https://secrets.pkubelka.cz \
NOMAD_LEADER_URL="https://nomad.pkubelka.cz/v1/status/leader" \
bash scripts/ensure-service-token.sh --rotate
```

Expected: `rotated and escrowed.` + `service-token verification: HTTP 200`.
Terraform is unaffected (secret version is ignored in config and state).

### SSH deploy keypair (path implemented, escrow live)

Fresh generation happens inside `scripts/run-remote-provision.sh` when
`PROVISION_SSH_KEY` is absent (ed25519, escrowed to
`PROVISION_SSH_PRIVATE_KEY`/`PROVISION_SSH_PUBLIC_KEY`, public half registered at
the OVH account). Manual equivalent:

```bash
ssh-keygen -t ed25519 -N '' -C ovh-nomad-provisioning -f /tmp/rotated-key
bao kv put -mount=secret projects/ovhcloud/PROVISION_SSH_PRIVATE_KEY value=@/tmp/rotated-key
bao kv put -mount=secret projects/ovhcloud/PROVISION_SSH_PUBLIC_KEY value=@/tmp/rotated-key.pub
# then authorize the public half on the target + register at OVH (runner does both)
```

## Operator paths (one dashboard step each, rest scripted)

### Cloudflare admin API token

Why dashboard: `POST /user/tokens` returns 403 under the deployment token
(User API-Token Write missing), so minting is impossible via API.

1. Dashboard: My Profile -> API Tokens -> view the current token summary,
   Create Token -> Custom token replicating its permissions, Complete.
2. Delete the old token in the same list.
3. Escrow (runner machine):
   `bao kv put -mount=secret projects/ovhcloud/ADMIN_CLOUDFLARE ADMIN_CLOUDFLARE=<new-value>`
4. Verify: `DASHBOARD_LOGIN_URL=... bash scripts/ensure-service-token.sh`
   (exercises the new token end to end) + `terraform plan` converges.

### R2 S3 access keys

Why dashboard: R2 token routes return 404 under the deployment token.

1. Dashboard: R2 -> bucket `ovh-host-backups` -> Manage API Tokens ->
   delete the old key, create Object Read & Write scoped to the bucket.
2. Escrow (all four fields — preflight and `fetch-r2-env.sh` fail closed
   when `endpoint` is absent):
   `bao kv put -mount=secret projects/ovhcloud/BACKUP_R2
   access_key_id=<id> secret_access_key=<secret> bucket=ovh-host-backups
   endpoint=https://<account-id>.r2.cloudflarestorage.com`
3. Verify (nothing to rewire):
   - No control plane holds an R2 copy: the retired plane's `s3_storages`
     destination row was deleted 2026-09-14 after proving zero references.
     Do NOT re-create one — the host timer is the single backup plane, and
     a new destination would reintroduce an at-rest credential.
   - Host: nothing to rewrite — the timer pulls memory-only via
     `fetch-r2-env.sh` on every run, so new keys take effect automatically.
   - `loader_out="$(BAO_ADDR=https://secrets.pkubelka.cz bash scripts/tf-env-from-openbao.sh)" || exit 2`
     then `eval "$loader_out"` and `bash scripts/backup-r2-probe.sh` must
     print `probe ok`. The
     loader exports the endpoint/bucket plus the keypair from the escrowed
     entry, so the probe verifies the full four-field rotation at once.

### OpenBao R2-reader accessor (host-side secret at rest)

The single file on the host is `/root/host-backup/openbao-token` (0600,
policy `backup-r2-reader`: read-only on the R2 entry). To rotate:
1. `bao token create -policy=backup-r2-reader -period=720h -orphan` (operator).
2. Pipe the new `client_token` to the host file (stdin pipe, 0600).
3. `sudo systemctl start host-backup.service` must complete all backups.
4. Revoke the old accessor: `bao token revoke -accessor <old>`. Unrenewed
   periodic tokens also self-expire after their period.

### Cloudflare Tunnel secret (deliberately unchanged)

The escrowed 44-char secret is inert: the live connector authenticates via
`--token-file` (verified in the process table and the 0600 file), and the
secret is only referenced as the Terraform tunnel input. Replacing it means
tunnel replacement surgery (new tunnel ID, DNS CNAME rewiring, Access app
rebinding, connector re-enrollment, old tunnel deletion) with a dashboard
outage window. Execute only if compromise of the secret itself is suspected;
otherwise the documented decision is to leave it.

## Verification invariant

After any rotation: service-token machine check HTTP 200 on the Nomad leader endpoint, human check 302,
`bash scripts/validate-repository.sh` passes, and the rotated credential's
old value is confirmed dead (revoked accessor lookup fails, old API key
returns 403/invalid-token).
