@testable import RaftHTTP

/// One installation domain graph: the shared production composer and both
/// private domain fixtures receive the same actual profile and OAuth owners.
public struct InstallationScene: Sendable {
    public let services: ServiceContainer
    public let auth: AuthFixture
    public let installations: InstallationFixture

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
        installations = InstallationFixture(oauth: oauth)
    }
}
