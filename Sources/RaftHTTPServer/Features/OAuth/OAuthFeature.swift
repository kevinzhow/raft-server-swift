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
                try services.emailAccounts.oauth.requestAgentAccess(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        oauth.post("agent-events") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond(status: { $0.httpStatus }, headers: { _ in .standard() }) {
                try services.emailAccounts.oauth.postAgentEvent(
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
                try OAuthDiscovery.openIDConfiguration(serverURL: oauthFlows.deploymentConfiguration.serverURL)
            }
        }
        oauth.get("jwks") { _ async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                try services.emailAccounts.oauth.jwks()
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
                try OAuthDiscovery.openIDConfiguration(serverURL: oauthFlows.deploymentConfiguration.serverURL)
            }
        }
        oidc.get(".well-known", "openid-configuration") { request async throws -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved:
                return try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                    try OAuthDiscovery.openIDConfiguration(
                        serverURL: oauthFlows.deploymentConfiguration.serverURL,
                        serverScope: segment
                    )
                }
            }
        }
        oidcOAuth.get(".well-known", "openid-configuration") { request async throws -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved:
                return try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                    try OAuthDiscovery.openIDConfiguration(
                        serverURL: oauthFlows.deploymentConfiguration.serverURL,
                        serverScope: segment
                    )
                }
            }
        }
        oidcOAuth.get("agents") { request async throws -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                    try services.emailAccounts.oauth.agentDirectory(
                        authorization: request.headers[.authorization],
                        baseURL: oauthFlows.deploymentConfiguration.serverURL,
                        scopeServerId: scope
                    )
                }
            }
        }
        oidcOAuth.get("jwks") { request async throws -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved:
                return try await respond(headers: .standard(extra: ["Cache-Control": "public, max-age=300"])) {
                    try services.emailAccounts.oauth.jwks()
                }
            }
        }
        oidcOAuth.get("userinfo") { request async throws -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond {
                    try services.emailAccounts.oauth.userinfo(
                        authorization: request.headers[.authorization],
                        baseURL: oauthFlows.deploymentConfiguration.serverURL,
                        scopeServerId: scope
                    )
                }
            }
        }
        oidcOAuth.get("serverinfo") { request async throws -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved(let scope):
                return try await respond {
                    try services.emailAccounts.oauth.serverinfo(
                        authorization: request.headers[.authorization],
                        baseURL: oauthFlows.deploymentConfiguration.serverURL,
                        scopeServerId: scope
                    )
                }
            }
        }
        oidcOAuth.get("authorize") { request async throws -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let error):
                return try await respond { () throws -> NoContentResponse in throw error }
            case .resolved:
                return try await respond(status: { $0.status }, headers: { $0.headers }) {
                    try services.emailAccounts.oauth.browserAuthorize(
                        query: request.url.query ?? "",
                        appURL: oauthFlows.deploymentConfiguration.appURL,
                        serverScope: request.parameters.get("server")
                    )
                }
            }
        }
        oidcOAuth.post("token") { request async throws -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
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
                        scopeServerId: scope
                    )
                }
            }
        }
    }
}

/// Scope validation happens before authentication and carries no cache policy.
private enum OIDCScopeResolution {
    case resolved(String)
    case failure(OIDCScopeError)
}

private struct OIDCScopeError: DomainError {
    var status: UInt
    var errorMessage: String
}

private func resolveOIDCScope(_ segment: String, oauth: OAuthLedger) -> OIDCScopeResolution {
    guard segment.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil else {
        return .failure(OIDCScopeError(status: 400, errorMessage: "invalid_server_scope"))
    }
    guard let scope = oauth.serverScopeId(segment) else {
        return .failure(OIDCScopeError(status: 404, errorMessage: "Not found"))
    }
    return .resolved(scope)
}
