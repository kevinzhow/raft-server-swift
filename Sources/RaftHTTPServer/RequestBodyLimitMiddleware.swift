import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

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

    var accounts: EmailLoginDirectory

    func respond(to incoming: Request, chainingTo next: any Responder) async throws -> Response {
        var request = incoming
        let contentType = (request.headers[.contentType] ?? "").lowercased()
        guard contentType.hasPrefix("application/json"),
              let rawLength = request.headers[.contentLength],
              let declared = Int(rawLength.trimmingCharacters(in: .whitespaces))
        else {
            return try await next.respond(to: request)
        }
        let path = request.url.path
        let isMigrationControl = request.method == .post && path.hasSuffix("/resumable/control")
        let limit = isMigrationControl ? Self.migrationControlLimit : Self.globalJSONLimit
        request.maxBodySize = .init(value: limit)
        guard declared > limit else {
            return try await next.respond(to: request)
        }
        if isMigrationControl, !accounts.computerCredentialIsLive(authorization: request.headers[.authorization]) {
            return Self.jsonReply(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        if isMigrationControl {
            return Self.jsonReply(413, "{\"error\":\"Migration control body is too large\",\"code\":\"migration_control_body_too_large\",\"limitBytes\":\(limit)}")
        }
        return Self.jsonReply(413, "{\"error\":\"Request body is too large\",\"code\":\"request_body_too_large\"}")
    }

    private static func jsonReply(_ status: Int, _ body: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.contentLength] = String(Data(body.utf8).count)
        return Response(status: HTTPResponse.Status(code: status, reasonPhrase: ""), headers: headers, body: .init(string: body))
    }
}
