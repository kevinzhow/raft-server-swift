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

Production now runs `ab04cacf` (`ab04cacf8e0cb45252eb379f08bcc7274242d11d`),
installed by the real upgrade from `b23b2516`. The post-swap health check
returned 200 with version `1.21.23` and SHA `ab04cacf`; the Main launch spec
(`/mnt/data/services/raft-swift/production/supervision/main.launch.json`)
records the same `gitCommit`, with MainPID 4059509. The previous b23 release and
its pre-upgrade dump remain for rollback.

The trunk result is the real merge `d244fe30d8840f56fe679c37e229538069179964`
of the prior trunk and `ab04cacf`; its full tree is
`92bfd00849a2fbc34f3c06fb52836b7260fa32da`, equal to the candidate tree.
`deploy-linux-docker` and `integrate-4` are both pushed at these commits.

The b23 baseline remains the rollback reference: it previously passed the actual
14-check acceptance and a 10-minute, 50-check browser canary, not evidence for
ab04.

## Qualified candidate

`ab04cacf` is fully qualified on its frozen tree. The unified gates passed:

- **Gate.** All five steps PASS: 3,250 sharded tests in 6 shards (build 118.6 s,
  tests 359.5 s, elapsed 485.5 s, under 10 minutes); one known Kimi isolated
  retry passed and `failures[]` is empty. E2E 62 s, smoke 25 s, architecture 22
  checks in 2 s, parity-check 3 s. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T200430Z/`.
- **Persistence.** Full serial `make test-pg` PASS: 49 gated startup cases,
  0 failed (311 s), database health PASS (0 s), infrastructure PASS (3 s).
  Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/test-pg/20261111T201408Z/`.
- **Release.** The independent initial release build took 423 s, tracked 1,700
  files with hash `9c98039d65dc988c32b2eb2896eacedea3948c5cf28a6c2ea539223c0f3ba30b`
  unchanged, and produced binary
  `5f69c8bc625ee049280fb3272d36c2ecf0fd8bbf0dd914b7ef2a9eee289141a0`. Proof:
  `/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/initial-release-build-proof.json`.
  Deployment reused the same clean worktree and binary in 12 s; that cached
  no-op is not a second 423 s build and does not replace the initial proof.
- **Deployment.** The driver ran build, stage, verify, quick `pg_dump`, upgrade,
  gateway restore and previous-release retention, ending `UPGRADE OK` and
  `DEPLOY OK`. The upgrade record has `actualObserved: true`, from b23 to ab04.
  Evidence:
  `/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/deploy-driver.log`
  and
  `/mnt/data/services/raft-swift/production/provision/upgrade-ab04cacf/upgrade-record.json`.
- **Privacy.** Two production JSON environment files were parsed and four
  private patterns produced zero matches; one configured deployment host also
  produced zero matches. The scan is not a claim that every key or all
  configurations were searched.

## Behavior delivered in ab04

`ab04` carries the completed Engine.IO v4 polling transport (auth, hub and
default client), Content-Length and chunked framing including illegal framing
and the negative-Range defect, late GET with close and final-Probe cleanup,
repeated probe pings answered with probe pongs, and per-request response
bindings that remove the synchronous no-op, preserve order under multi-SID
failure and answer header overflow with 431 like Node.

D2 only separates listeners. Fixed WebSocket client transport is not server
parity, and this work is not a full upstream semantic test-suite port.

## Acceptance status

No ab04 actual 14-check run JSON is recorded yet. Only a pre-deploy five-page
authenticated browser baseline exists (the D5 feedback 404 is the only error), and
the 36-case public HTTP helper is prepared but has not run against production.
Neither item accepts the release.

The ab04 acceptance must show 14 PASS, 0 FAIL/BLOCKED/SKIP; the hidden nonce
read in two consecutive real replies; the restart reply correlated to its
request; no console or HTTP errors beyond D5; and the official Computer/Codex
keep-session path intact. It must also pass the 10-minute canary over the five
authenticated pages. No such result is claimed here.

## Cleanup

The ab04 retarget is prepared at
`/mnt/data/raft-swift-development/tmp/stage-cleanup-execution-ab04cacf`. It
keeps the 19-object whitelist unchanged (2 scopes, 3 containers, 14 files) and
retains all 55 old KEEP entries plus 8 new ab04 contexts, 63 in total. The
18 READY / 1 KEEP split is only the earlier read-only inventory, not an actual
outcome. All 48 safety self-tests pass with zero mutation and no real candidate
touched, but those are not a cleanup run.

No stop or delete operation has run. After the real upgrade the Lead must pin
the actual current manifest SHA (`manifest.currentSha` is still unpinned); then
the final canary file must be created; only then may the read-only preflight and
an explicit execute run. No `canary-completed.json` exists, so cleanup is not
authorized or claimed.

Port 28443 remains `PROVEN_UNUSED`: live connector configuration version 9 has
8 ingress rules and zero references, observed read-only; recheck before cleanup.

## Route and module limits

Route baseline C0: 644 upstream versus 611 Swift, 583 exact, 1 variant, 57 raw
missing (5 false positives, 52 exclusions) and 27 extra; 0 reachable Class C.
`PARITY.tsv` has 406 modules, 230 mapped. These are explicit limits, not full
coverage or parity.

## Next steps

1. Run the actual 14-check acceptance on deployed ab04, with nonce, restart and
   keep-session evidence, then the five-page Web pass, the 36-case public HTTP
   check and the 10-minute monitor.
2. Keep the b23 release and dump available, and verify the rollback path before
   closing the release.
3. Have the Lead pin the current manifest SHA, create the final canary file,
   run the cleanup preflight and execute only the 19 whitelisted objects;
   postcheck for collateral changes.
4. Publish the final current-state plan and acceptance record after those steps.

## Completion conditions

- Gate and PostgreSQL pass on the deployed commit (met for ab04); acceptance is
  14 PASS, 0 FAIL/BLOCKED/SKIP with two consecutive nonce reads, a correlated
  restart reply, no console/HTTP errors except D5, and the Computer/Codex
  keep-session path intact (not yet met for ab04).
- The 36-case public HTTP check and the 10-minute Web canary pass on ab04; the
  rollback release and dump remain intact and the rollback path is verified.
- Engine.IO v4 polling and WebSocket upgrade match upstream observable
  behavior; fixed WebSocket client transport is not server parity.
- Cleanup executes only the unchanged 19 whitelisted objects after the manifest
  pin, final canary and read-only preflight, with a clean postcheck.
- Remaining differences stay in `docs/DEVIATIONS.md`; no new deviation, widened
  exclusion, full test-suite port or route match is claimed as parity.

## Evidence

The ab04 qualification root is
`/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/`, holding the
candidate record, gate and PostgreSQL driver logs, initial build proof,
deployment log and browser baseline. Gate and persistence logs are at the paths
above; the upgrade provision directory holds the record, dump and previous launch
specs. Keep the owner environment, data disk and credentials intact.
