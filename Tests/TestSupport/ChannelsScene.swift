import Foundation
@testable import RaftHTTP

/// One complete owner graph for the focused Channels HTTP boundary.
public struct ChannelsScene: Sendable {
    public let services: ServiceContainer
    public let auth: AuthFixture
    public let channels: ChannelsFixture

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
        self.channels = ChannelsFixture(oauth: oauth, messages: messages)
    }
}

/// Specific setup operations; the services retain these same two owners.
public struct ChannelsFixture: Sendable {
    private let oauth: OAuthLedger
    private let messages: MessagesAndThreadsStore

    init(oauth: OAuthLedger, messages: MessagesAndThreadsStore) {
        self.oauth = oauth
        self.messages = messages
    }

    public func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        oauth.addOwnedServer(id: id, slug: slug, name: name, ownerId: ownerId)
    }

    public func setMemberRole(serverId: String, userId: String, role: String) {
        oauth.addMember(serverId: serverId, userId: userId, role: role)
    }

    public func appendParentMessage(channelId: String, senderId: String, content: String) -> String {
        let id = UUID().uuidString.lowercased()
        messages.appendMessage(
            StoredHumanMessage(id: id, channelId: channelId, senderId: senderId, content: content, randomId: nil),
            ledger: MessageLedgerPort(oauth: oauth)
        )
        return id
    }
}
