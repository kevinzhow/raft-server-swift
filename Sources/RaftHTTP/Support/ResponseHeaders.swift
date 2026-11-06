import Foundation

/// The header policy a projected reply publishes.
///
/// Most routes answer with the standard JSON header set and add a cache or
/// timing header on top; a few legacy routes publish a header set of their own
/// (for example the feedback `201`, which has no `X-Robots-Tag`). Making that
/// choice explicit here keeps transport construction at the route boundary.
public struct ResponseHeaders: Sendable, Equatable {
    public enum Base: Sendable, Equatable {
        /// `X-Robots-Tag`, `Content-Type` and `Content-Length`, plus `values`.
        case standard
        /// Only `values`, plus `Content-Length`.
        case exact
    }

    public let base: Base
    /// Extra headers for `.standard`; the complete set for `.exact`.
    public let values: [String: String]

    private init(base: Base, values: [String: String]) {
        self.base = base
        self.values = values
    }

    /// The published JSON header set with `extra` merged on top.
    public static func standard(extra: [String: String] = [:]) -> ResponseHeaders {
        ResponseHeaders(base: .standard, values: extra)
    }

    /// Exactly `values`, with `Content-Length` set from the rendered body.
    public static func exact(_ values: [String: String]) -> ResponseHeaders {
        ResponseHeaders(base: .exact, values: values)
    }
}
