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
passes 11/11 in 67 s, including a Main restart, socket reconnect and a
post-restart reply from the official Computer/Codex agent. The opener ledger
read after that restart shows the `owner-opener-v2.0` stamp with four messages
and `needsManual` null.

The engine is in the "qualify the deployed release, then promote and deploy the
next integration" stage. Verification is scripted-first
(`scripts/acceptance/`), with the browser used only for visual confirmation.

A direct Computer-stop acceptance fails on the deployed release: with the
official Computer service stopped, a DM sent while it was offline got no
correlated reply within 180 s after the service started again. The connection
reported online and ready, but recovery was left in
`connection_lost_with_unsettled_execution`. The services remain active; the one
pending DM and its failure state are preserved deliberately, with `needsManual`
showing the connection-lost recovery and no manual reset applied, and the owner
account and Codex login are untouched. A recovery worker is implementing
retirement of the previous daemon execution on a complete empty ready with
ambiguity guards, and a read-only review of that change is active. The defect is
not fixed or verified yet, and nothing is published until its fix is gated and
accepted.

The authenticated Web pages for a channel, Tasks, Members and Computers render
against the deployed release. Each page logs the same 404 for
`/api/product-feedback/tickets`, the Hands feedback proxy that is intentionally
not ported (DEVIATIONS D5), so the console is not zero-error and the
zero-console condition stays open. The full-static public profile is still
unpublished.

The integration tree carries the merged process-refactor docs plus the agent-api
contract and OAuth slices. The validator slice (`b05e0fb`, merged as `8cbf1d5`)
passes 32/32 `LegacyAttestedSendTests` on the integrated source and adds zod-4
issues for legacy send and agent queries, the pinned request-contract schemas and
validator, and one capability/per-agent-grant/params-query/body gate over the
routes upstream wires. The auth slice (`01ce15a`, `d355cbd`, merged as `37607c5`)
passes 14 AuthCore plus 17 targeted auth tests and locks raw-JavaScript
completion-code truthiness before the pending-link token, the unknown-provider
404, mobile token-first order, and a truthy non-string code's generic 500 whose
body `correlationId` matches the `X-Slock-Error-Id` header. `make architecture`
(22/0) and `make parity-check` pass on the integrated source. The four original
`ccf4137` review findings are fixed in this tree, but no `make gate` or
`make test-pg` has run on the merged source: the recorded gate (3144 tests, one
isolated retry) and 46/46 fresh-database persistence run cover only `ccf4137`.
The integration is therefore not qualified and must not be called deployable or
deployed. A follow-up remains for task-history query consumption (G13). The
candidate build for `ccf4137` was canceled, so there is no release artifact,
upgrade record or scripted acceptance for the integration.

The correlated attachment-read acceptance (`a94b05e`, `0568eb2`) adds a two-round
hidden-nonce proof for the resident agent and keeps the downloaded output inside
the agent workspace. Its 11 network-free tests and the
12-check `--full --restart-main --dry-run` plan pass, but the real attachment
read has not run because the Computer-stop scenario still fails G11. A worker is
adding opt-in Computer-stop/offline-DM/start and agent keep-session restart
scripts that assert correlated first and second replies; it changes no
production source.

## What works

- **Parity ledger.** 406 upstream modules tracked and locked: route cases
  2000/2000, socket 16/16, daemon 2616/2616 with the exclusions recorded in
  `docs/PARITY.tsv`. `make parity-check` validates status, commits, case
  accounting and the new locking-test column.
- **Real-process gates.** `make test-sharded` runs the full suite as parallel
  test-runner shards (3144 tests in the last recorded integration gate, with one
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
  agent-query zod-4 issue bodies are in the integration tree only and are not
  deployed.
- **Route inventory.** `make route-inventory` dumps the booted Vapor router and
  diffs it against the pinned Express registrations into
  `docs/route-inventory.md`: upstream 644, Swift 611, exact matches 583,
  parameter variants 1, missing 57, extra 27. The channels family is complete
  (64/64, missing 0), and the developer-platform integrations family dropped
  from 19 missing to 3.
- **Deployed acceptance.** The scripted acceptance against the running release
  passes 11/11 in 67 s: health/version, owner login and refresh, server
  collection, read-only revision sweep, DM and mention replies, Task creation,
  attachment download and HTML preview, thread reply with `thread:updated`, and
  a unit restart with socket reconnect and a post-restart official Codex reply.
- **Production operations.** Reproducible Main release build, stage, verify and
  maintenance-ordered upgrade are in `deploy/swift-production/`; the current
  release replaced `7b4cd3c8`, and that release with the pre-upgrade `pg_dump`
  is retained for rollback.

## Open defects and gaps

| ID | Finding | State | Next action |
| --- | --- | --- | --- |
| G1 | A verified owner with no membership still got 401 from `GET /api/servers` instead of 200 `[]` | Fixed in the deployed `15219ef` release with the canonical-principal collection path; gated by a real-PG onboarding acceptance | Confirm the deployed release returns 200 `[]` for a verified owner with no membership; the production owner currently has a server |
| G2 | The opener ledger notice is not delivered/stamped in production | Confirmed on `15219ef`: the ledger read after a Main restart shows the `owner-opener-v2.0` stamp with four messages and `needsManual` null. The fix (a complete ready or `agent:session` retires a never-dispatched previous-epoch start, adopts the resident launch and clears connection-loss recovery) is gated by `AgentExecutionRestartRecoveryTests` and `postgresOwnerOpenerLedgerNoticeReachesAResidentAgentAfterMainRestart` | Keep the stamp check in the Computer acceptance; re-open if a restart clears or duplicates it |
| G3 | Ready-time agent status/activity could stay `inactive`/`offline` while the process runs | Presence reconciliation, ready `runningAgents` handling, `activityDetailKind` and the terminal-failure pause projection are deployed and gated | Confirm live status after the next Computer ready and after a Main restart |
| G4 | Legacy opener instruction text when the opener flag is explicitly off | Deliberately out of scope (see DEVIATIONS D11) | Re-open only if the flag is turned off in production |
| G5 | Full-static public profile not yet published | Restricted profile verified; public entry still limited | Publish only after full Web/console and provider acceptance |
| G6 | Official Computer/Codex/provider acceptance after the deployed release | Partially run on `15219ef`: the Web pages render and a Main restart produced a real Codex reply, but the direct Computer-stop/offline-DM/restart scenario fails (G11) | Fix and gate G11, then rerun the full Computer acceptance and record the result with the deployment record |
| G7 | One `make test` run hung in an unrelated test | Test-scaffold lost-wakeup fix merged; the sharded runner isolates and retries, and the last recorded integration gate passed its one isolated Kimi token-refresh retry | Re-open only if a failure survives the isolated retry; keep the shard log |
| G8 | Activity trajectory entries and gap recovery are not stored | Deliberate (see DEVIATIONS D10) | Re-open only if the pinned Web consumes them |
| G9 | Fresh-database `make test-pg` exposed warm-database fixtures and one epoch-scoping defect: the fourteen-owner snapshot assumed one shared revision although the fail-closed writer commits changed rows only; the config-breaker fixture left durably queued wakes unacknowledged after the resident-delivery release made them real deliveries; the Built-in unavailable projection expected the old two-provider metadata instead of the pinned sixteen-preset plus two-gateway catalog; the lease-loss journal only accepted the stale-heartbeat cause, not the fenced command that lost its session first; and an unexited process from an older human-takeover epoch was treated as the new epoch's live runtime. The keep-session wake integration added three more: a tracked mention action was dropped instead of queued for an admitted launch, and two gated suites waited for `agent:deliver` without reporting the process identity, or assumed a trigger message never rides the start. | Fixed and merged; the last recorded fresh-database run passes 46/46 gated startup suites plus database-health and infrastructure-check for the deployed trunk and the `ccf4137` integration tree | Keep the fresh-database run in the deploy checklist; re-open if a fixture depends on warm state again |
| G10 | Route inventory still lists 57 upstream Express registrations without a Swift counterpart and 27 Swift-only routes; the largest remaining families are `internal*.ts` (28, mostly agent-side labs/machine/profile variants and trace ingest), other/top-level (8), slack-bridge (6), public search index/detail (4) and integrations (3). | Tracked by `docs/route-inventory.md`; most missing families are unported external services covered by D5/D12/D19/D21 or not referenced by the pinned Web/CLI | Re-run `make route-inventory` after each slice; register the reachable gaps and record every remaining exclusion in `docs/DEVIATIONS.md` |
| G11 | A DM sent while the official Computer is stopped gets no reply after the Computer restarts | Open on `15219ef`: no correlated reply within 180 s; the connection is online and ready but recovery stays in `connection_lost_with_unsettled_execution` with one pending human delivery. The services and the live failure state are retained deliberately | Recovery worker is implementing retirement of the previous daemon execution on a complete empty ready with ambiguity guards; a read-only review is active. Not fixed or verified; publish only after a gated, accepted fix and a rerun of the direct stop/offline/restart scenario |
| G12 | Contract review of `ccf4137` found four defects: object-refinement schemas suppress check errors; `integration:register_app` accepts a body without the required `name` and with a duplicate `returnUrl`; provider-complete validation precedence is wrong; binary/octal and `Infinity` coercion is wrong | The four findings are fixed in the integration tree (`8cbf1d5`, `37607c5`); 32/32 contract tests and 14 + 17 targeted auth tests pass on the integrated source, with `make architecture` and `make parity-check` green. No full gate has run on the merged source | Rerun `make gate` and `make test-pg` on the integration commit after G13 lands; only then may the integration be called qualified |
| G13 | Task-history validation accepts JavaScript-coerced numerics such as `0b101`, but the route still converts the raw `task_number` with `Int(...)`, so the service receives 0 instead of the accepted number | Open; a worker is normalizing actual task-history consumption | Land the consumption fix with byte-level tests, then include it in the integration gate |

## Next steps

1. Confirm the remaining deployed `15219ef` behaviors: live agent presence (G3)
   and `GET /api/servers` = 200 `[]` for a verified owner with no membership
   (G1). The opener stamp (G2) is confirmed.
2. Fix the Computer offline-delivery recovery defect (G11) and complete the
   read-only review; gate and accept the fix, then rerun the direct
   stop/offline/restart scenario. Do not treat it as fixed before that run.
3. Land the task-history consumption fix (G13) and the in-flight opt-in
   Computer-stop/keep-session acceptance scripts. Then run `make gate` and
   `make test-pg` on the integration commit; the integration is not qualified
   until both pass.
4. Run the real two-round attachment-read acceptance once the Computer-stop
   path is unblocked, and record it with the release evidence.
5. Promote the gated integration to trunk with a real merge, then build, stage,
   verify and `make deploy COMMIT=<sha>`. Keep `15219ef` and the pre-upgrade
   `pg_dump` as the rollback pair; do not deploy the canceled `ccf4137`
   candidate.
6. Run the read-only scripted acceptance, then the full scripted acceptance
   (including the Main restart) on the new release in a quiet window.
7. Run official Computer enrollment, model execution, workspace and cold-read
   checks, the direct stop/offline/restart recovery and the browser console
   audit on the deployed release.
8. Publish the full-static public profile and run the public canary only after
   the Web/console and provider checks pass; clean up the release stage and keep
   the D5 `/api/product-feedback/tickets` 404 documented. These remain pending.
9. Re-run `make route-inventory` and either implement the reachable G10 gaps or
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
  pages other than documented DEVIATIONS entries.
- The official Computer/Codex path completes a real reply and survives a Main
  restart and a Computer stop/start without manual intervention.
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
