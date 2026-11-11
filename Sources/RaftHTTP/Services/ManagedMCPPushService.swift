import Foundation

/// Push registration: device registration, the browser subscription, delivery
/// status, installation unbind and the family-revoke capability.
///
/// The service returns published `JSONBodyConvertible`/`Codable` bodies and
/// throws `ManagedMCPLifecycleError`. The session family and its revoke nonce
/// live in `AuthProfileStore`, the registration rows in `NotificationsStore`;
/// each store change is one critical section there (the mint-or-reuse of the
/// nonce, the registration upsert, the family revocation). A registration is
/// two sections, because it spans both stores.
public struct ManagedMCPPushService: Sendable {
    private let oauth: OAuthLedger
    private let profiles: AuthProfileStore
    private let notifications: NotificationsStore
    private let now: @Sendable () -> Date

    init(
        oauth: OAuthLedger,
        profiles: AuthProfileStore,
        notifications: NotificationsStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.oauth = oauth
        self.profiles = profiles
        self.notifications = notifications
        self.now = now
    }

    private func principal(_ authorization: String?) throws -> (userId: String, familyId: String?) {
        guard let authorization, authorization.hasPrefix("Bearer "),
              let found = profiles.pushPrincipal(accessToken: String(authorization.dropFirst("Bearer ".count)))
        else { throw ManagedMCPLifecycleError.unauthorized }
        return found
    }

    // MARK: - POST /api/push/registrations

    public func registerPushDevice(
        authorization: String?,
        serverId: String,
        body: LenientJSONObjectRequest?
    ) throws -> PushRegistrationResponse {
        let principal = try principal(authorization)
        guard let object = body,
              let installationId = object["installationId"]?.legacyString,
              installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil,
              let provider = object["provider"]?.legacyString, provider == "apns" || provider == "fcm",
              let topic = object["topic"]?.legacyString,
              topic.wholeMatch(of: /^[A-Za-z0-9.-]{1,155}$/) != nil,
              let deviceToken = object["deviceToken"]?.legacyString
        else { throw ManagedMCPLifecycleError.invalidPushRegistration }
        let env = object["env"]?.legacyString ?? ""
        if provider == "apns" {
            guard env == "sandbox" || env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._-]{1,256}$/) != nil
            else { throw ManagedMCPLifecycleError.invalidPushRegistration }
        } else {
            guard env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._:-]{1,4096}$/) != nil
            else { throw ManagedMCPLifecycleError.invalidPushRegistration }
        }
        let family = profiles.ensurePushRevokeCapability(userId: principal.userId, familyId: principal.familyId)
        notifications.upsertPushRegistration(PushRegistration(
            installationId: installationId,
            provider: provider,
            env: env,
            topic: topic,
            deviceToken: deviceToken,
            appVersion: object["appVersion"]?.legacyString,
            userId: principal.userId,
            serverId: serverId,
            sessionFamilyId: family.familyId,
            revokeCapability: family.capability
        ))
        return PushRegistrationResponse(
            revokeCapability: family.capability,
            installationId: installationId,
            provider: provider,
            env: env,
            topic: topic
        )
    }

    // MARK: - POST /api/push/subscribe

    public func recordWebPushSubscription(
        authorization: String?,
        body: WebPushSubscribeRequest?
    ) throws -> OkResponse {
        let principal = try principal(authorization)
        guard let endpoint = body?.endpoint,
              Self.isPublicHTTPSPushEndpoint(endpoint),
              let p256dh = body?.p256dh, !p256dh.isEmpty,
              let auth = body?.auth, !auth.isEmpty
        else { throw ManagedMCPLifecycleError.invalidPushSubscription }
        notifications.recordWebPushSubscription(userId: principal.userId, endpoint: endpoint)
        return OkResponse()
    }

    // MARK: - GET /api/push/vapid-key

    /// The VAPID public key is intentionally unauthenticated; without one the
    /// published 503 makes the Web treat push as unavailable
    /// (`routes/push.ts:77-88`).
    public func vapidKey(configuredKey: String?) throws -> WebPushVapidKeyResponse {
        guard let key = configuredKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ManagedMCPLifecycleError.pushNotConfigured
        }
        return WebPushVapidKeyResponse(publicKey: key)
    }

    // MARK: - POST /api/push/prompt-events

    private static let promptEvents: Set<String> = [
        "web_push_prompt_shown", "web_push_native_result",
        "web_push_subscription_saved", "web_push_subscription_failed",
    ]
    private static let maxEventFieldLength = 128

    /// `routes/push.ts:92-139`: authenticated (not verified), the event must be
    /// in the closed set and the trigger non-empty; the optional `X-Server-Id`
    /// is retained only when the caller is a member.
    public func recordPushPromptEvent(
        authorization: String?,
        headerServerId: String?,
        body: LenientJSONObjectRequest?
    ) throws -> OkResponse {
        let principal = try principal(authorization)
        guard let event = Self.cleanEventField(body?["event"]?.legacyString),
              Self.promptEvents.contains(event),
              let trigger = Self.cleanEventField(body?["trigger"]?.legacyString)
        else { throw ManagedMCPLifecycleError.invalidPushPromptEvent }
        var serverId: String?
        if let headerServerId, !headerServerId.isEmpty,
           oauth.memberRole(serverId: headerServerId, userId: principal.userId) != nil {
            serverId = headerServerId
        }
        notifications.recordPushPromptEvent(PushPromptEvent(
            userId: principal.userId,
            serverId: serverId,
            event: event,
            trigger: trigger,
            result: Self.cleanEventField(body?["result"]?.legacyString),
            permissionBefore: Self.cleanEventField(body?["permissionBefore"]?.legacyString),
            permissionAfter: Self.cleanEventField(body?["permissionAfter"]?.legacyString),
            detail: Self.cleanEventField(body?["detail"]?.legacyString),
            createdAt: now()
        ))
        return OkResponse()
    }

    private static func cleanEventField(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxEventFieldLength))
    }

    // MARK: - DELETE /api/push/subscribe

    /// `routes/push.ts:182-208`: no push-enabled gate; an absent endpoint is
    /// the published 400 and a repeat removal is the same success.
    public func removeWebPushSubscription(
        authorization: String?,
        body: WebPushSubscribeRequest?
    ) throws -> OkResponse {
        let principal = try principal(authorization)
        guard let endpoint = body?.endpoint, !endpoint.isEmpty else {
            throw ManagedMCPLifecycleError.missingPushEndpoint
        }
        notifications.removeWebPushSubscription(userId: principal.userId, endpoint: endpoint)
        return OkResponse()
    }

    // MARK: - POST /api/push/test

    /// `routes/push.ts:349-397`: the disabled contract is the 503; a caller
    /// without a stored subscription is the 409; this port has no web-push
    /// transport, so a stored subscription is the truthful 502.
    public func sendTestPush(authorization: String?, configuredKey: String?) throws -> OkResponse {
        guard let key = configuredKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ManagedMCPLifecycleError.pushNotConfigured
        }
        let principal = try principal(authorization)
        guard notifications.webPushSubscriptionCount(userId: principal.userId) > 0 else {
            throw ManagedMCPLifecycleError.noPushSubscription
        }
        throw ManagedMCPLifecycleError.pushDeliveryFailed
    }

    // MARK: - POST /api/push/family-revoke

    public func revokePushFamily(body: PushFamilyRevokeRequest?) throws -> NoContentResponse {
        guard let capability = body?.capability else {
            throw ManagedMCPLifecycleError.invalidCapability
        }
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0].wholeMatch(of: /^[A-Za-z0-9-]+$/) != nil,
              parts[1].wholeMatch(of: /^[A-Za-z0-9]+$/) != nil
        else { throw ManagedMCPLifecycleError.invalidCapability }
        switch profiles.revokePushFamily(nonce: parts[1], now: now()) {
        case .invalid:
            throw ManagedMCPLifecycleError.capabilityNoLongerValid
        case .alreadyRevoked, .revoked:
            return NoContentResponse()
        }
    }

    /// Resolves the retained nonce's user and family without consuming it.
    public func familyRevokeTarget(capability: String) -> (userId: String, familyId: String)? {
        profiles.familyRevokeTarget(capability: capability)
    }

    // MARK: - GET /api/push/delivery-status

    public func pushDeliveryStatus(
        authorization: String?,
        installationId: String?
    ) throws -> PushDeliveryStatusResponse {
        let principal = try principal(authorization)
        guard let installationId, installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil else {
            throw ManagedMCPLifecycleError.installationIdRequired
        }
        let active = notifications.isFcmActive(installationId: installationId, userId: principal.userId)
        return PushDeliveryStatusResponse(
            serverIds: oauth.serverIdsForMember(userId: principal.userId).sorted(),
            fcmActive: active
        )
    }

    // MARK: - DELETE /api/push/registrations/:installationId

    public func unbindPushInstallation(
        authorization: String?,
        serverId: String,
        installationId: String
    ) throws -> PushUnbindResponse {
        _ = try principal(authorization)
        return PushUnbindResponse(unbound: notifications.unbindPushInstallation(installationId: installationId))
    }

    // MARK: - Subscription endpoint policy

    static func isPublicHTTPSPushEndpoint(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if host.contains(":") { return false }
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            guard let first = UInt8(octets[0]), let second = UInt8(octets[1]) else { return false }
            if first == 10 || first == 127 || first == 0 { return false }
            if first == 172, (16...31).contains(second) { return false }
            if first == 192, second == 168 { return false }
            if first == 169, second == 254 { return false }
            return false
        }
        return true
    }
}
