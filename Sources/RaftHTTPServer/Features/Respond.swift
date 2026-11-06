import Foundation
import RaftHTTP
import Vapor

/// The feature layer's one adapter from a typed service outcome to `Response`.
///
/// A migrated service returns a `Codable` DTO on success and throws a
/// `DomainError` on failure. This helper owns the status, header and body
/// projection, so a feature never builds JSON or copies the auth header set.
/// Any other error is rethrown to `JSONErrorBoundaryMiddleware`, which keeps
/// the existing fallback behavior for programming errors.
func respond<DTO: Encodable>(
    status: UInt = 200,
    _ call: () throws -> DTO
) throws -> Response {
    do {
        return routeResponse(try jsonReply(status: status, payload: try call()))
    } catch let error as any DomainError {
        return routeResponse(try jsonReply(
            status: error.status,
            payload: ErrorBody(error: error.errorMessage),
            extraHeaders: error.responseHeaders
        ))
    }
}

/// Overload for domains whose published error object is richer than
/// `{"error": …}`. The domain passes its typed error so the compiler selects
/// this mapping; the body is encoded exactly as the service declared it.
/// `respond` above is unchanged and stays byte-compatible for every
/// `DomainError`.
func respond<DTO: Encodable, Failure: DomainErrorWithBody>(
    errors _: Failure.Type,
    status: UInt = 200,
    _ call: () throws -> DTO
) throws -> Response {
    do {
        return routeResponse(try jsonReplySorted(status: status, payload: try call()))
    } catch let error as Failure {
        return routeResponse(try jsonReplySorted(
            status: error.status,
            payload: error.body,
            extraHeaders: error.responseHeaders
        ))
    }
}

/// The upstream `{"error": …}` body. Domains with a richer published shape get
/// their own DTO and a second mapping overload rather than JSON in the service.
private struct ErrorBody: Encodable {
    let error: String
}

/// Canonical encoder for the richer domain bodies.
///
/// Linux Foundation's `JSONEncoder` stores keyed containers in a dictionary,
/// so the default `jsonReply` above can emit the same object with different key
/// order on two calls. The rich overload sorts keys so a body is deterministic
/// and `Content-Length` stays meaningful; escaping and header bytes are
/// unchanged from `jsonReply`.
private func jsonReplySorted<T: Encodable>(
    status: UInt,
    payload: T,
    extraHeaders: [String: String] = [:]
) throws -> HTTPReply {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    var headers = [
        "X-Robots-Tag": AppFallback.robotsTag,
        "Content-Type": AppFallback.jsonContentType,
        "Content-Length": String(data.count),
    ]
    for (name, value) in extraHeaders { headers[name] = value }
    return HTTPReply(status: Int(status), headers: headers, body: String(decoding: data, as: UTF8.self))
}

/// The exact header set the auth surface already publishes for JSON replies.
private func jsonReply<T: Encodable>(
    status: UInt,
    payload: T,
    extraHeaders: [String: String] = [:]
) throws -> HTTPReply {
    let data = try JSONEncoder().encode(payload)
    var headers = [
        "X-Robots-Tag": AppFallback.robotsTag,
        "Content-Type": AppFallback.jsonContentType,
        "Content-Length": String(data.count),
    ]
    for (name, value) in extraHeaders { headers[name] = value }
    return HTTPReply(status: Int(status), headers: headers, body: String(decoding: data, as: UTF8.self))
}
