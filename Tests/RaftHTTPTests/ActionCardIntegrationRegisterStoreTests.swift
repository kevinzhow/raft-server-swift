import Foundation
@testable import RaftHTTP
import Testing

/// A small lock-guarded counter the concurrency test can share with the
/// non-escaping `createThread` closure the store calls under its own lock.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Idempotency lookup + store

/// The lookup and the write share one store lock, so a replay returns the
/// first reply's status and body and a different payload is the published
/// mismatch.
@Test func agentApiIdempotencyReplaysOnlyTheSameFingerprint() {
    let store = ManagedMCPAndCardsStore()
    let now = Date()

    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        now: now
    ) == .none)

    store.storeAgentApiIdempotency(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        status: 201,
        body: #"{"messageId":"m1"}"#,
        now: now
    )

    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        now: now.addingTimeInterval(60)
    ) == .replay(status: 201, body: #"{"messageId":"m1"}"#))

    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-2",
        now: now.addingTimeInterval(60)
    ) == .mismatch)

    // The same key on another route is a different row.
    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "taskCreate",
        key: "k1",
        fingerprint: "fp-1",
        now: now
    ) == .none)
}

/// The row expires after the shared 24-hour TTL; a later request is a fresh
/// write, not a replay.
@Test func agentApiIdempotencyExpiresAfterTheSharedTTL() {
    let store = ManagedMCPAndCardsStore()
    let now = Date()
    store.storeAgentApiIdempotency(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        status: 201,
        body: "{}",
        now: now
    )
    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        now: now.addingTimeInterval(ManagedMCPAndCardsStore.agentApiIdempotencyTTL - 1)
    ) == .replay(status: 201, body: "{}"))
    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        now: now.addingTimeInterval(ManagedMCPAndCardsStore.agentApiIdempotencyTTL + 1)
    ) == .none)
}

/// Only a success reply is stored, and a second store for the same key
/// replaces the first row.
@Test func agentApiIdempotencyStoreKeepsOnlySuccessfulReplies() {
    let store = ManagedMCPAndCardsStore()
    let now = Date()
    store.storeAgentApiIdempotency(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        status: 400,
        body: "{}",
        now: now
    )
    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        now: now
    ) == .none)

    store.storeAgentApiIdempotency(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-1",
        status: 201,
        body: #"{"messageId":"m1"}"#,
        now: now
    )
    store.storeAgentApiIdempotency(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-2",
        status: 201,
        body: #"{"messageId":"m2"}"#,
        now: now
    )
    #expect(store.agentApiIdempotencyLookup(
        agentId: "agent-a",
        route: "actionPrepare",
        key: "k1",
        fingerprint: "fp-2",
        now: now
    ) == .replay(status: 201, body: #"{"messageId":"m2"}"#))
}

// MARK: - Card execution state

/// The marketplace state transition is one critical section: the first execute
/// writes `executed` and the result; a second execute observes the committed
/// row instead of overwriting it.
@Test func marketplaceCardExecutionCommitsOnce() {
    let store = ManagedMCPAndCardsStore()
    let card = MarketplaceInstallCard(
        messageId: "card-1",
        serverId: "server-1",
        clientRecordId: "client-record-1",
        clientKey: "client-key",
        clientName: "Client",
        clientNameSha256: "sha",
        agentId: "agent-1",
        agentName: "Agent",
        scopes: ["openid"],
        storageChannelId: "channel-1",
        localCarrierChannelId: "channel-1",
        state: "prepared",
        executedByUserId: nil,
        resultJSON: nil
    )
    store.insertMarketplaceInstallCard(card)

    let first = store.markMarketplaceInstallCardExecuted(
        messageId: "card-1",
        userId: "user-1",
        resultJSON: #"{"kind":"first"}"#
    )
    #expect(first?.state == "executed")
    #expect(first?.executedByUserId == "user-1")
    #expect(first?.resultJSON == #"{"kind":"first"}"#)

    let second = store.markMarketplaceInstallCardExecuted(
        messageId: "card-1",
        userId: "user-2",
        resultJSON: #"{"kind":"second"}"#
    )
    #expect(second?.state == "executed")
    #expect(second?.executedByUserId == "user-1")
    #expect(second?.resultJSON == #"{"kind":"first"}"#)
    #expect(store.marketplaceInstallCard(messageId: "card-1")?.executedByUserId == "user-1")
}

/// The registration counterpart behaves the same way.
@Test func integrationRegisterCardExecutionCommitsOnce() {
    let store = ManagedMCPAndCardsStore()
    store.insertIntegrationRegisterCard(IntegrationRegisterCard(
        messageId: "register-1",
        serverId: "server-1",
        agentId: "agent-1",
        agentName: "Agent",
        storageChannelId: "channel-1",
        localCarrierChannelId: "channel-1",
        name: "App",
        clientKey: nil,
        homepageUrl: nil,
        returnUrl: "https://example.test/cb",
        agentManifestUrl: nil,
        setupUrl: nil,
        setupDescription: nil,
        scopes: ["openid"],
        state: "prepared",
        executedByUserId: nil,
        resultJSON: nil
    ))
    _ = store.markIntegrationRegisterCardExecuted(
        messageId: "register-1",
        userId: "user-1",
        resultJSON: "first"
    )
    let second = store.markIntegrationRegisterCardExecuted(
        messageId: "register-1",
        userId: "user-2",
        resultJSON: "second"
    )
    #expect(second?.executedByUserId == "user-1")
    #expect(second?.resultJSON == "first")
}

/// Concurrent executes of one prepared card cannot both write the result: only
/// the first row that observes `prepared` commits.
@Test func concurrentMarketplaceExecutionsCommitExactlyOnce() async {
    let store = ManagedMCPAndCardsStore()
    let card = MarketplaceInstallCard(
        messageId: "card-1",
        serverId: "server-1",
        clientRecordId: "client-record-1",
        clientKey: "client-key",
        clientName: "Client",
        clientNameSha256: "sha",
        agentId: "agent-1",
        agentName: "Agent",
        scopes: [],
        storageChannelId: "channel-1",
        localCarrierChannelId: "channel-1",
        state: "prepared",
        executedByUserId: nil,
        resultJSON: nil
    )
    store.insertMarketplaceInstallCard(card)

    let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for index in 0..<32 {
            group.addTask {
                let updated = store.markMarketplaceInstallCardExecuted(
                    messageId: "card-1",
                    userId: "user-\(index)",
                    resultJSON: #"{"winner":\#(index)}"#
                )
                return updated?.executedByUserId == "user-\(index)"
            }
        }
        var committed = 0
        for await won in group where won { committed += 1 }
        return committed
    }
    #expect(winners == 1)
}

// MARK: - Action-card reply thread

/// The canonical reply thread is found-or-created under one lock, so
/// concurrent executes cannot create two threads for the same card, and a
/// second call reuses the first id.
@Test func actionCardReplyThreadIsCreatedExactlyOnce() async {
    let store = ServersAndChannelsStore()
    store.postableChannels = [
        "storage-1": PostableChannel(
            serverId: "server-1",
            memberIds: ["agent-1", "user-1"],
            kind: "channel",
            name: "storage"
        ),
    ]
    let counter = LockedCounter()

    let ids = await withTaskGroup(of: String?.self, returning: [String].self) { group in
        for _ in 0..<32 {
            group.addTask {
                store.findOrCreateActionCardReplyThread(
                    storageChannelId: "storage-1",
                    messageId: "message-1",
                    requesterAgentId: "agent-1",
                    confirmerUserId: "user-1",
                    fallbackServerId: "server-1",
                    createThread: { parentChannelId, parentMessageId in
                        "thread-\(parentChannelId)-\(parentMessageId)-\(counter.increment())"
                    }
                )
            }
        }
        var values: [String] = []
        for await value in group {
            if let value { values.append(value) }
        }
        return values
    }

    #expect(counter.count == 1)
    #expect(ids.count == 32)
    #expect(Set(ids).count == 1)
    #expect(store.actionCardThreadChannel(
        parentChannelId: "storage-1",
        parentMessageId: "message-1"
    ) == ids.first)
}

/// The second call returns the existing canonical thread without invoking the
/// create closure again.
@Test func actionCardReplyThreadReusesTheCommittedThread() {
    let store = ServersAndChannelsStore()
    store.postableChannels = [
        "storage-1": PostableChannel(
            serverId: "server-1",
            memberIds: ["agent-1", "user-1"],
            kind: "channel",
            name: "storage"
        ),
    ]
    let counter = LockedCounter()
    let create: (String, String) -> String = { parentChannelId, parentMessageId in
        "thread-\(counter.increment())-\(parentChannelId)-\(parentMessageId)"
    }
    let first = store.findOrCreateActionCardReplyThread(
        storageChannelId: "storage-1",
        messageId: "message-1",
        requesterAgentId: "agent-1",
        confirmerUserId: "user-1",
        fallbackServerId: "server-1",
        createThread: create
    )
    let second = store.findOrCreateActionCardReplyThread(
        storageChannelId: "storage-1",
        messageId: "message-1",
        requesterAgentId: "agent-1",
        confirmerUserId: "user-1",
        fallbackServerId: "server-1",
        createThread: create
    )
    #expect(first != nil)
    #expect(first == second)
    #expect(counter.count == 1)
}

// MARK: - Small lookups

/// The duplicate-name check reads the channel rows in one critical section.
@Test func duplicateChannelNameLooksAtLiveChannelAndPrivateRows() {
    let store = ServersAndChannelsStore()
    store.postableChannels = [
        "c1": PostableChannel(serverId: "server-1", memberIds: [], kind: "channel", name: "room"),
        "c2": PostableChannel(
            serverId: "server-1",
            memberIds: [],
            kind: "channel",
            deletedAt: Date(),
            name: "gone"
        ),
        "c3": PostableChannel(serverId: "server-1", memberIds: [], kind: "dm", name: "dm-room"),
    ]

    #expect(store.isDuplicateActionCardChannelName(serverId: "server-1", name: "room"))
    #expect(!store.isDuplicateActionCardChannelName(serverId: "server-1", name: "gone"))
    #expect(!store.isDuplicateActionCardChannelName(serverId: "server-1", name: "dm-room"))
    #expect(!store.isDuplicateActionCardChannelName(serverId: "server-2", name: "room"))
}

/// The account handle lookup keeps the legacy case-sensitive exact match.
@Test func accountExactNameLookupIsCaseSensitive() {
    let store = AuthProfileStore()
    let account = Account(
        id: "user-1",
        email: "user@example.test",
        passwordHash: "hash",
        name: "Alice"
    )
    var state = AuthProfileStore.AccountState()
    state.accounts = ["user@example.test": account]
    store.accountState = state
    #expect(store.firstAccount(exactName: "Alice")?.id == "user-1")
    #expect(store.firstAccount(exactName: "alice") == nil)
}

/// The human-message anchor lookup filters by channel and id prefix.
@Test func humanMessageAnchorLooksUpByChannelAndPrefix() {
    let store = MessagesAndThreadsStore()
    store.humanMessageRows = [
        StoredHumanMessage(
            id: "abcdef12-0000-0000-0000-000000000001",
            channelId: "dm-1",
            senderId: "user-1",
            content: "anchor"
        ),
        StoredHumanMessage(
            id: "abcdef12-0000-0000-0000-000000000002",
            channelId: "dm-2",
            senderId: "user-1",
            content: "other channel"
        ),
    ]
    #expect(store.humanMessageId(channelId: "dm-1", idPrefix: "abcdef12") != nil)
    #expect(store.humanMessageId(channelId: "dm-2", idPrefix: "abcdef12") != nil)
    #expect(store.humanMessageId(channelId: "dm-1", idPrefix: "ffffffff") == nil)
}
