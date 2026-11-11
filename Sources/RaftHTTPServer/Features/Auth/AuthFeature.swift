import Foundation
import HTTPTypes
import RaftHTTP
import RaftRealtime
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
    private let core: AuthCoreService
    private let identities: AuthIdentitiesService
    private let oauthFlows: OAuthFlowsService
    private let verification: AuthVerificationService
    private let profile: AuthProfileService
    private let invites: JoinLinksAndInvitesService
    private let managedLifecycle: ManagedMCPLifecycleService
    private let publicServerDirectory: PublicServerDirectory?
    private let realtime: RealtimeHub?
    /// Post-update owner briefing retry for `signupSurveyServerId`; nil in
    /// focused scenes that do not compose the onboarding owner.
    private let onboardingBriefing: OnboardingBriefingService?

    public init(
        core: AuthCoreService,
        identities: AuthIdentitiesService,
        oauthFlows: OAuthFlowsService,
        verification: AuthVerificationService,
        profile: AuthProfileService,
        invites: JoinLinksAndInvitesService,
        managedLifecycle: ManagedMCPLifecycleService,
        publicServerDirectory: PublicServerDirectory? = nil,
        realtime: RealtimeHub? = nil,
        onboardingBriefing: OnboardingBriefingService? = nil
    ) {
        self.core = core
        self.identities = identities
        self.oauthFlows = oauthFlows
        self.verification = verification
        self.profile = profile
        self.invites = invites
        self.managedLifecycle = managedLifecycle
        self.publicServerDirectory = publicServerDirectory
        self.realtime = realtime
        self.onboardingBriefing = onboardingBriefing
    }

    /// Upstream `PATCH /api/auth/me` after the profile write: a nonempty
    /// `signupSurveyServerId` fires the same idempotent trigger when the caller
    /// is that server's primary owner. The field is not persisted and never
    /// changes the response.
    private func triggerSignupSurveyBriefing(_ request: UpdateProfileRequest?, userId: String) async {
        guard case .value(let serverId)? = request?.signupSurveyServerId, !serverId.isEmpty else { return }
        _ = await onboardingBriefing?.trigger(serverId: serverId, requestedByOwnerId: userId)
    }


    private func closePasswordSessions(_ target: PasswordSessionRevocation) {
        realtime?.revokeFamilies(userId: target.userId, familyIds: target.familyIds)
    }

    private func closeSessionAccess(_ target: SessionAccessRevocation) {
        switch target {
        case .user(let userId): realtime?.revokeUserAccess(userId: userId)
        case .family(let userId, let familyId): realtime?.revokeSessionAccess(userId: userId, familyId: familyId)
        }
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

        // `verify-email` and `resend-verification` are literal siblings of the
        // `:provider` auth routes, so they mount from the same `api/auth` group.
        auth.post("verify-email") { request async throws -> Response in
            // An empty or malformed body falls back to a nil token so the
            // missing-token branch still answers the upstream 400.
            let body = (try? await decodeJSONRequestBody(VerifyEmailRequest.self, request, decoding: .contentOnly)) ?? VerifyEmailRequest()
            return try await respond { try self.verification.verifyEmail(token: body.token) }
        }
        auth.post("resend-verification") { request async throws -> Response in
            return try await respond {
                try self.verification.resendVerificationEmail(
                    authorization: request.headers[.authorization]
                )
            }
        }

        auth.get("invite-info") { request async throws -> Response in
            try await respond {
                try self.invites.inviteInfo(
                    token: desktopQuery(request.url.query, "token")
                )
            }
        }

        mobileAppleNative.post("start") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(NativeAppleStartRequest.self, request, decoding: .json)) ?? NativeAppleStartRequest()
            return try await respond(status: 201) {
                try await self.oauthFlows.startNativeApple(body, authorization: request.headers[.authorization])
            }
        }
        mobileAppleNative.post("authorize") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(NativeAppleAuthorizeRequest.self, request, decoding: .json)) ?? NativeAppleAuthorizeRequest()
            return try await respond {
                try await self.oauthFlows.authorizeNativeApple(body, authorization: request.headers[.authorization])
            }
        }
        mobileOAuth.post("start") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(MobileOAuthStartRequest.self, request, decoding: .json)) ?? MobileOAuthStartRequest()
            return try await respond(status: 201) { try await self.oauthFlows.startMobileOAuth(body) }
        }
        mobileProvider.post("link", "start") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(MobileOAuthStartRequest.self, request, decoding: .json)) ?? MobileOAuthStartRequest()
            return try await respond(status: 201) {
                try await self.oauthFlows.startMobileOAuthLink(
                    provider: request.parameters.get("provider") ?? "",
                    body: body,
                    authorization: request.headers[.authorization]
                )
            }
        }
        mobileProvider.post("link", "complete") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(MobileOAuthCompleteRequest.self, request, decoding: .json)) ?? MobileOAuthCompleteRequest()
            return try await respond {
                try self.oauthFlows.completeMobileOAuthLink(
                    provider: request.parameters.get("provider") ?? "",
                    body: body,
                    authorization: request.headers[.authorization]
                )
            }
        }
        provider.get("start") { request async throws -> Response in
            try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await self.oauthFlows.startWebOAuth(
                    provider: request.parameters.get("provider") ?? "",
                    returnTo: desktopQuery(request.url.query, "returnTo"),
                    linkOnConflict: desktopQuery(request.url.query, "linkOnConflict") == "1"
                )
            }
        }
        provider.post("link", "start") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(WebOAuthLinkStartRequest.self, request, decoding: .json)) ?? WebOAuthLinkStartRequest()
            return try await respond(headers: { $0.headers }) {
                try await self.oauthFlows.startWebOAuthLink(
                    provider: request.parameters.get("provider") ?? "",
                    body: body,
                    authorization: request.headers[.authorization]
                )
            }
        }
        provider.post("callback") { request async throws -> Response in
            // A form post (`application/x-www-form-urlencoded`), not JSON: the
            // service parses the raw text with the legacy field parser.
            let body = try await request.bodyText()
            return try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await self.oauthFlows.webOAuthCallback(
                    provider: request.parameters.get("provider") ?? "",
                    body: body,
                    cookie: request.headers[.cookie]
                )
            }
        }
        provider.get("callback") { request async throws -> Response in
            try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await self.oauthFlows.mobileOAuthCallback(
                    provider: request.parameters.get("provider") ?? "",
                    code: desktopQuery(request.url.query, "code"),
                    state: desktopQuery(request.url.query, "state"),
                    providerError: desktopQuery(request.url.query, "error")
                )
            }
        }
        mobileOAuth.post("complete") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(MobileOAuthCompleteRequest.self, request, decoding: .json)) ?? MobileOAuthCompleteRequest()
            return try await respond { try await self.oauthFlows.completeMobileOAuthAsync(body) }
        }
        provider.post("complete") { request async throws -> Response in
            // A body that is not a JSON object reads as an empty request, so the
            // service answers the published "code is required" 400.
            let body = (try await decodeJSONRequestBody(SocialCompleteRequest.self, request, decoding: .json)) ?? SocialCompleteRequest()
            return try await respond {
                try await self.core.completeSocialAsync(
                    provider: request.parameters.get("provider") ?? "",
                    body: body,
                    userAgent: request.headers[.userAgent],
                    acceptLanguage: request.headers[.acceptLanguage],
                    authorization: request.headers[.authorization]
                )
            }
        }
        device.post("authorize") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(DeviceAuthorizeRequest.self, request, decoding: .json)) ?? DeviceAuthorizeRequest()
            return try await respond(status: 201) { try self.core.authorizeDevice(body) }
        }
        device.post("approve") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(DeviceApproveRequest.self, request, decoding: .json)) ?? DeviceApproveRequest()
            return try await respond {
                try self.core.approveDevice(body, authorization: request.headers[.authorization])
            }
        }
        device.post("token") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(DeviceTokenRequest.self, request, decoding: .json)) ?? DeviceTokenRequest()
            return try await respond { try self.core.pollDeviceToken(body) }
        }
        auth.post("staging-self-account", "retire") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(RetireStagingRequest.self, request, decoding: .json)) ?? RetireStagingRequest()
            return try await respond {
                try self.core.retireStagingSelfAccount(body, authorization: request.headers[.authorization],
                    onSessionsRevoked: self.closeSessionAccess)
            }
        }
        auth.post("register") { request async throws -> Response in
            // A body that is not a JSON object stays `nil`: the service answers
            // the published `Expected object` issue list.
            let body = try await decodeJSONRequestBody(RegisterRequest.self, request, decoding: .json)
            return try await respond {
                try await self.core.registerAsync(
                    body,
                    userAgent: request.headers[.userAgent],
                    acceptLanguage: request.headers[.acceptLanguage]
                )
            }
        }
        auth.post("refresh") { request async throws -> Response in
            let attempt = request.headers[HTTPField.Name("X-Slock-Auth-Refresh-Attempt-Id")!]
            let installation = request.headers[HTTPField.Name("X-Slock-Auth-Installation-Id")!]
            let body = (try await decodeJSONRequestBody(RefreshTokenRequest.self, request, decoding: .json)) ?? RefreshTokenRequest()
            return try await respond {
                try self.core.refresh(body, attemptHeader: attempt, installationHeader: installation)
            }
        }
        auth.post("logout") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(RefreshTokenRequest.self, request, decoding: .json)) ?? RefreshTokenRequest()
            return try await respond { self.core.logout(body, onSessionsRevoked: self.closeSessionAccess) }
        }
        identities.get { request async throws -> Response in
            try await respond { try self.identities.identities(authorization: request.headers[.authorization]) }
        }
        identities.delete(":provider") { request async throws -> Response in
            try await respond {
                try self.identities.unlink(
                    authorization: request.headers[.authorization],
                    provider: request.parameters.get("provider") ?? ""
                )
            }
        }
        auth.post("reset-password") { request async throws -> Response in
            // The typed body covers the published shape; a body sent without a
            // JSON Content-Type goes through the same byte decode so the
            // published validation replies do not depend on the header.
            let body = (try await decodeJSONRequestBody(ResetPasswordRequest.self, request)) ?? ResetPasswordRequest()
            return try await respond {
                try await self.profile.resetPasswordAsync(body, onSessionsRevoked: self.closePasswordSessions)
            }
        }
        auth.post("pending-link", "cancel") { request async throws -> Response in
            // An empty or malformed body still answers 204, so cancel stays
            // idempotent for every client shape.
            let body = (try? await decodeJSONRequestBody(CancelPendingLinkRequest.self, request, decoding: .contentOnly))
                ?? CancelPendingLinkRequest()
            return try await respond { self.profile.cancelPendingLink(body) }
        }
        auth.post("login") { request async throws -> Response in
            // The lenient decoder keeps every wrong-typed field so the service
            // can publish the upstream `issues` list; a non-object body is nil.
            let body = try await decodeJSONRequestBody(LoginRequest.self, request, decoding: .json)
            return try await respond { try await self.identities.loginAsync(body) }
        }
        appLogin.post("start") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(AppLoginStartRequest.self, request, decoding: .json)) ?? AppLoginStartRequest()
            return try await respond(status: 201) { try self.identities.appLoginStart(body) }
        }
        appLoginRequest.get { request async throws -> Response in
            try await respond {
                try self.identities.appLoginDescribe(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? ""
                )
            }
        }
        appLoginRequest.post("approve") { request async throws -> Response in
            try await respond {
                try self.identities.appLoginApprove(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? ""
                )
            }
        }
        appLoginRequest.post("deny") { request async throws -> Response in
            try await respond {
                try self.identities.appLoginDeny(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? ""
                )
            }
        }
        appLogin.post("complete") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(AppLoginCompleteRequest.self, request, decoding: .json)) ?? AppLoginCompleteRequest()
            return try await respond { try self.identities.appLoginComplete(body) }
        }
        auth.get("providers") { request async throws -> Response in
            try await respond {
                try self.oauthFlows.authProviders(platform: desktopQuery(request.url.query, "platform"))
            }
        }
        me.get { request async throws -> Response in
            try await respond { try self.identities.me(authorization: request.headers[.authorization]) }
        }
        me.on(.post, "avatar", maxBodySize: "6mb") { request async throws -> Response in
            let data = try await request.body.collect() ?? Data()
            return try await respond {
                try self.identities.uploadAvatar(
                    authorization: request.headers[.authorization],
                    contentType: request.headers[.contentType],
                    body: data
                )
            }
        }
        me.post("complete-profile") { request async throws -> Response in
            // The strict upstream schema reports every issue (wrong member type,
            // empty or too-long displayName, unknown key, non-object root), so
            // the decoder keeps the raw JSON value and the service publishes
            // PROFILE_SETUP_BODY_INVALID with that issue list.
            let body = try await decodeJSONRequestBody(CompleteProfileRequest.self, request, decoding: .json)
            return try await respond {
                try self.managedLifecycle.completeProfile(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        me.post("timezone-observation") { request async throws -> Response in
            let body = (try await decodeJSONRequestBody(TimezoneObservationRequest.self, request))
                ?? TimezoneObservationRequest()
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try self.profile.observeTimezone(
                    authorization: request.headers[.authorization],
                    body
                )
            }
        }
        me.patch { request async throws -> Response in
            // A body that is not a JSON object is nil; the service answers the
            // published 400 after the session check, as before.
            let body = try await decodeJSONRequestBody(UpdateProfileRequest.self, request, decoding: .json)
            return try await respond {
                let response = try await self.identities.updateProfileAsync(
                    authorization: request.headers[.authorization], body,
                    onSessionsRevoked: self.closePasswordSessions
                )
                await self.triggerSignupSurveyBriefing(body, userId: response.user.id)
                return response
            }
        }
        auth.post("accept-invite") { request async throws -> Response in
            // The typed body keeps the raw parser's tolerance for a missing
            // Content-Type; the public server directory reads the same buffered
            // bytes first and a 404 still falls through to this handler.
            let body = (try await decodeJSONRequestBody(JoinLinkAcceptRequest.self, request))
                ?? JoinLinkAcceptRequest()
            if let directory = self.publicServerDirectory {
                do {
                    let accepted = try directory.acceptInvite(
                        authorization: request.headers[.authorization],
                        body: try await request.bodyText()
                    )
                    return try await respond { accepted }
                } catch let error as any DomainError where error.status == 404 {
                    // The public directory does not own this invite; retain the
                    // original fallthrough to the account invite service.
                } catch {
                    return try await respond { () throws -> NoContentResponse in throw error }
                }
            }
            return try await respond {
                try self.invites.acceptInvite(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
    }
}
