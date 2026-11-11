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
`94aab873c819a1c1a8632cc8990ae411dc808774` (branch `deploy-linux-docker`,
writer epoch 9). The owner account is real, email-verified, with a completed
profile and one server. The restricted public profile is active; the
full-static public profile has not been published.

The engine is in the "close remaining delivery gaps, then qualify and deploy"
stage. Verification is moving from browser-only acceptance to scripted API
acceptance (`scripts/acceptance/`), with the browser used only for visual
confirmation. The `integrate-4` batch adds canonical `message:updated` and
system-notice frames, durable mention-delivery occurrences with `agent:start`
resume context, unified resident-launch adoption on both ready and
`agent:session` with takeover-epoch scoping, the gated fresh-database PG fixes,
the complete channels/joint and thread-read route family, attachment preview
and agent attachment context, the missing internal agent API routes,
account/billing/push/raftbench/avatar routes, and one shared handle validator
for register, complete-profile and username-available. It also carries the
keep-session restart fix (a queued message rides `agent:start.wakeMessage` and
releases exactly once), the single `LegacyAgentMachineGate` plus middleware for
every legacy `/internal/agent/:id/*` route, the developer-platform integration,
MCP OAuth and action-reconfirm route families, real avatar/logo object storage
with the public capability routes, and the shared zod-4 auth issue builder with
the password-length rules, and the shared `/internal/agent-api` request-contract
validator (one engine and transport gate for every route upstream wires, in the
pinned capability, per-agent-grant, then params/query/body order, including task
history/unclaim, the direct upload sessions and integration-app management). It
awaits the trunk gate and a deploy.

## What works

- **Parity ledger.** 406 upstream modules tracked and locked: route cases
  2000/2000, socket 16/16, daemon 2616/2616 with the exclusions recorded in
  `docs/PARITY.tsv`. `make parity-check` validates status, commits, case
  accounting and the new locking-test column.
- **Real-process gates.** `make test-sharded` runs the full suite as parallel
  test-runner shards; `make test-e2e` starts two isolated `RaftServer`
  processes plus `RaftDaemon`; `scripts/smoke-server.sh` passes 26 live checks;
  `make architecture` passes its layering/size/seam guardrails.
- **Real PostgreSQL acceptance.** Gated suites cover onboarding, presence and
  restart recovery, offline agent queue, resident delivery, human message
  execution, realtime active-auth, runtime forms/breakers, machine queries,
  business-persistence fail-closed, email shutdown, mention-delivery
  occurrences, opener-notice recovery and infrastructure fencing.
  `make test-pg` runs them on one throwaway PostgreSQL 17 + Redis pair.
- **Delivery paths.** Human auth (web/native/mobile), server/channel/DM/task/
  thread/attachment routes, owner onboarding (survey, handoff, opener-v2
  briefing and Team-Mode thread/artifact), resident agent delivery, presence
  reconciliation, resident-launch adoption after a restart, mention deliveries
  (durable occurrences, redrive and outcome projection), task history and
  `asTask`, canonical message payloads and `message:updated` updates, system
  notices, Socket.IO room joins/`message:new`/`thread:updated`/`dm:new`,
  `activityDetailKind` and terminal-failure visibility, the channels joint/
  conversion and saved-message routes, attachment preview plus agent attachment
  metadata and thread-parent read authority, the internal agent API contract
  validator on the task history/unclaim, avatar, upload-session and
  integration-app routes, legacy
  machine agent routes behind one machine-ownership gate and scope table, the
  developer-platform App-management/integration/MCP OAuth/action routes, real
  user/server/agent avatar and integration-logo byte storage behind
  `/api/avatars` and `/api/integration-logos`, and account (forgot-password,
  username-available), billing, push and raftbench routes.
- **Route inventory.** `make route-inventory` dumps the booted Vapor router and
  diffs it against the pinned Express registrations into
  `docs/route-inventory.md`: upstream 644, Swift 611, exact matches 583,
  parameter variants 1, missing 57, extra 27. The channels family is complete
  (64/64, missing 0), and the developer-platform integrations family dropped
  from 19 missing to 3.
- **Production operations.** Reproducible Main release build, stage, verify and
  maintenance-ordered upgrade are in `deploy/swift-production/`; the previous
  release is kept for rollback and the pre-upgrade `pg_dump` is taken.

## Open defects and gaps

| ID | Finding | State | Next action |
| --- | --- | --- | --- |
| G1 | A verified owner with no membership still got 401 from `GET /api/servers` instead of 200 `[]` | Fixed on trunk with the canonical-principal collection path; gated by a real-PG onboarding acceptance | Re-qualify the affected release and deploy; confirm with scripted acceptance server collection |
| G2 | The opener ledger notice is not delivered/stamped in production | Fixed on `integrate-4`: a complete ready or `agent:session` retires a never-dispatched previous-epoch start, adopts the resident launch and clears connection-loss recovery, so the opener ledger notice is admitted and delivered. Gated by `AgentExecutionRestartRecoveryTests` and `postgresOwnerOpenerLedgerNoticeReachesAResidentAgentAfterMainRestart` | Deploy the integration release and confirm the sent stamp on the next Computer ready; do not fabricate it |
| G3 | Ready-time agent status/activity could stay `inactive`/`offline` while the process runs | Presence reconciliation, ready `runningAgents` handling, `activityDetailKind` and the terminal-failure pause projection are implemented and gated | Confirm live status after the next deploy |
| G4 | Legacy opener instruction text when the opener flag is explicitly off | Deliberately out of scope (see DEVIATIONS D11) | Re-open only if the flag is turned off in production |
| G5 | Full-static public profile not yet published | Restricted profile verified; public entry still limited | Publish only after full Web/console and provider acceptance |
| G6 | Official Computer/Codex/provider acceptance after the latest release | Separate from the unit gate by design | Run it after deploy and record the result in the deployment record |
| G7 | One `make test` run hung in an unrelated test | Test-scaffold lost-wakeup fix merged; sharded runner now isolates and retries | Re-run `make gate`; keep the shard log if it recurs |
| G8 | Activity trajectory entries and gap recovery are not stored | Deliberate (see DEVIATIONS D10) | Re-open only if the pinned Web consumes them |
| G9 | Fresh-database `make test-pg` exposed warm-database fixtures and one epoch-scoping defect: the fourteen-owner snapshot assumed one shared revision although the fail-closed writer commits changed rows only; the config-breaker fixture left durably queued wakes unacknowledged after the resident-delivery release made them real deliveries; the Built-in unavailable projection expected the old two-provider metadata instead of the pinned sixteen-preset plus two-gateway catalog; the lease-loss journal only accepted the stale-heartbeat cause, not the fenced command that lost its session first; and an unexited process from an older human-takeover epoch was treated as the new epoch's live runtime. The keep-session wake integration added three more: a tracked mention action was dropped instead of queued for an admitted launch, and two gated suites waited for `agent:deliver` without reporting the process identity, or assumed a trigger message never rides the start. | Fixed and merged; the full `make test-pg` passes 46/46 gated startup suites plus database-health and infrastructure-check on the integration commit | Deploy after the integration gate and the full persistence gate |
| G10 | Route inventory still lists 57 upstream Express registrations without a Swift counterpart and 27 Swift-only routes; the largest remaining families are `internal*.ts` (28, mostly agent-side labs/machine/profile variants and trace ingest), other/top-level (8), slack-bridge (6), public search index/detail (4) and integrations (3). | Tracked by `docs/route-inventory.md`; most missing families are unported external services covered by D5/D12/D19/D21 or not referenced by the pinned Web/CLI | Re-run `make route-inventory` after each slice; register the reachable gaps and record every remaining exclusion in `docs/DEVIATIONS.md` |

## Next steps

1. Run `make gate` once on the integration commit; fix only real failures.
2. Run `make test-pg` because persistence and agent execution changed.
3. `make deploy COMMIT=<sha>` after the gate, with the quick `pg_dump` backup
   taken by the upgrade script.
4. Run the read-only scripted acceptance, then the full scripted acceptance in
   a quiet window; use the browser only for UI confirmation.
5. Finish official Computer enrollment/model execution, workspace and cold-read
   checks, restart recovery and console audit on the deployed release.
6. Publish the full-static public profile and run the public canary.

## Completion conditions

The objective is complete when all of the following hold on one qualified
release:

- `make gate` and `make test-pg` pass on the integration commit.
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
scripted acceptance report. Do not report Swift test counts as upstream
coverage, and do not treat a locked ledger or a passing unit test as proof of
the production user path.
