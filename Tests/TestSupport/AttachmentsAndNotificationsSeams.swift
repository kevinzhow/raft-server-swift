// Test seams for attachments and notifications: kill switch, account/identity pokes,
// the agent attachment presign handler, agent credential/grant revocation, the native
// notification row pokes and the mobile-app lifecycle-mail fixtures.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    /// Operator kill switch for `/internal/agent-api` and `/internal/computer`.
    /// `SLOCK_EXPERIMENTAL_SURFACES_DISABLED=true` disables them; tests may
    /// override without touching the process environment.
    public func setExperimentalSurfacesDisabledForTesting(_ value: Bool?) {
        authProfileStore.state.withLock { owned in
            owned.accountSurface.experimentalSurfacesDisabledOverride = value
        }
    }

    public func setAccountProfileForTesting(id: String, name: String, displayName: String? = nil) {
        authProfileStore.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == id })?.key,
               var account = owned.accountSurface.accounts[key] {
                account.name = name
                account.displayName = displayName ?? name
                owned.accountSurface.accounts[key] = account
            }
        }
    }

    public func socialCompletionUserIdForTesting(provider: String, code: String) -> String?? {
        return authProfileStore.state.withLock { owned in
            guard let completion = owned.accountSurface.socialCompletions.first(where: { $0.provider == provider && $0.code == code }) else {
                return nil
            }
            return .some(completion.userId)
        }
    }

    public func setAgentAttachmentPresignForTesting(_ handler: (@Sendable (String, Int, String, String) throws -> String)?) {
        agentsRuntimeStore.withState { state in
            state.agentAttachmentPresign = handler
        }
    }

    public func addAgentAttachmentForTesting(
        channelId: String,
        id: String,
        uploaderId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        storageKey: String? = nil,
        bytes: Data
    ) {
        precondition(sizeBytes == bytes.count)
        messagesAndThreadsStore.withState { state in
            state.developmentAttachmentBytes[id] = bytes
            state.channelAttachments[id] = ChannelAttachment(
                id: id,
                channelId: channelId,
                uploaderId: uploaderId,
                filename: filename,
                messageId: nil,
                messagePosition: nil,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                storageKey: storageKey
            )
        }
        agentsRuntimeStore.storeAgentAttachmentBytes(id: id, bytes: bytes)
    }

    public func setAgentAudienceStatusForTesting(agentId: String, status: String) {
        managedMCPAndCardsStore.storage.withLock { owned in
            owned.agentAudienceStatusOverrides[agentId] = status
        }
    }

    public func revokeAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        managedMCPAndCardsStore.storage.withLock { owned in
            owned.agentIntegrationGrants["\(agentId)\n\(clientKey)"] = true
        }
    }

    public func restoreAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        managedMCPAndCardsStore.storage.withLock { owned in
            owned.agentIntegrationGrants["\(agentId)\n\(clientKey)"] = false
        }
    }

    public func revokeAgentCredentialForTesting(apiKey: String) {
        agentsRuntimeStore.withState { owned in
            owned.agentCredentials[apiKey]?.revokedAt = Date()
        }
    }
}

/// One stored enrollment grant as the tests inspect it: the hash and the JSON
/// of the row, which must never contain the opaque grant.
public struct NativeEnrollmentGrantRecord: Sendable {
    public var secretHash: String
    public var json: String
}

extension EmailLoginDirectory {
    // MARK: - Native notification rows

    public func nativeEnrollmentGrantRecords() -> [NativeEnrollmentGrantRecord] {
        notificationsStore.native.snapshot().grants.map { grant in
            let json = "{\"id\":\(jsonString(grant.id)),\"secretHash\":\(jsonString(grant.secretHash)),\"publicKey\":\(jsonString(grant.publicKey)),\"nonce\":\(jsonString(grant.nonce))}"
            return NativeEnrollmentGrantRecord(secretHash: grant.secretHash, json: json)
        }
    }

    /// Moves a stored enrollment grant into the past. Exchange must then fail closed.
    public func expireNativeEnrollmentGrant(id: String) {
        notificationsStore.native.setGrantExpiry(id: id, to: Date().addingTimeInterval(-1))
    }

    /// Moves a stored native event into the past. A later stream must fail closed.
    public func expireNativeNotificationEvent(id: String) {
        notificationsStore.native.setEventExpiry(id: id, to: Date().addingTimeInterval(-1))
    }

    public func expireNativeNotificationCredential(id: String) {
        notificationsStore.native.setCredentialExpiry(id: id, to: Date().addingTimeInterval(-1))
    }

    public func nativeNotificationCredentialJSON(id: String) -> String? {
        guard let row = notificationsStore.native.snapshot().credentials.first(where: { $0.id == id }) else { return nil }
        return "{\"id\":\(jsonString(row.id)),\"secretHash\":\(jsonString(row.secretHash)),\"scope\":\(jsonString(row.scope))}"
    }

    public func nativeNotificationDeviceRevokedAt(id: String) -> Date? {
        notificationsStore.native.snapshot().devices.first { $0.id == id }?.revokedAt
    }

    public func nativeNotificationEventCount(eventKey: String) -> Int {
        notificationsStore.native.snapshot().events.filter { $0.eventKey == eventKey }.count
    }

    public func nativeNotificationEventIDs(recipientUserId: String) -> [String] {
        notificationsStore.native.snapshot().events.filter { $0.recipientUserId == recipientUserId }.map(\.eventId)
    }

    /// Marks every session family for this user revoked. A later enrollment exchange must fail closed.
    public func revokeSessionFamilies(userId: String) {
        authProfileStore.state.withLock { owned in
            let now = Date()
            for key in owned.accountSurface.sessionFamilies.keys where owned.accountSurface.sessionFamilies[key]?.userId == userId {
                if owned.accountSurface.sessionFamilies[key]?.revokedAt == nil {
                    owned.accountSurface.sessionFamilies[key]?.revokedAt = now
                }
                owned.accountSurface.revokedFamilies.insert(key)
            }
        }
    }

    // MARK: - Mobile-app lifecycle mail

    /// Signed token for `GET/POST /api/email/mobile-app/unsubscribe`. A missing locale is `en`.
    public func createMobileAppEmailUnsubscribeToken(userId: String, locale: String? = nil) -> String {
        let canonical = MobileAppEmailUnsubscribe.mobileAppUnsubscribeLocale(locale)
        let claims = "{\"v\":1,\"typ\":\"mobile-app-email-unsubscribe\",\"sub\":\(jsonString(userId)),\"locale\":\(jsonString(canonical))}"
        let payload = AuthTokenCodec.base64url(Data(claims.utf8))
        let signature = MobileAppEmailUnsubscribe.mobileAppUnsubscribeSignature(payload: payload, secret: MobileAppEmailUnsubscribe(notifications: nativeNotifications).deploymentConfiguration.secret)
        return "\(payload).\(signature)"
    }

    /// A scheduled mobile-app lifecycle email. Unsubscribe cancels `day1Status` of `scheduled`.
    public func addMobileAppEmailJourney(userId: String, email: String, journeyKey: String, day1Status: String, day1EmailId: String?) {
        authProfileStore.state.withLock { owned in
            owned.profile.storedMobileAppEmailJourneys.append(MobileAppEmailJourney(
                userId: userId,
                email: AccountNaming.normalize(email),
                journeyKey: journeyKey,
                day1Status: day1Status,
                day1EmailId: day1EmailId,
                suppressedReason: nil,
                canceledAt: nil
            ))
        }
    }

    public func mobileAppEmailJourneys() -> [MobileAppEmailJourney] {
        return authProfileStore.state.withLock { owned in
            return owned.profile.storedMobileAppEmailJourneys
        }
    }

    /// Local opt-outs for the mobile-app lifecycle audience. The human page does not write one.
    public func mobileAppEmailContacts() -> [MobileAppEmailContact] {
        return authProfileStore.state.withLock { owned in
            return owned.profile.mobileAppEmailContactsByKey.values.sorted { $0.email < $1.email }
        }
    }

    // MARK: - Accounts

    public func addAccount(id: String, email: String, password: String, avatarUrl: String? = nil, passwordCredentialEstablished: Bool = true) {
        let normalized = AccountNaming.normalize(email)
        let passwordHash = AuthFixturePassword.encoded(password)
        authProfileStore.state.withLock { owned in
            owned.accountSurface.accounts[normalized] = Account(
                id: id,
                email: normalized,
                passwordHash: passwordHash,
                passwordCredentialEstablishedAt: passwordCredentialEstablished ? Date() : nil,
                displayLanguage: nil,
                name: String(normalized.split(separator: "@").first ?? "user"),
                profileSetupSuggestedHandle: nil,
                profileSetupProvider: nil,
                profileSetupCompletedAt: Date(),
                avatarUrl: avatarUrl
            )
            owned.accountSurface.analyticsIds[id] = UUID().uuidString.lowercased()
        }
    }

    /// The product-analytics id for this user. Opting out removes it. Opting back in mints a new one.
    public func analyticsId(userId: String) -> String? {
        return authProfileStore.state.withLock { owned in
            return owned.accountSurface.analyticsIds[userId]
        }
    }
}
