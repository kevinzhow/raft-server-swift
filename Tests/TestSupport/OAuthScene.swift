@testable import RaftHTTP

/// The composer and the two private domain fixtures share these actual owners.
public struct OAuthScene: Sendable {
    public let services: ServiceContainer
    public let auth: AuthFixture
    public let oauth: OAuthFixture

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
            profiles: profiles, notifications: notifications, productEvents: productEvents,
            inboxFacts: inboxFacts, threadFollows: threadFollows, messages: messages,
            agents: agents, tasks: tasks, machines: machines, channels: channels,
            cards: cards, feedback: feedback, oauth: oauth
        )
        auth = AuthFixture(profiles: profiles)
        self.oauth = OAuthFixture(oauth: oauth)
    }
}
