import Foundation
import TestSupport
@testable import RaftHTTP

/// Local test-target subjects over the same owners used by the actual composer.
struct OAuthFlowsUnitFixture: Sendable {
    private let profiles: AuthProfileStore
    private let flags: AgentsRuntimeStore

    let service: OAuthFlowsService
    let store: OAuthFlowsStore

    init() {
        let profiles = AuthProfileStore()
        profiles.state.withLock { $0.configSurface.oauthDeployment.socialAuthStateSecret = AuthJWTFixture.socialSigningSecret }
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
        self.flags = agents
        service = services.identity.oauthFlows
        store = OAuthFlowsStore(profiles: profiles)
    }

    func setAppURL(_ value: String) {
        profiles.state.withLock { $0.configSurface.oauthDeployment.appURL = value }
    }

    func setServerURL(_ value: String) {
        profiles.state.withLock { $0.configSurface.oauthDeployment.serverURL = value }
    }

    func setConfiguredProviders(_ providers: Set<String>) {
        profiles.state.withLock { $0.configSurface.oauthDeployment.configuredSocialAuthProviders = providers }
    }

    func allowAppleLogin(on platforms: [String]) {
        profiles.state.withLock { $0.accountSurface.appleLoginPlatforms.formUnion(platforms) }
    }

    func setMobileProviderProfile(_ profile: MobileProviderProfile?) {
        profiles.state.withLock { $0.configSurface.mobileProviderProfile = profile }
    }

    func addAccount(id: String, email: String, password: String) {
        let normalized = AccountNaming.normalize(email)
        let passwordHash = AuthFixturePassword.encoded(password)
        profiles.state.withLock { owned in
            owned.accountSurface.accounts[normalized] = Account(
                id: id,
                email: normalized,
                passwordHash: passwordHash,
                passwordCredentialEstablishedAt: Date(),
                displayLanguage: nil,
                name: String(normalized.split(separator: "@").first ?? "user"),
                profileSetupSuggestedHandle: nil,
                profileSetupProvider: nil,
                profileSetupCompletedAt: Date(),
                avatarUrl: nil
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

    func createFeatureFlagForTesting(key: String, defaultEnabled: Bool = false, killSwitch: Bool = false) {
        flags.withState { owned in
            owned.featureFlagRecords[key] = FeatureFlagRecord(
                key: key, enabled: true, killSwitch: killSwitch, defaultEnabled: defaultEnabled
            )
        }
    }

    func addFeatureFlagRuleForTesting(key: String, stage: String, decision: String, values: [String]) {
        flags.withState { owned in
            owned.featureFlagRuleRecords.append(FeatureFlagRuleRecord(
                key: key, stage: stage, decision: decision, values: values,
                clientOs: nil, minClientBuild: nil, clientBuildTypes: nil, priority: 0
            ))
        }
    }

    var sessionCount: Int { profiles.state.withLock { $0.accountSurface.sessions.count } }
    var accountCount: Int { profiles.state.withLock { $0.accountSurface.accounts.count } }
    var socialCompletionCount: Int { profiles.state.withLock { $0.accountSurface.socialCompletions.count } }

    func linkedIdentityCount(userId: String) -> Int {
        profiles.state.withLock { $0.accountSurface.linkedIdentities.filter { $0.userId == userId }.count }
    }

    func linkedProviderUserIds(userId: String, provider: String) -> [String] {
        profiles.state.withLock {
            $0.accountSurface.linkedIdentities
                .filter { $0.userId == userId && $0.provider == provider }.compactMap(\.providerUserId)
        }
    }

    func mobileHandoffFacts(id: String) -> (codeHash: String?, handoffCode: String?)? {
        profiles.state.withLock { owned in
            guard let request = owned.accountSurface.mobileRequests[id] else { return nil }
            return (codeHash: request.codeHash, handoffCode: request.handoffCode)
        }
    }
}
