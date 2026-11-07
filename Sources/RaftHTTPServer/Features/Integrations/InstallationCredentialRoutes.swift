import RaftHTTP
import Vapor

/// The production installation credential handlers. Both the full Features and
/// a focused HTTP scene use these registrations with the same concrete service.
public struct InstallationCredentialRoutes: Sendable {
    private let apps: IntegrationsAndAppAccessService

    public init(apps: IntegrationsAndAppAccessService) {
        self.apps = apps
    }

    /// Mount at the existing `api/oauth` group, preserving its sibling order.
    public func registerMint(routes oauth: any RoutesBuilder) {
        oauth.post("installation-token") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try apps.issueInstallationCredential(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
    }

    /// Mount at the existing `api/app-installation` group.
    public func registerReads(routes appInstallation: any RoutesBuilder) {
        appInstallation.get("server") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try apps.installationServer(authorization: request.headers[.authorization])
            }
        }

        appInstallation.get("channels") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try apps.installationChannels(authorization: request.headers[.authorization])
            }
        }
    }
}
