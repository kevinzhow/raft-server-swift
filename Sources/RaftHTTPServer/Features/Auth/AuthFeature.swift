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

    /// Decodes one typed JSON body even when the client omitted a JSON
    /// `Content-Type`. The published handlers accepted a raw JSON body before
    /// the typed migration, so the fallback keeps that behavior without a
    /// second raw parser in the service.
    private func jsonBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
        if let decoded = try? await request.content.decode(type) { return decoded }
        guard let data = try await request.body.collect() else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Decodes one lenient JSON body the way the retired raw parser read it:
    /// as JSON whatever the `Content-Type` claims. A body that does not decode
    /// (empty, not an object) is `nil`; the service publishes the same reply
    /// the old non-object cast did.
    private func rawJSON<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
        if let decoded = try? await request.content.decode(type, using: JSONDecoder()) { return decoded }
        guard let data = try await request.body.collect() else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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
        let authCore = AuthCoreService(directory: services.emailAccounts)
        let identityService = services.emailAccounts.authIdentities

        // `verify-email` and `resend-verification` are literal siblings of the
        // `:provider` auth routes, so they mount from the same `api/auth` group.
        auth.post("verify-email") { request async throws -> Response in
            // An empty or malformed body falls back to a nil token so the
            // missing-token branch still answers the upstream 400.
            let body = (try? await request.content.decode(VerifyEmailRequest.self)) ?? VerifyEmailRequest()
            return try await respond { try services.emailAccounts.authVerification.verifyEmail(token: body.token) }
        }
        auth.post("resend-verification") { request async throws -> Response in
            return try await respond {
                try services.emailAccounts.authVerification.resendVerificationEmail(
                    authorization: request.headers[.authorization]
                )
            }
        }

        auth.get("invite-info") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.inviteInfo(
                    token: desktopQuery(request.url.query, "token")
                )
            }
        }

        mobileAppleNative.post("start") { request async throws -> Response in
            routeResponse(services.emailAccounts.startNativeApple(
                body: try await request.bodyText(),
                authorization: request.headers[.authorization]
            ))
        }
        mobileAppleNative.post("authorize") { request async throws -> Response in
            let reply = await services.emailAccounts.authorizeNativeApple(
                body: try await request.bodyText(),
                authorization: request.headers[.authorization]
            )
            return routeResponse(reply)
        }
        mobileOAuth.post("start") { request async throws -> Response in
            return routeResponse(services.emailAccounts.startMobileOAuth(body: try await request.bodyText()))
        }
        mobileProvider.post("link", "start") { request async throws -> Response in
            return routeResponse(services.emailAccounts.startMobileOAuthLink(
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText(),
                authorization: request.headers[.authorization]
            ))
        }
        mobileProvider.post("link", "complete") { request async throws -> Response in
            return routeResponse(services.emailAccounts.completeMobileOAuthLink(
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText(),
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
        provider.post("link", "start") { request async throws -> Response in
            routeResponse(services.emailAccounts.startWebOAuthLink(
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText(),
                authorization: request.headers[.authorization]
            ))
        }
        provider.post("callback") { request async throws -> Response in
            routeResponse(services.emailAccounts.webOAuthCallback(
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText(),
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
        mobileOAuth.post("complete") { request async throws -> Response in
            return routeResponse(services.emailAccounts.completeMobileOAuth(body: try await request.bodyText()))
        }
        provider.post("complete") { request async throws -> Response in
            return routeResponse(services.emailAccounts.completeSocial(
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText(),
                userAgent: request.headers[.userAgent],
                acceptLanguage: request.headers[.acceptLanguage],
                authorization: request.headers[.authorization]
            ))
        }
        device.post("authorize") { request async throws -> Response in
            // The typed body covers the published shape; every other body keeps
            // the directory's raw parser and its `client_name_invalid` reply.
            if let body = try? await request.content.decode(DeviceAuthorizeRequestDTO.self) {
                return routeResponse(authCore.authorizeDevice(body))
            }
            return routeResponse(services.emailAccounts.authorizeDevice(body: try await request.bodyText()))
        }
        device.post("approve") { request async throws -> Response in
            if let body = try? await request.content.decode(DeviceApproveRequestDTO.self) {
                return routeResponse(authCore.approveDevice(body, authorization: request.headers[.authorization]))
            }
            return routeResponse(services.emailAccounts.approveDevice(
                body: try await request.bodyText(),
                authorization: request.headers[.authorization]
            ))
        }
        device.post("token") { request async throws -> Response in
            if let body = try? await request.content.decode(DeviceTokenPollRequestDTO.self) {
                return routeResponse(authCore.pollDeviceToken(body))
            }
            return routeResponse(services.emailAccounts.pollDeviceToken(body: try await request.bodyText()))
        }
        auth.post("staging-self-account", "retire") { request async throws -> Response in
            return routeResponse(services.emailAccounts.retireStagingSelfAccount(
                body: try await request.bodyText(),
                authorization: request.headers[.authorization]
            ))
        }
        auth.post("register") { request async throws -> Response in
            return routeResponse(services.emailAccounts.register(
                body: try await request.bodyText(),
                userAgent: request.headers[.userAgent],
                acceptLanguage: request.headers[.acceptLanguage]
            ))
        }
        auth.post("refresh") { request async throws -> Response in
            let attempt = request.headers[HTTPField.Name("X-Slock-Auth-Refresh-Attempt-Id")!]
            let installation = request.headers[HTTPField.Name("X-Slock-Auth-Installation-Id")!]
            // A body without a usable `refreshToken` falls through to the raw
            // parser so the published "Refresh token is required" reply stands.
            if let body = try? await request.content.decode(RefreshRequestDTO.self) {
                return routeResponse(authCore.refresh(
                    body,
                    attemptHeader: attempt,
                    installationHeader: installation
                ))
            }
            return routeResponse(services.emailAccounts.refresh(
                body: try await request.bodyText(),
                attemptHeader: attempt,
                installationHeader: installation
            ))
        }
        auth.post("logout") { request async throws -> Response in
            if let body = try? await request.content.decode(LogoutRequestDTO.self) {
                return routeResponse(authCore.logout(body))
            }
            return routeResponse(services.emailAccounts.logout(body: try await request.bodyText()))
        }
        identities.get { request async throws -> Response in
            try await respond { try identityService.identities(authorization: request.headers[.authorization]) }
        }
        identities.delete(":provider") { request async throws -> Response in
            try await respond {
                try identityService.unlink(
                    authorization: request.headers[.authorization],
                    provider: request.parameters.get("provider") ?? ""
                )
            }
        }
        auth.post("reset-password") { request async throws -> Response in
            // The typed body covers the published shape; a body sent without a
            // JSON Content-Type goes through the same byte decode so the
            // published validation replies do not depend on the header.
            let body = (try await jsonBody(ResetPasswordRequest.self, request)) ?? ResetPasswordRequest()
            return try await respond { try services.emailAccounts.authProfile.resetPassword(body) }
        }
        auth.post("pending-link", "cancel") { request async throws -> Response in
            // An empty or malformed body still answers 204, so cancel stays
            // idempotent for every client shape.
            let body = (try? await request.content.decode(CancelPendingLinkRequest.self))
                ?? CancelPendingLinkRequest()
            return try await respond { services.emailAccounts.authProfile.cancelPendingLink(body) }
        }
        auth.post("login") { request async throws -> Response in
            // The lenient decoder keeps every wrong-typed field so the service
            // can publish the upstream `issues` list; a non-object body is nil.
            let body = try await rawJSON(LoginRequest.self, request)
            return try await respond { try identityService.login(body) }
        }
        appLogin.post("start") { request async throws -> Response in
            let body = (try await rawJSON(AppLoginStartRequest.self, request)) ?? AppLoginStartRequest()
            return try await respond(status: 201) { try identityService.appLoginStart(body) }
        }
        appLoginRequest.get { request async throws -> Response in
            try await respond {
                try identityService.appLoginDescribe(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? ""
                )
            }
        }
        appLoginRequest.post("approve") { request async throws -> Response in
            try await respond {
                try identityService.appLoginApprove(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? ""
                )
            }
        }
        appLoginRequest.post("deny") { request async throws -> Response in
            try await respond {
                try identityService.appLoginDeny(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? ""
                )
            }
        }
        appLogin.post("complete") { request async throws -> Response in
            let body = (try await rawJSON(AppLoginCompleteRequest.self, request)) ?? AppLoginCompleteRequest()
            return try await respond { try identityService.appLoginComplete(body) }
        }
        auth.get("providers") { request in
            routeResponse(services.emailAccounts.authProviders(platform: desktopQuery(request.url.query, "platform")))
        }
        me.get { request async throws -> Response in
            try await respond { try identityService.me(authorization: request.headers[.authorization]) }
        }
        me.on(.post, "avatar", maxBodySize: "6mb") { request async throws -> Response in
            let data = try await request.body.collect() ?? Data()
            return try await respond {
                try identityService.uploadAvatar(
                    authorization: request.headers[.authorization],
                    contentType: request.headers[.contentType],
                    body: data
                )
            }
        }
        me.post("complete-profile") { request async throws -> Response in
            let body = try await rawJSON(LenientJSONObjectRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPLifecycle.completeProfile(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        me.post("timezone-observation") { request async throws -> Response in
            let body = (try await jsonBody(TimezoneObservationRequest.self, request))
                ?? TimezoneObservationRequest()
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try services.emailAccounts.authProfile.observeTimezone(
                    authorization: request.headers[.authorization],
                    body
                )
            }
        }
        me.patch { request async throws -> Response in
            // A body that is not a JSON object is nil; the service answers the
            // published 400 after the session check, as before.
            let body = try await rawJSON(UpdateProfileRequest.self, request)
            return try await respond {
                try identityService.updateProfile(authorization: request.headers[.authorization], body)
            }
        }
        auth.post("accept-invite") { request async throws -> Response in
            // The typed body keeps the raw parser's tolerance for a missing
            // Content-Type; the public server directory reads the same buffered
            // bytes first and a 404 still falls through to this handler.
            let body = (try await jsonBody(JoinLinkAcceptRequest.self, request))
                ?? JoinLinkAcceptRequest()
            if let directory = services.publicServerDirectory {
                let reply = directory.acceptInvite(
                    authorization: request.headers[.authorization],
                    body: try await request.bodyText()
                )
                if reply.status != 404 {
                    return routeResponse(reply)
                }
            }
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.acceptInvite(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
    }
}
