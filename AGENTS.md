# Raft source parity port

Equivalent reimplementation of the `raft-source` server and daemon at tag `v1.21.23-source.1`. The specification is observable behavior asserted by the upstream Node suite: HTTP status codes, JSON bodies, response headers, and socket frames. All 406 upstream parity modules (219/219 route, 7/7 socket, 180/180 daemon) are locked, with the daemon execution/exclusion qualifications recorded in docs/PARITY.tsv and docs/PLAN.md. Active work is Phase 6 architecture cleanup (docs/PLAN.md, docs/ARCHITECTURE.md): typed Route -> Service -> Store boundaries, removal of remaining directory extensions/global-lock transactions, checked store isolation, and eventual ServiceContainer composition while keeping all parity, E2E, smoke, and architecture guardrails green.

## Work unit

One slice = either a behavioral parity slice (one upstream route module or one frame family) or a domain architecture refactoring slice. A refactoring slice moves one domain to `Feature -> Service -> Store` with `Codable` DTOs, `req.content.decode`, and `routes.grouped`, shrinking `EmailLogin.swift` / `EmailLogin+*.swift` without introducing mega-files (enforced by `make architecture`). 400–2000 changed lines, 2–5 turns, one commit. The plan and phase order live in `docs/PLAN.md`; the target layering lives in `docs/ARCHITECTURE.md`.

- Write the failing acceptance test first against the published path.
- One test file may lock a group of Node assertions from one upstream module.
- Do not port private helpers, query-count spies, tracer sinks, failpoints, or orchestrator injection unless the HTTP status/JSON/frame is the assertion and it is reachable without a spy.
- Delete a `recorded*` side channel when a slice touches it; replace it with the real output.

## Tests and commits

- `make test` uses `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`; system `/usr/bin/swift` is 6.1.3, do not use it.
- Single test: `swift test --filter <TestName>`.
- Every slice must pass target tests, `make test`, `make test-e2e`, `./scripts/smoke-server.sh`, `make architecture`, and `make parity-check` before commit.
- One feature slice per commit. Imperative title; the body lists the behaviors the slice locks.
- The full suite occasionally aborts with signal 6 or 11; rerun once after an isolated pass. With `tee`, use `${PIPESTATUS[0]}`.
- Append locked behavior to `docs/BEHAVIOR.md`; keep `docs/PARITY.tsv` current when a slice changes a module's status.

## Progress

`make parity` reads `docs/PARITY.tsv` and prints locked modules and weighted case coverage. Report that, not test counts or turn counts.

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

Next new user starts at `11111111-1111-4111-8111-111111111645`; next server starts at `33333333-3333-4333-8333-333333333671`.

## Source

`/mnt/data/tmp/grok/raft-source-v1.21.23/`, tag `v1.21.23-source.1`. OAuth ledger in `Sources/RaftHTTP/OAuthLedger.swift`; Vapor route registrations in `Sources/RaftHTTPServer/FallbackApplication.swift`; feature modules in `Sources/RaftHTTPServer/Features/`; domain services in `Sources/RaftHTTP/Services/`; domain stores in `Sources/RaftHTTP/Stores/`; Codable DTOs in `Sources/RaftHTTP/DTO/`.
