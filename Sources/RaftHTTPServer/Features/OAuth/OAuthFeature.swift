import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/api/oauth/...`, `/oidc/:server/...` and root `.well-known` routes extracted
/// from `FallbackApplication.configure`.
///
/// Responses use the canonical ordered DTO and domain-error projection while
/// preserving the published paths, methods and header policies.
/// `boot` delegates to the same synchronous `register(routes:)` used by the
/// pinned Vapor async boot path.
public struct OAuthFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let app = routes
        let oauth = app.grouped("api", "oauth")
        let oidc = app.grouped("oidc", ":server")
        let oidcOAuth = oidc.grouped("api", "oauth")
        let oauthFlows = services.emailAccounts.oauthFlows
        let issuerMetadata = services.emailAccounts.oauthIssuerMetadata

        oauth.put("installations", ":installationId", "setup") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try services.emailAccounts.integrationsAndAppAccess.reportInstallationSetup(
                    authorization: request.headers[.authorization],
                    installationId: request.parameters.get("installationId") ?? "",
                    body: body
                )
            }
        }
        oauth.post("authorize", "human") { request async throws -> Response in
            let session = services.emailAccounts.authIdentities.oauthSession(authorization: request.headers[.authorization])
            let body = try await request.bodyText()
            return try await respond {
                try services.emailAccounts.oauth.issueHumanAuthorization(session: session, body: body)
            }
        }
        InstallationCredentialRoutes(apps: services.emailAccounts.integrationsAndAppAccess).registerMint(routes: oauth)
        oauth.post("token") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try services.emailAccounts.oauth.exchangeToken(
                    authorization: request.headers[.authorization],
                    body: body,
                    issuer: OAuthDiscovery.issuerOrigin(oauthFlows.deploymentConfiguration.serverURL) ?? ""
                )
            }
        }
        oauth.get("userinfo") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.oauth.userinfo(
                    authorization: request.headers[.authorization],
                    baseURL: oauthFlows.deploymentConfiguration.serverURL
                )
            }
        }
        oauth.get("agents") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try services.emailAccounts.oauth.agentDirectory(
                    authorization: request.headers[.authorization],
                    baseURL: oauthFlows.deploymentConfiguration.serverURL
                )
            }
        }
        oauth.get("serverinfo") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.oauth.serverinfo(
                    authorization: request.headers[.authorization],
                    baseURL: oauthFlows.deploymentConfiguration.serverURL
                )
            }
        }
        oauth.post("installations", "lookup") { request async throws -> Response in
            // A body that does not decode reads as an empty lookup, which
            // answers the published credential refusal.
            let body = await jsonRequestBody(OAuthInstallationLookupDTO.self, request)
                ?? OAuthInstallationLookupDTO()
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try oauthFlows.installationLookup(body, authorization: request.headers[.authorization])
            }
        }
        oauth.post("requests", "agent") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond {
                try services.emailAccounts.integrationsAndAppAccess.requestAgentAccess(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        oauth.post("agent-events") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond(status: { $0.httpStatus }, headers: { _ in .standard() }) {
                try services.emailAccounts.integrationsAndAppAccess.postAgentEvent(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        oauth.get("clients", "lookup") { request async throws -> Response in
            let session = services.emailAccounts.authIdentities.oauthSession(authorization: request.headers[.authorization])
            return try await respond {
                try services.emailAccounts.oauth.clientLookup(
                    session: session,
                    clientId: desktopQuery(request.url.query, "client_id") ?? desktopQuery(request.url.query, "clientId") ?? "",
                    serverId: desktopQuery(request.url.query, "server_id") ?? desktopQuery(request.url.query, "serverId") ?? "",
                    scope: desktopQuery(request.url.query, "scope") ?? ""
                )
            }
        }
        app.get(".well-known", "openid-configuration") { _ async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                try issuerMetadata.discovery()
            }
        }
        oauth.get("jwks") { _ async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                try issuerMetadata.jwks()
            }
        }
        oauth.get("authorize") { request async throws -> Response in
            try await respond(status: { $0.status }, headers: { $0.headers }) {
                try services.emailAccounts.oauth.browserAuthorize(
                    query: request.url.query ?? "",
                    appURL: oauthFlows.deploymentConfiguration.appURL
                )
            }
        }
        oauth.get(".well-known", "openid-configuration") { _ async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                try issuerMetadata.discovery()
            }
        }
        oidc.get(".well-known", "openid-configuration") { request async throws -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch issuerMetadata.resolveServerScope(segment) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                    try issuerMetadata.discovery(scope: scope)
                }
            }
        }
        oidcOAuth.get(".well-known", "openid-configuration") { request async throws -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch issuerMetadata.resolveServerScope(segment) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                    try issuerMetadata.discovery(scope: scope)
                }
            }
        }
        oidcOAuth.get("agents") { request async throws -> Response in
            switch issuerMetadata.resolveServerScope(request.parameters.get("server") ?? "") {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                    try services.emailAccounts.oauth.agentDirectory(
                        authorization: request.headers[.authorization],
                        baseURL: oauthFlows.deploymentConfiguration.serverURL,
                        scopeServerId: scope.serverId
                    )
                }
            }
        }
        oidcOAuth.get("jwks") { request async throws -> Response in
            switch issuerMetadata.resolveServerScope(request.parameters.get("server") ?? "") {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved:
                return try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                    try issuerMetadata.jwks()
                }
            }
        }
        oidcOAuth.get("userinfo") { request async throws -> Response in
            switch issuerMetadata.resolveServerScope(request.parameters.get("server") ?? "") {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond {
                    try services.emailAccounts.oauth.userinfo(
                        authorization: request.headers[.authorization],
                        baseURL: oauthFlows.deploymentConfiguration.serverURL,
                        scopeServerId: scope.serverId
                    )
                }
            }
        }
        oidcOAuth.get("serverinfo") { request async throws -> Response in
            switch issuerMetadata.resolveServerScope(request.parameters.get("server") ?? "") {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond {
                    try services.emailAccounts.oauth.serverinfo(
                        authorization: request.headers[.authorization],
                        baseURL: oauthFlows.deploymentConfiguration.serverURL,
                        scopeServerId: scope.serverId
                    )
                }
            }
        }
        oidcOAuth.get("authorize") { request async throws -> Response in
            switch issuerMetadata.resolveServerScope(request.parameters.get("server") ?? "") {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond(status: { $0.status }, headers: { $0.headers }) {
                    try services.emailAccounts.oauth.browserAuthorize(
                        query: request.url.query ?? "",
                        appURL: oauthFlows.deploymentConfiguration.appURL,
                        serverScope: scope.segment
                    )
                }
            }
        }
        oidcOAuth.post("token") { request async throws -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch issuerMetadata.resolveServerScope(segment) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                let origin = OAuthDiscovery.issuerOrigin(oauthFlows.deploymentConfiguration.serverURL) ?? ""
                let body = try await request.bodyText()
                return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                    try services.emailAccounts.oauth.exchangeToken(
                        authorization: request.headers[.authorization],
                        body: body,
                        issuer: "\(origin)/oidc/\(segment)",
                        scopeServerId: scope.serverId
                    )
                }
            }
        }
    }
}
