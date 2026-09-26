# OpenBao on Nomad

The canonical private setup is now [KSonny4/secrets-local](https://github.com/KSonny4/secrets-local).
Its `jobs/openbao.nomad.hcl`, `docs/NOMAD.md`, `docs/WORKSTATION.md`, and
`docs/BACKUPS.md` own Bao deployment, recovery, login, lookup, and backup setup.
This repository owns the Nomad host, edge proxy, tunnel, and fleet backups.
The local Bao job is a mirror; use the canonical repository for future changes.

## Verified migration — 2026-09-25

- Operator revised the scope to two HA processes on the existing single host.
  Both are unsealed against the existing Neon PostgreSQL database.
- Public `secrets.pkubelka.cz` uses the Nomad tunnel and Traefik active-instance
  health routing. Pi is stopped with restart policy disabled.
- Pausing the active process proved a public authenticated read through the
  new active instance after 23.59 seconds. Both listeners passed reads afterward.
- Workstation AppRole login no longer depends on Pi. Requested Grafana entries
  and `secret/projects/nomad/NOMAD_BOOTSTRAP` are readable; its `acl_token`
  is the agreed deployment credential, rather than absent `projects/dump/acl`.
- Same-host HA does not cover host or edge-proxy failure. Each restarted process
  still needs two Shamir unseal shares. Fujitsu placement is tracked in
  [secrets-local#2](https://github.com/KSonny4/secrets-local/issues/2).

## Backups

An earlier R2 export was restored into isolated PostgreSQL 18/OpenBao 2.6.2,
unsealed, and read successfully. The project-scoped Neon credential now exists
in Bao. The existing worker still needs read permission for
`secret/data/projects/nomad/OPENBAO_NEON_BACKUP`; recurring execution is pending
that grant and a successful first service run. Follow the canonical backup
installer, not the earlier installer from this implementation branch.

## Recovery

Follow the canonical Nomad runbook. Stop both Nomad instances before starting
and unsealing the non-HA Pi rollback copy. Nomad's encrypted variable holds the
PostgreSQL URL; retain Nomad snapshots and bootstrap material. Never copy
credentials, database dumps, or unseal shares into either repository.
