import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/api/oauth/...`, `/oidc/:server/...` and root `.well-known` routes extracted
/// from `FallbackApplication.configure`.
///
/// The handlers are lifted verbatim so paths, methods, header projections and
/// `routeResponse` mapping stay identical. This collection is not mounted by
/// `FallbackApplication` yet; the composition root decides when it is live.
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
            routeResponse(services.emailAccounts.oauth.issueHumanAuthorization(
                session: services.emailAccounts.authIdentities.oauthSession(authorization: request.headers[.authorization]),
                body: try await request.bodyText()
            ))
        }
        oauth.post("installation-token") { request async throws -> Response in
            routeResponse(services.emailAccounts.oauth.mintInstallationToken(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        oauth.post("token") { request async throws -> Response in
            routeResponse(services.emailAccounts.oauth.exchangeToken(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(),
                issuer: OAuthDiscovery.issuerOrigin(services.emailAccounts.serverURL) ?? ""
            ))
        }
        oauth.get("userinfo") { request -> Response in
            routeResponse(services.emailAccounts.oauth.userinfo(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL
            ))
        }
        oauth.get("agents") { request -> Response in
            routeResponse(services.emailAccounts.oauth.agentDirectory(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL
            ))
        }
        oauth.get("serverinfo") { request -> Response in
            routeResponse(services.emailAccounts.oauth.serverinfo(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL
            ))
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
            routeResponse(services.emailAccounts.oauth.requestAgentAccess(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        oauth.post("agent-events") { request async throws -> Response in
            routeResponse(services.emailAccounts.oauth.postAgentEvent(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        oauth.get("clients", "lookup") { request -> Response in
            routeResponse(services.emailAccounts.oauth.clientLookup(
                session: services.emailAccounts.authIdentities.oauthSession(authorization: request.headers[.authorization]),
                clientId: desktopQuery(request.url.query, "client_id") ?? desktopQuery(request.url.query, "clientId") ?? "",
                serverId: desktopQuery(request.url.query, "server_id") ?? desktopQuery(request.url.query, "serverId") ?? "",
                scope: desktopQuery(request.url.query, "scope") ?? ""
            ))
        }
        app.get(".well-known", "openid-configuration") { _ -> Response in
            routeResponse(OAuthDiscovery.openIDConfiguration(serverURL: services.emailAccounts.serverURL))
        }
        oauth.get("jwks") { _ -> Response in
            routeResponse(services.emailAccounts.oauth.jwks())
        }
        oauth.get("authorize") { request -> Response in
            routeResponse(services.emailAccounts.oauth.browserAuthorize(
                query: request.url.query ?? "",
                appURL: services.emailAccounts.appURL
            ))
        }
        oauth.get(".well-known", "openid-configuration") { _ -> Response in
            routeResponse(OAuthDiscovery.openIDConfiguration(serverURL: services.emailAccounts.serverURL))
        }
        oidc.get(".well-known", "openid-configuration") { request -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved:
                return routeResponse(OAuthDiscovery.openIDConfiguration(
                    serverURL: services.emailAccounts.serverURL,
                    serverScope: segment
                ))
            }
        }
        oidcOAuth.get(".well-known", "openid-configuration") { request -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved:
                return routeResponse(OAuthDiscovery.openIDConfiguration(
                    serverURL: services.emailAccounts.serverURL,
                    serverScope: segment
                ))
            }
        }
        oidcOAuth.get("agents") { request -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved(let scope):
                return routeResponse(services.emailAccounts.oauth.agentDirectory(
                    authorization: request.headers[.authorization],
                    baseURL: services.emailAccounts.serverURL,
                    scopeServerId: scope
                ))
            }
        }
        oidcOAuth.get("jwks") { request -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved:
                return routeResponse(services.emailAccounts.oauth.jwks())
            }
        }
        oidcOAuth.get("userinfo") { request -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved(let scope):
                return routeResponse(services.emailAccounts.oauth.userinfo(
                    authorization: request.headers[.authorization],
                    baseURL: services.emailAccounts.serverURL,
                    scopeServerId: scope
                ))
            }
        }
        oidcOAuth.get("serverinfo") { request -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved(let scope):
                return routeResponse(services.emailAccounts.oauth.serverinfo(
                    authorization: request.headers[.authorization],
                    baseURL: services.emailAccounts.serverURL,
                    scopeServerId: scope
                ))
            }
        }
        oidcOAuth.get("authorize") { request -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved:
                return routeResponse(services.emailAccounts.oauth.browserAuthorize(
                    query: request.url.query ?? "",
                    appURL: services.emailAccounts.appURL,
                    serverScope: request.parameters.get("server")
                ))
            }
        }
        oidcOAuth.post("token") { request async throws -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved(let scope):
                let origin = OAuthDiscovery.issuerOrigin(services.emailAccounts.serverURL) ?? ""
                return routeResponse(services.emailAccounts.oauth.exchangeToken(
                    authorization: request.headers[.authorization],
                    body: try await request.bodyText(),
                    issuer: "\(origin)/oidc/\(segment)",
                    scopeServerId: scope
                ))
            }
        }
    }
}

/// File-private copies of the helpers the extracted OIDC handlers need. The
/// originals stay private to `FallbackApplication.swift`; keeping a copy here is
/// what lets the collection be registered on a bare `Application` without
/// editing the composition root.
private enum OIDCScopeResolution {
    case resolved(String)
    case failure(Response)
}

private func resolveOIDCScope(_ segment: String, oauth: OAuthLedger) -> OIDCScopeResolution {
    guard segment.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil else {
        return .failure(pixelAvatarError(400, "invalid_server_scope"))
    }
    guard let scope = oauth.serverScopeId(segment) else {
        return .failure(pixelAvatarError(404, "Not found"))
    }
    return .resolved(scope)
}

private func pixelAvatarError(_ status: Int, _ error: String) -> Response {
    let body = "{\"error\":\"\(error)\"}"
    return routeResponse(HTTPReply(
        status: status,
        headers: [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ],
        body: body
    ))
}
