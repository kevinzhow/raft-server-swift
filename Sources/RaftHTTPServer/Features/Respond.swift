import Foundation
import RaftHTTP
import Vapor

// The feature layer's only adapter from a typed service outcome to `Response`.
//
// A service returns a DTO and throws a `DomainError`; this file owns the
// status, header and body projection so no feature builds JSON, copies the
// header set or invents its own overload. The API is deliberately small:
//
//   respond(status:headers:_:)          plain `Encodable` DTO (sorted keys)
//   respond(status:headers:_:)          `JSONBodyConvertible` DTO (exact order)
//   respond(status:headers:_:)          payload-dependent header policy
//   respond(_:)                         bare 204 (`NoContentResponse`)
//   respond(status:headers:_:)          204 with a custom header policy
//   respond(status:headers:rawJSON:)    body the domain already rendered
//
// Errors are not a separate overload: every `DomainError` carries its exact
// body (`errorBody`, or the default `{"error": …}`), and the legacy
// `DomainErrorWithBody` Codable shape keeps its sorted encoding.

/// A plain `Encodable` success body.
///
/// `JSONEncoder` runs with sorted keys because Linux keyed containers are hash
/// ordered: sorting is what makes two identical responses byte-identical. A
/// body whose published order is not alphabetical conforms to
/// `JSONBodyConvertible` instead and the ordered overload below wins.
func respond<DTO: Encodable>(
    status: UInt = 200,
    headers: ResponseHeaders = .standard(),
    _ call: () async throws -> DTO
) async throws -> Response {
    do {
        return response(try encodedReply(status: status, payload: try await call(), headers: headers))
    } catch let error as any DomainError {
        return domainErrorResponse(error)
    } catch let error as any DomainErrorWithBody {
        return try richBodyErrorResponse(error)
    }
}

/// A success body whose headers depend on the value just produced.
///
/// Use this for a legacy reply whose `Server-Timing`/cache headers are derived
/// from the payload (the product-feedback receipt is the current caller). The
/// returned `ResponseHeaders` is the complete policy for the success reply; a
/// thrown error keeps its own `errorHeaders`.
func respond<DTO: Encodable>(
    status: UInt = 200,
    headers: @escaping (DTO) -> ResponseHeaders,
    _ call: () async throws -> DTO
) async throws -> Response {
    do {
        let payload = try await call()
        return response(try encodedReply(status: status, payload: payload, headers: headers(payload)))
    } catch let error as any DomainError {
        return domainErrorResponse(error)
    } catch let error as any DomainErrorWithBody {
        return try richBodyErrorResponse(error)
    }
}

/// A success body that owns its exact published order.
///
/// `JSONBodyConvertible.jsonBody` already knows the member order, so no
/// `JSONEncoder` runs. Swift selects this overload over the `Encodable` one
/// when the closure returns a type that conforms to both (the existential
/// parameter is more specific than the generic one).
func respond(
    status: UInt = 200,
    headers: ResponseHeaders = .standard(),
    _ call: () async throws -> any JSONBodyConvertible
) async throws -> Response {
    do {
        return response(orderedReply(
            status: status,
            body: try await call().jsonBody.render(),
            headers: headers
        ))
    } catch let error as any DomainError {
        return domainErrorResponse(error)
    } catch let error as any DomainErrorWithBody {
        return try richBodyErrorResponse(error)
    }
}

/// A success body that owns its exact published order *and* whose header
/// policy depends on the payload.
///
/// The idempotent action-prepare replay republishes the first reply's stored
/// bytes with the legacy `Cache-Control: no-store` header set (no
/// `X-Robots-Tag`), while a fresh `201` keeps the standard JSON set. The
/// `Encodable & JSONBodyConvertible` constraint makes this overload more
/// specialised than the plain `Encodable` one above, so a type that conforms to
/// both still renders through `jsonBody` instead of `JSONEncoder`.
func respond<DTO: Encodable & JSONBodyConvertible>(
    status: UInt = 200,
    headers: @escaping (DTO) -> ResponseHeaders,
    _ call: () async throws -> DTO
) async throws -> Response {
    do {
        let payload = try await call()
        return response(orderedReply(
            status: status,
            body: payload.jsonBody.render(),
            headers: headers(payload)
        ))
    } catch let error as any DomainError {
        return domainErrorResponse(error)
    } catch let error as any DomainErrorWithBody {
        return try richBodyErrorResponse(error)
    }
}

/// A route whose published success carries no body (204) and the bare
/// `Content-Length: 0` header set.
func respond(_ call: () async throws -> NoContentResponse) async throws -> Response {
    do {
        _ = try await call()
        return response(HTTPReply(status: 204, headers: ["Content-Length": "0"], body: ""))
    } catch let error as any DomainError {
        return domainErrorResponse(error)
    } catch let error as any DomainErrorWithBody {
        return try richBodyErrorResponse(error)
    }
}

/// A `204` whose legacy reply still published a header set of its own.
///
/// The onboarding-wizard ack reused the JSON reply helper before the
/// migration, so it kept `X-Robots-Tag`, `Content-Type` and
/// `Content-Length: 0`. `respond(_:)` above stays the bare no-header reply for
/// routes that never published those headers; a thrown `DomainError` keeps its
/// own body and header policy.
func respond(
    status: UInt,
    headers: ResponseHeaders,
    _ call: () async throws -> NoContentResponse
) async throws -> Response {
    do {
        _ = try await call()
        return response(HTTPReply(
            status: Int(status),
            headers: resolvedHeaders(headers, contentLength: 0),
            body: ""
        ))
    } catch let error as any DomainError {
        return domainErrorResponse(error)
    } catch let error as any DomainErrorWithBody {
        return try richBodyErrorResponse(error)
    }
}

/// A body the domain already serialized (for example a `201` with a custom
/// header set, or an empty body that still publishes the JSON header set).
///
/// The bytes are published unchanged; the policy supplies the headers and
/// `Content-Length` is always recomputed from `body`.
func respond(
    status: UInt = 200,
    headers: ResponseHeaders = .standard(),
    rawJSON body: String
) -> Response {
    response(orderedReply(status: status, body: body, headers: headers))
}

// MARK: - Projection

private func response(_ reply: HTTPReply) -> Response {
    routeResponse(reply)
}

private func resolvedHeaders(_ headers: ResponseHeaders, contentLength: Int) -> [String: String] {
    var resolved: [String: String]
    switch headers.base {
    case .standard:
        resolved = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(contentLength),
        ]
    case .exact:
        resolved = [:]
    }
    for (name, value) in headers.values { resolved[name] = value }
    resolved["Content-Length"] = String(contentLength)
    return resolved
}

/// Deterministic `Encodable` projection: sorted keys and the resolved header
/// policy.
private func encodedReply<T: Encodable>(
    status: UInt,
    payload: T,
    headers: ResponseHeaders
) throws -> HTTPReply {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    return HTTPReply(
        status: Int(status),
        headers: resolvedHeaders(headers, contentLength: data.count),
        body: String(decoding: data, as: UTF8.self)
    )
}

/// Exact-bytes projection; the caller owns the JSON text.
private func orderedReply(
    status: UInt,
    body: String,
    headers: ResponseHeaders
) -> HTTPReply {
    HTTPReply(
        status: Int(status),
        headers: resolvedHeaders(headers, contentLength: body.utf8.count),
        body: body
    )
}

/// One `DomainError` projection shared by every success overload.
private func domainErrorResponse(_ error: any DomainError) -> Response {
    response(orderedReply(
        status: error.status,
        body: error.publishedErrorBody.render(),
        headers: error.errorHeaders
    ))
}

/// The retained `DomainErrorWithBody` projection: a synthesized `Codable` error
/// object is encoded with sorted keys, exactly as before.
private func richBodyErrorResponse(_ error: any DomainErrorWithBody) throws -> Response {
    response(try encodedReply(
        status: error.status,
        payload: error.body,
        headers: .standard(extra: error.responseHeaders)
    ))
}
