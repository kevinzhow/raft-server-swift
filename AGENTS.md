# Raft source parity port

Equivalent reimplementation of the `raft-source` server and daemon at tag `v1.21.23-source.1`. The specification is observable behavior asserted by the upstream Node suite: HTTP status codes, JSON bodies, response headers, and socket frames. Daemon and server foundations exist; the route surface is incomplete. This is not done.

## Work unit

One slice = one upstream route module (or one frame family) plus the data model, events, authorization, and acceptance tests it needs. 400–2000 changed lines, 2–5 turns, one commit. The plan and phase order live in `docs/PLAN.md`.

- Write the failing acceptance test first against the published path.
- One test file may lock a group of Node assertions from one upstream module.
- Do not port private helpers, query-count spies, tracer sinks, failpoints, or orchestrator injection unless the HTTP status/JSON/frame is the assertion and it is reachable without a spy.
- Delete a `recorded*` side channel when a slice touches it; replace it with the real output.

## Tests and commits

- `make test` uses `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`; system `/usr/bin/swift` is 6.1.3, do not use it.
- Single test: `swift test --filter <TestName>`.
- Target test first, then `make test`; add `make test-e2e` when the slice spawns processes or binds ports. All green before commit.
- One feature slice per commit. Imperative title; the body lists the behaviors the slice locks.
- The full suite occasionally aborts with signal 6 or 11; rerun once after an isolated pass. With `tee`, use `${PIPESTATUS[0]}`.
- Append locked behavior to `docs/BEHAVIOR.md`; keep `docs/PARITY.tsv` current when a slice changes a module's status.

## Progress

`make parity` reads `docs/PARITY.tsv` and prints locked modules and weighted case coverage. Report that, not test counts or turn counts.

## Constraints

- Vapor is pinned at `0f2a8ee9f38b2589c066b604de3e3168ed54c82d`. Do not switch to a branch, do not hand-edit `Package.resolved`.
- `/daemon/connect` stays in SwiftNIO. The socket.io listener is SwiftNIO too, on its own port: the pinned Vapor snapshot has no WebSocket upgrade.
- Without a database the process keeps `/health` at 503 `{"status":"error","detail":"database unreachable"}`.
- Every slice runs a single-process startup smoke. The two-real-`RaftServer` gate and completion logging close Phase 4.

## Documents

README is the project introduction. `docs/BEHAVIOR.md` is the append-only locked-behavior log. `docs/PLAN.md` is the plan. This file is the working contract. Do not duplicate content between them; no per-step developer diary.

## Identifiers

Next new user starts at `11111111-1111-4111-8111-111111111622`; next server starts at `33333333-3333-4333-8333-333333333666`.

## Source

`/mnt/data/tmp/grok/raft-source-v1.21.23/`, tag `v1.21.23-source.1`. OAuth ledger in `Sources/RaftHTTP/OAuthLedger.swift`, routes in `Sources/RaftHTTPServer/FallbackApplication.swift`.
