# Working contract

This file is the working agreement for changes in this repository. It is not a
plan; current status and completion conditions live in [docs/PLAN.md](docs/PLAN.md),
deliberate upstream differences in [docs/DEVIATIONS.md](docs/DEVIATIONS.md), and
the target layering in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Environment

- The deployment on this machine is the owner's own development/production-like
  environment, not a public service. The agent team may restart services, reset
  agents and create test data. Keep the owner's account and Codex login intact,
  never commit secrets, domains or IP addresses, and take the quick `pg_dump`
  backup on every deploy (the upgrade script does).
- The specification is observable upstream behavior at
  `/mnt/data/tmp/grok/raft-source-v1.21.23/`, tag `v1.21.23-source.1`: HTTP
  status codes, JSON bodies, headers and socket frames.
- Development, builds, caches, services and temporary artifacts use the data
  disk. Production credentials and environment-specific paths stay outside Git.

## Branch and worktree strategy

- Trunk is `deploy-linux-docker`; it is what gets deployed. Do not develop
  directly on it.
- Work happens in a few persistent per-area worktrees under
  `/mnt/data/raft-swift-development/batch/<area>` with a warm `.build`, so a
  fix does not pay a cold build or copy large build directories. Keep the
  worktree set small; one worktree per active area, not one per fix.
- Each fix or slice uses a short-lived branch from trunk. Merge integration
  branches with real merge commits (`git merge --no-ff`), never by copying
  files or rebasing someone else's history away.
- `Sources/` and existing test logic are owned by the area branches. Tooling,
  scripts and docs changes must not rewrite them from a process branch.
- Run focused tests while developing. Do not spin up a new cold worktree just
  to run one test; use `make check FILTER=<regex>` in the area worktree.

## Tiered gates

| Gate | Command | When |
| --- | --- | --- |
| Focused | `make check FILTER=<regex>` | Every edit loop: incremental build + only matching tests (minutes). |
| Affected suites | `swift test --filter <Suite>` or `make check FILTER='<suite>'` | Before handoff when the change touches a bounded area. |
| Trunk gate | `make gate` | Once on the integration commit before merging to trunk. Runs test-sharded, test-e2e, smoke, architecture and parity-check, fail-fast, logs to one directory. |
| Persistence gate | `make test-pg` | When persistence, transactions, writer fail-closed or agent execution changes. One throwaway PostgreSQL 17 + Redis pair, every gated real-PG suite, then removal. |
| Sharded suite | `make test-sharded [SHARDS=N]` | Full suite in parallel test-runner shards, with one isolated retry for a failed test. Use it instead of a serial `make test` for the full suite. |

`make test` and the existing individual targets remain valid, but the tiered
path above is the expected one. Never treat a locked parity ledger, a passing
unit test, or a smoke check as a complete user path.

One Swift build runs at a time per worktree; parallel sharded test runners are
fine because they run tests against one build. `make gate` and `make test-pg`
both launch their own build, so run them sequentially in the same worktree. A
separate warm build area is fine as long as it stays on the data disk. All build
artifacts, logs, caches and temporary files stay on the data disk and outside Git.

## Acceptance

- Scripted first: `scripts/acceptance/acceptance.py` runs the API checks against
  the running environment (health/version, owner login/refresh, servers, DM,
  mention, Task, attachment, thread, read-only revision sweep, optional
  restart). It writes JSON plus a human summary and exits non-zero on failure.
- The browser is for UI confirmation only: layout, console errors, visible
  state. Do not use repeated browser attempts as the primary development method.
- Failure policy: stop only for an outage (`/health` 503 or unreachable), a
  possible data corruption (read-only sweep moved persisted revisions), or a
  security signal. Record every other defect, continue, and mark dependent
  steps `BLOCKED`. Do not stop at the first cosmetic or isolated defect.
- Do not run message-sending acceptance while other campaigns are active
  against the same environment; use `--read-only` or `--dry-run` then.

## Deploy procedure

Environment-specific values live in `deploy/swift-production/local.env`
(git-ignored; copy `local.env.example`). Never commit that file.

```bash
make deploy COMMIT=<sha>
```

This resolves the full commit and runs build → stage → verify → upgrade. The
upgrade takes the quick `pg_dump` backup, closes the public gateway, swaps the
manifest and launch spec (keeping the previous release), starts the user unit,
verifies private health/version/PID mappings and restores the gateway. A
failure prints rollback instructions; follow them instead of improvising.
Staged verification must pass before the upgrade step; never install an
unverified artifact.

## Documentation policy

- Commit message body lists the observable behaviors the commit locks. It is
  the per-slice record; do not keep a parallel append-only behavior log.
- `docs/DEVIATIONS.md` records deliberate differences and adjudicated
  exclusions. Add an entry before claiming a deviation is intentional.
- `docs/PLAN.md` is current status only: objective, stage, deployed commit,
  what works, open defects, next steps, completion conditions. Replace stale
  statements instead of appending snapshots.
- `docs/PARITY.tsv` stays current when a slice changes a module's status. Its
  sixth column names the Swift test file(s) that lock the module, derived from
  the locking commit; blank means unknown.
- `docs/ARCHITECTURE.md` owns the target layering and guardrail numbers. Do not
  duplicate its content in the plan or this file.

## Proactive parity

- Before acceptance, build the route/payload inventory for the affected
  contract family: method/path, authentication, tenant scope, required and
  nested response fields, authoritative state, failure and restart behavior.
- Compare the actual pinned upstream implementation and the fields the real
  Web/CLI consumer reads; a matching route name is not parity.
- When a bug class is found, audit the same pattern across the codebase in the
  same fix. Do not fix one missing field per browser attempt.
- Do not port private helpers, query-count spies, tracer sinks, failpoints or
  orchestrator injection unless the HTTP status/JSON/frame is the assertion and
  it is reachable without a spy. Use `docs/DEVIATIONS.md` for the rest.

## Team coordination

- Before dispatching a task, check the in-flight tasks and their areas; never
  give the same defect to two workers. One owner per defect and per area
  worktree.
- Dispatch a fix as soon as a defect is confirmed; do not wait for the end of
  an acceptance round.
- Workers report: root cause with upstream citations, behaviors locked
  (commit-message style), deviations (proposed `docs/DEVIATIONS.md` entries),
  red→green evidence and gate log paths.
- Integrate finished branches in batches (roughly every one to two hours), run
  `make gate` (and `make test-pg` when relevant) once on the integration commit,
  push, then `make deploy`.

## Log hygiene

- Always write long-running command and service logs to files, then inspect the
  file. Never pipe a gate through `tee` (an undrained pipe can block the run).
- `make gate` writes one log per step under `.build/gate-logs/<stamp>/`;
  `make test-sharded` writes shard logs and `summary.json` under
  `.build/test-sharded/<stamp>/`; `make test-pg` writes suite logs under
  `.build/test-pg/<stamp>/`.
- Keep artifacts outside Git. Quote the log path in the report instead of
  pasting large output.

## Hard constraints

- Swift 6.4.1 only, at
  `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift`. Never use
  `/usr/bin/swift` or `/mnt/data/raft-swift-development/bin/swift`.
- Vapor is pinned at `0f2a8ee9f38b2589c066b604de3e3168ed54c82d`. Do not switch
  to a branch and do not hand-edit `Package.resolved`.
- `/daemon/connect` stays in SwiftNIO. The Socket.IO listener is SwiftNIO too,
  on its own port; the pinned Vapor snapshot has no WebSocket upgrade.
- Without a database the process keeps `/health` at 503
  `{"status":"error","detail":"database unreachable"}`.
- `make architecture` guardrails are binding: `Feature -> Service -> Store`,
  no Vapor imports in Services, per-file size limits, the composition
  container shape, and the test-seam scans. `make parity-check` is binding.
- Every accepted slice passes its focused tests and, on the integration commit,
  `make gate`. Persistence work also passes `make test-pg`.
- Keep the deployment rollback path (previous release plus pre-upgrade dump)
  until the new release is verified in normal operation.

## Identifiers

Next new user starts at `11111111-1111-4111-8111-111111111651`; next server
starts at `33333333-3333-4333-8333-333333333677`.

## Source map

`Sources/RaftHTTP/OAuthLedger.swift`; Vapor route registrations in
`Sources/RaftHTTPServer/FallbackApplication.swift`; feature modules in
`Sources/RaftHTTPServer/Features/`; domain services in
`Sources/RaftHTTP/Services/`; stores in `Sources/RaftHTTP/Stores/`; Codable DTOs
in `Sources/RaftHTTP/DTO/`. Release tools are in `deploy/swift-production/`;
acceptance tools are in `scripts/acceptance/`.
