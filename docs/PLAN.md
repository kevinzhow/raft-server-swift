# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), [PARITY.tsv](PARITY.tsv) and [ARCHITECTURE.md](ARCHITECTURE.md).

## Objective

Finish the production delivery of the Swift reimplementation of `raft-source`
tag `v1.21.23-source.1`: the published HTTP/socket contract, the fixed Web and
CLI consumers, real PostgreSQL persistence, the daemon/Computer path and the
existing deployment. Parity tests evidence the contract, not a complete user path.

## Current stage

Production runs release selector `b23b251667a3740d4e25fc4ed9f161ad959e3145`
(`b23b2516`). Its sources were merged to trunk as
`07a9bce02be669253ae685623230f0bdb78477c4`; the full tree equals the candidate
(`232f219230025297a9920dd58b64145b2f422e71`). The previous `db2ebc71` release and
pre-upgrade dump remain for rollback; the upgrade kept a 143,283-byte quick
backup in the provision directory.

The earlier `db2ebc71` acceptance was 12/14: its Main-restart fence and DM
task-claim root causes are fixed and closed in this release.

## Release qualification

- **Gate.** `make gate` passed all five steps on `b23b2516`: 3,209 tests in
  6 shards (build 221.7 s, tests 377.3 s, total 601.6 s), one isolated retry of
  the pre-existing Kimi known-gap test passed, and the final `failures[]` is
  empty. E2E, smoke, architecture and parity-check also passed. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T165554Z/`.
- **Persistence.** The full `make test-pg` passed: 49 gated startup cases,
  0 failed; database-health and infrastructure-check passed. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/test-pg/20261111T170912Z/`.
- **Artifact.** Release build 391 s; tracked-file hash unchanged
  `6f38abe06430cffe99e0aba9235b8288a78a95382038951e8b580892fbdf86c1` (1,690 files);
  binary `7eae69e694613b38ab987ed3d5123819c546d6bdd3c6d89f8b30cec694314cb1`.
  Staging, verify, upgrade and `make deploy` installed `b23b2516`.

## Actual acceptance

The real 14-check acceptance finished with 14 PASS, 0 FAIL, 0 BLOCKED and
0 SKIP in 217.6 s against the deployed release. The hidden nonce existed only in
the uploaded bytes. Cindy read it in two consecutive real replies (seq 114 and
116). Main restart produced reply 121; Computer restart produced the first reply
at 123 and the second at 125; keep-session `mode=restart` returned HTTP 202 with
replies 127 and 129. Owner login and refresh passed, all 14 durable rows stayed
unchanged, and DM, mention, task, attachment preview and thread all passed.

Proof: `/mnt/data/raft-swift-development/tmp/qualification-b23b2516/acceptance-full.json`
and its driver log; the browser pass is not a persistence test for a newly created
production UI account.

## Web state

On the new release after restart, five authenticated pages had no new console or
HTTP failures; only the known D5 Hands-feedback `/api/product-feedback/tickets`
404 remains, documented. Owner name, Cindy and the online Computer were checked in
screenshots. Proof: `/mnt/data/raft-swift-development/tmp/qualification-b23b2516/browser-canary/`.

## Closed source defects

All source defects found this round are merged and closed by the actual
acceptance above:

- Main turn completion now restores the fence and pending release.
- DM task claim converts a plain message while keeping the host unchanged, and
  publishes only the task event with durable PostgreSQL state.
- Exact canonical peer and assignee matching, 8-hex and typed DM grammar, and an
  independent `identity_borrowing` for raw assistant posting.
- History, search, action card, modern/legacy send and DM thread list share
  canonical DM references; one escaping path defines the exact DM wire.

No new deliberate difference was added in this round. The built-in app
conversation remains absent under D12.

## Full-static and canary

Full-static is loaded. The corrected publication run rehearsed closed-all and
restricted rollback, then applied the full profile with the same Main PID and a
preserved inode.
Profile SHA-256: `1b0fd817da7515a55b8c33ce527f3f9e5b1d50c41fb5c7474f69f3a381b7ee1f`.
The first rehearsal stopped only because a restricted local entry was expected to
answer 200; the restricted profile was restored automatically and this was not
an application failure.
Proof: `/mnt/data/raft-swift-development/tmp/qualification-b23b2516/publication-r2/publication.json`.

The 10-minute public canary is NOT complete. One HEALTHY monitor round is not a
10-minute pass; only the Lead's final completion proof can close it.

## Cleanup and route proof

Stage cleanup has not run; no deletion or removed count is claimed. The
route proof for port 28443 is `PROVEN_UNUSED`: the live connector configuration
is version 9 with 8 ingress rules and zero references to that port, observed
read-only. Recheck the proof immediately before any cleanup because the
configuration can change.

## Route and ledger limits

The route audit baseline is C0: 644 upstream versus 611 Swift registrations,
583 exact, 1 parameter variant, 57 raw missing and 27 raw extra. The 57 are
5 parse false positives plus 52 documented exclusions; 0 reachable Class C
missing. This does not claim all upstream semantics or tests are ported.
`PARITY.tsv` has 406 modules, 230 with a test mapping; blanks and this baseline
stay explicit limits.

## Open work

1. Lead completes the 10-minute public canary on the published full-static
   profile and records the final proof.
2. Recheck the route proof, then run the planned stage cleanup.
3. Lead records the final canary and cleanup result in this plan. Keep the
   rollback release and its dump until those results exist.

## Completion conditions

Complete only when all of these hold on this release:

- `make gate` and `make test-pg` pass on the deployed commit (met).
- The 14-check actual acceptance records 14 PASS and 0 FAIL, BLOCKED or SKIP,
  including hidden-nonce reads, restart checks and an authenticated Web pass (met).
- The deployed Web path has no console or HTTP errors on audited pages except
  documented exclusions (met).
- The official Computer/Codex path survives Main restart and Computer stop/start
  without manual intervention (met in the actual acceptance).
- Full-static is published, the 10-minute public canary passes and rollback is
  rehearsed on the same release. Publication and rollback are met; canary is
  pending.
- Remaining differences are in `docs/DEVIATIONS.md`; no undocumented deviation,
  test mapping, test count or route match is claimed as parity.

## Evidence and reporting

Evidence stays on the data disk under
`/mnt/data/raft-swift-development/tmp/qualification-b23b2516/` (release, deployment,
acceptance and browser logs), the gate and persistence logs above and the upgrade
provision directory. Quote paths, not logs. Swift test counts are not upstream
coverage; a locked ledger or unit test is not the production path. Keep the owner
environment, data disk and credentials intact.
