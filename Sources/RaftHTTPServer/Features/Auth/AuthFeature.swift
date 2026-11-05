import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/api/auth/...` routes extracted from `FallbackApplication.configure`.
///
/// Registering this collection mounts the same paths, methods, headers, and
/// reply handling as the original fallback registrations. `configure` remains
/// the single composition root and mounts this collection with
/// `register(routes:)`; `boot` delegates to that same method for async mounts.
///
/// The prefix is grouped once so every handler reads as the route it serves.
public struct AuthFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    /// Synchronous mount for `configure`, whose call sites are not `async`.
    public func register(routes: any RoutesBuilder) {
        let auth = routes.grouped("api", "auth")
        // `:provider` is a literal sibling of the named auth routes, so it keeps
        // its own group and registration order.
        let provider = auth.grouped(":provider")
        let mobileOAuth = auth.grouped("mobile", "oauth")
        let mobileProvider = mobileOAuth.grouped(":provider")
        let mobileAppleNative = mobileOAuth.grouped("apple", "native")
        let device = auth.grouped("device")
        let identities = auth.grouped("identities")
        let appLogin = auth.grouped("app-login")
        let appLoginRequest = appLogin.grouped("requests", ":requestId")
        let me = auth.grouped("me")
        let profile = AuthProfileService(emailAccounts: services.emailAccounts)

        // `verify-email` and `resend-verification` are literal siblings of the
        // `:provider` auth routes, so they mount from the same `api/auth` group.
        auth.post("verify-email") { request async throws -> Response in
            // An empty or malformed body falls back to a nil token so the
            // missing-token branch still answers the upstream 400.
            let body = (try? await request.content.decode(VerifyEmailRequest.self)) ?? VerifyEmailRequest()
            return try authVerificationResponse(services.emailAccounts.verifyEmail(token: body.token))
        }
        auth.post("resend-verification") { request async throws -> Response in
            return try authVerificationResponse(services.emailAccounts.resendVerificationEmail(
                authorization: request.headers[.authorization]
            ))
        }

        auth.get("invite-info") { request -> Response in
            routeResponse(services.emailAccounts.inviteInfo(token: desktopQuery(request.url.query, "token")))
        }

        mobileAppleNative.post("start") { request -> Response in
            routeResponse(services.emailAccounts.startNativeApple(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        mobileAppleNative.post("authorize") { request async -> Response in
            let reply = await services.emailAccounts.authorizeNativeApple(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            )
            return routeResponse(reply)
        }
        mobileOAuth.post("start") { request -> Response in
            return routeResponse(services.emailAccounts.startMobileOAuth(body: request.body.string ?? ""))
        }
        mobileProvider.post("link", "start") { request -> Response in
            return routeResponse(services.emailAccounts.startMobileOAuthLink(
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        mobileProvider.post("link", "complete") { request -> Response in
            return routeResponse(services.emailAccounts.completeMobileOAuthLink(
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        provider.get("start") { request in
            routeResponse(services.emailAccounts.startWebOAuth(
                provider: request.parameters.get("provider") ?? "",
                returnTo: desktopQuery(request.url.query, "returnTo"),
                linkOnConflict: desktopQuery(request.url.query, "linkOnConflict") == "1"
            ))
        }
        provider.post("link", "start") { request -> Response in
            routeResponse(services.emailAccounts.startWebOAuthLink(
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        provider.post("callback") { request -> Response in
            routeResponse(services.emailAccounts.webOAuthCallback(
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? "",
                cookie: request.headers[.cookie]
            ))
        }
        provider.get("callback") { request -> Response in
            return routeResponse(services.emailAccounts.mobileOAuthCallback(
                provider: request.parameters.get("provider") ?? "",
                code: desktopQuery(request.url.query, "code"),
                state: desktopQuery(request.url.query, "state"),
                providerError: desktopQuery(request.url.query, "error")
            ))
        }
        mobileOAuth.post("complete") { request -> Response in
            return routeResponse(services.emailAccounts.completeMobileOAuth(body: request.body.string ?? ""))
        }
        provider.post("complete") { request -> Response in
            return routeResponse(services.emailAccounts.completeSocial(
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? "",
                userAgent: request.headers[.userAgent],
                acceptLanguage: request.headers[.acceptLanguage],
                authorization: request.headers[.authorization]
            ))
        }
        device.post("authorize") { request -> Response in
            return routeResponse(services.emailAccounts.authorizeDevice(body: request.body.string ?? ""))
        }
        device.post("approve") { request -> Response in
            return routeResponse(services.emailAccounts.approveDevice(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        device.post("token") { request -> Response in
            return routeResponse(services.emailAccounts.pollDeviceToken(body: request.body.string ?? ""))
        }
        auth.post("staging-self-account", "retire") { request -> Response in
            return routeResponse(services.emailAccounts.retireStagingSelfAccount(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization]
            ))
        }
        auth.post("register") { request -> Response in
            return routeResponse(services.emailAccounts.register(
                body: request.body.string ?? "",
                userAgent: request.headers[.userAgent],
                acceptLanguage: request.headers[.acceptLanguage]
            ))
        }
        auth.post("refresh") { request -> Response in
            return routeResponse(services.emailAccounts.refresh(
                body: request.body.string ?? "",
                attemptHeader: request.headers[HTTPField.Name("X-Slock-Auth-Refresh-Attempt-Id")!],
                installationHeader: request.headers[HTTPField.Name("X-Slock-Auth-Installation-Id")!]
            ))
        }
        auth.post("logout") { request -> Response in
            return routeResponse(services.emailAccounts.logout(body: request.body.string ?? ""))
        }
        identities.get { request -> Response in
            routeResponse(services.emailAccounts.authIdentities(
                authorization: request.headers[.authorization]
            ))
        }
        identities.delete(":provider") { request -> Response in
            routeResponse(services.emailAccounts.unlinkAuthIdentity(
                authorization: request.headers[.authorization],
                provider: request.parameters.get("provider") ?? ""
            ))
        }
        auth.post("reset-password") { request async throws -> Response in
            // Typed bodies go through the profile service; anything that does
            // not decode keeps the original raw-body path so an untyped client
            // still gets the upstream validation replies.
            if let body = try? await request.content.decode(ResetPasswordRequest.self) {
                return routeResponse(profile.resetPassword(body))
            }
            return routeResponse(services.emailAccounts.resetPassword(body: request.body.string ?? ""))
        }
        auth.post("pending-link", "cancel") { request async throws -> Response in
            // An empty or malformed body still answers 204, so cancel stays
            // idempotent for every client shape.
            let body = (try? await request.content.decode(CancelPendingLinkRequest.self))
                ?? CancelPendingLinkRequest()
            return routeResponse(profile.cancelPendingLink(body))
        }
        auth.post("login") { request -> Response in
            return routeResponse(services.emailAccounts.login(body: request.body.string ?? ""))
        }
        appLogin.post("start") { request -> Response in
            routeResponse(services.emailAccounts.appLoginStart(body: request.body.string ?? "{}"))
        }
        appLoginRequest.get { request -> Response in
            routeResponse(services.emailAccounts.appLoginDescribe(
                authorization: request.headers[.authorization],
                requestId: request.parameters.get("requestId") ?? ""
            ))
        }
        appLoginRequest.post("approve") { request -> Response in
            routeResponse(services.emailAccounts.appLoginApprove(
                authorization: request.headers[.authorization],
                requestId: request.parameters.get("requestId") ?? ""
            ))
        }
        appLoginRequest.post("deny") { request -> Response in
            routeResponse(services.emailAccounts.appLoginDeny(
                authorization: request.headers[.authorization],
                requestId: request.parameters.get("requestId") ?? ""
            ))
        }
        appLogin.post("complete") { request -> Response in
            routeResponse(services.emailAccounts.appLoginComplete(body: request.body.string ?? "{}"))
        }
        auth.get("providers") { request in
            routeResponse(services.emailAccounts.authProviders(platform: desktopQuery(request.url.query, "platform")))
        }
        me.get { request -> Response in
            return routeResponse(services.emailAccounts.me(authorization: request.headers[.authorization]))
        }
        me.on(.post, "avatar", maxBodySize: "6mb") { request async throws -> Response in
            let data = try await request.body.collect() ?? Data()
            return routeResponse(services.emailAccounts.uploadAvatar(
                authorization: request.headers[.authorization],
                contentType: request.headers[.contentType],
                body: data
            ))
        }
        me.post("complete-profile") { request -> Response in
            routeResponse(services.emailAccounts.completeProfile(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        me.post("timezone-observation") { request -> Response in
            return routeResponse(services.emailAccounts.observeTimezone(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        me.patch { request -> Response in
            return routeResponse(services.emailAccounts.patch(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        auth.post("accept-invite") { request -> Response in
            if let directory = services.publicServerDirectory {
                let reply = directory.acceptInvite(
                    authorization: request.headers[.authorization],
                    body: request.body.string ?? ""
                )
                if reply.status != 404 {
                    return routeResponse(reply)
                }
            }
            return routeResponse(services.emailAccounts.acceptInvite(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
    }
}

/// Query-string lookup for redirect parameters. `FallbackApplication.swift` keeps
/// its own file-private copy for the routes that stay there; this one serves the
/// extracted handlers unchanged.
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

/// Encodes one typed verification result with `JSONEncoder` into the same
/// header/body shape the rest of the auth surface publishes.
private func authVerificationResponse(_ result: AuthVerificationResult) throws -> Response {
    let status: Int
    let payload: Data
    switch result {
    case .verified, .sent:
        status = 200
        payload = try JSONEncoder().encode(OkResponse())
    case .failure(let failure):
        status = Int(failure.status)
        payload = try JSONEncoder().encode(AuthErrorResponse(error: failure.message))
    }
    let reply = HTTPReply(
        status: status,
        headers: [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(payload.count),
        ],
        body: String(decoding: payload, as: UTF8.self)
    )
    return routeResponse(reply)
}
