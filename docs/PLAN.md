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
confirmation.

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
  business-persistence fail-closed, email shutdown and infrastructure fencing.
  `make test-pg` runs them on one throwaway PostgreSQL 17 + Redis pair.
- **Delivery paths.** Human auth (web/native/mobile), server/channel/DM/task/
  thread/attachment routes, owner onboarding (survey, handoff, opener-v2
  briefing and Team-Mode thread/artifact), resident agent delivery, presence
  reconciliation, mention deliveries, task history and `asTask`, canonical
  message payloads, Socket.IO room joins/`message:new`/`thread:updated`/`dm:new`.
- **Production operations.** Reproducible Main release build, stage, verify and
  maintenance-ordered upgrade are in `deploy/swift-production/`; the previous
  release is kept for rollback and the pre-upgrade `pg_dump` is taken.

## Open defects and gaps

| ID | Finding | State | Next action |
| --- | --- | --- | --- |
| G1 | A verified owner with no membership still got 401 from `GET /api/servers` instead of 200 `[]` | Fixed on trunk with the canonical-principal collection path; gated by a real-PG onboarding acceptance | Re-qualify the affected release and deploy; confirm with scripted acceptance server collection |
| G2 | The opener ledger notice is not delivered/stamped in production | Diagnosed; visible opener messages and the Team-Mode thread/artifact are present | Confirm the retry path on the next Computer ready; do not fabricate the sent stamp |
| G3 | Ready-time agent status/activity could stay `inactive`/`offline` while the process runs | Presence reconciliation and ready `runningAgents` handling are implemented and gated | Confirm live status after the next deploy |
| G4 | Legacy opener instruction text when the opener flag is explicitly off | Deliberately out of scope (see DEVIATIONS D11) | Re-open only if the flag is turned off in production |
| G5 | Full-static public profile not yet published | Restricted profile verified; public entry still limited | Publish only after full Web/console and provider acceptance |
| G6 | Official Computer/Codex/provider acceptance after the latest release | Separate from the unit gate by design | Run it after deploy and record the result in the deployment record |
| G7 | One `make test` run hung in an unrelated test | Test-scaffold lost-wakeup fix merged; sharded runner now isolates and retries | Re-run `make gate`; keep the shard log if it recurs |
| G8 | Activity trajectory entries and gap recovery are not stored | Deliberate (see DEVIATIONS D10) | Re-open only if the pinned Web consumes them |
| G9 | `make test-pg` with one fresh database per test exposes gated tests that were only passing on a warm database or under low load: `postgresMentionActionsRequireActualAgentReceiptsAndAtomicClaims` (`.invalidSnapshot`, expects 14 durable documents), `postgresRuntimeConfigChangesLiftOnlyCommittedTerminalBlocks` (`.timeout` after 30s) and `postgresRuntimeFormSourcesUseActualMachineQueries` (projection expectations). `writerLeaseLoss...` and `RuntimeFormSources` also appeared load-sensitive. | Tooling is correct; these are test-fixture or product gaps outside the process slice | Owning area (agent execution/persistence) should re-run each test alone on a fresh database and fix the fixture dependency or the product path; do not mask them with a retry |

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
