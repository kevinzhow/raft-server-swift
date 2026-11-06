# Architecture: target Swift layering

**Status**: Phase 5 extracted the old `EmailLogin/` files; Phase 6 is removing the remaining transport, directory, and concurrency coupling. An empty old directory and a 48-line class body do not mean that migration is complete. `EmailLoginDirectory` still owns a global lock, has extensions outside that directory, and is referenced by services and tests. The remaining milestones live in `docs/PLAN.md`.

**Specification**: observable HTTP status codes, JSON bytes, response headers, and socket frames asserted by the upstream suite at `v1.21.23-source.1`. Refactoring preserves those contracts, including validation order, omission versus null, input coercion, and stored JSON fingerprints.

**Scope**: the complete local dependency closure of `RaftServer`: `RaftHTTP`, `RaftHTTPServer`, `RaftRealtime`, `RaftServer`, `RaftMachineSocket`, `RaftConnectAuth`, and `RaftShared`. The daemon-only targets are `RaftDaemonClient` and `RaftDaemon`. Shared targets are counted once. The ratchets exclude `Sources/RaftHTTPServer/Generated/`; that exception is explicit and does not apply to the production `ForTesting` scan.

## 1. Current structure

The upstream server separates route modules, services, database schema, middleware, and shared contracts. This port has extracted those boundaries progressively while retaining an in-memory backend.

| Path | Current role |
| --- | --- |
| `Sources/RaftHTTPServer/FallbackApplication.swift` | Composition, middleware order, lifecycle wiring, and policy catch-alls |
| `Sources/RaftHTTPServer/Features/` | 16 `RouteCollection` modules plus request/response helpers; 19 Swift files |
| `Sources/RaftHTTP/EmailLogin.swift` | 48-line directory root: 12 principal store instances, OAuth ledger, and remaining transaction/relay locks |
| `Sources/RaftHTTP/Services/` | 96 Swift files of domain services and remaining directory accessors; no Vapor imports |
| `Sources/RaftHTTP/Stores/` | 50 Swift files; large store implementations split into extensions by responsibility; every file at most 1,000 lines |
| `Sources/RaftHTTP/DTO/` | Codable request shapes, ordered response payloads, and semantic outcomes |
| `Sources/RaftHTTP/Support/` | Naming, token, cursor, projection, runtime-config, and policy helpers; no directory extensions or legacy reply factories |
| `Sources/RaftHTTP/OAuthLedger.swift` and `OAuth/` | 95-line ledger root plus 18 domain files; the largest OAuth file is 466 lines |
| `Sources/RaftShared/` | Shared value contracts, including `JSONValue` |
| `Tests/TestSupport/` | Test-only seams, deterministic setup, and injected dependencies; never a production dependency |

`Sources/RaftHTTP/EmailLogin/` has no Swift files. The remaining directory extensions are under `Services/` and `Stores/`, not hidden by that empty-directory result. Large store splits retain each store's original transaction lock and method bodies; the required cross-file access changes do not make state private to individual extension files.

## 2. Target layers

| Layer | Owns | Boundary |
| --- | --- | --- |
| Feature | Registration, request extraction, response status/headers/body projection | Calls services; does not implement domain state or hand-build JSON |
| Service | Authorization and validation order, domain orchestration, typed results/errors | Vapor-free; state belongs in stores |
| Store | Domain records and atomic domain operations | Does not create HTTP replies or invoke another store while holding its state lock |
| DTO | Codable request values, `JSONBodyConvertible` response payloads, explicit domain outcomes | No mutable shared state and no Vapor dependency |
| Support | Small functions and policies with a named responsibility | Does not become another directory or a generic reply factory |
| Shared | Contracts consumed by multiple targets | Does not depend on server, daemon, or Vapor targets |
| TestSupport | Test setup and observation of real outputs | Not imported by production targets |

Allowed dependency direction:

```text
Feature -> Service -> Store
    |          |        |
    +----------+--------+--> DTO / RaftShared
RaftRealtime -----------------> RaftShared
Tests ------------------------> TestSupport
```

This is the target boundary. Directory accessors, cross-domain snapshots, and global-lock critical sections remain migration debt, even when their source file is under `Services/`. The script enforces measurable rules, not every architectural property in this table.

### 2.1 Features and request decoding

`configure(app:services:)` installs middleware and feature collections. Route handlers retain the published method/path pairs and authorization order. Migrated domains invoke typed services and use `Features/Respond.swift` for JSON projection. Other JSON paths, including knowledge replies and some channel/message handlers, still use the legacy reply adapter; the remaining reply tokens are not all transport-only infrastructure.

`Features/RequestBody.swift` centralizes the existing typed request policies: registered content decoder with raw-JSON fallback, explicit JSON decoding, or content decoder only. Callers select their established empty/blank-body defaults and read-error behavior. Form bodies, file uploads, and existing raw-text compatibility paths remain explicit. There are no synchronous `request.body.string` reads and no global body-buffering middleware.

Moving a route to a helper must not silently change these policies. In particular, malformed JSON must not precede an authentication refusal, and adding a content-type requirement must not turn an accepted raw-JSON request into a 415.

### 2.2 Services, outcomes, and response projection

A domain returns a named payload or a semantic outcome and throws a `DomainError`. `Respond.swift` projects the error's published body and complete header policy. The success path uses `JSONBodyConvertible` when member order matters, or an Encodable payload when sorted encoding is the contract.

Examples of semantic outcomes are public attachment file/redirect results, release-note published/not-modified results, and mobile-email unsubscribe confirmation/invalid-link/unsubscribed/one-click results. These preserve non-JSON responses without replacing `HTTPReply` with another generic status/headers/body container.

Conditional release-note responses retain their ETag and the original 304 header omissions. Public-search HEAD suppresses the body while retaining the corresponding GET representation length, including errors. No adapter may recompute that length from the suppressed body.

### 2.3 Stores and concurrency

Each principal store owns one record family. Its methods retain their existing critical sections during file extraction. Splitting a file is distinct from changing its synchronization model.

The current directory still supplies a global `NSLock`, relay locks, and the freshness-commit lock. Several stores and the OAuth ledger still declare unchecked Sendable conformance. OAuth's signing secret now lives in a `Mutex` because token signing can occur after a record transaction releases its lock; that change does not make the rest of the ledger checked Sendable.

The remaining work is to give mutable state checked `Mutex` or actor isolation and move each read-modify-write into its owning store before removing the global lock. Merely removing a lock around separately locked snapshot getters/setters would allow lost updates. Cross-domain transaction and lock-order assumptions must be reviewed explicitly.

### 2.4 JSON and compatibility boundaries

`Support/OrderedJSON.swift` preserves member order, omission versus null, string escaping, and scalar types. `JSONBodyConvertible` supplies the exact published body; `Respond.swift` maps it to Vapor. The contract and migration recipe are in `docs/PHASE6_JSON.md` and `docs/PHASE6_RECIPE.md`.

Foundation remains at specific input or stored-text compatibility boundaries. Its JSON object parser takes the last duplicate key, while Swift's keyed JSONDecoder can take the first. Existing Foundation Bool casts accept numeric 0/1, and some inputs filter heterogeneous arrays or distinguish missing/null values. Public settings, translations, visits, release cursors, signed-token verification, and OAuth input parsing preserve those established rules.

Stored runtime configuration and OAuth event fingerprints also retain Foundation's sorted serialization where client-supplied numbers must keep Foundation's established representation after parsing and serialization. Routing those values through an Int64/Double-only tree can overflow UInt64 values or alter decimal bytes. Differential tests cover large integers, decimals, booleans, slashes, duplicate keys, normalization, redaction, and provider-key merging. These compatibility writers are counted as remaining JSON-any text; they are not claimed to be typed response serialization.

### 2.5 Test seams and real outputs

Production `ForTesting` markers are a hard zero. Test setup lives in `Tests/TestSupport/`, with explicit injected dependencies where possible. The production behavior remains observable through HTTP or socket output.

The channel-message recorded-event side channel has been removed. The attachment-order regression captures the actual `message:new` sink, checks its payload, and verifies that an idempotent replay emits no second event. Other retained audit/recorded collections require separate evaluation; extracting their files does not count as removing them.

## 3. Architecture guardrails

Run `make architecture` or `python3 scripts/check_architecture.py`. `--json` returns a machine-readable report; `--root PATH` checks another checkout. Python exit codes are 0 for pass/warnings, 1 for a guardrail violation, and 2 for invalid input or an operational error. The Makefile target is installed.

| Check | Rule |
| --- | --- |
| Directory root size | `EmailLogin.swift` at most 48 lines; the ceiling only decreases |
| Feature size | Every feature/helper Swift file at most 1,200 lines |
| Service size | Every service/accessor Swift file at most 1,200 lines |
| Store size | Every Store Swift file, including nested extension files, at most 1,000 lines |
| Retired directory | No Swift files under `Sources/RaftHTTP/EmailLogin/`; legacy per-file limit 1,600 |
| Production test markers | `ForTesting` per-file baseline is empty across all `Sources/`; root warning baseline is also zero |
| Service imports | `import Vapor` is a hard zero in `Services/` |

### 3.1 Per-file ratchets

Each metric has `scripts/ratchet_<metric>.tsv` with `path<TAB>count`. An unlisted file has a baseline of zero. Except for the string-literal scanner, these are textual occurrence counts and include comments; they are not counts of runtime operations.

| Metric | Scope | Counted |
| --- | --- | --- |
| `extension_directory` | `Sources/RaftHTTP` | Literal directory extension declarations |
| `service_httpreply` | Services | Legacy reply tokens |
| `service_json_any` | Services and DTO | `JSONSerialization`, `[String: Any]`, `[String:Any]` |
| `unchecked_sendable` | Sources excluding Generated | Explicit unchecked Sendable declarations |
| `directory_forwarder` | Directory forwarding file | Physical lines; zero after deletion |
| `service_directory_calls` | Services | Literal `directory.` text, including comments |
| `httpreply_sources` | Seven server targets | Legacy reply tokens, including transport adapters and comments |
| `json_any_sources` | Seven server targets | The same three JSON-any text patterns |
| `directory_references` | Sources excluding Generated | Bare directory type identifiers, with word boundaries |
| `unchecked_sendable_server` | Seven server targets | Explicit unchecked Sendable declarations |
| `json_string_payloads` | Seven server targets | Object/array-shaped Swift string literal candidates |

The two JSON metrics measure different things. The string scanner handles ordinary, raw, and multiline strings, interpolation, nested strings inside interpolation, and concatenation prefixes. It skips line and nested block comments. Constants and DTO defaults are candidates too; a JSON-shaped label such as `[1]` can be a false positive. It does not validate complete JSON, follow variables/appends/arbitrary splits, decode Unicode escapes, or parse Swift regex literals. Neither metric proves that all handwritten response construction is gone.

The updater validates every metric before writing any TSV. Ordinary `--update-baselines` refuses per-file growth and cannot partially lower earlier metrics after a later validation failure. Both growth and stale higher baselines fail the gate, so reductions are recorded in the same change.

For a new metric, expanded scope, or a reviewed pure file move, `--print-ratchet-baseline METRIC` exports the current data without writing it. Review the scope and before/after totals, explicitly adopt the migration, then use the ordinary decreasing-only updater. Hand-editing a TSV is not evidence of a legitimate reduction. The updater never changes `for_testing_baseline.tsv`.

`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py' -v` covers scan scope, duplicate roots, exclusions, scanner boundaries, decreasing-only updates, validation before writes, and file-size boundaries.

### 3.2 Snapshot and exclusions

The current handwritten-source snapshot has 12 directory extension occurrences, a 580-line forwarding file, 60 server reply tokens, 94 server JSON-any text occurrences, 98 directory type references, and 185 string-literal candidates. Services have zero reply tokens; the combined Services/DTO JSON-any occurrence and the two Services `directory.` occurrences are comments. Source-level transport and string construction remain outside those narrow service zeros.

The unchecked conformance ratchet remains 69 across handwritten Sources: 28 in the server dependency closure and 41 in daemon-only targets. Generated knowledge telemetry contains one additional explicit unchecked conformance, so the physical full-source count is 70. The generated exception is not a concurrency-safety conclusion. Removing unchecked conformance outside the daemon, including that generated helper, remains planned work; the daemon's NIO handlers and process handles require individual assessment.

## 4. Behavioral gates and remaining work

Every accepted slice runs relevant published-path regressions, `make test`, `make test-e2e`, `scripts/smoke-server.sh`, `make architecture`, and `make parity-check`. Smoke is supplemental evidence for real-process wiring, not proof of every locked module. Coverage progress comes from `make parity` and the qualifications in `docs/PARITY.tsv`.

The next boundaries are removal of the remaining directory extensions/forwarders and global lock, checked store isolation, then the repository-wide `ServiceContainer` rename and remaining server concurrency cleanup. The detailed phase order belongs in `docs/PLAN.md`. None of these steps changes the pinned Vapor revision, replaces the SwiftNIO listeners, or changes the no-database `/health` 503 contract.
