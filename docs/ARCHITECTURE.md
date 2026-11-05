# Architecture: target Swift layering

**Status**: target design with executable guardrails. The tree is in a
transitional state: the route surface is registered inline in one file and the
domain behavior lives in one ledger class. This document defines where feature
slices move code, and `scripts/check_architecture.py` enforces the measurable
part of the target.

**Scope**: the HTTP/frame server surface (`RaftHTTP`, `RaftHTTPServer`,
`RaftRealtime`). The daemon targets (`RaftDaemonClient`, `RaftDaemon`,
`RaftMachineSocket`, `RaftConnectAuth`) keep their own layout and only consume
shared contracts once `RaftShared` exists.

**Specification**: observable behavior (status codes, JSON bodies, headers,
socket frames asserted by the upstream Node suite), per `AGENTS.md`. This
document does not add behavior; it only says where behavior belongs.

## 1. Why the port needs layers

Upstream `raft-source` (`v1.21.23-source.1`) is a modular Express 5 server:

| Upstream | Count | Role |
| --- | --- | --- |
| `packages/server/src/routes/*.ts` | 77 router modules, 149 `*.api.test.ts` files | One `Router` per domain, mounted in `app.ts` |
| `packages/server/src/services/*.ts` | 320 service modules | Domain logic and persistence calls |
| `packages/server/src/db/schema.ts` + drizzle | 1 schema + migrations | Persistence shape |
| `packages/server/src/middleware/` | auth, route-auth policy, observability | Cross-cutting request policy |
| `packages/shared` (`@botiverse/raft-shared`) | 116 modules | Request/response/event contracts shared by server, daemon, web, SDK |
| `__set…ForTests` helpers (guarded by `NODE_ENV === "test"`) | several | Test seams are explicit, exported, and environment-gated |

Our port currently collapses those boundaries into two files:

| File (measured 2026-11-05) | Size | Contents |
| --- | --- | --- |
| `Sources/RaftHTTPServer/FallbackApplication.swift` | 4,523 lines, 503 inline `app.<verb>(…)` registrations | Composition root **and** every route handler |
| `Sources/RaftHTTP/EmailLogin.swift` | 31,656 lines, 758 `public func` | Every in-memory domain store, lock, validation rule, serializer, and test seam |
| `Tests/RaftHTTPServerTests/*.swift` | 471 files | Mostly black-box HTTP tests through `configure(app, services:)` |

That is why parallel slices collide: every route slice edits the same two
files, and a 31k-line class has no isolated write scope. The target layering
gives each upstream route module a file, each upstream service module a file,
and each domain store its own lock.

## 2. Target layers

| Layer | Swift path | Owns | Must not |
| --- | --- | --- | --- |
| **Features** | `Sources/RaftHTTPServer/Features/<Name>/<Name>Feature.swift` | A `RouteCollection`: method, path, parameters, headers, body extraction, `routeResponse`/service invocation. One feature per upstream router module. | Contain domain rules, locks, persistence, or ad-hoc JSON string building. |
| **Services** | `Sources/RaftHTTPServer/Services/` | Orchestration: authorize, validate request shape, call stores, map results to DTOs, choose status/error codes. Vapor-free enough to unit test. | Store state, hold `NSLock`, or import `Vapor`/`RaftRealtime`. |
| **Stores** | `Sources/RaftHTTP/Stores/` | Domain state with a per-domain lock (`NSLock` today, `actor` where async is unavoidable), or the Postgres adapter behind the same API. One store per domain. | Build HTTP responses, know about routes, or call other stores while holding a lock. |
| **DTO** | `Sources/RaftHTTP/DTO/` | `Codable` request/response/event structs and one canonical encoder (`JSONEncoder` configuration or a shared `JSONValue`). Shapes follow upstream JSON exactly. | Hold mutable state or depend on Vapor. |
| **Test seams** | `Tests/TestSupport/` (test-only SwiftPM target) | Fakes, clocks, deterministic IDs, and hooks needed to assert behavior. | Be imported by a production target; appear as `…ForTesting` members on production types. |
| **Shared contracts** | `Sources/RaftShared/` (new dependency-free target) | Codable contracts and constants used by more than one target (server ↔ realtime ↔ daemon). | Import any other target, `Vapor`, or `Foundation` beyond pure Codable needs. |

### 2.1 Features

```swift
// Sources/RaftHTTPServer/Features/Notifications/NotificationsFeature.swift
import HTTPTypes
import RaftHTTP
import Vapor

public struct NotificationsFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "notifications", "devices") { request -> Response in
            routeResponse(services.notifications.listDevices(
                authorization: request.headers[.authorization]
            ))
        }
        // …one block per upstream route, copied verbatim from the composition root
    }
}
```

Rules:

- The file name is `<Name>Feature.swift`; the directory is the upstream router
  module name in PascalCase (`notifications.ts` → `Notifications/`).
- `boot` registers routes only. The handler body is the existing block moved
  unchanged: same method, path, header reads, `routeResponse` call. Extraction
  slices must not change behavior.
- The 1,200-line ceiling is the split signal: a feature that outgrows it gets
  split along an upstream route group, not left to grow.
- Features never access `EmailLoginDirectory` directly. They call
  `FallbackServices`/services entry points; the composition root constructs the
  services.

### 2.2 Services

A service is the transcription of an upstream `services/<name>Service.ts` (or a
cohesive group of route handlers) into Swift:

- takes explicit dependencies (`any Clock`, stores, emitters) via `init`;
- returns typed results or a small error enum; the feature (or a shared
  `routeResponse` helper) owns HTTP status/header projection;
- keeps the upstream error codes and statuses in one place per service;
- does not import `Vapor` so it can be tested without an `Application`.

### 2.3 Stores

The current `EmailLoginDirectory` already has the seed of this design: one
unchecked-Sendable class owning several per-domain `NSLock`s (accounts, agent
connections, realtime emitter, migrations, …). Target:

- one store type per domain (`AccountsStore`, `ChannelsStore`,
  `NotificationsStore`, `AgentKnowledgeStore`, …) in `Sources/RaftHTTP/Stores/`;
- state and its lock are private to the store; every mutation that spans fields
  happens under that store's lock;
- no store calls another store while holding a lock; orchestration is a
  service's job;
- an in-memory and a Postgres-backed implementation may share one protocol; the
  composition root chooses one (the database stays optional, per `AGENTS.md`);
- stores throw domain errors, never build JSON or HTTP responses.

### 2.4 DTO and JSON

`EmailLogin.swift` currently interleaves `Codable` model structs with hand-built
JSON strings (`Self.json(200, "{…}")`). Target:

- request/response/event shapes are `Codable` structs in `Sources/RaftHTTP/DTO/`;
- one canonical JSON encoder is used for API responses so key order, date
  encoding, and escaping cannot drift between features;
- a handler that needs an upstream-exact string (for example a webhook body)
  documents why in a comment next to the DTO;
- `[String: Any]` dictionaries are not used to build responses.

### 2.5 Test seams

The production ledger currently carries 243 `…ForTesting` markers. That was
pragmatic while routes and state shared one class, but it is a public surface
with no owner. Target:

- deterministic seams live in `Tests/TestSupport/` as fakes/hooks passed through
  `FallbackServices`, not as mutable members on a production type;
- a production type keeps a `ForTesting` member only when the seam cannot be
  expressed as an injected dependency; the guardrail script counts them and
  warns on growth;
- new `private func …ForTesting` members in `EmailLogin.swift` are a hard
  design smell; the baseline is 0.

### 2.6 Shared contracts

`RaftShared` is a new dependency-free library target for shapes that cross
target boundaries: socket.io frame payloads used by both `RaftHTTPServer` and
`RaftRealtime`, daemon handshake/machine context types, and constants such as
error codes. `Package.swift` is not editable from this slice; the target lands
with the first contract that is actually duplicated across targets. Until then,
duplicate shapes stay in `RaftHTTP` and are marked for extraction.

## 3. Target tree

```text
Sources/
  RaftShared/                     # new: Codable contracts, zero deps
  RaftHTTP/                       # framework-independent domain
    Stores/<Domain>Store.swift    # per-domain state + lock
    DTO/<Domain>DTO.swift         # Codable shapes, canonical JSON
    JSON/<Encoder>.swift
  RaftHTTPServer/
    FallbackApplication.swift     # composition root only (middleware + register)
    Features/<Name>/<Name>Feature.swift
    Services/<Name>Service.swift
    Middleware/                   # existing middleware, unchanged
  RaftRealtime/                   # frame assembly, consumes RaftShared
Tests/
  RaftHTTPServerTests/            # black-box HTTP assertions
  RaftHTTPTests/
  TestSupport/                    # new: fakes, clocks, IDs, hooks
```

## 4. Dependency rules

Allowed import direction (arrows mean "may import"):

```text
Features ──▶ Services ──▶ Stores ──▶ DTO
    │            │           │
    └────────────┴───────────┴──────▶ RaftShared
RaftRealtime ────────────────────────▶ RaftShared
Tests (any target) ──▶ TestSupport
```

- `RaftHTTP` never imports `Vapor`, `RaftHTTPServer`, or `RaftRealtime`.
- `RaftHTTPServer` never imports test targets and never state that belongs to a
  store.
- No feature imports a store directly; it goes through a service.
- `RaftShared` imports nothing from this package.
- No cycles between targets.

## 5. Composition root

`FallbackApplication.configure(_:services:)` keeps exactly three jobs:

1. build services from `FallbackServices` (and wire lifecycle hooks, e.g. the
   agent-read emitter);
2. register one `RouteCollection` per feature:

   ```swift
   try app.register(collection: NotificationsFeature(services: services))
   try app.register(collection: AuthFeature(services: services))
   ```

3. install middleware in the existing order, with `FallbackMiddleware` last so
   unmatched paths keep the upstream JSON 404:

   ```swift
   middleware.use(JSONErrorBoundaryMiddleware())
   middleware.use(ExperimentalSurfaceGate(directory: …))
   middleware.use(RequestBodyLimitMiddleware(accounts: …))
   middleware.use(BufferedRequestBodyMiddleware())
   middleware.use(CorsMiddleware(origins: …))
   middleware.use(PublicSearchMiddleware(…))
   middleware.use(FallbackMiddleware(services: services))
   app.middleware = middleware
   ```

Route registration order inside `boot` is irrelevant to Vapor routing except
for duplicate paths; the upstream path + method pair is the contract.

## 6. Migration order

The layers land in slices, without a behavior change in the extraction steps:

| Step | Slice | Exit criterion |
| --- | --- | --- |
| R1 | Move route blocks from `FallbackApplication.swift` into `Features/<Name>/<Name>Feature.swift`, register collections | Each feature file ≤ 1,200 lines; registration tests assert method/path pairs; route-table output identical |
| R2 | Move handler orchestration into `Services/` | Services are Vapor-free and unit-testable; features shrink to route + `routeResponse` |
| R3 | Split `EmailLoginDirectory` into `Stores/` with one lock per domain | Store tests cover lock boundaries; `EmailLogin.swift` only shrinks |
| R4 | Architecture documentation + guardrail script (this slice) | `scripts/check_architecture.py` exits 0; baseline recorded |
| R5 | Extract test seams to `TestSupport`, duplicated contracts to `RaftShared` | `ForTesting` count in production targets does not grow; shared target has zero package deps |

The end state is not "no ledger": domain state still exists. The end state is
that each upstream route module, service module, and store has its own file,
lock, and owner, and no file needs to be 31k lines.

## 7. Guardrails

`scripts/check_architecture.py` enforces the measurable boundaries:

| Check | Rule | Failure |
| --- | --- | --- |
| `email-login-ceiling` | `Sources/RaftHTTP/EmailLogin.swift` must stay at or below its recorded baseline of **31,656 lines** | New line count > baseline. Lowering the file is always allowed; the baseline constant may then be lowered, never raised. |
| `feature-file-ceiling` | Every `.swift` file under `Sources/RaftHTTPServer/Features/` ≤ **1,200 lines** | Any file over the limit. A missing `Features/` directory is reported as zero files, not an error. |
| `email-login-test-seams` | `ForTesting` markers in `EmailLogin.swift` may not grow beyond the recorded **243**; `private func …ForTesting` baseline is **0** | **Warning only** (exit code unchanged). Migration to `TestSupport` is R5. |

Usage:

```console
$ scripts/check_architecture.py                 # concise report, exit 0/1/2
$ scripts/check_architecture.py --json          # machine-readable report
$ scripts/check_architecture.py --root PATH     # check another checkout
```

Exit codes: `0` pass or warnings only, `1` guardrail violation, `2` missing
required input or invalid root. The script is standard-library-only Python 3, is
not wired into `make` in this slice, and is safe to run from CI or a review
script once a Makefile owner adds a target.

Baseline policy: the constants are a ratchet. A slice that shrinks the file or
moves test seams updates the constant downward in the same commit and records
the new number here and in `docs/team/R4_REPORT.md`. No slice raises a
constant to make the check pass.

## 8. Non-goals

- No behavior change in an extraction slice; the acceptance test is the same
  upstream assertion, now routed through the new file.
- No port of private upstream helpers, query-count spies, tracer sinks,
  failpoints, or orchestrator injection (`AGENTS.md`).
- No new third-party dependency and no `Package.swift` change in R4.
- No `recorded*` side channel added; a slice that touches one removes it.


## Current migration status (2026-11-05)

| Stage | State | Evidence |
| --- | --- | --- |
| R1 route extraction | done for auth, feedback, public, translations, servers, channels, messaging, OAuth/OIDC, internal agent-api, internal admin, integrations, notifications/misc | `Sources/RaftHTTPServer/Features/` (12 collections, ~500 route registrations moved); `configure()` 4,520 -> 667 lines (only policy catch-alls + wiring); per-feature registration tests |
| R2 canonical JSON | foundation done | `Sources/RaftHTTP/Support/JSONValue.swift` + `HTTPReply.jsonValue` + `Tests/RaftHTTPTests/JSONValueTests.swift`; feature handlers migrate as they are rewritten |
| R3 store/lock split | started | `Stores/ProductEventStore.swift` owns product/client events + idempotency; `Stores/AuthProfileStore.swift` owns linked identities, password-reset tokens and legal acceptances. `Stores/ThreadFollowStore.swift` owns agent thread-follow rows and `Stores/InboxFactStore.swift` owns inbox facts. Target next: ChannelStore, TaskStore, ReadCursorStore |
| R4 guardrails | done | `scripts/check_architecture.py`, `make architecture`: EmailLogin line ratchet (33,700; reset for the multi-app, attested-send and migration slices; these blocks are candidates for dedicated files in R3), Features <= 1,200 lines, ForTesting warning baseline 243 |
| R5 shared contracts | started | `Sources/RaftShared` target added; canonical `JSONValue` moved there, `HTTPReply.jsonValue` stays in RaftHTTP; next: capability/error-code contracts and feature DTOs |

Remaining composition-root route families: internal agent-api, internal agent/computer/machine,
integrations, MCP, provider-connections, notifications/product-events and misc.


## Remaining parity work (2026-11-05, after 211/219 route modules locked)

Locked executable route surface covers all feature collections plus the parity
suites; still partial: `agents.api` and `socketMembershipRevocation.api`. These need either a missing subsystem
(knowledge corpus, multi-app binding, P2 upload service, joint tasks) or a
large acceptance matrix (agents/channels); they are tracked in `docs/PARITY.tsv`.

Generated knowledge corpus lives in `Sources/RaftHTTPServer/Generated/KnowledgeCorpus.swift` (data-only, outside the Features line ceiling); regenerate from upstream `manual/agent-knowledge` + `manual/recipes` when the corpus changes.


## EmailLogin split progress (2026-11-05)

- `Sources/RaftHTTP/EmailLogin.swift`: 34,306 -> 21,257 lines (-13,049, -38%).
  Behavior now lives in 13 extension files under `Sources/RaftHTTP/EmailLogin/`
  (largest ~1.6k lines); `EmailLoginStatics`/`ActionCards`/`ManagedMCP` are
  additionally split so no extension exceeds ~1.6k lines.
- Moved 109 nested data-model declarations (1,171 lines) into
  `Sources/RaftHTTP/EmailLoginModels.swift`; moved 210 static helpers
  (2,567 lines) into `EmailLoginStatics.swift`. Both are behavior-preserving;
  instance handlers/stores remain in EmailLogin. The prop-free feedback
  multi-app/test-seam tail was moved into `EmailLogin/EmailLogin+FeedbackMultiApp.swift`
  and `EmailLogin+TestSeams.swift` (1,751 lines). Next split candidates are the
  remaining prop-free handler regions, the static-helper file by domain, then
  R3 domain stores.
