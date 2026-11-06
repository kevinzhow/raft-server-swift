import Foundation

/// One typed domain failure the feature layer can render without knowing which
/// domain produced it.
///
/// A migrated service throws a conforming error instead of choosing an HTTP
/// status, header set or body. `Sources/RaftHTTPServer/Features/Respond.swift`
/// is the only place a `DomainError` becomes a response. The enum case is the
/// machine-readable code; `errorMessage` is the published upstream `error` text.
public protocol DomainError: Error, Sendable {
    /// Status the published error answers with.
    var status: UInt { get }
    /// Body text for the upstream `{"error": …}` shape.
    var errorMessage: String { get }
    /// Extra response headers; the default JSON header set needs none.
    var responseHeaders: [String: String] { get }
    /// Optional machine-readable `code` appended to the error body. The
    /// default keeps the plain `{"error": …}` bytes every existing domain
    /// publishes.
    var errorCode: String? { get }
}

public extension DomainError {
    var responseHeaders: [String: String] { [:] }
    var errorCode: String? { nil }
}

/// One typed domain failure whose published body is a `Codable` shape rather
/// than the default `{"error": …}`.
///
/// `Sources/RaftHTTPServer/Features/Respond.swift` has a second overload that
/// encodes `body` directly for domains whose upstream error object carries
/// `code`, `reason` or `suggestedNextAction`. The plain `DomainError` path is
/// untouched, so its bytes cannot drift.
public protocol DomainErrorWithBody: Error, Sendable {
    /// Status the published error answers with.
    var status: UInt { get }
    /// Exact `Codable` body the domain publishes for this failure.
    var body: any Encodable { get }
    /// Extra response headers; the default JSON header set needs none.
    var responseHeaders: [String: String] { get }
}

public extension DomainErrorWithBody {
    var responseHeaders: [String: String] { [:] }
}

/// One typed domain failure whose published body is already serialized in the
/// legacy key order.
///
/// `JSONEncoder` on Linux stores keyed containers in a dictionary, so neither
/// declaration order nor a custom `encode(to:)` yields a stable key order. A
/// domain whose upstream body has a fixed non-alphabetical order (for example
/// `{"error": …}` before `{"code": …}`) carries the exact bytes instead.
/// `Sources/RaftHTTPServer/Features/Respond.swift` sets `Content-Length` from
/// `bodyJSON` and keeps `responseHeaders` verbatim.
public protocol OrderedBodyDomainError: Error, Sendable {
    /// Status the published error answers with.
    var status: UInt { get }
    /// Exact published body bytes, in legacy key order.
    var bodyJSON: String { get }
    /// Response headers verbatim; `Content-Length` is added by the projection.
    var responseHeaders: [String: String] { get }
}

public extension OrderedBodyDomainError {
    var responseHeaders: [String: String] { [:] }
}
