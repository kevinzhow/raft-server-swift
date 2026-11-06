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

/// Overload for a domain whose published error body keeps a legacy key order
/// that `JSONEncoder` cannot reproduce (`{"error": …}` before `{"code": …}`).
///
/// The success payload is encoded with sorted keys, which is byte-stable; for
/// the receipts this projection serves, that is also the legacy field order.
/// The failure body is the domain's exact bytes, and `headers` is the exact
/// success header set: the legacy feedback `201` published `Cache-Control` and
/// `Server-Timing` without `X-Robots-Tag`, so this overload never adds a
/// header the domain did not ask for.
func respond<DTO: Encodable, Failure: OrderedBodyDomainError>(
    errors _: Failure.Type,
    status: UInt,
    headers: (DTO) -> [String: String],
    _ call: () async throws -> DTO
) async throws -> Response {
    do {
        let payload = try await call()
        return routeResponse(try exactJSONReply(
            status: status,
            payload: payload,
            headers: headers(payload)
        ))
    } catch let error as Failure {
        return try orderedBodyErrorResponse(error)
    }
}

/// A 204 whose pre-migration reply reused the JSON reply helper, so the
/// published response kept the JSON header set (`X-Robots-Tag` and
/// `Content-Type`) with an empty body. `respond(_:)` above stays the bare 204
/// for call sites that never published those headers.
func respond<Failure: OrderedBodyDomainError>(
    jsonNoContent _: Failure.Type,
    _ call: () throws -> NoContentResponse
) throws -> Response {
    do {
        _ = try call()
        return routeResponse(HTTPReply(
            status: 204,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": "0",
            ],
            body: ""
        ))
    } catch let error as Failure {
        return try orderedBodyErrorResponse(error)
    }
}

/// Deterministic success encoding for the ordered-body overload. `id`/`status`
/// sort to the legacy declaration order, and `.withoutEscapingSlashes` matches
/// the encoder the legacy feedback replies used. Richer domains use
/// `OrderedBodyDomainError` for the failure side.
private func exactJSONReply<T: Encodable>(
    status: UInt,
    payload: T,
    headers: [String: String]
) throws -> HTTPReply {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(payload)
    var resolved = headers
    resolved["Content-Length"] = String(data.count)
    return HTTPReply(
        status: Int(status),
        headers: resolved,
        body: String(decoding: data, as: UTF8.self)
    )
}

/// Exact-byte error projection for `OrderedBodyDomainError`.
private func orderedBodyErrorResponse<Failure: OrderedBodyDomainError>(
    _ error: Failure
) throws -> Response {
    let body = error.bodyJSON
    var headers = error.responseHeaders
    headers["Content-Length"] = String(body.utf8.count)
    return routeResponse(HTTPReply(status: Int(error.status), headers: headers, body: body))
}

/// The upstream `{"error": …}` body. Domains with a richer published shape get
/// their own DTO and a second mapping overload rather than JSON in the service.
///
/// `code` is omitted when the domain publishes none, so every existing error
/// keeps the exact `{"error": …}` bytes. When present it is appended after
/// `error`, the order the archive reply uses.
private struct ErrorBody: Encodable {
    let error: String
    let code: String?

    init(error: String, code: String? = nil) {
        self.error = error
        self.code = code
    }
}

/// One `DomainError` projection shared by every `respond` overload.
private func domainErrorResponse(_ error: any DomainError) throws -> Response {
    routeResponse(try jsonReply(
        status: error.status,
        payload: ErrorBody(error: error.errorMessage, code: error.errorCode),
        extraHeaders: error.responseHeaders
    ))
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
