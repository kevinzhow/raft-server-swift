# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), [PARITY.tsv](PARITY.tsv) and
[ARCHITECTURE.md](ARCHITECTURE.md).

## Objective

Deliver the Swift reimplementation of `raft-source` tag `v1.21.23-source.1`:
HTTP/socket contract, fixed Web/CLI consumers, PostgreSQL persistence, the
daemon/Computer path and deployment. Parity tests evidence the contract, not a
complete user path.

## Deployed runtime

Production runs `ab04cacf` (`ab04cacf8e0cb45252eb379f08bcc7274242d11d`),
installed by the real upgrade from `b23b2516`. Post-swap `/health` returned 200
and the version endpoint reports `1.21.23` at SHA `ab04cacf`, stable after the
swap. The Main launch spec records the same `gitCommit`; no MainPID is pinned
here because acceptance restarts Main and the PID changes. The b23 release and
its pre-upgrade dump remain for rollback.

The trunk result is the real merge `d244fe30d8840f56fe679c37e229538069179964`
of the prior trunk and `ab04cacf`, with tree
`92bfd00849a2fbc34f3c06fb52836b7260fa32da` equal to the candidate tree; both
`deploy-linux-docker` and `integrate-4` are pushed at these commits.

## Durable-state clearance

The pre/post raw hash of 3 of 14 durable rows changed; the review calls this
expected lifecycle writes, not corruption. `post-deploy-verification.json` keeps
`passed: false` untouched, while reviewed `post-deploy-reviewed.json` records
`passed: true` before the message campaign, with 11/14 payloads byte-identical:

- `agents_runtime`: Set-backed scopes, capabilities, runtimes and launch IDs
  re-encoded; new connection epoch, one synthetic onboarding-context notice
  (not a messages row) with dispatch, and two presence transitions.
- `auth_profiles`: two refresh rotations inside existing owner families;
  sessions stay 46, access tokens move 173 to 175.
- `machines_and_computers`: detection status, duration and timestamps, plus
  per-kind model `updatedAt`; per-kind model lists are identical.

Owner account, password hash, roles, secrets, rights and session families are
unchanged; no message, task, OAuth, server or durable domain was added, removed
or lost and no identity was created. This is state clearance, not a Source fix,
and it does not claim the raw 14 rows were identical during the upgrade. The
acceptance read-only sweep again passed with 14 rows unchanged.

## Qualified candidate

`ab04cacf` is fully qualified on its frozen tree:

- **Gate.** All five steps PASS: 3,250 tests in 6 shards (485.5 s), the known
  Kimi retry passed and `failures[]` is empty; E2E, smoke, architecture and
  parity-check passed. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T200430Z/`.
- **Persistence.** Full serial `make test-pg` PASS: 49 cases, 0 failed; logs
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/test-pg/20261111T201408Z/`.
- **Release.** Initial build 423 s produced `5f69c8bc...`; deployment reused it
  in 12 s, a cached no-op not a second build.
- **Deployment.** Build, stage, verify, `pg_dump`, upgrade, gateway restore and
  retention ended `UPGRADE OK`/`DEPLOY OK`; `actualObserved: true`.
- **Privacy.** Two production JSON env files parsed; four private patterns had
  zero matches, without claiming every key or configuration was searched.

## Behavior delivered in ab04

`ab04` carries the completed Engine.IO v4 polling transport (auth, hub and
default client), Content-Length and chunked framing including illegal framing
and the negative-Range defect, late GET with close and final-Probe cleanup,
repeated probe pings answered with probe pongs, and per-request response slots
that fix the synchronous noop response hang. The noop6 behavior itself is still
required. Responses remain ordered under multi-SID failure, and header overflow
answers 431 like Node. D2 only separates listeners; fixed WebSocket client
transport is not server parity, and this is not a full upstream semantic
test-suite port.

## Acceptance status

The actual ab04 14-check acceptance passed: 14 PASS, 0 FAIL/BLOCKED/SKIP in
204.7 s (20:43:13Z to 20:46:38Z, `acceptance-full.json`). It recorded the
hidden nonce in two consecutive real replies, correlated restart replies, the
official `raft-swift-production-computer.service` restart with queued and
resident replies, keep-session reset, and 14 unchanged durable rows. Earlier
partial campaigns are non-final evidence.

A 14-check dry run at 20:43:01Z planned the same set with the explicit unit:

`scripts/acceptance/acceptance.py --full --restart-main --restart-computer --computer-service-unit raft-swift-production-computer.service --restart-agent keep-session --reply-timeout 180`

The five-page authenticated Web round, gateway-closed restricted full rehearsal,
36-case origin+public check and 600 s monitor remain pending; the b23 canary is
only the rollback baseline.

## Cleanup

The cleanup manifest pins the current manifest SHA
`c4ebd84ac557e0d7f8fa9960a392086b714666558f1026cbaa7c9b988e5cc48c`; deployed and
staged `main.release.json` bytes are equal. The executable is pinned at
`5f69c8bc...`; the 19-object whitelist (2 scopes, 3 containers, 14 files), 63
KEEP entries and 48 self-tests pass unchanged. `B-ccf41374` stays the one KEEP
candidate because its qualified copy is absent; 0 objects were stopped or deleted.

The gateway config `1b0fd817...` is active; port 28443 remains `PROVEN_UNUSED`
and must be rechecked. Conditional cleanup is authorized but not eligible until
the final canary file exists, the updated preflight passes, execute is explicit
and postcheck is clean; no `canary-completed.json` exists.

## Route and module limits

Route baseline C0: 644 upstream versus 611 Swift, 583 exact, 1 variant, 57 raw
missing (5 false positives, 52 exclusions) and 27 extra; 0 reachable Class C.
`PARITY.tsv` has 406 modules, 230 mapped. These are explicit limits, not full
coverage or parity.

## Next steps

1. Run the five-page authenticated Web round, gateway-closed restricted full
   rehearsal, 36-case origin+public check and the 600 s monitor.
2. Create the final canary file from that evidence, run the updated read-only
   cleanup preflight, execute only the 19 whitelisted objects, and postcheck.
3. Keep the b23 release and dump available and verify the rollback path; publish
   the final acceptance record and current-state plan for Lead review.

## Completion conditions

- Gate, PostgreSQL and the 14-check acceptance pass on ab04: 14 PASS, 0 FAIL/
  BLOCKED/SKIP, two nonce reads, correlated restart reply, Computer/Codex
  keep-session intact.
- The five-page Web round passes without console or HTTP errors except D5; the
  36-case check and 600 s canary pass; the rollback release, dump and path stay
  intact.
- Engine.IO v4 polling and WebSocket upgrade match upstream observable behavior;
  fixed WebSocket client transport is not server parity.
- Cleanup executes only the unchanged 19 whitelisted objects after the pinned
  manifest, final canary and read-only preflight, with a clean postcheck.
- Remaining differences stay in `docs/DEVIATIONS.md`; no new deviation, widened
  exclusion, full test-suite port or route match is claimed as parity.

## Evidence

The ab04 qualification root is
`/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/`, holding the
candidate record, gate and PostgreSQL logs, initial build proof, deployment log,
browser baseline, `acceptance-full.json`, `post-deploy-verification.json`,
`post-deploy-reviewed.json` and `deployment-state-review/facts.json`. The
upgrade provision directory holds the record, dump and previous launch specs;
keep the owner environment, data disk and credentials intact.
