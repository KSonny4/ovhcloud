# 2026-09-26T151100Z — forgejo-live-pg Step 1 repo (deployer host_volume grant)

Lane: FORGEJO-LIVE-PG (Meta Muse). Backing issue: KSonny4/forgejo#1.
Worktree: `.worktrees/deployer-hostvol` (branch `deployer-forgejo-hostvol`,
from origin/master f12f16f). Forgejo spec worktree (read-only):
`~/git_projects/forgejo/.worktrees/live-pg` @ a0610cf.

## Pre-flight (forgejo live-plan)
`docker buildx imagetools inspect` on all five tags; every digest matches
the specs in `nomad/*.nomad.hcl` (postgres
`sha256:b0f9560a…e552b24`, alpine `sha256:8a1f59ff…e11715`, python
`sha256:5a824eb8…b9a1614`, forgejo `sha256:cf5f5ae6…64053fe`, runner
`sha256:ca3d5eea…55f7552`). No bump PR needed.

## Change
`acl/deployer.policy.hcl`: added exactly three `host_volume` blocks
(forgejo-pg-data, forgejo-data, forgejo-runner-data), each
`capabilities = ["mount-readwrite"]` (the capabilities spelling, not
`policy = "write"`). Header comment updated: the old "no host_volume
block" line now documents the scoped exception + KSonny4/forgejo#1 ref.

## Contract (tests/test_acl_s4.py)
- `host_volume` removed from global FORBIDDEN_BLOCKS; governed by targeted
  tests instead. `policy = "write"` stays forbidden everywhere (existing
  test untouched).
- New `FORGEJO_HOST_VOLUMES` constant (mirrors KSonny4/forgejo
  nomad/volumes/*.hcl) + `_host_volume_violations()` validator.
- New tests: deployer holds exactly the three with exactly
  `["mount-readwrite"]`; no host_volume in any other policy; wildcard and
  4th-name mutations are violations; `policy = "write"` spelling is a
  violation. Negative behavior proven by direct validator run (wildcard-4th
  and policy-write fixtures both yield violations; good file yields none).
- `test_deployer_covers_exactly_the_production_namespaces` now allows the
  `host_volume` block kind alongside `namespace`/`node`.

## Gates
`/opt/homebrew/bin/python3.14 -m unittest discover -s tests` → 44 tests
OK. `git diff --check` clean. Leak-grep (Step-2 regex) clean. No secrets
involved at any point (policy text only).
