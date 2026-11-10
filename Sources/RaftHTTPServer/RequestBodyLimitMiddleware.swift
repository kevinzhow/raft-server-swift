import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Node's global express.json limit runs before its API cache/auth mounts.
/// Only reject declared oversize here: no body parsing, stores or credentials.
/// Scope/migration exceptions retain their authenticated inner parser order.
struct GlobalJSONLengthPreflightMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        if let body = RequestBodyLimitMiddleware.declaredJSONBody(request),
           !body.isScopeAttestation, !body.isMigrationControl,
           body.declared > body.limit {
            return RequestBodyLimitMiddleware.globalFailureResponse()
        }
        return try await next.respond(to: request)
    }
}

/// Route-scoped JSON body limits.
///
/// The upstream server runs `express.json()` with the default 100 KB limit for
/// every route, and raises it only for one surface: the resumable migration
/// control manifest, whose 512 KB manifest plus envelope headroom must reach the
/// handler instead of dying in the parser. A body over the allowance answers a
/// typed 413 (the route-scoped surface names its code and limit), and no parser
/// runs before credential validation on that surface, so an oversized request
/// without a Computer principal is still a 401.
struct RequestBodyLimitMiddleware: Middleware {
    static let globalJSONLimit = 100 * 1024
    static let migrationControlLimit = 512 * 1024 + 64 * 1024
    static let scopeAttestationLimit = 1024 * 1024

    /// Pure declared-length classification shared with the outer global preflight.
    /// Special parsers only classify here; their live credential checks stay below.
    static func declaredJSONBody(_ request: Request) -> (declared: Int, limit: Int, isMigrationControl: Bool, isScopeAttestation: Bool)? {
        let contentType = (request.headers[.contentType] ?? "").lowercased()
        guard contentType.hasPrefix("application/json"),
              let rawLength = request.headers[.contentLength],
              let declared = Int(rawLength.trimmingCharacters(in: .whitespaces)) else { return nil }
        let path = request.url.path
        let migration = request.method == .post && path.hasSuffix("/resumable/control")
        let scope = request.method == .post && path.hasSuffix("/internal/machine/scope-attestation")
        let limit = migration ? migrationControlLimit : (scope ? scopeAttestationLimit : globalJSONLimit)
        return (declared, limit, migration, scope)
    }

    static func globalFailureResponse() -> Response {
        jsonReply(413, "{\"error\":\"Request body is too large\",\"code\":\"request_body_too_large\"}")
    }

    let runtimeForms: RuntimeFormsAndProbesService

    func respond(to incoming: Request, chainingTo next: any Responder) async throws -> Response {
        var request = incoming
        guard let body = Self.declaredJSONBody(request) else {
            return try await next.respond(to: request)
        }
        let isMigrationControl = body.isMigrationControl
        let isScopeAttestation = body.isScopeAttestation
        let limit = body.limit
        request.maxBodySize = .init(value: limit)
        guard body.declared > limit else {
            return try await next.respond(to: request)
        }
        if isScopeAttestation, !runtimeForms.machineCredentialIsLive(authorization: request.headers[.authorization]) {
            return Self.jsonReply(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        if isScopeAttestation {
            return Self.jsonReply(413, "{\"error\":\"Scope attestation body is too large\",\"code\":\"scope_attestation_body_too_large\",\"limitBytes\":\(limit)}")
        }
        if isMigrationControl, !runtimeForms.computerCredentialIsLive(authorization: request.headers[.authorization]) {
            return Self.jsonReply(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        if isMigrationControl {
            return Self.jsonReply(413, "{\"error\":\"Migration control body is too large\",\"code\":\"migration_control_body_too_large\",\"limitBytes\":\(limit)}")
        }
        return Self.globalFailureResponse()
    }

    private static func jsonReply(_ status: Int, _ body: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.contentLength] = String(Data(body.utf8).count)
        return Response(status: HTTPResponse.Status(code: status, reasonPhrase: ""), headers: headers, body: .init(string: body))
    }
}
