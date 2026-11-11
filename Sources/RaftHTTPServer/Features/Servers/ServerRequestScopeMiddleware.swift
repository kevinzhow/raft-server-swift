import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Mounts the pinned `requireServerMatchesParam` funnel once, as route-group
/// middleware on the `/api/servers/:id` routes registered after
/// `routes/servers.ts:994`.
///
/// `HumanAdmissionMiddleware` is global and already answers 401 for every
/// `/api/servers` request, so authentication still precedes these checks. The
/// labs routes are registered on the bare server group (their upstream mount is
/// `routes/servers.ts:993`, before the lockdown) and never enter here.
struct ServerRequestScopeMiddleware: Middleware {
    let scope: ServerRequestScopeService
    /// The route is one of the eight guest-hidden path families from
    /// `routes/servers.ts:996-1004`; a live guest is refused after membership.
    let hidesGuests: Bool

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard let serverId = request.parameters.get("id"), !serverId.isEmpty else {
            // `use("/:id", …)` fail-closed branch; the registered group always
            // carries the parameter, so this is the same 400 as a mount bug.
            return domainErrorResponse(ServerRequestScopeError.serverIdRequired)
        }
        do {
            _ = try scope.enforce(
                authorization: request.headers[.authorization],
                serverId: serverId,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!],
                isDeleteServerRoot: Self.isDeleteServerRoot(request),
                hidesGuests: hidesGuests
            )
        } catch let error as any DomainError {
            return domainErrorResponse(error)
        }
        return try await next.respond(to: request)
    }

    /// The middleware's exemption is only `DELETE /api/servers/:id`; the
    /// matched route is authoritative, so an alias cannot widen it.
    private static func isDeleteServerRoot(_ request: Request) -> Bool {
        guard request.method == .delete, let route = request.route else { return false }
        var components: [String] = []
        for component in route.path {
            switch component {
            case .constant(let literal):
                if !literal.isEmpty { components.append(literal) }
            case .parameter:
                components.append(":")
            case .anything, .catchall, .partialParameter:
                return false
            }
        }
        return components == ["api", "servers", ":"]
    }
}
