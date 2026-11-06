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
