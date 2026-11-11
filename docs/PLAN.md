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

Deployed Main is `15219ef09061068e29194843f5b431e8d30377ac` on
`deploy-linux-docker` (writer epoch 14), staged-verified before the upgrade, with
`7b4cd3c8` and the pre-upgrade `pg_dump` retained. The owner is a real verified
profiled user with one server; the restricted public profile is active and
full-static is unpublished.

The deployed release still exhibits G11: with the official Computer stopped, an
offline DM got no correlated reply within 180 s after the restart; the
connection reported online and ready while recovery stayed in
`connection_lost_with_unsettled_execution`. The one pending DM, its
`needsManual` state and the services are retained deliberately with no reset;
the owner account and Codex login are untouched.

The integration tree now carries all source fixes. The restart-recovery fix
(`a402d31`, `f67b876`, merged as `8449894`) retires a previous daemon instance's
launches on a complete new-instance ready, re-obliges a never-attempted wake
start through the durable pending-delivery inbox, releases exactly one
`agent:start` carrying the wake message, and keeps manual recovery for
unacknowledged writes and written/ambiguous starts. Peer-review P2 (wake-start
re-obligation) and P3 (nil/empty daemon identity must not fence a tracked live
process) are red→green, and the ambiguity guards (repeated ready, revoked
authority, old snapshot) are preserved. Evidence: 23/23 recovery unit tests,
90/90 affected tests in 9 suites, 2/2 HTTP-server visibility tests, 2/2 gated
real-PostgreSQL restarts, `make architecture` 22/0 and `make parity-check` green.
This closes the implementation review, not production and not G11.

Other merged slices are source and evidence only: contract validator (`b05e0fb`
via `8cbf1d5`) 32/32 focused; auth/schema (`01ce15a`, `d355cbd` via `37607c5`)
14 AuthCore plus 17 targeted; task history (`405a447` via `3f3fc33`) 3
TaskHistory plus 13 AgentApiContract; correlated attachment read (`a94b05e` via
`0568eb2`) 11 network-free tests; scripted Computer/keep-session acceptance
(`d73ae84` via `300f451`) 27 Python tests plus a 14-check dry run.

All of this awaits one full `make gate` and `make test-pg` on the frozen
candidate; nothing above is qualified, deployable or deployed. After this docs
refresh the tree is frozen and the Lead runs both gates. The last full gate
(3144 tests, one isolated retry) and the 46/46 fresh-database run predate these
merges and do not qualify them.

## What works

- **Parity ledger.** 406 modules (219 route, 7 socket, 180 daemon), route
  2000/2000, socket 16/16, daemon 2616/2616, with the exclusions in
  `docs/PARITY.tsv`; `make parity-check` validates status, commits and case
  accounting. Test mapping covers 230/406 modules, which does not mean all
  upstream tests were ported.
- **Gates.** `make test-sharded`, `make test-e2e` (isolated `RaftServer`
  processes plus `RaftDaemon`), `scripts/smoke-server.sh` (26 live checks) and
  `make architecture` (22/0) are the gate path; `make test-pg` runs the gated
  real-PostgreSQL suites on one throwaway PostgreSQL 17 + Redis pair.
- **Delivery paths.** Human auth, server/channel/DM/task/thread/attachment
  routes, owner onboarding, resident delivery, presence/restart reconciliation,
  mentions, task history/`asTask`, canonical payloads and `message:updated`,
  notices and Socket.IO frames, activity visibility, attachment preview,
  internal and ownership-gated machine routes, developer-platform routes,
  avatar/logo storage, and account/billing/push/raftbench routes. The shared
  contract validator and latest auth/task-history fixes are integration-only.
- **Route inventory.** Upstream 644, Swift 611, missing 57, extra 27
  (`docs/route-inventory.md`); the channels family is complete. Most missing
  families are unported external services covered by DEVIATIONS or unreferenced
  by the pinned Web/CLI; zero static references is not proof of unreachability.
- **Deployed acceptance.** Scripted acceptance on `15219ef` passes 11/11 in
  67 s: health/version, owner login/refresh, server collection, read-only sweep,
  DM/mention replies, Task, attachment preview, thread reply with
  `thread:updated`, and a Main restart with socket reconnect and a Codex reply.
  The expanded 14-check plan passed only as a dry run.

## Open items

- **G11.** Fixed in the integration tree; the deployed release still fails the
  direct Computer-stop case until the fixed release is gated, deployed and accepted.
- **Qualification.** No full gate or full `make test-pg` has run on the frozen
  candidate; do not call it qualified until both pass.
- **G1.** The verified-owner-with-no-server 200 `[]` path is fixed and real-PG
  locked; live proof remains on a controlled disposable account or a real-PG check.
- **G3.** Confirm live agent status/activity after the next Computer ready and
  after a Main restart; reconciliation and terminal-failure projection are deployed.
- **G10.** The remaining 57 missing and 27 extra route registrations need a
  read-only audit outside Git before the public profile; record accepted exclusions.
- **G5.** Full-static is unpublished; publish only after the browser and provider checks.
- **D5 console.** Audited Web pages log the allowlisted
  `/api/product-feedback/tickets` 404 from the intentionally unported Hands proxy;
  the zero-console condition stays open.

## Next steps

1. Freeze after this docs commit; the Lead runs `make gate` and `make test-pg`,
   keeping the logs.
2. On green, build, stage and verify, take the quick `pg_dump` during the
   maintenance-ordered upgrade, deploy, and keep `15219ef` plus its dump.
3. Run the 14-check actual acceptance, including the hidden-file attachment read,
   the Computer stop/offline/new-instance path, the keep-session restart and the
   Main restart.
4. Run the full authenticated Web/browser pass, confirm G1/G3 live, and require
   a clean console except D5.
5. Finish the read-only route-exclusion review, publish full-static and run the
   public canary.
6. Clean up the release stage; keep the documented D5 404.

## Completion conditions

Complete only when all of these hold on one qualified release:

- `make gate` and `make test-pg` pass on the deployed commit.
- The 14-check actual acceptance passes (or records reviewed skips), including
  the real attachment read and both restart paths.
- The deployed Web path has no console errors on audited pages except DEVIATIONS.
- The official Computer/Codex path survives Main restart and Computer stop/start
  without manual intervention.
- Full-static is intentionally published, the canary passes, and rollback is
  rehearsed on the same release.
- Remaining differences are in `docs/DEVIATIONS.md`; no undocumented deviation,
  test mapping, test count or route match is claimed as parity.

## Evidence and reporting

Evidence stays on the data disk under `/mnt/data/raft-swift-development/tmp/`
(`recovery-review-followup/logs/`, `task6-acceptance/`) and under `.build/`
(`gate-logs/`, `test-sharded/`, `test-pg/`). Quote paths instead of pasting logs
and cite the deployed commit's acceptance report. Swift test counts are not
upstream coverage; a locked ledger or unit test is not the production path.
