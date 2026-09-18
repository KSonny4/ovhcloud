# Evidence archive (retired control plane)

These JSON snapshots record the live-state proofs of the retired
Docker-based deployment control plane (removed 2026-09-18; the fleet now
runs on Nomad — see `docs/03-nomad.md`).

They were moved here from `docs/` untouched so the historical record is
preserved without polluting the active runbook, which is Nomad-only.
Do not update them; new proofs belong in `docs/` under the Nomad-era
filenames.

- `live-proofs.json`, `live-proofs-stages.json`, `live-reconciliation.json`
  — last live-state captures of the retired plane.
- `rehearsal-report.latest.json` — last fresh-environment rehearsal report
  of the retired plane.
