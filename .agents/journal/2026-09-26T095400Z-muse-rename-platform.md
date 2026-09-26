# Journal — absorb NomadSetup agent config (R1 PR)

- Start: 2026-09-26T09:54Z (UTC), agent: muse (lane R-a, writer for platform + worktrees).
- Task: GitHub issue KSonny4/platform#15 (Slice R: rename ovhcloud → platform, absorb and deprecate NomadSetup); this file covers the feat/absorb-nomadsetup-15 PR only.
- Repo: `KSonny4/platform`; worktree/branch: `~/git_projects/platform/.worktrees/absorb-nomadsetup-15`, branch `feat/absorb-nomadsetup-15` from `origin/master` @ b7e26d3.
- Source `~/git_projects/NomadSetup` treated as READ-ONLY (only read + `cp` from; never modified).
- Shared guidance: repo-local AGENTS.md/CONTEXT.md; engineering-guidance standards/agent-journal.md (journal format); Cognee recall "ovhcloud NomadSetup platform repo rename" at session start.

## Changes

- `config/nomad.hcl` (new): absorbed from NomadSetup `config/nomad.hcl`, now the single committed Nomad agent config. Keeps the dump host volumes (`dump-dev-media/prod-media`, `dump-pg-dev/prod`), the Docker driver `auth { config = /opt/nomad/docker-auth.json }` block, and documents the provision-script gossip mechanism (separate 0600 `/etc/nomad.d/gossip.hcl` from `NOMAD_GOSSIP_KEY`, never committed). Header notes the installer + secrecy contract. One in-file touch-up vs source: the `registry-data` comment now points at `scripts/provision-nomad.sh` instead of the dropped `scripts/install-nomad.sh`.
- `scripts/provision-nomad.sh`: installs the committed file (`../config/nomad.hcl` in a checkout, `./nomad.hcl` flat copy when shipped remotely) with `install -m 600` instead of generating its own heredoc copy; creates all declared volume dirs and `chown 999:999` the postgres ones (per the config's own contract). Gossip-file, unit, leadership-wait and ACL-bootstrap sections unchanged. Secret handling unchanged (values never printed except the single bootstrap escrow line).
- `scripts/run-remote-provision.sh`: ships `$repo_root/config/nomad.hcl` flat into the remote stage dir (`scp` list + comment); remote cleanup already removes the stage dir.
- `scripts/registry-chunked-push.py` (new): verbatim copy of NomadSetup's (md5-identical, py_compile ok); not previously present under platform `scripts/`.
- `docs/03-nomad.md`: new section 6 "Absorbed from NomadSetup" with the old-path → new-path/dropped mapping.
- Deliberately NOT copied: `scripts/install-nomad.sh`, `scripts/bootstrap-acl.sh`, `scripts/verify.sh`, `config/nomad.service` (duplicates of provision/verify scripts), `jobs/registry.nomad.hcl` (platform's `jobs/registry.nomad.hcl` is the evolved copy).
- Secrets: source config contained no literal secret (verified by grep for encrypt/secret/token/password: no match), so no placeholder substitution was needed. No secret values in code, commits, or this journal.

## Checks

- `bash -n` on both changed shell scripts: pass.
- `python3 -m py_compile` on the copied script: pass.
- `git diff --check`: clean (re-run at commit time).
- `bash scripts/validate-repository.sh` (repo's own suite: validate-iac.py, bash -n + shellcheck over all scripts, retired-plane gate, git diff --check, terraform fmt/init/validate, graft check): PASS — `Repository validation passed.` on 2026-09-26T~09:58Z in this worktree.
- Offline `nomad` agent-config validation: SKIPPED — this lane forbids all `nomad`/`bao`/ssh commands, so no local CLI validation was possible; the HCL is a comment-only delta over a file that has been live on the host since 2026-09-18.

## Status

- Work in progress in worktree; commit + push + PR opening follow under this lane. DO NOT MERGE — orchestrator reviews.
- Reflection: reusable point — when a provision script generates config inline, absorbing means (1) commit the file, (2) teach the script both lookup paths (checkout + flattened remote copy), (3) teach the shipper to send the file. Delivery: pending-sync (to be saved at session end if durable tooling allows; no secrets involved).
