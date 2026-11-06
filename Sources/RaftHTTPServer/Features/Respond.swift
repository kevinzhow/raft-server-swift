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

/// Success bodies whose published member order is part of the contract.
///
/// Linux `JSONEncoder` does not preserve keyed-container insertion order, so
/// the domain declares an explicit `JSONBody` tree. This overload writes the
/// bytes that tree renders (same escaping, separators and header set as the
/// legacy `Self.json` reply), which keeps the body and `Content-Length`
/// byte-identical to the pre-migration handler.
func respond<DTO: ExactJSONBody>(
    status: UInt = 200,
    _ call: () throws -> DTO
) throws -> Response {
    do {
        return routeResponse(try exactJSONReply(status: status, body: try call()))
    } catch let error as any DomainError {
        return try domainErrorResponse(error)
    }
}

/// The exact-body projection with the extra headers a legacy reply published.
func respond<DTO: ExactJSONBody>(
    status: UInt = 200,
    extraHeaders: [String: String],
    _ call: () throws -> DTO
) throws -> Response {
    do {
        return routeResponse(try exactJSONReply(
            status: status,
            body: try call(),
            extraHeaders: extraHeaders
        ))
    } catch let error as any DomainError {
        return try domainErrorResponse(error)
    }
}

/// Exact-body success and exact-body failure in one call.
///
/// The failure object keeps the published member order (`error`, `errorCode`,
/// `currentRevision`, …) instead of the sorted order the generic rich overload
/// uses, so the migrated error bytes match the archive reply.
func respond<DTO: ExactJSONBody, Failure: DomainErrorWithExactBody>(
    errors _: Failure.Type,
    status: UInt = 200,
    _ call: () throws -> DTO
) throws -> Response {
    try respond(errors: Failure.self, status: status, extraHeaders: [:], call)
}

/// The exact-body error mapping plus headers the legacy success published (the
/// failure keeps its own `responseHeaders`).
func respond<DTO: ExactJSONBody, Failure: DomainErrorWithExactBody>(
    errors _: Failure.Type,
    status: UInt = 200,
    extraHeaders: [String: String],
    _ call: () throws -> DTO
) throws -> Response {
    do {
        return routeResponse(try exactJSONReply(
            status: status,
            body: try call(),
            extraHeaders: extraHeaders
        ))
    } catch let error as Failure {
        return routeResponse(try exactJSONReply(
            status: error.status,
            body: error.exactBody,
            extraHeaders: error.responseHeaders
        ))
    }
}

/// Render one `ExactJSONBody` with the auth surface's published header set.
private func exactJSONReply(
    status: UInt,
    body: any ExactJSONBody,
    extraHeaders: [String: String] = [:]
) throws -> HTTPReply {
    let text = body.exactJSON
    var headers = [
        "X-Robots-Tag": AppFallback.robotsTag,
        "Content-Type": AppFallback.jsonContentType,
        "Content-Length": String(Data(text.utf8).count),
    ]
    for (name, value) in extraHeaders { headers[name] = value }
    return HTTPReply(status: Int(status), headers: headers, body: text)
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
