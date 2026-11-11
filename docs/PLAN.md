# Delivery plan and current status

This is a current-status document, not a diary. Replace stale statements
instead of appending a new snapshot. Historical detail lives in git commits and
in the deployment records; deliberate differences from upstream live in
[DEVIATIONS.md](DEVIATIONS.md).

No domain, address, credential or other environment secret belongs in this
file.

## Objective

Finish the production delivery of the Swift reimplementation of `raft-source`
tag `v1.21.23-source.1`: the published HTTP/socket contract, the fixed Web and
CLI consumers, real PostgreSQL persistence, the daemon/Computer path and the
existing Cloudflare/Caddy deployment. Parity tests are evidence for the server
contract; they are not proof that a complete user path works.

## Current stage

Production Main is deployed and running the release built from
`15219ef09061068e29194843f5b431e8d30377ac` on `deploy-linux-docker` (the
current trunk and remote tip; writer epoch 14). The owner account is real,
email-verified, with a completed profile and one server. The restricted public
profile is active; the full-static public profile has not been published.

The 2026-11-11 deploy passed the release gates: the staged manifest and launch
spec verified, a staged process served the pinned version and the exact
database-unreachable `/health` body, and the upgrade replaced `7b4cd3c8`, kept
that release plus the pre-upgrade `pg_dump`, and restored the gateway. The
deployed state is recorded by the production release manifest and launch spec,
the staged verification report in the qualified-artifact staging directory, and
the upgrade record with the pre/post durable-state snapshots in the production
provision directory. A full scripted acceptance against the deployed Main
passes 11/11, including a Main restart, socket reconnect and post-restart agent
reply.

The engine is in the "qualify the deployed release, then promote and deploy the
next integration" stage. Verification is scripted-first
(`scripts/acceptance/`), with the browser used only for visual confirmation.

The `integrate-4` branch is at `ccf4137` and is four commits ahead of the
deployed trunk. It adds zod-4 issues for legacy send and agent queries, the
pinned agent-api request-contract schemas and validator, and one
capability/per-agent-grant/params-query/body gate over the routes upstream
wires. Its gate (3144 tests, one isolated retry) and 46/46 fresh-database
persistence run are recorded in the integration worktree, but it is not merged
to trunk and has no release artifact, upgrade record or scripted acceptance. Do
not report it as deployed or complete.

## What works

- **Parity ledger.** 406 upstream modules tracked and locked: route cases
  2000/2000, socket 16/16, daemon 2616/2616 with the exclusions recorded in
  `docs/PARITY.tsv`. `make parity-check` validates status, commits, case
  accounting and the new locking-test column.
- **Real-process gates.** `make test-sharded` runs the full suite as parallel
  test-runner shards (3144 tests in the latest integration gate, with one
  isolated retry); `make test-e2e` starts two isolated `RaftServer` processes
  plus `RaftDaemon`; `scripts/smoke-server.sh` passes 26 live checks;
  `make architecture` passes its layering/size/seam guardrails.
- **Real PostgreSQL acceptance.** Gated suites cover onboarding, presence and
  restart recovery, offline agent queue, resident delivery, human message
  execution, realtime active-auth, runtime forms/breakers, machine queries,
  business-persistence fail-closed, email shutdown, mention-delivery
  occurrences, opener-notice recovery and infrastructure fencing.
  `make test-pg` runs them on one throwaway PostgreSQL 17 + Redis pair; the
  fresh-database run passes 46/46 gated startup suites plus the
  database-health and infrastructure checks.
- **Delivery paths.** Human auth (web/native/mobile), server/channel/DM/task/
  thread/attachment routes, owner onboarding (survey, handoff, opener-v2
  briefing and Team-Mode thread/artifact), resident agent delivery, presence
  reconciliation, resident-launch adoption after a restart, mention deliveries
  (durable occurrences, redrive and outcome projection), task history and
  `asTask`, canonical message payloads and `message:updated` updates, system
  notices, Socket.IO room joins/`message:new`/`thread:updated`/`dm:new`,
  `activityDetailKind` and terminal-failure visibility, the channels joint/
  conversion and saved-message routes, attachment preview plus agent attachment
  metadata and thread-parent read authority, the internal agent API routes for
  task history/unclaim, avatar, upload sessions and integration apps, legacy
  machine agent routes behind one machine-ownership gate and scope table, the
  developer-platform App-management/integration/MCP OAuth/action routes, real
  user/server/agent avatar and integration-logo byte storage behind
  `/api/avatars` and `/api/integration-logos`, and account (forgot-password,
  username-available), billing, push and raftbench routes. The shared
  `/internal/agent-api` request-contract validator and the legacy-send/
  agent-query zod-4 issue bodies are on `integrate-4` only and are not
  deployed.
- **Route inventory.** `make route-inventory` dumps the booted Vapor router and
  diffs it against the pinned Express registrations into
  `docs/route-inventory.md`: upstream 644, Swift 611, exact matches 583,
  parameter variants 1, missing 57, extra 27. The channels family is complete
  (64/64, missing 0), and the developer-platform integrations family dropped
  from 19 missing to 3.
- **Deployed acceptance.** The scripted acceptance against the running release
  passes 11/11: health/version, owner login and refresh, server collection,
  read-only revision sweep, DM and mention replies, Task creation, attachment
  download and HTML preview, thread reply with `thread:updated`, and a unit
  restart with socket reconnect and post-restart agent reply.
- **Production operations.** Reproducible Main release build, stage, verify and
  maintenance-ordered upgrade are in `deploy/swift-production/`; the current
  release replaced `7b4cd3c8`, and that release with the pre-upgrade `pg_dump`
  is retained for rollback.

## Open defects and gaps

| ID | Finding | State | Next action |
| --- | --- | --- | --- |
| G1 | A verified owner with no membership still got 401 from `GET /api/servers` instead of 200 `[]` | Fixed in the deployed `15219ef` release with the canonical-principal collection path; gated by a real-PG onboarding acceptance | Confirm the deployed release returns 200 `[]` for a verified owner with no membership; the production owner currently has a server |
| G2 | The opener ledger notice is not delivered/stamped in production | The fix is in the deployed `15219ef` release: a complete ready or `agent:session` retires a never-dispatched previous-epoch start, adopts the resident launch and clears connection-loss recovery, so the opener ledger notice is admitted and delivered. Gated by `AgentExecutionRestartRecoveryTests` and `postgresOwnerOpenerLedgerNoticeReachesAResidentAgentAfterMainRestart` | Confirm the sent stamp on the next Computer ready; do not fabricate it |
| G3 | Ready-time agent status/activity could stay `inactive`/`offline` while the process runs | Presence reconciliation, ready `runningAgents` handling, `activityDetailKind` and the terminal-failure pause projection are deployed and gated | Confirm live status after the next Computer ready and after a Main restart |
| G4 | Legacy opener instruction text when the opener flag is explicitly off | Deliberately out of scope (see DEVIATIONS D11) | Re-open only if the flag is turned off in production |
| G5 | Full-static public profile not yet published | Restricted profile verified; public entry still limited | Publish only after full Web/console and provider acceptance |
| G6 | Official Computer/Codex/provider acceptance after the deployed release | Pending on `15219ef`; separate from the unit gate by design | Run it on the deployed release and record the result with the deployment record |
| G7 | One `make test` run hung in an unrelated test | Test-scaffold lost-wakeup fix merged; the sharded runner isolates and retries, and the latest integration gate passed its one isolated Kimi token-refresh retry | Re-open only if a failure survives the isolated retry; keep the shard log |
| G8 | Activity trajectory entries and gap recovery are not stored | Deliberate (see DEVIATIONS D10) | Re-open only if the pinned Web consumes them |
| G9 | Fresh-database `make test-pg` exposed warm-database fixtures and one epoch-scoping defect: the fourteen-owner snapshot assumed one shared revision although the fail-closed writer commits changed rows only; the config-breaker fixture left durably queued wakes unacknowledged after the resident-delivery release made them real deliveries; the Built-in unavailable projection expected the old two-provider metadata instead of the pinned sixteen-preset plus two-gateway catalog; the lease-loss journal only accepted the stale-heartbeat cause, not the fenced command that lost its session first; and an unexited process from an older human-takeover epoch was treated as the new epoch's live runtime. The keep-session wake integration added three more: a tracked mention action was dropped instead of queued for an admitted launch, and two gated suites waited for `agent:deliver` without reporting the process identity, or assumed a trigger message never rides the start. | Fixed and merged; the fresh-database run passes 46/46 gated startup suites plus database-health and infrastructure-check for the deployed trunk and the integration tree | Keep the fresh-database run in the deploy checklist; re-open if a fixture depends on warm state again |
| G10 | Route inventory still lists 57 upstream Express registrations without a Swift counterpart and 27 Swift-only routes; the largest remaining families are `internal*.ts` (28, mostly agent-side labs/machine/profile variants and trace ingest), other/top-level (8), slack-bridge (6), public search index/detail (4) and integrations (3). | Tracked by `docs/route-inventory.md`; most missing families are unported external services covered by D5/D12/D19/D21 or not referenced by the pinned Web/CLI | Re-run `make route-inventory` after each slice; register the reachable gaps and record every remaining exclusion in `docs/DEVIATIONS.md` |

## Next steps

1. Confirm the deployed `15219ef` release's open behaviors: the opener ledger
   stamp on the next Computer ready (G2), live agent presence (G3) and
   `GET /api/servers` = 200 `[]` for a verified owner with no membership (G1).
2. Promote the gated `integrate-4` tip to trunk with a real merge, then build,
   stage, verify and `make deploy COMMIT=<sha>`. Keep `15219ef` and the
   pre-upgrade dump as the rollback pair.
3. Run the read-only scripted acceptance, then the full scripted acceptance
   (including the Main restart) on the new release in a quiet window.
4. Run official Computer enrollment, model execution, workspace and cold-read
   checks, restart recovery and the browser console audit on the deployed
   release.
5. Publish the full-static public profile and run the public canary only after
   the Web/console and provider checks pass.
6. Re-run `make route-inventory` and either implement the reachable G10 gaps or
   record each remaining exclusion in `docs/DEVIATIONS.md`.

## Completion conditions

The objective is complete when all of the following hold on one qualified
release:

- `make gate` and `make test-pg` pass on the integration commit that is
  deployed.
- The scripted acceptance passes every check (or records a reviewed, deliberate
  skip) against the deployed environment, including restart/reconnect delivery.
- The deployed Main serves the complete normal Web path (login, server, DM,
  mention, Task, attachment, thread) with no console errors on the audited
  pages.
- The official Computer/Codex path completes a real reply and survives a Main
  restart without manual intervention.
- The public entry is intentionally published (full-static profile) and the
  maintenance/rollback procedure has been rehearsed on the same release.
- Remaining differences are listed in `docs/DEVIATIONS.md`; no undocumented
  deviation is claimed as parity.

## Reporting

Report `make parity` output with its qualifications, the gate results and the
scripted acceptance report. Name the deployed commit and cite its acceptance
report; do not call the integration tip deployed until its own release
artifact, upgrade record and scripted acceptance exist. Do not report Swift
test counts as upstream coverage, and do not treat a locked ledger or a passing
unit test as proof of the production user path.
