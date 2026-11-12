# Architecture: modular single-process Main

**Status (2026-11-12):** This describes the Main source architecture. Current
release identity, gate acceptance and rollout status are tracked in
[PLAN.md](PLAN.md); this file owns the target layering, persistence invariants and
architecture guardrail numbers.

**Specification:** observable HTTP status codes, JSON bytes, response headers
and socket frames from `raft-source` tag `v1.21.23-source.1`. Refactoring keeps
validation order, omission versus null, input coercion and stored JSON
fingerprints.

**Scope:** `RaftHTTP`, `RaftHTTPServer`, `RaftRealtime`, `RaftServer`,
`RaftMachineSocket`, `RaftConnectAuth`, `RaftShared`, `RaftPersistence`,
`RaftRedis`, `RaftObjectStorage`, `RaftDaemonClient` and `RaftDaemon`. Shared
targets are counted once. Generated sources are included in the unchecked
conformance and `ForTesting` scans; the embedded-corpus file-size scans exclude
`Sources/RaftHTTPServer/Generated/`, which does not exempt generated executable
code from the unchecked scan.

## 1. Runtime topology

Main is one stateful process with three listeners on separate ports:

| Listener | Implementation | Role |
| --- | --- | --- |
| HTTP | Vapor at the pinned revision | API routes, middleware, JSON projection, lifecycle |
| Socket.IO | SwiftNIO `RealtimeServer` | Engine.IO v4 polling, upgrade, socket frames |
| `/daemon/connect` | SwiftNIO `MachineConnectServer` | Raw machine upgrade and `machine:context` |

`SOCKET_PORT=0` disables the Socket.IO listener and `DAEMON_CONNECT_PORT=0`
disables `/daemon/connect`. `PORT=0` does not disable HTTP: the entrypoint only
applies the configured port when it is greater than zero, so zero retains
Vapor's default HTTP port. Vapor does not host the Socket.IO
upgrade; the pinned Vapor snapshot has no WebSocket upgrade, so both socket
surfaces stay on SwiftNIO. HTTP remains a stateful service: one process owns the
retained domain owners, the realtime hub and the single PostgreSQL writer. A
second Main process cannot share that state or claim the writer lease; it fails
closed instead of scaling horizontally. Realtime fan-out is process-local, not
Redis pub/sub.

Production external dependencies are deliberately narrow:

- **PostgreSQL** is the durable authority. It stores thirteen domain roots plus
  the separate native-notifications root, the writer fence and the durable
  outbox. Without a configured database the process keeps `/health` at 503.
- **Redis** backs only the shared public-search minute bucket and the explicit
  readiness ping. It does not store sessions, domain records or socket state.
- **Object storage** is S3-compatible, using Cloudflare R2 in production.
  `S3AttachmentStorage` encrypts attachment and avatar bytes, writes them
  outside PostgreSQL, and keeps only object references in the owned rows.

The production Computer is the upstream Node `raft-computer` process, outside
this repository. The Swift `RaftDaemon`/`RaftDaemonClient` is a minimal
handshake and reconnect client used to prove the daemon wire; it is not the
shipped provider runtime and does not replace the official Computer.

## 2. Owner graph and production composition

`EmailLoginDirectory` is a 28-line root that retains thirteen actual owners:
twelve stores plus the OAuth ledger. It holds references and deployment
configuration only; it has no global lock, field proxies or domain decisions.
`makeDurableBindings()` binds fourteen codecs because the notifications store
has an additional `native` root. Every codec reads and restores the same owner
instance; no second graph is constructed for persistence.

The explicit composer takes all thirteen owners and builds one
`ServiceContainer`: nine immutable groups containing 64 concrete Service/Support
values. `ProductionFeatureGraph` pairs that container with the owner-bound
`OnboardingBriefingService`. `FallbackServices.featureGraph` defaults to
`emailAccounts.productionFeatureGraph()`, so production constructs the graph
over the same directory it restores and wires. `ServiceContainer()` still
allocates a fresh graph for tests and standalone use; production does not call it
after wiring.

The accepted production cutover covers three Feature families:

- `AuthFeature`, `OAuthFeature` and `IntegrationsFeature` consume
  `ProductionFeatureGraph` service values for identity, OAuth, apps,
  integrations, cards and the onboarding briefing.
- Focused HTTP tests mount `configure` with an explicit graph over a separate
  directory and prove `/api/auth/me`, `/api/auth/providers`,
  `/api/integrations/clients`, global and scoped OIDC discovery, and live
  deployment changes. A factory-backed mount would fail those cases.
- The graph retains owners rather than construction snapshots: accounts,
  servers and deployment configuration added after composition are visible.

All other Feature mounts still obtain services through `FallbackServices` and
`EmailLoginDirectory` factory/accessor methods: Agents, Computers, Reminders,
Notifications, Servers, Channels, Messaging, Feedback, Translation, Public,
Billing, RaftBench, Knowledge, avatar routes and the internal surfaces. Those
methods read the same owners but remain transitional composition debt. The old
root is not deleted, and this document does not claim a complete production
cutover.

## 3. Persistence and commit invariants

Persistence is coarse-grained by design. Each of the fourteen bindings serializes
a complete domain root, not individual rows. There is one fenced PostgreSQL
writer:

- A dedicated PostgreSQL session holds an advisory lock and a monotonically
  increasing writer epoch. A competing process cannot claim the lease.
- All business commands share one FIFO. The permit spans operation, SQL commit,
  publication and deferred-effect flush; actor isolation alone would let another
  command enter at an await.
- `compareAndSwap` validates the writer epoch and every expected revision inside
  one serializable transaction. Durable effects are inserted in that same
  transaction before COMMIT.

Startup and activation preserve the same ownership:

1. `start` restores the owner rows but deliberately leaves admission closed.
2. Application wiring installs live relay, provider and secret configuration on
   those owners.
3. `activate` encodes all fourteen bindings once from the committed read view and
   seeds the canonical committed-byte cache. This post-restore, post-wiring seed
   prevents pure wiring from looking like a durable change.
4. Only then does admission open and the listeners begin serving.

Every command encodes each pending snapshot once, then compares its bytes with
the canonical cache. A pure read performs no write and consumes no revision. A
changed command writes only the changed roots, but the transaction still
validates all fourteen revisions. The cache advances only after PostgreSQL
confirms COMMIT and the returned revisions cover every changed binding.
Rollback, a failed commit or an unknown outcome never advances it; an unknown
business commit fails admission closed, and production exits for a supervisor
restart rather than continuing as a 503-only zombie.

An effects-only command still writes every binding as the transaction payload,
but reuses the pending snapshots already encoded for that transaction instead of
encoding them again. The durable outbox is the deferred-effect carrier:
producers insert immutable effect IDs, workers claim and acknowledge them with
the same writer epoch, and receivers must deduplicate those IDs. Publication
runs only after commit; an ambiguous delivery consumes an attempt rather than
being blindly retried.

The real PostgreSQL codec test wraps the production bindings and counts actual
codec calls. It proves a pure read at 14 calls (was 28) and an effects-only
commit at 14 (was 42). Those are call counts, not latency, throughput or a
claim that persistence is twice or three times faster.

The tradeoff is explicit. Every command still serializes all fourteen roots, and
the cache retains one canonical `Data` per binding. A small edit rewrites a whole
domain root and pays a full-domain encode/copy. The 16 MiB limit applies to a
CAS/read payload, and each outbox payload is limited to 1 MiB; neither bounds the
steady-state cache or overall process heap. A single writer still serializes all
business commands, including `execute`-based pure reads. This is an intentional
atomic-coarse-snapshot design, not per-entity persistence and not a horizontal
scaling model.

## 4. Attachment transfer plane

The attachment transfer plane moves selected slow object I/O and multipart
collection out of the global writer FIFO without changing the contract family.

`AttachmentBodyPlanePolicy` classifies the exact raw request target, without
percent decoding or route reconstruction. Only these shapes use the bounded
transaction port:

- `GET` and `HEAD /api/attachments/<uuid>` for the raw body.
- `GET` and `HEAD /api/attachments/<uuid>/preview`.
- `GET` and `HEAD /api/attachments/<uuid>/html-preview`.
- `POST /api/attachments/upload` for a human multipart upload.

Flex admission still distinguishes human, machine, computer and preview-token
authority. The bounded path runs short committed phases around I/O:

1. Commit admission, authorization and the pre-I/O projection.
2. Perform object get/put or multipart body collection outside every writer
   permit.
3. Re-read the row and recheck this binding, the object reference, the message
   channel and the authorization decision in another short committed phase.
4. Commit row changes, or project the original refusal; a response is built only
   after those facts are settled.

A failed or definitely-uncommitted upload may delete the object it just wrote.
An unknown SQL outcome retains the object because the row may have committed;
automatic deletion would destroy a possibly referenced file.

Every other attachment shape stays on the legacy serialized path with its
existing errors: upload sessions, `url`, `urls`, `html-preview-url`, comments,
malformed or non-UUID IDs, aliases, trailing or doubled slashes, internal
agent/machine paths and public attachments. A false negative only keeps the old
serialization; the exact segment count and UUID check prevent a false positive.

`AttachmentTransferBudget.shared` runs at most four classified preparations at
once, using a cancellation-safe FIFO. It bounds multipart collection, object I/O
and response preparation only. It does not bound buffers retained by slow
clients while responses drain, connection memory or overall heap, and separate
instances do not coordinate.

## 5. Target layers

| Layer | Owns | Boundary |
| --- | --- | --- |
| Feature | Registration, request extraction, response status/headers/body projection | Calls services; does not implement domain state or hand-build JSON |
| Service | Authorization and validation order, domain orchestration, typed results/errors | Vapor-free; state belongs in stores |
| Store | Domain records and atomic domain operations | No HTTP replies or arbitrary callbacks under a state borrow; named fixed nested-owner capabilities are documented |
| DTO | Codable request values, `JSONBodyConvertible` response payloads, explicit outcomes | No mutable shared state and no Vapor dependency |
| Support | Small functions and policies with a named responsibility | Not another directory or a generic reply factory |
| Shared | Contracts consumed by multiple targets | Does not depend on server, daemon or Vapor targets |
| TestSupport | Test setup and observation of real outputs | Not imported by production targets |

Allowed dependency direction:

```text
Feature -> Service -> Store
    |          |        |
    +----------+--------+--> DTO / RaftShared
RaftRealtime -----------------> RaftShared
Tests ------------------------> TestSupport
```

The script enforces measurable rules, not every property in this table. Swift
compilation, owner binding review and published-path tests remain required.
Directory factory captures, broad Feature initialization dependencies and raw
ledger calls remain debt in the unmigrated Features listed in section 2.

## 6. Architecture guardrails

Run `make architecture` or `python3 scripts/check_architecture.py`. `--json`
returns a machine-readable report; `--root PATH` checks another checkout. Python
exits 0 for pass/warnings, 1 for a violation and 2 for invalid input or an
operational error.

| Check | Rule | Current 22-PASS state | Headroom |
| --- | --- | --- | --- |
| Directory root | `EmailLogin.swift` at most 28 lines | 28 lines | 0 |
| Feature size | Every Feature/helper file at most 1,200 lines | 29 files, largest 1,045 | 155 |
| Service size | Every Service/accessor file at most 1,200 lines | 191 files, largest 1,174 | 26 |
| Store size | Every Store file, including nested extension files, at most 1,000 lines | 67 files, largest 945 | 55 |
| Composition size | Each Composition file at most 1,000 lines | 7 files, largest 713 | 287 |
| Container size | `ServiceContainer` at most 28 lines | 17 lines | 11 |
| Retired directory | No Swift files under `Sources/RaftHTTP/EmailLogin/` | absent | n/a |
| Production test markers | No `ForTesting` baseline across `Sources/` | 0 | 0 |
| Service imports | `import Vapor` hard zero in `Services/` | 0 in 191 files | 0 |
| Composition values | Exactly nine public groups of approved concrete values | 9 groups, 64 values | n/a |
| Composition boundaries | Hard zero Vapor, HTTPReply, JSONSerialization, Any and AnyObject; protected declarations stay in canonical files | 0 violations | 0 |

The fresh 22-PASS static run is
`/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/integrated-all-slices-static.log`.
It reports 191 Service files with the largest still 1,174, 67 Stores with the
largest 945, 29 Feature files with the largest 1,045, and seven Composition
files. The 26-line Service headroom and all other bounds are unchanged.

The fresh run keeps the ratchets unchanged: six directory extension occurrences
across six files, zero directory forwarders, zero Service reply tokens, one
Service/DTO JSON-any occurrence (a comment), 60 server reply tokens across 21
files, 81 server JSON-any occurrences across 20 files, 43 directory references
across 24 files, 162 server string-literal candidates across 55 files, three
unchecked Sendable declarations across two daemon-only files and zero in the
server closure. This is textual ratchet state, not a runtime operation count and
not proof that all handwritten response construction is gone.

Composition declaration checks use a restricted lexical grammar, not a Swift AST
or type resolver. They do not prove shared owner identity, free-function purity,
all alias chains, macro expansion or construction DAGs; regex literals are
outside the tokenizer's supported subset.

## 7. Gates and open proof

Every accepted slice runs its focused tests and affected published-path
regressions. The Lead then runs `make gate` on the integration commit and, for
persistence or transaction changes, serial `make test-pg`. Smoke is supplemental
real-process wiring evidence, not proof of every locked module. Integration uses
real merge commits. Detailed gate results, acceptance evidence, the current
release identity and rollout status live in [PLAN.md](PLAN.md); this document
does not duplicate that record or make a deployment or acceptance claim.

Remaining architecture debt is the unmigrated Feature factories and old root in
section 2, raw Feature ledger operations, the single writer and fourteen
whole-root encodes per command, unbounded process heap and slow-client response
buffers, and the daemon concurrency inventory. The target layering, owner graph,
persistence invariants and exclusions above are expected to stay stable through
gate and rollout.
