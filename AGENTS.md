# Raft source parity port

Equivalent reimplementation of the `raft-source` server and daemon at tag `v1.21.23-source.1`. The specification is observable behavior asserted by the upstream Node suite: HTTP status codes, JSON bodies, response headers, and socket frames. The 406 upstream parity modules are tracked in docs/PARITY.tsv; current locked/partial status and execution qualifications are recorded there and in docs/PLAN.md. The legacy machine-on-behalf attested-send module is partial: its E1/freshness funnel is not established by credential-route tests. Phase 6 defines the remaining architecture cleanup (docs/PLAN.md, docs/ARCHITECTURE.md). The current user delivery objective, stage and completion conditions live in docs/PLAN.md and the active session goal; architecture cleanup does not replace that objective.

## Work unit

One slice = either a behavioral parity slice (one upstream route module or one frame family) or a domain architecture refactoring slice. A refactoring slice moves one domain to `Feature -> Service -> Store` with `Codable` DTOs, `req.content.decode`, and `routes.grouped`, shrinking `EmailLogin.swift` / `EmailLogin+*.swift` without introducing mega-files (enforced by `make architecture`). 400–2000 changed lines, 2–5 turns, one commit. The plan and phase order live in `docs/PLAN.md`; the target layering lives in `docs/ARCHITECTURE.md`.

- Write the failing acceptance test first against the published path.
- One test file may lock a group of Node assertions from one upstream module.
- Do not port private helpers, query-count spies, tracer sinks, failpoints, or orchestrator injection unless the HTTP status/JSON/frame is the assertion and it is reachable without a spy.
- Delete a `recorded*` side channel when a slice touches it; replace it with the real output.

## Code-first delivery

- Before implementation or deployment, trace the complete user path in code: actual Web/CLI consumers -> registered routes and socket handlers -> DTOs -> Services -> authoritative Stores -> persistence and daemon/provider adapters. Compare the pinned upstream implementation and the fields actually consumed; a matching interface name or a registered route is insufficient.
- Build a bounded contract matrix for the delivery path. Record methods/paths, required and nested response fields, authentication and tenant scope, authoritative state, transitions, failure/restart behavior, current evidence and concrete gaps. Inspect the whole affected contract family before choosing a repair batch.
- Resolve connected gaps in a coherent batch. Do not use repeated browser attempts, one missing field at a time, as the primary development method. If runtime verification exposes a gap, return to the related code path and audit its dependent contracts before another build or browser pass.
- Derive projections from real retained facts. Never fabricate online/ready/completed status, metadata, historical timestamps, provider acceptance or persistence to satisfy a client. Distinguish required blockers from optional unsupported capabilities; document the latter instead of returning invented success payloads.
- Use published-path regressions and real integration outputs to validate the analysis. Run focused tests while a batch changes; run all required commit gates once the batch is stable. Browser and production canary checks verify the completed path; they do not substitute for code analysis or authorize skipping gates.
- Before starting production listeners, trace the actual gateway configuration and startup dependencies. An absent upstream is not an explicit maintenance barrier; verify how the process will become reachable and order bootstrap, enrollment, verification and activation accordingly.

## Tests and commits

- `make test` uses `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`; system `/usr/bin/swift` is 6.1.3, do not use it.
- Single test: `swift test --filter <TestName>`.
- Every slice must pass target tests, `make test`, `make test-e2e`, `./scripts/smoke-server.sh`, `make architecture`, and `make parity-check` before commit.
- One feature slice per commit. Imperative title; the body lists the behaviors the slice locks.
- The full suite occasionally aborts with signal 6 or 11; rerun once after an isolated pass. With `tee`, use `${PIPESTATUS[0]}`.
- Append locked behavior to `docs/BEHAVIOR.md`; keep `docs/PARITY.tsv` current when a slice changes a module's status.

## Progress

`make parity` reads `docs/PARITY.tsv` and prints locked modules and weighted case coverage. Report that, not test counts or turn counts. Locked parity cases do not prove a complete user path or production readiness.

- Keep the active user goal and docs/PLAN.md aligned: objective, current stage, verified results with their limits, known gaps, next coherent batch and completion conditions.
- Update them in the same working turn when the user changes direction, code analysis changes scope or sequencing, a gate fails, or a milestone is verified. Do not wait for the user to ask, the next checkpoint or context compaction; replace stale claims rather than appending a contradictory diary.
- Keep the original delivery objective active while resolving subproblems. A discovered DTO, fixture or deployment issue is a task within that objective, not a replacement goal. When a persisted session goal exists, update it as well as the plan and task list.

## Checkpoints

- A slice boundary is a checkpoint. Before a turn ends the repo must describe itself: the slice committed (or reverted), `docs/PARITY.tsv` and `docs/BEHAVIOR.md` current, `docs/PLAN.md` snapshot refreshed when the numbers moved.
- Context compaction is normal, not a blocker. Do not block the goal because a session is long: finish or revert the in-flight slice, write the next step into the docs, and continue on the next round.
- Never hand an unverified change to a later round. Green target test, `make test`, and `make test-e2e` when ports/processes are involved come first; the commit records the behaviors it locks.

## Constraints

- Vapor is pinned at `0f2a8ee9f38b2589c066b604de3e3168ed54c82d`. Do not switch to a branch, do not hand-edit `Package.resolved`.
- `/daemon/connect` stays in SwiftNIO. The socket.io listener is SwiftNIO too, on its own port: the pinned Vapor snapshot has no WebSocket upgrade.
- Without a database the process keeps `/health` at 503 `{"status":"error","detail":"database unreachable"}`.
- Every slice runs a single-process startup smoke. The two-real-`RaftServer` gate and completion logging close Phase 4.

## Documents

README is the project introduction. `docs/BEHAVIOR.md` is the append-only locked-behavior log. `docs/PLAN.md` is the plan. `docs/ARCHITECTURE.md` defines the target `Feature -> Service -> Store` layering and the `scripts/check_architecture.py` guardrails. This file is the working contract. Do not duplicate content between them; no per-step developer diary.

## Identifiers

Next new user starts at `11111111-1111-4111-8111-111111111651`; next server starts at `33333333-3333-4333-8333-333333333677`.

## Source

`/mnt/data/tmp/grok/raft-source-v1.21.23/`, tag `v1.21.23-source.1`. OAuth ledger in `Sources/RaftHTTP/OAuthLedger.swift`; Vapor route registrations in `Sources/RaftHTTPServer/FallbackApplication.swift`; feature modules in `Sources/RaftHTTPServer/Features/`; domain services in `Sources/RaftHTTP/Services/`; domain stores in `Sources/RaftHTTP/Stores/`; Codable DTOs in `Sources/RaftHTTP/DTO/`.
