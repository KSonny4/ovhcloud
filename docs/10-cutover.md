# 10. Cutover handoff (operator-gated, M5)

The repository is Nomad-only; this page is the single ordered procedure
that retires the live retired-plane instance and converges the world on
it. Every step is operator-executed — automation never performs it.
Fast-cut rollback agreed: an OVH snapshot (not a proven restore) is the
backout. Do not start without the snapshot in hand.

## 0. Snapshot (backout)

Take an OVH snapshot of the preserved VPS and record its ID + UTC time.
Only one active snapshot is allowed — this consumes the slot for the
cutover window. If any later step fails closed, restore this snapshot
and stop: the repo work is already committed, the world is unchanged.

## 1. Duplicate Bao entries (new names, verify, keep old)

For every escrow entry, create the Nomad-era name as a COPY (never a
move — the retired plane still reads the old names until step 4):

- R2 four-field entry → `BACKUP_R2`
- machine service-token entry → `EDGE_ACCESS_SERVICE_TOKEN`
- preserved tunnel secret → `EDGE_TUNNEL_SECRET`, per-target tunnel
  entries → `EDGE_TUNNEL_<NAME>`, cold token → `EDGE_TUNNEL_TOKEN`
- provisioning SSH pair → `PROVISION_SSH_*`
- reader policy `backup-r2-reader` (read on `BACKUP_R2` +
  `NOMAD_BOOTSTRAP`); mint a fresh host accessor
- Exact retired spellings (needed to find + delete the old entries in
  step 6): `bao kv list secret/projects/nomad/` enumerates them, or
  `git log --all -S <new-name> --oneline` shows the renaming commit with
  both sides.

Verify readback of every new entry by FIELD NAME only
(`bao kv get -field=<field> <new-path>` must succeed; values never print).

## 2. Bucket + token + state (Cloudflare + Terraform)

1. Create the `ovh-host-backups` bucket (EEUR); copy all objects from the
   retired bucket; verify counts match.
2. Create the `ovh-nomad-machine-verification` service token; escrow the
   pair at the new Bao entry (step 1 names).
3. Rename the tunnel to `nomad-admin` (tunnel ID stable; DNS uses the ID).
4. `terraform init -migrate-state` to the `ovhcloud-nomad/` key after
   updating the ignored local `backend.hcl` (bucket + key).
5. `terraform plan`: expect ONLY the intended pairs (UI DNS + Access
   destroy/create, tunnel rename + ingress update, bucket/token
   re-point). Anything else → stop.

## 3. Apply + provision + verify

1. Authorized `terraform apply`.
2. Uninstall the retired plane on the host; run
   `scripts/provision-nomad.sh` (ACL token escrows to `NOMAD_BOOTSTRAP`).
3. Deploy `jobs/edge-proxy.nomad.hcl`, then workload jobs
   (`jobs/registry.nomad.hcl`, OmniRoute per `docs/07-omniroute.md`).
4. `bash scripts/verify-nomad-live.sh` must print ALL LIVE CHECKS PASS.
5. `scripts/rollback-nomad-snapshot.sh` must print RESTORE_OK (first
   Nomad-era drill; schedules the nightly timer via
   `scripts/schedule-host-backup.sh`).

## 4. Decommission

Only after health holds for a full backup cycle (snapshot + workloads in
R2, timer green):

1. Delete the retired DNS record, Access app, R2 bucket, and service
   token (dashboard/API).
2. Delete the old Bao entries enumerated in step 1.
3. Update the ignored local `backend.hcl`/`imports.tf` or delete them
   (they are regenerated per workflow).
4. Re-run `bash scripts/validate-repository.sh` and
   `bash scripts/rehearse-fresh-environment.sh` — both must pass.

## 5. Cross-repo sweep (M3)

Each owned repo with retired-plane references gets the same treatment:
remove/replace references, direct-merge where permitted, record the merge
SHA in the closeout report. Enumerate candidates with
`gh repo list` + a shallow-clone grep (procedure in the M1 record).
