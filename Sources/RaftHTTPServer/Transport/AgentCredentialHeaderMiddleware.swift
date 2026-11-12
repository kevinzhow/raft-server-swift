import RaftHTTP
import Vapor

/// Apply the Agent credential header precondition once to each registered Agent
/// route family. Existing services retain credential, capability and grant checks.
struct AgentCredentialHeaderMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer ") else {
            return domainErrorResponse(AgentCredentialAuthError.missingCredential)
        }
        return try await next.respond(to: request)
    }
}
