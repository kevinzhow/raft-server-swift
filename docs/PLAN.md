# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), the route ledger in [PARITY.tsv](PARITY.tsv)
and the guardrails in [ARCHITECTURE.md](ARCHITECTURE.md). No secret belongs here.

## Objective

Finish the production delivery of the Swift reimplementation of `raft-source`
tag `v1.21.23-source.1`: the published HTTP/socket contract, the fixed Web and
CLI consumers, real PostgreSQL persistence, the daemon/Computer path and the
existing deployment. Parity tests evidence the contract, not a complete user path.

## Current stage

Deployed Main is `db2ebc71013db8c6cc89a84e68d59c43ecbe5bcb` (`db2ebc71`) on
`deploy-linux-docker`, upgraded at 2026-11-11 22:39 JST. The upgrade took the
quick `pg_dump` backup (130,281 bytes), swapped the release, verified private
health/version/PID mappings and restored the restricted gateway. Main PID at the
upgrade was 2659883; writer epoch 17 was observed at the upgrade. The acceptance
then restarted Main, so 17 is the upgrade observation, not an immutable
current value. `15219ef` and the dump are retained at
`/mnt/data/services/raft-swift/production/provision/upgrade-db2ebc71/`.

Trunk is the no-ff merge `3be7bcc`, whose tree `fd58f0aa...` matches the tested
candidate `db2ebc71`. The release selector and tested artifact are `db2ebc71`,
not the merge SHA.

The code is frozen; this commit changes only these docs. The original G11
pending DM `54eef20e` was carried by the accepted start `E59E2966` with
`needsManual` null, 0 pending deliveries, a completed launch, no inflight command
and no manual reset (`.../qualification-db2ebc71/original-pending-recovery.json`).
Owner login/refresh passed in the acceptance, and no owner account or Codex
login reset was performed.

The actual 14-check acceptance finished at 22:55 JST: 12 PASS, 2 FAIL, 0
blocked/skipped, 497.0 s (`.../qualification-db2ebc71/acceptance-full.json`,
exit 1). `attachment-read` failed at 13:50:14Z with no agent reply carrying the
hidden nonce within 180 s. `restart-main` failed at 13:53:18Z with no
post-restart agent reply within 180 s. The other checks passed, including
`restart-computer` (new instance; queued reply seq 100, resident reply seq 102)
and `restart-agent` (reset HTTP 202; replies seq 104, 106). Do not claim a
passed 14-check run or a clean browser pass.

## Qualified gates

- **Full gate.** PASS on the frozen candidate: 3,161 tests in 6 shards, 561.0 s
  (build 181.1 s, test 372.3 s). One isolated retry passed for the pre-existing
  Kimi `knownGapLogin...` test, which records its documented known issue; no
  product-test failure. E2E 48 s, smoke 25 s (26 checks), architecture 1 s
  (22/0), parity-check 2 s. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T131259Z/`.
- **Persistence gate.** Serial `make test-pg` PASS: 47 gated startup tests
  (0 failed), database-health 4/4, infrastructure checks. Logs:
  `/mnt/data/raft-swift-development/tmp/qualification-db2ebc71/pg-serial/`.
- **Qualification limits.** The first parallel `make test-pg` collided with the
  gate build on the same worktree's build database; that was an infrastructure
  failure, not a product test failure. The serial rerun qualifies. The Kimi
  retry was pre-existing and isolated.
- **Release proof.** The release build took 687 s; `make deploy` reused the same
  binary `97a0f0c...` in 25 s and passed staged verification. Tracked source was
  unchanged before and after the build; candidate and trunk trees match; the
  9-pattern privacy scan found no Git match (`candidate.json`, `trunk.json`,
  `privacy-scan.json`).

## What works

- **Parity ledger.** 406 modules (219 route, 7 socket, 180 daemon); route
  2000/2000, socket 16/16, daemon 2616/2616; test mapping 230/406. A locked
  ledger is contract evidence, not upstream test coverage.
- **Deployed service.** `/health` and `/api/version` report 1.21.23 at
  `db2ebc71`; PID mappings and the restricted gateway are verified. The
  rollback release and dump remain.
- **Route audit.** 644 upstream / 611 Swift registrations: 583 exact, 1
  parameter-variant, 57 raw missing, 27 raw extra. The 57 are 5 Class A false
  positives, 15 Class B and 37 Class B* documented exclusions, 0 Class C
  reachable missing; all 52 intentional exclusions are in DEVIATIONS. The 37 B*
  rows are actual existing unsupported App, OAuth, legacy-agent/machine,
  SDK-only and migration features, not new decisions. The 27 extras are 15
  fail-closed wildcards, 5 parser misses and 7 compatibility/refusal endpoints;
  the channel family is 64/64.
- **G1.** Real-PostgreSQL proof is complete: `OnboardingPostgresAcceptanceTests`
  lines 105-123, run among the 47 gated tests, shows normal HTTP login and
  refresh 200 and the empty `[]` server collection before membership. This does
  not claim a fresh production UI account was created.
- **G11.** `restart-computer` passed live: the Computer stopped, a DM queued
  offline, a new instance started, and both replies arrived (seq 100, 102). The
  original pending DM was carried with no manual reset (Current stage).
- **Full-static.** The public-profile candidate is prepared privately at
  `/mnt/data/raft-swift-development/tmp/full-static-publication-candidate`
  (SHA-256 `1b0fd817...`), with Caddy adapt/validate and 41/41 structural checks
  passing. It is not applied; the live gateway remains restricted and
  full-static remains unpublished.

## Open items

- **Failed acceptance checks.** `attachment-read` (no agent reply with the
  hidden nonce in 180 s) and `restart-main` (no post-restart reply in 180 s)
  remain open; the run is 12 PASS / 2 FAIL, not accepted.
- **G3.** Final live agent presence/activity after the restarts is pending.
- **Full-static publication.** Not applied; public publication, canary and
  cleanup remain. The previous release and dump keep rollback available.
- **D5 console.** Five authenticated pages were captured; only the allowlisted
  `/api/product-feedback/tickets` 404 appears. This is a baseline; the
  zero-console condition remains open.

## Next steps

1. Root-cause the `attachment-read` and `restart-main` failures, fix or
   adjudicate them, and rerun the affected checks; do not accept the release
   until the run passes or records reviewed skips.
2. Keep G11's passed Computer-stop path and confirm G3 live presence after the
   restart-agent run; keep the Main-restart delivery failure open.
3. Run the full authenticated browser pass after the scripted failures are
   resolved or adjudicated, keeping D5 as the allowed defect.
4. Publish full-static after review, run the public canary, clean the release
   stage and keep the documented D5 404.
5. Keep the previous release, dump, owner account and Codex login until normal
   operation is verified.

## Completion conditions

Complete only when all of these hold on one qualified release:

- `make gate` and `make test-pg` pass on the deployed commit.
- The 14-check actual acceptance passes (or records reviewed skips), including
  the hidden-file attachment read and all restart paths.
- The deployed Web path has no console errors on audited pages except DEVIATIONS.
- The official Computer/Codex path survives Main restart and Computer stop/start
  without manual intervention.
- Full-static is intentionally published, the canary passes, and rollback is
  rehearsed on the same release.
- Remaining differences are in `docs/DEVIATIONS.md`; no undocumented deviation,
  test mapping, test count or route match is claimed as parity.

## Evidence and reporting

Evidence stays on the data disk under
`/mnt/data/raft-swift-development/tmp/qualification-db2ebc71/` (gate, PG and
acceptance logs, browser baseline, original pending recovery), under the gate
leaf above and under the upgrade provision directory. Quote paths instead of
pasting logs. Swift test counts are not upstream coverage; a locked ledger or
unit test is not the production path.
