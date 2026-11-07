import Foundation
@testable import RaftHTTP

/// Auth unit subjects and typed setup over one actual thirteen-owner graph.
struct AuthServicesUnitFixture: Sendable {
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let lifecycle: AgentsLifecycleService

    let core: AuthCoreService
    let identities: AuthIdentitiesService
    let authorization: OAuthAuthorizationService

    init() {
        let profiles = AuthProfileStore()
        let notifications = NotificationsStore()
        let productEvents = ProductEventStore()
        let inboxFacts = InboxFactStore()
        let threadFollows = ThreadFollowStore()
        let messages = MessagesAndThreadsStore()
        let agents = AgentsRuntimeStore()
        let tasks = TasksAndRemindersStore()
        let machines = MachinesAndComputersStore()
        let channels = ServersAndChannelsStore()
        let cards = ManagedMCPAndCardsStore()
        let feedback = FeedbackStore()
        let oauth = OAuthLedger()
        let services = composeServices(
            profiles: profiles, notifications: notifications, productEvents: productEvents,
            inboxFacts: inboxFacts, threadFollows: threadFollows, messages: messages,
            agents: agents, tasks: tasks, machines: machines, channels: channels,
            cards: cards, feedback: feedback, oauth: oauth
        )
        self.profiles = profiles
        self.oauth = oauth
        lifecycle = services.agents.lifecycle
        core = services.identity.core
        identities = services.identity.identities
        authorization = services.identity.authorization
    }

    func setAppURL(_ value: String) {
        profiles.state.withLock { $0.configSurface.oauthDeployment.appURL = value }
    }

    func setDeviceLoginGate(_ value: String) {
        profiles.state.withLock { $0.configSurface.authCoreDeployment.deviceLoginGate = value }
    }

    func setReleaseBranch(_ value: String) {
        profiles.state.withLock { $0.configSurface.authCoreDeployment.releaseBranch = value }
    }

    func addAccount(
        id: String, email: String, password: String, avatarUrl: String? = nil,
        passwordCredentialEstablished: Bool = true
    ) {
        let normalized = AccountNaming.normalize(email)
        profiles.state.withLock { owned in
            owned.accountSurface.accounts[normalized] = Account(
                id: id,
                email: normalized,
                passwordHash: AuthTokenCodec.sha256(password),
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

    func markEmailVerified(userId: String) {
        profiles.markEmailVerified(userId: userId)
    }

    func mintAccessTokenForTesting(userId: String) -> String {
        profiles.openSession(userId: userId).accessToken
    }

    func openSession(userId: String) -> IssuedSessionTokens {
        profiles.openSession(userId: userId)
    }

    func sessionCount(for userId: String) -> Int {
        profiles.accountState.sessions.values.filter { $0.userId == userId }.count
    }

    func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        profiles.legalAcceptance(userId: userId)
    }

    func emailVerificationRecordCount(userId: String) -> Int {
        profiles.state.withLock { $0.emailVerificationTokens[userId]?.count ?? 0 }
    }

    var legalAcceptanceCount: Int { profiles.state.withLock { $0.legalAcceptances.count } }
    var retirementReceiptCount: Int { profiles.state.withLock { $0.accountSurface.retirementReceipts.count } }
    var deviceGrantCount: Int { profiles.accountState.deviceGrants.count }

    func hasAccount(email: String) -> Bool {
        profiles.accountState.accounts[AccountNaming.normalize(email)] != nil
    }

    func addSocialCompletion(provider: String, code: String, email: String, returnTo: String = "/") {
        profiles.state.withLock { owned in
            owned.accountSurface.socialCompletions.append(SocialCompletion(
                provider: provider, code: code, mode: "login", intendedAction: "login",
                email: AccountNaming.normalize(email), returnTo: returnTo,
                userId: nil, providerUserId: nil, linkOnConflict: false
            ))
        }
    }

    func prepareStagingRetirementAccount(currentEmail: String, retirementEmail: String, capability: String) {
        var state = profiles.accountState
        let key = AccountNaming.normalize(currentEmail)
        state.accounts[key]?.emailVerified = true
        state.accounts[key]?.email = retirementEmail
        state.accounts[retirementEmail] = state.accounts.removeValue(forKey: key)
        state.accounts[retirementEmail]?.stagingSelfAccountCapabilityHash = AuthTokenCodec.sha256(capability)
        profiles.accountState = state
    }

    /// The original store transaction is itself the subject of the claim test.
    func retireStagingAccount(
        userId: String, actorUserId: String, capabilityHash: String, now: Date
    ) -> StagingRetirementOutcome {
        profiles.retireStagingAccount(
            userId: userId, actorUserId: actorUserId, capabilityHash: capabilityHash, now: now
        )
    }

    func addAuthIdentityForTesting(userId: String, provider: String, providerEmail: String) {
        profiles.appendIdentity(userId: userId, provider: provider, providerEmail: providerEmail)
    }

    func markPasswordCredentialEstablished(userId: String) {
        profiles.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
                owned.accountSurface.accounts[key]?.passwordCredentialEstablishedAt = Date()
            }
        }
    }

    func sessionUserId(authorization: String?) -> String? {
        lifecycle.sessionUserId(authorization: authorization)
    }

    /// Preserves this payload fixture's Account defaults, including its Date().
    func seedMeAccount(userId: String, email: String, password: String, completedAt: Date) {
        profiles.state.withLock { state in
            state.accountSurface.accounts[email] = Account(
                id: userId,
                email: email,
                passwordHash: AuthTokenCodec.sha256(password),
                displayLanguage: "en",
                name: "identity-03",
                profileSetupSuggestedHandle: "ident",
                profileSetupProvider: "google",
                profileSetupCompletedAt: completedAt,
                avatarUrl: "/api/avatars/users/x.webp",
                shareUsageData: true,
                emailVerified: true
            )
        }
    }

    func userDTO(userId: String) -> AuthUserDTO? {
        profiles.account(userId: userId).map { AuthUserDTO(account: $0) }
    }

    func seedTimezoneObservation(
        userId: String, firstTimezone: String, firstAt: Date, lastTimezone: String, lastAt: Date
    ) {
        profiles.state.withLock { state in
            state.profile.timezoneObservations[userId] = TimezoneObservation(
                firstTimezone: firstTimezone, firstAt: firstAt, lastTimezone: lastTimezone, lastAt: lastAt
            )
        }
    }

    func analyticsId(userId: String) -> String? {
        profiles.state.withLock { $0.accountSurface.analyticsIds[userId] }
    }

    func expireAppLoginRequestForTesting(requestId: String) {
        profiles.state.withLock { owned in
            owned.accountSurface.appLoginRequests[requestId]?.expiresAt = Date().addingTimeInterval(-1)
        }
    }

    func authIdentityCount(userId: String) -> Int {
        profiles.identityCount(userId: userId)
    }

    func seedPendingSocialLink(
        token: String, provider: String, providerUserId: String, email: String
    ) {
        var state = profiles.accountState
        state.pendingSocialLinks[token] = PendingSocialLink(
            token: token, provider: provider, providerUserId: providerUserId, email: email,
            expiresAt: Date().addingTimeInterval(600)
        )
        profiles.accountState = state
    }

    func linkedProviderUserIds(userId: String, provider: String) -> [String] {
        profiles.accountState.linkedIdentities
            .filter { $0.userId == userId && $0.provider == provider }.map(\.providerUserId)
    }

    func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        oauth.addOwnedServer(id: id, slug: slug, name: name, ownerId: ownerId)
    }

    func revokeSessionFamilies(userId: String) {
        profiles.state.withLock { owned in
            let now = Date()
            for key in owned.accountSurface.sessionFamilies.keys where owned.accountSurface.sessionFamilies[key]?.userId == userId {
                if owned.accountSurface.sessionFamilies[key]?.revokedAt == nil {
                    owned.accountSurface.sessionFamilies[key]?.revokedAt = now
                }
                owned.accountSurface.revokedFamilies.insert(key)
            }
        }
    }

    func addPasswordResetTokenForTesting(userId: String, token: String, expiresAt: Date) {
        profiles.setResetToken(hash: AuthTokenCodec.sha256(token), userId: userId, expiresAt: expiresAt)
    }

    func resetToken(hash: String) -> (userId: String, expiresAt: Date)? {
        profiles.resetToken(hash: hash)
    }

    func passwordCredentialFacts(email: String) -> (passwordHash: String, passwordCredentialEstablishedAt: Date?)? {
        profiles.accounts[AccountNaming.normalize(email)].map {
            (passwordHash: $0.passwordHash, passwordCredentialEstablishedAt: $0.passwordCredentialEstablishedAt)
        }
    }

    func issuePendingSocialLinkForTesting(
        provider: String, providerUserId: String, email: String,
        returnTo: String? = nil, returnUri: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(600)
    ) -> String {
        let token = AuthTokenCodec.randomHex(32)
        profiles.state.withLock { owned in
            owned.accountSurface.pendingSocialLinks[token] = PendingSocialLink(
                token: token, provider: provider, providerUserId: providerUserId,
                email: AccountNaming.normalize(email), returnTo: returnTo, returnUri: returnUri,
                expiresAt: expiresAt
            )
        }
        return token
    }

    func pendingSocialLinkCancelled(token: String) -> Bool? {
        profiles.accountState.pendingSocialLinks[token]?.cancelled
    }

    func makeProfileService(
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { AuthTokenCodec.randomHex(32) }
    ) -> AuthProfileService {
        AuthProfileService(store: profiles, now: now, makeToken: makeToken)
    }
}
