# Phase 6 slice recipe: Feature → Service → Store
Proven on email verification (`AuthVerificationService`, `AuthFeature`). One
domain per slice; parity is locked.

## 0. Pre-flight
- Clean tree in `/mnt/data/wt/p6-pilot`;
  `SWIFT=/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift`.
- Baseline `check_architecture.py` and `parity.py --check` pass before you start.

## 1. Inventory the slice (no edits yet)
- `grep -n '<route>' Sources/RaftHTTPServer/Features` — the handlers.
- `grep -n 'func <handler>' Sources/RaftHTTP/Services Sources/RaftHTTP/EmailLogin*`
  — the real logic, usually an `extension EmailLoginDirectory` block.
- `grep -n '<store method>' Sources/RaftHTTP/Stores` — the state and its lock;
  `grep -rn '<removed>' Tests/` — seams. Never add `ForTesting` to `Sources/`.

## 2. Store: state + lock first
Extend the store that already owns the rows. Keep state private, with one locked
critical section per read-modify-write. Do not add a store class for one slice:
a new `@unchecked Sendable` raises a ratchet that may only decrease.

```swift
// Sources/RaftHTTP/Stores/AuthProfileStore.swift
func userId(forAccessToken token: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    ...
}
```

## 3. Shared error contract
`Sources/RaftHTTP/Support/DomainError.swift`:

```swift
public protocol DomainError: Error, Sendable {
    var status: UInt { get }
    var errorMessage: String { get }
    var responseHeaders: [String: String] { get }
}
public extension DomainError { var responseHeaders: [String: String] { [:] } }
```
## 4. Service: DTO out, DomainError thrown
- File `Sources/RaftHTTP/Services/<Domain>Service.swift`; no `Vapor`,
  `HTTPReply`, `JSONSerialization` or `[String: Any]`.
- Explicit dependencies through `init`; return a `Codable` DTO from
  `Sources/RaftHTTP/DTO/` and throw the domain enum.

```swift
public enum AuthVerificationError: DomainError, Equatable {
    case missingToken, invalidOrExpiredToken, unauthenticated, invalidAccessToken
    public var status: UInt { ... }   // 400 / 401 / 429 / 500
    public var errorMessage: String { ... }
}

public struct AuthVerificationService: Sendable {
    init(store: AuthProfileStore, now: @Sendable () -> Date = { Date() }, ...)
    public func verifyEmail(token: String?) throws -> OkResponse {
        guard let token, !token.isEmpty else { throw AuthVerificationError.missingToken }
        ...
        return OkResponse()
    }
}
```

## 5. Feature: one `respond` call per route
`Sources/RaftHTTPServer/Features/Respond.swift` is the only place a DTO or a
`DomainError` becomes a `Response`. It reuses the existing `X-Robots-Tag`,
`Content-Type` and `Content-Length` header set and `JSONEncoder`, so the bytes
match the pre-migration reply.

```swift
auth.post("verify-email") { request async throws -> Response in
    let body = (try? await request.content.decode(VerifyEmailRequest.self)) ?? VerifyEmailRequest()
    return try respond { try services.emailAccounts.authVerification.verifyEmail(token: body.token) }
}
```

## 6. Delete the old path
- Remove the `extension EmailLoginDirectory` handlers/forwarders and the seam
  only they used; the directory keeps a computed accessor for the service
  (`EmailLogin.swift` has a 48-line ceiling — do not add lines there).
- Remove unread result types, DTOs and `DirectoryStoreForwarders` accessors;
  keep a thin forwarder only where unmigrated code calls it, and update tests
  to use the store, the service, or the HTTP route.

## 7. Verify, then commit everything together
```console
$SWIFT build
$SWIFT test --filter <VerificationTests>
$SWIFT test --filter <RouteRegistrationTests>
python3 scripts/check_architecture.py --update-baselines   # decreases only
python3 scripts/check_architecture.py
python3 scripts/parity.py --check
```
Commit code, `scripts/ratchet_*.tsv`, and the `docs/ARCHITECTURE.md` row together.
## Pitfalls
- Status, JSON body and headers are the contract: reuse the previous encoder
  and header names; never re-derive them.
- Keep the upstream order: authorization (401) before any policy write.
- Ratchets are bidirectional; an `--update-baselines` run that raises a count
  is a rejected slice.
- a read-modify-write that used to run under the directory lock must stay ONE
  store critical section. Split `count` + `latest` + `insert` + `increment`
  calls let two concurrent requests both pass a rate-limit policy; expose one
  store method that decides and writes under the same lock.
