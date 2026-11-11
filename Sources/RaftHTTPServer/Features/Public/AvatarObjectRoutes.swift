import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// The public, capability-addressed profile-asset routes. Upstream mounts
/// `/api/avatars` and `/api/integration-logos` above the authenticated API with
/// no session because the content hash in the path is the capability.
///
/// The service owns lookup and storage; this feature owns the streaming status
/// and header projection (real content type, immutable cache policy).
public struct AvatarObjectRoutes: Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func register(routes: any RoutesBuilder) {
        let avatars = routes.grouped("api", "avatars")
        avatars.get(":namespace", ":filename") { request async throws -> Response in
            do {
                return Self.objectResponse(try await services.emailAccounts.avatars.avatarContent(
                    namespace: request.parameters.get("namespace") ?? "",
                    filename: request.parameters.get("filename") ?? ""
                ))
            } catch let error as any DomainError {
                return domainErrorResponse(error)
            }
        }

        let logos = routes.grouped("api", "integration-logos")
        logos.get(":clientId", ":filename") { request async throws -> Response in
            do {
                return Self.objectResponse(try await services.emailAccounts.avatars.integrationLogoContent(
                    clientRecordId: request.parameters.get("clientId") ?? "",
                    filename: request.parameters.get("filename") ?? ""
                ))
            } catch let error as any DomainError {
                return domainErrorResponse(error)
            }
        }
    }

    private static func objectResponse(_ content: AvatarBinaryContent) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = content.contentType
        headers[.cacheControl] = "public, max-age=31536000, immutable"
        headers[.contentLength] = String(content.bytes.count)
        return Response(status: .ok, headers: headers, body: .init(data: content.bytes))
    }
}
