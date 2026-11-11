import Foundation
import RaftRealtime
@testable import RaftHTTP
@testable import TestSupport

struct PublisherBindingTask: Sendable {
    let id: String
    let messageId: String
    let title: String
    let number: Int
}

struct PublisherBindingAuth: RealtimeAuthorizing {
    let auth: AuthCoreService
    let membership: SocketMembershipService

    func userId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        membership.syncMessages(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)?.jsonBody()
    }
}

/// Owners remain local; the test receives service values and actual seeded facts.
struct PublisherBindingFixture: Sendable {
    static let customNow = Date(timeIntervalSince1970: 1_234)
    let userId: String
    let serverId: String
    let services: ServiceContainer
    let timedThreads: ThreadsService
    let timedAssignments: ManagedMCPAssignmentsService
    let channelId: String
    let parentMessageId: String
    let threadId: String
    let taskFacts: [PublisherBindingTask]
    let token: String

    var authorization: String { "Bearer \(token)" }
    var realtimeAuth: PublisherBindingAuth {
        PublisherBindingAuth(auth: services.identity.core, membership: services.messaging.socketMembership)
    }

    init() {
        let userId = "11111111-1111-4111-8111-111111111648"
        let serverId = "33333333-3333-4333-8333-333333333675"
        self.userId = userId
        self.serverId = serverId
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
        self.services = services
        let auth = AuthFixture(profiles: profiles)
        auth.addAccount(id: userId, email: "publisher-bindings@slock.test", password: "password123")
        auth.markEmailVerified(userId: userId)
        token = auth.mintAccessTokenForTesting(userId: userId)
        oauth.addOwnedServer(id: serverId, slug: "publisher-bindings", name: "Publisher Bindings", ownerId: userId)
        let channelId = oauth.createChannel(serverId: serverId, name: "publisher-bindings", creatorUserId: userId)
        self.channelId = channelId
        channels.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId, name: "publisher-bindings")
        let parentMessageId = UUID().uuidString.lowercased()
        self.parentMessageId = parentMessageId
        messages.appendMessage(
            StoredHumanMessage(id: parentMessageId, channelId: channelId, senderId: userId, content: "publisher parent", randomId: nil),
            ledger: MessageLedgerPort(oauth: oauth)
        )
        let threadId = oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parentMessageId)
        self.threadId = threadId
        channels.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: channelId, parentMessageId: parentMessageId, memberId: userId)
        oauth.addChannelHuman(channelId: threadId, userId: userId)
        taskFacts = services.tasks.catalog.addTasks(channelId: channelId, titles: ["silent", "published", "custom"], creatorId: userId).compactMap { id in
            tasks.task(id: id).map { PublisherBindingTask(id: $0.id, messageId: $0.messageId, title: $0.title, number: $0.taskNumber) }
        }
        let probe = ChannelProbeAccessQuery(channels: channels, messages: messages, inboxFacts: inboxFacts, oauth: oauth)
        timedThreads = ThreadsService(
            store: messages,
            dependencies: ThreadsDependencies(
                auth: services.identity.core, channels: channels, profiles: profiles, tasks: tasks, oauth: oauth,
                channelProbeAccess: probe.access, guestCanSeeScope: services.agents.lifecycle.guestCanSeeScope,
                visibility: ManagedMCPChannelVisibility(oauth: oauth, channels: channels), now: { Self.customNow }
            ),
            publishFollowersUpdated: services.channels.messaging.publishThreadFollowers
        )
        timedAssignments = ManagedMCPAssignmentsService(
            channels: channels, messages: messages, tasks: tasks, agents: agents, profiles: profiles,
            oauth: oauth, auth: services.identity.core, ownership: AssistantOwnershipQuery(agents: agents, oauth: oauth),
            probe: probe, notices: SystemNoticeAppender(
                messages: messages, channels: channels, profiles: profiles, oauth: oauth,
                ledger: MessageLedgerPort(oauth: oauth)
            ),
            membership: services.channels.membership, catalog: services.tasks.catalog,
            createThreadFirstReply: { serverId, channelId, userId, content in
                try services.messaging.create.createThreadFirstReply(
                    serverId: serverId, channelId: channelId, userId: userId, content: content
                )
            },
            now: { Self.customNow }, publishTaskUpdated: services.channels.messaging.publishCommittedTaskUpdated
        )
    }
}
