# 07. OmniRoute (RETIRED 2026-09-19)

OmniRoute was decommissioned: the workload never ran as a Nomad job (no
jobspec was ever committed; `omni.`/`omniroute.` had no backing service)
and is not migrated to the new host.

- `omni.` + `omniroute.` DNS and tunnel ingress are removed from
  `infra/terraform/main.tf`; the live records are deleted on the next
  authorized apply — until then they 404 via the edge proxy.
- `secret/projects/nomad/OMNIROUTE` is no longer consumed by any script;
  delete the entry once the cutover verifies healthy.
- The generic app-secret escrow machinery (`lib/escrowed-app-envs`,
  `fetch-app-secrets.sh`) is unchanged; its self-test fixtures use an
  example path, not a live entry.

History lives in git log.
