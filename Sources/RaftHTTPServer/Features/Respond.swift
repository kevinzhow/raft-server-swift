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
        return try domainErrorResponse(error)
    }
}

/// The same projection as `respond`, plus the extra headers a legacy reply
/// published (for example `Cache-Control: private, no-store`). Error mapping is
/// shared with the plain overload, so a typed failure keeps the published
/// status, body and headers.
func respond<DTO: Encodable>(
    status: UInt = 200,
    extraHeaders: [String: String],
    _ call: () throws -> DTO
) throws -> Response {
    do {
        return routeResponse(try jsonReply(
            status: status,
            payload: try call(),
            extraHeaders: extraHeaders
        ))
    } catch let error as any DomainError {
        return try domainErrorResponse(error)
    }
}

/// A route whose published success carries no body (204). The marker is not
/// `Encodable`, so this overload cannot collide with the JSON ones; a thrown
/// `DomainError` still maps through the same published error shape.
func respond(_ call: () throws -> NoContentResponse) throws -> Response {
    do {
        _ = try call()
        return routeResponse(HTTPReply(status: 204, headers: ["Content-Length": "0"], body: ""))
    } catch let error as any DomainError {
        return try domainErrorResponse(error)
    }
}

/// The upstream `{"error": …}` body. Domains with a richer published shape get
/// their own DTO and a second mapping overload rather than JSON in the service.
private struct ErrorBody: Encodable {
    let error: String
}

/// One `DomainError` projection shared by every `respond` overload.
private func domainErrorResponse(_ error: any DomainError) throws -> Response {
    routeResponse(try jsonReply(
        status: error.status,
        payload: ErrorBody(error: error.errorMessage),
        extraHeaders: error.responseHeaders
    ))
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
