# Phase 6: canonical ordered JSON bodies

`JSONEncoder` prints keyed containers in hash order, so a body whose key order
is part of the wire contract cannot be synthesized. One mechanism owns that:
`OrderedJSON` (`Sources/RaftHTTP/Support/OrderedJSON.swift`) renders an explicit
tree with the legacy `jsonString` escaping, and `Respond.swift` is the only
place a body becomes a `Response`. Do not add another ordered-JSON type,
protocol or `respond` overload; extend this API.

## API
- `OrderedJSON` — `.object([OrderedJSONField])`, `.array`, `.string`, `.int`,
  `.double`, `.bool`, `.null`, `.raw(fragment)`; `render() -> String`.
  Builders: `OrderedJSONField("key", value)` (String/Int/Double/Bool/OrderedJSON/
  nested body), initializers with `optional:` (JSON null when nil) and
  `OrderedJSONObject.append(_:ifPresent:)` (member omitted when nil).
- `JSONBodyConvertible` — `var jsonBody: OrderedJSON`; a DTO that publishes an
  exact order conforms to it.
- `DomainError` — keeps `status`, `errorMessage`, `errorCode`,
  `responseHeaders`; adds `errorBody: OrderedJSON?`. The default body is
  `{"error": …}` then `"code"` when present. A domain whose published order is
  different (or that adds keys) supplies `errorBody`; `errorHeaders` may be
  `.exact(…)` for a non-standard header set.
- `Respond.swift` — `respond(status:headers:_:)` for an `Encodable` DTO (sorted
  keys, deterministic) or a `JSONBodyConvertible` DTO (exact order); a
  payload-dependent-header variant `respond(status:headers: { dto in … })`; the
  bare `respond(_:)` 204; and `respond(status:headers:rawJSON:)`.
- `DomainErrorWithBody` remains the legacy sorted-encoder Codable error path
  (action cards). New domains use `DomainError.errorBody`.
## Examples
```swift
// 1. Plain DTO: sorted, deterministic bytes.
return try await respond { try services.authVerification.verifyEmail(token: token) }
// 2. Ordered body: published order is not alphabetical.
struct Accepted: Codable, JSONBodyConvertible {
    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("status", "accepted")
        body.append("receipt_id", receiptId)
        body.append("route_basis", ifPresent: routeBasis)  // omitted when nil
        return body.json
    }
}
// 3. Rich domain error: error, then code, then scope.
public var errorBody: OrderedJSON? {
    .object([
        OrderedJSONField("error", "missing required scope"),
        OrderedJSONField("requiredScope", scope),
        OrderedJSONField("reason", "missing_scope"),
    ])
}
```
## Migration map (unmerged variants → canonical)

| Branch | Old name | New name |
| --- | --- | --- |
| agentmigrationstatus | `OrderedJSON`, `OrderedJSONField` | same names, canonical file |
| | `OrderedJSON.serialized()` | `OrderedJSON.render()` |
| | `OrderedJSONBody.orderedJSON` | `JSONBodyConvertible.jsonBody` |
| | `timestampOrNull` / `stringOrNull` | `stringOrNull` (timestamps are strings) |
| | error overload with `code` before `error` | `DomainError.errorBody` in that order |
| productfeedback | `OrderedBodyDomainError.bodyJSON` | `DomainError.errorBody` (tree, or `.raw(bodyJSON)`) |
| | success/error header sets | `headers: { dto in .exact([…]) }`, `errorHeaders = .exact(…)` |
| | `respond(jsonNoContent:)` | `respond(status: 204, headers: .exact([…])) { … }` (extension below) |
| | `ProductFeedbackErrorEnvelope.bodyJSON` | `DomainError.errorBody` built from `OrderedJSONObject` |
| agentsend | `OrderedJSONBody.jsonBody() -> String` | `JSONBodyConvertible.jsonBody: OrderedJSON` |
| | `OrderedJSONError.errorJSONBody()` | `DomainError.errorBody` |
| | `respond(errors:)` | plain `respond` (the thrown error carries its body) |
| runtimeusage | `CanonicalJSONBody.jsonBody() -> String` | `JSONBodyConvertible.jsonBody: OrderedJSON` |
| | `CanonicalDomainErrorBody.bodyJSON` | `DomainError.errorBody` |
| | `JSONScalarValue` | stays in its DTO (decode-only helper) |
| actioncardprepare | `JSONBody` / `JSONMember` | `OrderedJSON` / `OrderedJSONField` |
| | `ExactJSONBody.exactJSON` | `JSONBodyConvertible.jsonBody.render()` |
| | `DomainErrorWithExactBody.exactBody` | `DomainError.errorBody` |
| | `extraHeaders: [:]` | `headers: .standard(extra: [:])` |
| joinlinks | `ExactJSONResponse.jsonBody() -> String` | `JSONBodyConvertible.jsonBody: OrderedJSON` |
| | `ExactBodyDomainError` | `DomainError` + `errorBody` + `errorHeaders` |
| main (feedbacklocator) | `OrderedJSONBody` / `OrderedJSONDomainError` | `JSONBodyConvertible` / `DomainError.errorBody` |

`respond(errors:)` no longer exists: every `DomainError` carries its own body.
`ResponseHeaders.standard(extra:)` merges the published header set;
`.exact(…)` replaces it (the domain owns `Content-Type`/`Retry-After`).

## Composition: a typed tree around an unmigrated fragment

A migrated service can own the outer member order while one nested value is
still rendered by a domain that has not migrated. The fragment enters the
service as a closure returning `OrderedJSON` (wired in the directory accessor)
and the DTO places it at the published position; the closure renders it with
`OrderedJSON.raw` from the existing projection. The container's delimiters stay
the DTO's: a fragment array is `[<members>]`, a fragment object `{<members>}`,
so an empty page still prints `[]` / `{}`. This is the canonical API, not a new
type: `InboxAndWakeDTO` uses it for the reaction buckets, forward metadata,
action-card metadata and thread summaries the inbox page embeds.

## Extension: a 204 with a header policy

`respond(_:)` publishes the bare `Content-Length: 0` 204. The onboarding-wizard
ack reused the legacy JSON reply helper, so it also published `X-Robots-Tag`
and `Content-Type`. `respond(status:headers:_:)` was added to `Respond.swift`
for that case; it reuses `resolvedHeaders` and the shared `DomainError`
projection, and leaves the bare overload unchanged for every other 204.

```swift
return try await respond(
    status: 204,
    headers: .exact([
        "X-Robots-Tag": AppFallback.robotsTag,
        "Content-Type": AppFallback.jsonContentType,
    ])
) {
    try services.emailAccounts.productFeedbackSubmissions.recordOnboardingWizard(…)
}
```

## Extension: an ordered body with payload-dependent headers

`respond(status:headers:_:)` over `Encodable` prints sorted keys, so an ordered
DTO could not carry a legacy header set that depends on the value just produced.
The agent task-create idempotent replay and the action-card prepare replay
(`ActionCardIntegrationRegisterService.prepareActionCard`) need both: a first
write publishes the standard JSON header set, while a replay of the stored body publishes the legacy
`Content-Type` and `Cache-Control: no-store` set without `X-Robots-Tag`.
`Respond.swift` gained one overload for that pair; it renders
`JSONBodyConvertible.jsonBody` and passes the DTO to the header closure.

```swift
struct Created: JSONBodyConvertible {
    var headers: ResponseHeaders          // .standard() or .exact([…])
    var jsonBody: OrderedJSON { … }
}

return try await respond(headers: { $0.headers }) {
    try services.actionCardMarketplace.createTasks(…)
}
```

The `Encodable` overloads are unchanged and no existing caller combines both
protocols. A future DTO that conforms to both would have to disambiguate the
overload explicitly; `ActionCardTaskCreateResponse` conforms only to
`JSONBodyConvertible`, so its member order cannot fall back to sorted keys.
`ActionCardPrepareResponse` follows the same rule (it dropped its `Encodable`
conformance when the two slices' overloads were unified into this one).

## Extension: a status and header policy that depend on the payload

The product-feedback ticket routes relay a Hands reply. Upstream decides `200`
versus `201`, and the header policy differs per relay (JSON with
`Server-Timing`, a plain JSON relay, or an attachment with its own
`Content-Type`). `respond(status:headers:_:)` fixed the status before the call,
so `Respond.swift` gained one overload that derives both from the DTO:

```swift
return try await respond(status: { $0.status }, headers: { $0.headers }) {
    try await services.emailAccounts.feedbackMultiApp.tickets(…)
}
```

The DTO (`FeedbackHandsReply`) conforms to `JSONBodyConvertible` only and
publishes the upstream text through `OrderedJSON.raw`; it carries its status and
`ResponseHeaders`. The `UInt`-status overloads are unchanged.

## Fix: `DomainError.errorHeaders` is a protocol requirement

`errorHeaders` was declared only in the `DomainError` extension, so a conforming
type's override (`.exact([… "Retry-After" …])`) was ignored when `Respond.swift`
projected the error through `any DomainError`: the standard header set (with
`X-Robots-Tag`, without `Retry-After`) was published. It is now a requirement
with the extension supplying the default, so the override is dispatched
dynamically. This restores the legacy headers of the retryable feedback errors
(`429`, route-binding `503`).
