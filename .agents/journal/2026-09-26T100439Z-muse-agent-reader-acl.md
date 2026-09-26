# Journal: agent-reader Nomad ACL lane (AR-16)

- Start (UTC): 2026-09-26T10:03Z. Agent/role: Muse Spark (pi), sole writer.
- Task: scoped agent-reader Nomad policy + contract test + escrow apply
  script. Intended outcome: agents get read-only baseline access; owner
  applies later. Lane is the Slice N prerequisite.
- Backing issue: KSonny4/platform#16 (Slice N). Branch:
  `feat/agent-reader-acl-16`, worktree
  `~/git_projects/platform/.worktrees/agent-reader-16`, cut from
  origin/master @ b7e26d3.
- Shared guidance: AGENTS.md (ovhcloud runbook) + adopted
  engineering-guidance rev `474b8c21` (L1 informative, prepare-only).
  Playbooks triggered: none beyond AGENTS.md. Journal standard:
  `~/git_projects/engineering-guidance/standards/agent-journal.md`.
- Cognee recall first: `nomad ACL agent-reader read-only policy token
  escrow bao` (15 memories). Material lessons applied, verified against
  current source rather than trusted blindly:
  - escrow via stdin pipe (`VAR | bao kv put ... 'field=-'`), SecretID
    never on argv/stdout (run-remote-provision.sh gossip-key pattern);
  - Nomad server `acl.token_max_expiration_ttl` defaults to 24h, so the
    720h default TTL fails closed unless the server limit is raised
    (documented in script + docs, no silent clamp, no non-expiring token);
  - never run nomad/bao/ssh, never read tokens (this lane ran none of
    them; only `nomad`/`bao` presence checks in dry-run text, no calls).

## Actions and observations

- 10:03Z: confirmed the alloc-stats ACL claim against the official Nomad
  HTTP API docs (`/api-docs/client`): `GET
  /v1/client/allocation/:alloc_id/stats` requires `namespace:read-job`;
  fs/logs requires `read-logs`; fs/* requires `read-fs`; `/v1/client/stats`
  requires `node:read`. Noted in the policy header with URL + date.
- Wrote `acl/agent-reader.policy.hcl`: namespace `*` with explicit
  capabilities `[list-jobs, read-job, read-logs, read-fs]` (no `policy`
  shorthand, so no Variables read); `node { policy = "read" }` with a
  comment explaining the node block has no capability list. No
  submit/dispatch/scale/alloc-lifecycle/alloc-exec/variables/host_volume/
  operator/agent/quota/plugin/sentinel grant; no `policy = "write"`.
- Wrote `tests/test_acl_agent_reader.py` (stdlib unittest, parsing approach
  reused from polymarket-wallet-finder `test_nomad_t1.py`): asserts the
  forbidden set, no write policy, explicit capabilities per namespace
  block, exact read set on `*`, node read-only, header names holders +
  Bao path. Fixed one self-inflicted test bug (header split matched the
  word "namespace" in prose; now splits on the block-start regex).
- Wrote `scripts/apply-agent-reader-acl.sh` (owner-run, never executed
  here): `--dry-run` default, `--apply` does policy apply + client token
  mint (`AGENT_READER_TTL`, default 720h) + stdin-piped Bao escrow to
  `secret/projects/nomad/AGENT_READ_TOKEN` field `token`; prints only
  accessor + path; requires caller-supplied NOMAD_ADDR/NOMAD_TOKEN/BAO_ADDR
  and reads the management token from nowhere else; escrow failure revokes
  the orphaned token. Fixed one shellcheck info (SC2016 backticks).
- Docs: `docs/03-nomad.md` section 6 (grants/denies, owner apply, single-
  process agent consumption without export/history/files).
- Deliberately did NOT touch `scripts/validate-repository.sh`: it runs no
  Python unittest suite (only `validate-iac.py`), so per the lane spec the
  test runs standalone: `python3.14 -m unittest discover -s tests -p
  'test_acl_*.py'` (also directly `python3 tests/...`). No fallback needed:
  python3.14 exists on this machine.

## Checks

- `python3.14 -m unittest discover -s tests -p 'test_acl_*.py'`: 8 tests OK.
- `bash -n scripts/apply-agent-reader-acl.sh`: clean.
- `shellcheck scripts/apply-agent-reader-acl.sh`: clean.
- `bash scripts/validate-repository.sh`: PASSED 2026-09-26 (~terraform init + graft check OK). No shellcheck findings locally; the known CI red (#19) is a runner-version difference, none of its listed files are mine.
- `git diff --check`: clean.

## Decisions

- Namespace `*` (not per-namespace): Slice N baselines every namespace;
  a read-only glob cannot escalate (no submit path in any namespace).
- Re-runs of `--apply` mint + replace (rotation semantics): Nomad never
  re-reveals a SecretID, so true no-op idempotence is impossible; the
  script converges (policy present, escrow holds a valid token).
- `bao kv put` (not patch) for the escrow entry: first write creates it;
  documented as replace-on-rotation.

## Final status

- Committed <sha>, pushed, PR <url> (Refs #16), #16 commented. NOT merged.
- All lane checks green; no open code questions. Owner action: run the
  apply script (needs server `acl.token_max_expiration_ttl` >= 720h or a
  smaller AGENT_READER_TTL), then run the Slice N baseline.

## Reflection / memory delivery

- Lesson: Nomad per-alloc stats ACL is `namespace:read-job` (official
  client API docs, 2026-09-26) -- a read-only stats token needs only
  read-job/read-logs/read-fs/list-jobs + node read. Conditions: Nomad 2.x
  HTTP API. Action next time: check the endpoint's "ACL Required" row
  before assuming a capability. Delivery: this journal + PR; no Cognee
  save (Cognee MCP tools not wired in this session).
