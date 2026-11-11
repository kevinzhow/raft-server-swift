# Vapor 5 idiom + Raft layering audit (`RaftHTTPServer`)

Read-only audit of the Vapor mount and route features. No Sources/Tests/Makefile/
Package/parity/behavior/plan file was modified; this document is the only write
from the audit.

Scope read:

- `Sources/RaftHTTPServer/FallbackApplication.swift` (668 lines) and all three
  middleware files (`JSONErrorBoundaryMiddleware`, `RequestBodyLimitMiddleware`,
  `BufferedRequestBodyMiddleware`), plus `InternalSurfacePolicy.swift`.
- All 14 files under `Sources/RaftHTTPServer/Features/**` (3 800+ lines).
- Representative tests: `FeatureServersRoutesTests`, `FeatureAuthRoutesTests`,
  `GuestJoinTests`, `PublicVisitsTests`, `StartupTests`, `VersionEndpointTests`.
- Cross-checked against upstream `packages/server/src/app.ts`,
  `routes/auth.ts`, `services/userService.ts` at `v1.21.23-source.1`, and the
  pinned Vapor snapshot `0f2a8ee9`.

Evidence counts (grep over the tree at audit time; re-run to refresh):

| Metric | Count |
|---|---|
| `request.body.string` reads in `RaftHTTPServer` | 218 |
| `req.content.decode` / `req.content` uses | 0 |
| `request.headers[...]` reads in features + composition root | 700 |
| `routeResponse(...)` calls in `RaftHTTPServer` | 553 |
| literal route registrations (features + root) | 517 |
| `routes.grouped(...)` / `app.grouped(...)` uses | 0 |
| duplicate `private func desktopQuery` copies | 11 |
| `JSONSerialization` uses in `RaftHTTPServer` | 53 |
| `*ForTesting` members in `Sources/` | 301 (1 308 test-side uses) |

The list below is ordered by impact. Every item is a mechanical/structural
change; none of them requires a wire-behavior change, and the parity tests
continue to own the status codes and bodies.

---

## 1. Handlers read the lazy body synchronously, which forces a global buffering middleware

- `Sources/RaftHTTPServer/Features/Auth/AuthFeature.swift:32` — `body: request.body.string ?? ""`
  (and ~217 more; e.g. `ServersFeature.swift:47`, `MessagingFeature.swift:53`).
- `Sources/RaftHTTPServer/BufferedRequestBodyMiddleware.swift:4-12` exists **only**
  to compensate: its own comment says `app.testing` pre-collects the body while a
  real process hands handlers a lazy stream, so the middleware calls
  `request.body.collect()` for every non-GET request.

Impact: every POST copies the whole body once for buffering and then again into
`String`; content decoding lives in the service instead of Vapor; the 100 KB /
512 KB / 1 MB limits are enforced by a hand-written header sniff rather than
`maxBodySize`; and `app.testing` and production take different code paths, which
is exactly the class of divergence the startup tests were added to catch.

Fix: define a `Content` DTO per route (`struct RegisterRequest: Content`), make
the handler `async throws` and use `try req.content.decode(RegisterRequest.self)`
(or `req.content.decode` with `validate`). Then delete
`BufferedRequestBodyMiddleware` and let `RequestBodyLimitMiddleware` set
`request.maxBodySize` only. Keep the raw body only for the two multipart routes
(item 9).

## 2. Request handlers block a thread for up to 12 s on a semaphore around `URLSession`

- `Sources/RaftHTTP/EmailLogin/EmailLogin+FeedbackMultiApp.swift:91-112` —
  `handsFeedbackSend` starts `URLSession.dataTask` and then
  `semaphore.wait(timeout: .now() + 12)` on the calling thread.
- `Sources/RaftHTTP/EmailLogin/EmailLogin+TestSeams.swift:199-219` — the product
  feedback POST repeats the same semaphore + `URLSession` pattern inline.

Impact: `POST /api/feedback` and the feedback-route binding probe park a Vapor
worker thread for the upstream timeout. Under concurrency this consumes the
concurrency pool (the handler is synchronous inside) and turns an upstream
slowdown into process-wide tail latency. Vapor 5's model is `async` handlers on
the concurrency pool, not blocking waits.

Fix: mark the service methods `async throws`, replace the semaphore with
`try await URLSession.shared.data(for:)` (or the already-available async
`Data`/`HTTPClient` surface), keep the 12 s limit as a request timeout, and make
the route closure `{ request async throws -> Response in }`. The injectable
`handsFeedbackUpstreamHandler` seam should become an injectable `FeedbackClient`
protocol so the test does not need a synchronous shim (see item 11).

## 3. The service layer returns pre-serialized `HTTPReply` strings, and handlers re-parse them to recover typed values

- `Sources/RaftHTTPServer/Features/Knowledge/KnowledgeFeature.swift:49-70` —
  `resolveIdentity` calls `services.emailAccounts.agentApiIdentity(...)`, then
  `JSONSerialization.jsonObject` on `identityReply.body` to pull `agentId`,
  `serverId`, `scopes`.
- `Sources/RaftHTTPServer/FallbackApplication.swift:411-448` — task-created /
  task-updated realtime publishing decodes the reply body and the request body
  with `JSONSerialization` just to read `channelId`, `taskIds`, `title`.
- `Sources/RaftHTTPServer/Features/Channels/ChannelsFeature.swift:539-560` —
  same pattern for `channel:updated`.
- `Sources/RaftHTTPServer/Features/Messaging/MessagingFeature.swift:507-548` —
  same pattern for `task:created` / `task:updated` (`publishTaskUpdated` at :507,
  `publishTaskCreated` at :517).

Impact: every internal call that needs a value pays a serialize → string →
parse round trip; there is no compiler-checked contract between the route and
the service; a JSON key rename can only fail at runtime. This is the largest
layering deviation from upstream Raft, where route handlers call typed services
and `res.json(obj)`.

Fix: have the service return typed values (`Identity`, `Task`, `Channel`) and
let the route encode them with `Response(content:)`; for the handful of routes
that must stream/preserve exact bytes, keep `HTTPReply` as an internal edge type
only inside `RaftHTTP` (item 12).

## 4. One monolithic `EmailLoginDirectory` is both service and store; the dedicated stores are bypassed

- `Sources/RaftHTTPServer/FallbackApplication.swift:36` — `public var emailAccounts: EmailLoginDirectory`.
- Every feature calls `services.emailAccounts.<domain method>`: `AuthFeature.swift:27`,
  `ServersFeature.swift:60`, `MessagingFeature.swift:53-56`, `ChannelsFeature.swift:32-38`,
  `NotificationsFeature.swift:503`, `InternalAdminFeature.swift:50`.
- `Sources/RaftHTTP/EmailLogin.swift` is one type split across a ~1 200-line
  `EmailLogin.swift` plus 20+ `EmailLogin/*.swift` slices (`EmailLogin+AuthCore`,
  `EmailLogin+Agents2`, `EmailLogin+ManagedMCP1-4`, `EmailLogin+ActionCards1-3`, ...);
  it is still a single god object with in-memory maps. `Sources/RaftHTTP/Stores/
  {AuthProfileStore, InboxFactStore, ProductEventStore,ThreadFollowStore}.swift`
  exist but are used only from inside that one type.
- `Sources/RaftHTTPServer/FallbackApplication.swift:15-44` — `FallbackServices`
  is a 25-field struct that is the de-facto service locator.

Impact: routes cannot be tested without the whole directory; the "routes →
services → stores" split that upstream Raft enforces with Express routers +
service modules is collapsed into routes → one god object → in-memory maps.

Fix (no behavior change): introduce per-domain service facades
(`AuthService`, `ServerService`, `MessageService`, `ChannelService`) that wrap
the existing directory and accept `*Store` protocols; features take only the
facade they need instead of the god `FallbackServices`. Move the directory's
`public` surface behind `internal` once facades exist.

## 5. JSON is hand-built in the Vapor layer instead of `Content` / `Response(content:)`

- `Sources/RaftHTTPServer/FallbackApplication.swift:317,325` — middleware writes
  `"{\"error\":\"...\",\"code\":\"\(code)\"}"` by string interpolation.
- `FallbackApplication.swift:390` — experimental-surface 503 body interpolated by hand.
- `FallbackApplication.swift:562` — `pixelAvatarError` builds `"{\"error\":\"\(error)\"}"`.
- `JSONErrorBoundaryMiddleware.swift:15-24` — the error boundary builds its body
  with `#"..."#` interpolation (safe here, but still not a `Content` type).
- `NotificationsFeature.swift:797` — plain `Response(status: .notFound, body: .init(string: "Not found"))`,
  i.e. `text/plain` for a JSON API 404.

Impact: unescaped interpolation is one dynamic value away from a broken body;
content type and length are decided ad hoc; error shapes drift between the
middleware, the boundary, and the services.

Fix: `struct APIError: Content { let error: String; let code: String? }`,
`Response(status: .serviceUnavailable, content: APIError(...))`. For the
robots-tag/`X-Robots-Tag` responses use a small `Response` factory that sets the
header and the `Content` body.

## 6. CORS is preflight-only and is mounted after the body buffering/limit middleware

- `Sources/RaftHTTPServer/FallbackApplication.swift:288-303` — `CorsMiddleware`
  returns a reply only when `WebCORS.preflight(...)` matches; otherwise it calls
  through without adding `Access-Control-Allow-Origin` to the actual response.
- `Sources/RaftHTTP/Cors.swift:33-55` — `preflight` is the only CORS output; no
  `Access-Control-Allow-Origin` is ever attached to a normal response.
- `FallbackApplication.swift:269-285` — middleware order is
  `JSONErrorBoundary → ExperimentalSurfaceGate → RequestBodyLimit → BufferedRequestBody
  → Cors → PublicSearch → Fallback → router`, so an OPTIONS preflight is buffered
  and size-checked before CORS answers it.

Impact: browser clients can preflight but the actual cross-origin response is
unreadable (no ACAO); a preflight with a body or an oversized `Content-Length`
gets a 413/parse work before CORS. Vapor 5's `CORSMiddleware` handles both
preflight and normal responses and is normally first in the chain.

Fix: replace with `app.middleware.use(CORSMiddleware(configuration: ...))` (or a
small middleware that sets the ACAO/credentials headers on every response and
short-circuits preflight) and move it before `RequestBodyLimitMiddleware`.

## 7. No route grouping or `RouteCollection` mounting; 517 inline registrations and a sync `register(routes:)` shim

- `Sources/RaftHTTPServer/FallbackApplication.swift:219-233` — 13 features are
  mounted with `Feature(...).register(routes: app)` in `configure`, not with
  `app.register(collection:)`.
- `Sources/RaftHTTPServer/Features/Auth/AuthFeature.swift:19-24` — `boot` just
  calls `register`; the comment says `configure` "whose call sites are not
  async" drives the duplicate entry point.
- `FeatureServersRoutesTests.swift:19` — tests mount the same feature with
  `try await app.register(collection:)`, so the production and test mount paths
  already differ.
- 0 `grouped(...)` uses; every path repeats `"api", "servers", ":id", ...`.

Impact: route prefixes are copy-pasted, auth/scope headers must be re-read in
every closure (item 8), and the two mount paths are a standing drift risk.

Fix: make `configure` `async throws` (it is called once in `main`) and mount
each collection with `try app.register(collection:)`; inside a feature use
`let servers = routes.grouped("api", "servers")` and mount typed sub-groups.
Delete the sync `register(routes:)` shim.

## 8. Eleven copies of `desktopQuery` and 700 manual header reads instead of request decoding + auth middleware

- `FallbackApplication.swift:588`, `AuthFeature.swift:235`,
  `ChannelsFeature.swift:536`, `IntegrationsFeature.swift:335`,
  `InternalAdminFeature.swift:436`, `InternalAgentApiFeature.swift:612`,
  `MessagingFeature.swift:429`, `NotificationsFeature.swift:930`,
  `OAuthFeature.swift:242`, `PublicFeature.swift:101`, `ServersFeature.swift:668`
  — identical `private func desktopQuery(_:_:)`.
- 700 `request.headers[...]` reads in the features; e.g. `AuthFeature.swift:33,97-99,129-130`
  re-read `authorization`, `userAgent`, `acceptLanguage` in each handler;
  `X-Server-Id` is read by hand in ~40 places.

Impact: URL parsing has 11 diverging implementations (one of them percent-decodes
`+` as space, others do not), and bearer/session extraction is repeated per
handler instead of being a Vapor authenticator, so a header-name change touches
hundreds of lines.

Fix: add `Request.queryValue(_:)` (or use `req.query.decode(Query.self)`) once in
`RaftHTTP/Support`; add `UserAuthenticator` / `ServerScopeMiddleware`
(`AsyncBearerAuthenticator` + `req.auth.require(User.self)`) and delete the
per-handler header plumbing.

## 9. Hand-rolled multipart parser plus a dead `Content` declaration

- `FallbackApplication.swift:128-132` — `AttachmentUploadForm: Content` is
  declared but referenced nowhere.
- `FallbackApplication.swift:143-217` — 75 lines of manual boundary splitting,
  header parsing, and `CharacterSet` trimming for attachment and share-image
  uploads; both are used from `ChannelsFeature`/`NotificationsFeature`.

Impact: a hand parser for a format Vapor already decodes, with weaker rules
(no quoted-parameter handling, no RFC 7578 edge cases), and a misleading dead
type.

Fix: `struct AttachmentUploadForm: Content { let channelId: String; let files: [File] }`
and `try req.content.decode(AttachmentUploadForm.self)`; `File` gives `filename`,
`contentType`, and `data`. Keep only the max-size guard as middleware.

## 10. Duplicate route registration is reproduced for parity but not contained

- `Sources/RaftHTTPServer/Features/Servers/ServersFeature.swift:367` and `:541` —
  the same `DELETE api/servers/:id/machines/:machineId` handler is registered
  twice.
- `FeatureServersRoutesTests.swift:29-31` — the test deliberately locks the
  multiset ("two `DELETE .../:machineId` registrations exist upstream"), so this
  is intentional parity, not an accident.
- Effect visible at runtime: every startup logs
  `[RoutingKit] [Routing] Overriding duplicate route for leaf` (observed in the
  smoke run), because RoutingKit replaces the first leaf with the second.

Fix **without changing behavior**: keep both registrations but route them
through one named helper (`registerServerMachineDelete(routes:)`) with a comment
pointing at the upstream route file, and assert the duplicate count (and the
warning) in a test so a future Vapor/RoutingKit change that rejects duplicates
is caught. Do not silently de-duplicate: the parity test owns that contract.

## 11. Test-only seams live in production types

- `Sources/RaftHTTP/EmailLogin/EmailLogin+TestSeams.swift` (982 lines) — despite
  the name it contains production handlers (`submitProductFeedback`,
  `mobileAppEmailUnsubscribePage`, signing helpers); the seams are interleaved.
- `Sources/RaftHTTP/EmailLogin/EmailLogin+AuthCore.swift:691` —
  `markEmailVerified(userId:)`, whose doc says "The Node fixture marks a row
  verified without an HTTP call".
- `Sources/RaftHTTP/EmailLogin/EmailLogin+FeedbackMultiApp.swift:92-97` — an
  injectable `((URLRequest) -> (Int, [String: String], Data))` handler in the
  production type.
- 301 `*ForTesting` members in `Sources/` (e.g. `OAuthLedger.swift` has 20+),
  used by 1 308 test call sites.

Impact: production binaries carry mutation APIs that bypass the HTTP contract;
the file name actively misleads; and tests couple to internals instead of the
route (the opposite of the repo's black-box contract).

Fix: move fixture seams into an `internal`/`#if DEBUG` extension in a separate
`RaftHTTPTestSupport` target, or invert them into injected protocols on the
directory. Keep `markEmailVerified` internal and add the missing public
`POST /api/auth/verify-email` (see runtime findings) so tests can use the route.

## 12. `HTTPReply` → `Response` conversion is duplicated and `httpStatus` re-implements `HTTPResponse.Status`

- `FallbackApplication.swift:604-627` (`vaporResponse`) and
  `Features/Notifications/NotificationsFeature.swift:941-960` — two copies of the
  header copy/Content-Length fix-up.
- `FallbackApplication.swift:647-668` and `NotificationsFeature.swift:962-983` —
  two copies of the `Int → HTTPResponse.Status` switch.
- 553 `routeResponse(...)` call sites cross this adapter.

Impact: an upstream status added in one switch is silently a generic status in
the other; Content-Length handling differs between "route response" and "share
image response".

Fix: keep one adapter inside `RaftHTTP` (or return `Response`/`Content` from the
features) and use `HTTPResponse.Status(code:reasonPhrase:)` directly; delete the
second converter and the local status switch.

## 13. Wildcard catch-all loops in the composition root duplicate the internal policy

- `FallbackApplication.swift:244-264` — two `for method in [...5 methods...]` loops
  register `internal/computer/**`, `internal/agent-api/**`, `internal/agent/**`
  fail-closed handlers (15 wildcard routes).
- `InternalAdminFeature.swift:12-19` and `InternalAgentApiFeature.swift:13-17` —
  the comments explain that these catch-alls must stay in `configure` because
  they share a loop; the features own the static routes.
- `InternalSurfacePolicy.swift:33-58` then scans `app.routes.all` to derive the
  claimed-surface snapshot, excluding wildcards, so the snapshot depends on the
  manual mount order.

Impact: policy is expressed as routes rather than middleware, so the wildcard
registration count couples to the method list, and the route snapshot is a
post-hoc derivation instead of a registration-time invariant.

Fix: one `InternalSurfaceGuardMiddleware` that checks the claimed-prefix registry
(`InternalSurfacePolicy.principal(forPath:)`) and answers the fail-closed JSON;
register it once in the middleware chain and delete the 15 wildcard routes.
`InternalSurfacePolicy.snapshot` can then be built from the features' route
collections, not from a global `app.routes.all` scrape.

## 14. Error/response shape drift and `try!` in the event-publishing path

- `NotificationsFeature.swift:797` — text/plain `"Not found"` for a JSON API.
- `InternalAdminFeature.swift:310-314` — a registered route that always returns
  401 `auth_policy_unregistered_path` (a policy answer implemented as a stub
  route, rather than middleware).
- `FallbackApplication.swift:451-461` — `jsonChannelString` uses `try!` inside a
  request path; `RaftServer/main.swift:17-21` — `machineJSONString` uses `try!`.
- `FallbackApplication.swift:463-469` — `reminderIdFromReply` silently returns
  `nil` on a body parse failure, so the event is dropped with no diagnostic.

Impact: inconsistent 404 content type; a policy stub that grows into a route; a
crash (`try!`) reachable if the JSON encoder ever rejects a value; silent event
loss.

Fix: route the stub through the item-13 policy middleware; use
`JSONEncoder().encode(["value"])` (non-failable for `String`) or a shared
`jsonString` helper without `try!`; log and count the dropped-event cases
instead of `nil` return.

## 15. `configure` assigns `app.middleware` wholesale and hides Vapor defaults

- `FallbackApplication.swift:269-285` — `var middleware = Middlewares(); ...;
  app.middleware = middleware` replaces the application's middleware stack,
  including Vapor's default `ErrorMiddleware` (the custom JSON boundary is the
  replacement) and any `CORSMiddleware`/`FileMiddleware` the app would add.
- `FallbackApplication.swift:270` — `internalSurface.set(...)` runs after all
  mounts but before `app.start()`; the "configuration-time snapshot" is a
  comment-enforced invariant, not a type-level one.

Impact: future middleware added to `app.middleware` in `main` is silently
discarded, and the order is a single 17-line block with no test for the order.

Fix: `app.middleware.use(...)` each middleware in order (or `app.middleware = .init()`
then append), and drop the custom `JSONErrorBoundaryMiddleware` in favor of
Vapor's `ErrorMiddleware` with a custom `AbortError` → content mapper if the
upstream JSON body must be preserved. Add a route-table/middleware-order test so
the block cannot drift.

---

## Runtime findings (from `scripts/smoke-server.sh`, not Vapor idioms)

1. **A freshly registered human can never post a message.** Upstream
   `packages/server/src/routes/auth.ts:1709` and `:1730` expose
   `POST /api/auth/verify-email` and `POST /api/auth/resend-verification`, and
   `userService.createUser` (upstream `services/userService.ts:311-375`) stores a
   verification token. The port has neither route (grep for `verify-email` in
   `Sources/` returns nothing; `AuthFeature` registers 36 routes and the locked
   list omits both), and the upstream E2E opt-in
   (`SLOCK_E2E_AUTO_VERIFY_EMAIL=1` + `__e2eAutoVerify: true`, upstream
   `routes/auth.ts:678`) is also absent. Result: `POST /api/messages` answers
   `403 {"error":"Email verification required"}` forever, and only the in-process
   `markEmailVerified(userId:)` seam can produce a posting human. `docs/PARITY.tsv`
   marks `auth.api` as `locked`, which overstates coverage.
   Repro: `scripts/smoke-server.sh` (see the `POST /api/messages unverified human`
   check and the NOTE block).
2. **Duplicate-route warning on every startup**:
   `[RoutingKit] [Routing] Overriding duplicate route for leaf` — from the
   intentional `DELETE /api/servers/:id/machines/:machineId` parity duplicate
   (item 10). Harmless today, but it is noise that hides a real duplicate later.
3. **`POST /api/messages` is the only wall the smoke hit**; the agent-principal
   path (`POST /api/agents`, credential issuance, channel membership,
   `POST /internal/agent-api/send`, human `GET /api/messages/channel/:id`) works
   end to end in a real process, including realtime `rooms:joined` and the
   daemon `101 + machine:context` handshake.

## Verification

- `scripts/smoke-server.sh` — 19 PASS checks, two consecutive clean runs.
- `swift build --product RaftServer` with
  `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift` (6.4.1).
- No modifications to `Sources/**`, `Tests/**`, `Makefile`, `Package.swift`,
  `docs/PARITY.tsv`, `docs/DEVIATIONS.md`, `docs/PLAN.md`.
