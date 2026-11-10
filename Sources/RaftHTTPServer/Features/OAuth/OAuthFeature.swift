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
    private let oauthFlows: OAuthFlowsService
    private let issuerMetadata: OAuthIssuerMetadataService
    private let authorization: OAuthAuthorizationService
    private let principal: OAuthPrincipalService
    private let apps: IntegrationsAndAppAccessService

    public init(
        oauthFlows: OAuthFlowsService,
        issuerMetadata: OAuthIssuerMetadataService,
        authorization: OAuthAuthorizationService,
        principal: OAuthPrincipalService,
        apps: IntegrationsAndAppAccessService
    ) {
        self.oauthFlows = oauthFlows
        self.issuerMetadata = issuerMetadata
        self.authorization = authorization
        self.principal = principal
        self.apps = apps
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let app = routes
        let oauth = app.grouped("api", "oauth")
        let oidc = app.grouped("oidc", ":server")
        let oidcOAuth = oidc.grouped("api", "oauth")
        let oauthFlows = self.oauthFlows
        let issuerMetadata = self.issuerMetadata
        let authorization = self.authorization
        let principal = self.principal
        let apps = self.apps

        oauth.put("installations", ":installationId", "setup") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try apps.reportInstallationSetup(
                    authorization: request.headers[.authorization],
                    installationId: request.parameters.get("installationId") ?? "",
                    body: body
                )
            }
        }
        oauth.post("authorize", "human") { request async throws -> Response in
            let session = authorization.beginSession(authorization: request.headers[.authorization])
            let body = try await request.bodyText()
            return try await respond {
                try authorization.issueHumanAuthorization(session: session, body: body)
            }
        }
        InstallationCredentialRoutes(apps: apps).registerMint(routes: oauth)
        oauth.post("token") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try authorization.exchangeToken(
                    authorization: request.headers[.authorization],
                    body: body,
                    context: authorization.tokenContext()
                )
            }
        }
        oauth.get("userinfo") { request async throws -> Response in
            try await respond {
                try principal.userinfo(
                    authorization: request.headers[.authorization]
                )
            }
        }
        oauth.get("agents") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try principal.agentDirectory(
                    authorization: request.headers[.authorization]
                )
            }
        }
        oauth.get("serverinfo") { request async throws -> Response in
            try await respond {
                try principal.serverinfo(
                    authorization: request.headers[.authorization]
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
                try apps.requestAgentAccess(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        oauth.post("agent-events") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond(status: { $0.httpStatus }, headers: { _ in .standard() }) {
                try apps.postAgentEvent(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        oauth.get("clients", "lookup") { request async throws -> Response in
            let session = authorization.beginSession(authorization: request.headers[.authorization])
            return try await respond {
                try authorization.clientLookup(
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
                try authorization.browserAuthorize(
                    query: request.url.query ?? ""
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
                    try principal.agentDirectory(
                        authorization: request.headers[.authorization],
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
                    try principal.userinfo(
                        authorization: request.headers[.authorization],
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
                    try principal.serverinfo(
                        authorization: request.headers[.authorization],
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
                    try authorization.browserAuthorize(
                        query: request.url.query ?? "",
                        scope: scope
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
                let context = authorization.tokenContext(scope: scope)
                let body = try await request.bodyText()
                return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                    try authorization.exchangeToken(
                        authorization: request.headers[.authorization],
                        body: body,
                        context: context
                    )
                }
            }
        }
    }
}
