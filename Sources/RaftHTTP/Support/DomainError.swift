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
    /// Optional machine-readable `code` appended to the default error body. The
    /// default keeps the plain `{"error": …}` bytes.
    var errorCode: String? { get }
    /// The exact published body, when the default `{"error": …[, "code": …]}`
    /// object is not the contract. A domain with a different key order, extra
    /// keys (`requiredCapability`, `reason_code`, …) or a non-object body
    /// supplies `OrderedJSON` here.
    var errorBody: OrderedJSON? { get }
    /// The complete error header policy. A requirement (not only an extension
    /// member) so a conforming type's override is reached through the
    /// `any DomainError` that `Respond.swift` projects.
    var errorHeaders: ResponseHeaders { get }
}

public extension DomainError {
    var responseHeaders: [String: String] { [:] }
    var errorCode: String? { nil }
    var errorBody: OrderedJSON? { nil }

    /// The complete error header policy. The default keeps the standard JSON
    /// header set and merges `responseHeaders`; a domain whose legacy reply
    /// publishes a header set of its own returns `.exact(…)`.
    var errorHeaders: ResponseHeaders { .standard(extra: responseHeaders) }

    /// The exact published error body.
    ///
    /// When the domain supplies `errorBody` that tree is used verbatim (so a
    /// domain can publish `code` before `error`, or add scope/reason keys).
    /// Otherwise the default is the legacy order: `error` first, then `code`
    /// only when `errorCode` is present.
    var publishedErrorBody: OrderedJSON {
        if let errorBody { return errorBody }
        var body = OrderedJSONObject()
        body.append("error", errorMessage)
        if let errorCode { body.append("code", errorCode) }
        return body.json
    }
}

/// One typed domain failure whose published body is a `Codable` shape rather
/// than a fixed ordered tree.
///
/// This is the existing rich-body contract, retained for a domain that already
/// publishes a synthesized `Codable` error object (currently the action-card
/// and provider-connection surface). `Respond.swift` encodes `body` with sorted
/// keys so the bytes are deterministic. New domains use
/// `DomainError.errorBody`; this protocol is not the ordered-JSON mechanism.
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
