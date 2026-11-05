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
        app.put("api", "oauth", "installations", ":installationId", "setup") { request -> Response in
            routeResponse(services.emailAccounts.reportInstallationSetup(
                authorization: request.headers[.authorization],
                installationId: request.parameters.get("installationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("api", "oauth", "authorize", "human") { request -> Response in
            routeResponse(services.emailAccounts.oauth.issueHumanAuthorization(
                session: services.emailAccounts.oauthSession(authorization: request.headers[.authorization]),
                body: request.body.string ?? ""
            ))
        }
        app.post("api", "oauth", "installation-token") { request -> Response in
            routeResponse(services.emailAccounts.oauth.mintInstallationToken(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        app.post("api", "oauth", "token") { request -> Response in
            routeResponse(services.emailAccounts.oauth.exchangeToken(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "",
                issuer: OAuthDiscovery.issuerOrigin(services.emailAccounts.serverURL) ?? ""
            ))
        }
        app.get("api", "oauth", "userinfo") { request -> Response in
            routeResponse(services.emailAccounts.oauth.userinfo(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL
            ))
        }
        app.get("api", "oauth", "agents") { request -> Response in
            routeResponse(services.emailAccounts.oauth.agentDirectory(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL
            ))
        }
        app.get("api", "oauth", "serverinfo") { request -> Response in
            routeResponse(services.emailAccounts.oauth.serverinfo(
                authorization: request.headers[.authorization],
                baseURL: services.emailAccounts.serverURL
            ))
        }
        app.post("api", "oauth", "installations", "lookup") { request -> Response in
            routeResponse(services.emailAccounts.oauth.installationLookup(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        app.post("api", "oauth", "requests", "agent") { request -> Response in
            routeResponse(services.emailAccounts.oauth.requestAgentAccess(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        app.post("api", "oauth", "agent-events") { request -> Response in
            routeResponse(services.emailAccounts.oauth.postAgentEvent(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        app.get("api", "oauth", "clients", "lookup") { request -> Response in
            routeResponse(services.emailAccounts.oauth.clientLookup(
                session: services.emailAccounts.oauthSession(authorization: request.headers[.authorization]),
                clientId: desktopQuery(request.url.query, "client_id") ?? desktopQuery(request.url.query, "clientId") ?? "",
                serverId: desktopQuery(request.url.query, "server_id") ?? desktopQuery(request.url.query, "serverId") ?? "",
                scope: desktopQuery(request.url.query, "scope") ?? ""
            ))
        }
        app.get(".well-known", "openid-configuration") { _ -> Response in
            routeResponse(OAuthDiscovery.openIDConfiguration(serverURL: services.emailAccounts.serverURL))
        }
        app.get("api", "oauth", "jwks") { _ -> Response in
            routeResponse(services.emailAccounts.oauth.jwks())
        }
        app.get("api", "oauth", "authorize") { request -> Response in
            routeResponse(services.emailAccounts.oauth.browserAuthorize(
                query: request.url.query ?? "",
                appURL: services.emailAccounts.appURL
            ))
        }
        app.get("api", "oauth", ".well-known", "openid-configuration") { _ -> Response in
            routeResponse(OAuthDiscovery.openIDConfiguration(serverURL: services.emailAccounts.serverURL))
        }
        app.get("oidc", ":server", ".well-known", "openid-configuration") { request -> Response in
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
        app.get("oidc", ":server", "api", "oauth", ".well-known", "openid-configuration") { request -> Response in
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
        app.get("oidc", ":server", "api", "oauth", "agents") { request -> Response in
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
        app.get("oidc", ":server", "api", "oauth", "jwks") { request -> Response in
            switch resolveOIDCScope(request.parameters.get("server") ?? "", oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved:
                return routeResponse(services.emailAccounts.oauth.jwks())
            }
        }
        app.get("oidc", ":server", "api", "oauth", "userinfo") { request -> Response in
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
        app.get("oidc", ":server", "api", "oauth", "serverinfo") { request -> Response in
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
        app.get("oidc", ":server", "api", "oauth", "authorize") { request -> Response in
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
        app.post("oidc", ":server", "api", "oauth", "token") { request -> Response in
            let segment = request.parameters.get("server") ?? ""
            switch resolveOIDCScope(segment, oauth: services.emailAccounts.oauth) {
            case .failure(let response):
                return response
            case .resolved(let scope):
                let origin = OAuthDiscovery.issuerOrigin(services.emailAccounts.serverURL) ?? ""
                return routeResponse(services.emailAccounts.oauth.exchangeToken(
                    authorization: request.headers[.authorization],
                    body: request.body.string ?? "",
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

private func desktopQuery(_ query: String?, _ name: String) -> String? {
    guard let query, !query.isEmpty else { return nil }
    for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.first == name else { continue }
        let raw = parts.count > 1 ? parts[1] : ""
        return raw.removingPercentEncoding ?? raw
    }
    return nil
}
