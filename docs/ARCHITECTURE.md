# Architecture: target Swift layering

**Status**: Phase 6 has removed directory state forwarding and the global transaction lock. `EmailLoginDirectory` is a 28-line owner assembly root, but six extensions still contain factories and transitional helper methods and services/tests still reference that type. Explicit service composition and the final `ServiceContainer` migration remain; the empty old directory and smaller root do not establish completion. The remaining milestones live in `docs/PLAN.md`.

**Specification**: observable HTTP status codes, JSON bytes, response headers, and socket frames asserted by the upstream suite at `v1.21.23-source.1`. Refactoring preserves those contracts, including validation order, omission versus null, input coercion, and stored JSON fingerprints.

**Scope**: the complete local dependency closure of `RaftServer`: `RaftHTTP`, `RaftHTTPServer`, `RaftRealtime`, `RaftServer`, `RaftMachineSocket`, `RaftConnectAuth`, and `RaftShared`. The daemon-only targets are `RaftDaemonClient` and `RaftDaemon`. Shared targets are counted once. Both unchecked-conformance ratchets and the production `ForTesting` scan include Generated. Other ratchets exclude `Sources/RaftHTTPServer/Generated/` because of the embedded corpus; this does not exempt generated executable code from the unchecked scan.

## 1. Current structure

The upstream server separates route modules, services, database schema, middleware, and shared contracts. This port has extracted those boundaries progressively while retaining an in-memory backend.

| Path | Current role |
| --- | --- |
| `Sources/RaftHTTPServer/FallbackApplication.swift` | Composition, middleware order, lifecycle wiring, and policy catch-alls |
| `Sources/RaftHTTPServer/Features/` | 16 `RouteCollection` modules plus request/response helpers; 19 Swift files |
| `Sources/RaftHTTP/EmailLogin.swift` | 28-line directory root: 12 principal store instances and the OAuth ledger; no shared lock or field forwarders |
| `Sources/RaftHTTP/Services/` | 111 Swift files of domain services and remaining directory accessors; no Vapor imports |
| `Sources/RaftHTTP/Stores/` | 54 Swift files; implementations split by responsibility; every file at most 1,000 lines, currently largest 974 |
| `Sources/RaftHTTP/DTO/` | Codable request shapes, ordered response payloads, and semantic outcomes |
| `Sources/RaftHTTP/Support/` | Naming, token, cursor, projection, runtime-config, and policy helpers; no directory extensions or legacy reply factories |
| `Sources/RaftHTTP/OAuthLedger.swift` and `OAuth/` | 97-line ledger root plus 19 domain files; the largest OAuth file is 466 lines |
| `Sources/RaftShared/` | Shared value contracts, including `JSONValue` |
| `Tests/TestSupport/` | Test-only seams, deterministic setup, and injected dependencies; never a production dependency |

`Sources/RaftHTTP/EmailLogin/` has no Swift files. The six remaining directory extensions are under `Services/`; the Store forwarding file has been deleted. They contain service factories and transitional helper methods and still need migration to explicit composition. PushRegistration is an independent notification DTO; Stores and push registration no longer depend on a directory-nested record. Mutex state and typed owner transactions protect domain operations independently of the old directory lock.

## 2. Target layers

| Layer | Owns | Boundary |
| --- | --- | --- |
| Feature | Registration, request extraction, response status/headers/body projection | Calls services; does not implement domain state or hand-build JSON |
| Service | Authorization and validation order, domain orchestration, typed results/errors | Vapor-free; state belongs in stores |
| Store | Domain records and atomic domain operations | No HTTP replies or arbitrary callbacks under a state borrow; the two fixed ledger-port edges are documented below |
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

This is the target boundary. Directory factory captures, policy closures in assembly, broad initialization dependencies, and raw ledger calls from Features remain migration debt, even under `Services/`. The global directory lock and field proxies are gone. The script enforces measurable rules, not every architectural property in this table.

### 2.1 Features and request decoding

`configure(app:services:)` installs middleware and feature collections. Route handlers retain the published method/path pairs and authorization order. Migrated domains invoke typed services and use `Features/Respond.swift` for JSON projection. Other JSON paths, including knowledge replies and some channel/message handlers, still use the legacy reply adapter; the remaining reply tokens are not all transport-only infrastructure.

`Features/RequestBody.swift` centralizes the existing typed request policies: registered content decoder with raw-JSON fallback, explicit JSON decoding, or content decoder only. Callers select their established empty/blank-body defaults and read-error behavior. Form bodies, file uploads, and existing raw-text compatibility paths remain explicit. There are no synchronous `request.body.string` reads and no global body-buffering middleware.

Moving a route to a helper must not silently change these policies. In particular, malformed JSON must not precede an authentication refusal, and adding a content-type requirement must not turn an accepted raw-JSON request into a 415.

### 2.2 Services, outcomes, and response projection

A domain returns a named payload or a semantic outcome and throws a `DomainError`. `Respond.swift` projects the error's published body and complete header policy. The success path uses `JSONBodyConvertible` when member order matters, or an Encodable payload when sorted encoding is the contract.

Examples of semantic outcomes are public attachment file/redirect results, release-note published/not-modified results, and mobile-email unsubscribe confirmation/invalid-link/unsubscribed/one-click results. These preserve non-JSON responses without replacing `HTTPReply` with another generic status/headers/body container.

Conditional release-note responses retain their ETag and the original 304 header omissions. Public-search HEAD suppresses the body while retaining the corresponding GET representation length, including errors. No adapter may recompute that length from the suppressed body.

Two leaf services now make the construction graph acyclic at the known policy loops. `AgentCredentialUseService` holds Agents, OAuth and the realtime relay, preserving the owner's use/throttle transaction and publishing external presence afterwards. Credential lookup no longer needs PrivateSurface. `MessageSuppressionService` holds Messages and OAuth and evaluates current prefs/mentions using the existing predicate; execute captures this leaf and no longer constructs tools to make that decision. Their long-lived values retain owners, not state or callback snapshots. AssistantOwnershipQuery likewise separates raw stored links from live membership/flag eligibility using only Agents and OAuth. Prepare/send and assignment owner lookup use that query directly; the three corresponding directory helpers are deleted. AgentSendFreshnessPolicy preserves the original pure system/causal-actor/subtype rule.

CredentialLookup, RuntimePolicy and MobileEmail helpers now receive explicit owners or narrow services; their Source directory initializers/callers are retired. TaskCatalog is now TaskCatalogService with explicit Tasks/Profile/OAuth owners, and all six Source directory-construction calls are retired. Catalog projection, access policy and number-allocation behavior stay in that domain service. Other broad service constructors/factory captures remain. HumanMessageCreate, ReactionsRealtime, InboxAndWake and SearchMentions now have explicit owner/service construction through four named dependency components; their directory initializers and three live factories are deleted. Inbox auth-error and probe conversions stay in named domain adapters. Their lifecycle collaborator still has a joint-channel factory capture to migrate; the machine/hosted-runtime and runtime-form collaborators now have explicit owner/AuthCore/relay constructors too. Registration and API-key reads use Machines directly, and provider/origin/config reads remain live. These direct boundaries still do not certify the complete transitive graph. LedgerRealtimeAuth, LedgerMachineLookup and RequestBodyLimitMiddleware now hold explicit services rather than the directory. AuthCore's transport identity keeps the original push token-table predicate, SocketMembership owns the handshake role read, and ComputersFleet owns the Computer five-state query; body admission retains the existing RuntimeForms Bool predicates and 401-before-413 order. Replacing the remaining type name alone would not finish composition.

### 2.3 Stores and concurrency

Each principal store owns one record family. All twelve principal stores and the OAuth ledger now declare checked Sendable conformance, with mutable records and configuration isolated by `Mutex`. State values and the 55 shared value records used by those transactions have checked conformances too. Locked helpers borrow the caller's state explicitly and do not acquire that Mutex again. OAuth flows intentionally share the AuthProfileStore state so account, identity, legal acceptance, and session writes remain one auth transaction.

Field setters update only their own field in one transaction, fixing the old whole-State copy/writeback race. Separately locked getters/setters still do not form an atomic read-modify-write. Directory field proxies have now been deleted, and test setup borrows the actual owning State for complete single-owner operations. Multi-field OAuth/native deployment settings use typed owner cohorts; Services read them when handling an operation.

The 28-line directory root has only immutable checked owner references and no transaction lock. Human, agent, comment, system, and app-reminder writers share one Messages allocator. Human replay/attachment validation/binding/append/mirror/done/cursor writes remain one transaction; a refusal returns before mutation. Mention uniqueness and insertion also share one Messages borrow. Relay slots are copied under their owner's Mutex and invoked outside it. These boundaries do not establish a cross-store authorization snapshot or make remaining factory extensions pure composition.

OAuth's signing secret uses a separate Mutex so signing can run after a record transaction. The cards store's send-commit barrier remains separate from its State Mutex: the protected orchestration calls back into receipt/state operations, so merging the two would cause reentry.

Two concrete callback-free ledger ports permit nested owner transactions:

| Held owner → leaf owner | Complete operation |
| --- | --- |
| Messages → OAuth | Append the already constructed mirror and advance the human sender cursor before releasing Messages |
| Channels → OAuth | Reuse the existing DM identity operation, then prepare the local projection and agent/human membership before releasing Channels |

These ports hold only a checked OAuthLedger reference and enter record-only leaf methods. OAuth has no reverse dependency on Messages or Channels and calls no service or injected callback on these paths. Role notices release Channels before entering Messages; Messages never takes Channels or Auth. Payload rendering, realtime publication, cancellation, and arbitrary callbacks stay outside State borrows. Fixed-sequence test setup uses the same approved Messages → OAuth mirror boundary without adding a production sequence override.

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
| Directory root size | `EmailLogin.swift` at most 28 lines; the ceiling only decreases |
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
| `unchecked_sendable` | All Sources, including Generated | Explicit unchecked Sendable declarations |
| `directory_forwarder` | Directory forwarding file | Physical lines; zero after deletion |
| `service_directory_calls` | Services | Literal `directory.` text, including comments |
| `httpreply_sources` | Seven server targets | Legacy reply tokens, including transport adapters and comments |
| `json_any_sources` | Seven server targets | The same three JSON-any text patterns |
| `directory_references` | Sources excluding Generated | Bare directory type identifiers, with word boundaries |
| `unchecked_sendable_server` | Seven server targets, including Generated | Explicit unchecked Sendable declarations |
| `json_string_payloads` | Seven server targets | Object/array-shaped Swift string literal candidates |

The two JSON metrics measure different things. The string scanner handles ordinary, raw, and multiline strings, interpolation, nested strings inside interpolation, and concatenation prefixes. It skips line and nested block comments. Constants and DTO defaults are candidates too; a JSON-shaped label such as `[1]` can be a false positive. It does not validate complete JSON, follow variables/appends/arbitrary splits, decode Unicode escapes, or parse Swift regex literals. Neither metric proves that all handwritten response construction is gone.

The updater validates every metric before writing any TSV. Ordinary `--update-baselines` refuses per-file growth and cannot partially lower earlier metrics after a later validation failure. Both growth and stale higher baselines fail the gate, so reductions are recorded in the same change.

For a new metric, expanded scope, or a reviewed pure file move, `--print-ratchet-baseline METRIC` exports the current data without writing it. Review the scope and before/after totals, explicitly adopt the migration, then use the ordinary decreasing-only updater. Hand-editing a TSV is not evidence of a legitimate reduction. The updater never changes `for_testing_baseline.tsv`.

`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py' -v` covers scan scope, duplicate roots, exclusions, scanner boundaries, decreasing-only updates, validation before writes, and file-size boundaries.

### 3.2 Snapshot and exclusions

The current handwritten-source snapshot has six directory extension occurrences, zero forwarding lines/properties, 60 server reply tokens, 94 server JSON-any text occurrences, 62 directory type references, and 169 string-literal candidates. Services have zero reply tokens; the combined Services/DTO JSON-any occurrence and the remaining Services `directory.` occurrence are comments. Source-level transport/string construction, factory captures, and transitional directory helpers remain outside those narrow zeros.

The unchecked conformance ratchet now covers all Sources, including Generated: 28 declarations, all daemon-only; the complete server dependency closure is zero. Stores, public directories, caches, the immutable directory root, the realtime hub/session/attention state, connect state, and generated knowledge telemetry use checked storage. The realtime parser handler is deliberately non-Sendable and transferred only through SDK `NIOLoopBound` for synchronous installation on its channel loop; every entry checks that loop. Connect tasks capture immutable values and checked connection state, with channel writes/status callbacks on the owning loop. Session terminal writes and attention callbacks use a single ordered drainer outside their state locks. Session drains process at most 64 frames per batch; only backlog schedules a 1 ms continuation, so continuous HTTP broadcasts cannot keep one immediate task running indefinitely or prevent the selector from polling other connections. Idle admission still schedules its first drain immediately.

The generated telemetry helper no longer has an unchecked exception. Its recovered generator and template are in `scripts/generate_knowledge.py` and `scripts/templates/knowledge.swift`; `python3 scripts/generate_knowledge.py --upstream-root /path/to/raft-source-v1.21.23 --check` verifies reproduction. Registry/table blocks remain byte-identical to the pinned corpus.

The 28 retained daemon declarations are not certified safe merely because they are outside the server closure. The [daemon concurrency inventory](CONCURRENCY.md) records their fields, actual protections, callback/ownership assumptions, inspected tests, and concrete gaps. It distinguishes complete one-shot/storage gates from unprotected public mutable models, raw Any payloads, timer publication/cancellation windows, and cross-queue accesses. Six immutable daemon errors already use checked conformance. RuntimeChildGuard now has a checked lifecycle state machine and effect callbacks outside its Mutex; HTTP CompletionBox has checked one-shot state and its parser/deadlines stay on their owning NIO loop. These fixes have real-child/network acceptance, with the exact evidence and in-flight callback boundaries in the inventory. Four mutable daemon model classes now use checked snapshots while preserving public setters and identity; retired response Data is released outside its Mutex. Independent property setters and separate cause snapshots do not provide a multi-object transaction. Remaining fixes require domain transactions and lifecycle evidence, not annotation deletion.

## 4. Behavioral gates and remaining work

Every accepted slice runs relevant published-path regressions, `make test`, `make test-e2e`, `scripts/smoke-server.sh`, `make architecture`, and `make parity-check`. Smoke is supplemental evidence for real-process wiring, not proof of every locked module. Coverage progress comes from `make parity` and the qualifications in `docs/PARITY.tsv`.

The remaining work is explicit construction of Services, removal of factory captures and transitional directory helpers, migration of raw ledger operations in Features, and replacement of the old type with a pure `ServiceContainer`. The current owner root has no global lock or field proxies; that does not complete those composition boundaries. Unresolved daemon boundaries remain documented separately. The detailed phase order belongs in `docs/PLAN.md`. None of these steps changes the pinned Vapor revision, replaces the SwiftNIO listeners, or changes the no-database `/health` 503 contract.
