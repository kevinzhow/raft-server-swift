@testable import RaftHTTP

/// One owner graph, shared by production service composition and private fixtures.
public struct AuthScene: Sendable {
    public let services: ServiceContainer
    public let auth: AuthFixture
    public let mobile: AuthMobileFixture
    public let invites: AuthInviteFixture

    public init() {
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

        services = composeServices(
            profiles: profiles,
            notifications: notifications,
            productEvents: productEvents,
            inboxFacts: inboxFacts,
            threadFollows: threadFollows,
            messages: messages,
            agents: agents,
            tasks: tasks,
            machines: machines,
            channels: channels,
            cards: cards,
            feedback: feedback,
            oauth: oauth
        )
        auth = AuthFixture(profiles: profiles)
        mobile = AuthMobileFixture(profiles: profiles)
        invites = AuthInviteFixture(channels: channels, oauth: oauth)
    }
}
