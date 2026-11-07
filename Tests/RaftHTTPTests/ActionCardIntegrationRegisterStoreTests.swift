import Foundation
@testable import RaftHTTP
import Testing

private func replyThreadFixture() -> (
    store: ServersAndChannelsStore, oauth: OAuthLedger,
    threadChannels: ThreadChannelCommand, storageChannelId: String
) {
    let store = ServersAndChannelsStore()
    let oauth = OAuthLedger()
    oauth.addOwnedServer(id: "server-1", slug: "reply-thread", name: "Reply Thread", ownerId: "user-1")
    let threadChannels = ThreadChannelCommand(oauth: oauth)
    let storageChannelId = oauth.createChannel(serverId: "server-1", name: "storage", creatorUserId: "user-1")
    for memberId in ["agent-1", "user-1"] {
        store.addPostableChannel(serverId: "server-1", channelId: storageChannelId, memberId: memberId, name: "storage")
    }
    return (store, oauth, threadChannels, storageChannelId)
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
@Test func actionCardReplyThreadIsCreatedExactlyOnce() async throws {
    let (store, oauth, threadChannels, storageChannelId) = replyThreadFixture()
    let ids = await withTaskGroup(of: String?.self, returning: [String].self) { group in
        for _ in 0..<32 {
            group.addTask {
                store.findOrCreateActionCardReplyThread(
                    storageChannelId: storageChannelId,
                    messageId: "message-1",
                    requesterAgentId: "agent-1",
                    confirmerUserId: "user-1",
                    fallbackServerId: "server-1",
                    threadChannels: threadChannels
                )
            }
        }
        var values: [String] = []
        for await value in group {
            if let value { values.append(value) }
        }
        return values
    }

    let rows = oauth.state.withLock { state in
        state.channelRecords.filter {
            $0.type == "thread" && $0.parentChannelId == storageChannelId && $0.parentMessageId == "message-1"
        }
    }
    #expect(rows.count == 1)
    #expect(ids.count == 32)
    #expect(Set(ids).count == 1)
    let id = try #require(ids.first)
    #expect(rows.map(\.id) == [id])
    #expect(rows.first?.serverId == "server-1")
    #expect(rows.first?.name == "")
    #expect(store.actionCardThreadChannel(
        parentChannelId: storageChannelId,
        parentMessageId: "message-1"
    ) == id)
    let local = try #require(store.postableChannel(id: id))
    #expect(local.memberIds == ["agent-1", "user-1"])
    #expect(local.serverId == "server-1")
    #expect(local.parentChannelId == storageChannelId)
    #expect(local.parentMessageId == "message-1")
    #expect(local.name == "thread")
    #expect(store.threadOrder.isEmpty)
}

/// A replay returns the committed canonical id without creating another
/// primary record, even when the local row is soft-deleted or on another server.
@Test func actionCardReplyThreadReusesTheCommittedThread() throws {
    let (store, oauth, threadChannels, storageChannelId) = replyThreadFixture()
    let first = store.findOrCreateActionCardReplyThread(
        storageChannelId: storageChannelId,
        messageId: "message-1",
        requesterAgentId: "agent-1",
        confirmerUserId: "user-1",
        fallbackServerId: "server-1",
        threadChannels: threadChannels
    )
    let id = try #require(first)
    let second = store.findOrCreateActionCardReplyThread(
        storageChannelId: storageChannelId,
        messageId: "message-1",
        requesterAgentId: "agent-1",
        confirmerUserId: "user-1",
        fallbackServerId: "server-1",
        threadChannels: threadChannels
    )
    #expect(first != nil)
    #expect(first == second)
    store.mutex.withLock { state in
        state.postableChannels[id]?.serverId = "server-2"
        state.postableChannels[id]?.deletedAt = Date()
        state.postableChannels[id]?.memberIds = ["user-1"]
    }
    let reusedAfterDeletion = store.findOrCreateActionCardReplyThread(
        storageChannelId: storageChannelId, messageId: "message-1",
        requesterAgentId: "agent-1", confirmerUserId: "user-1",
        fallbackServerId: "server-1", threadChannels: threadChannels
    )
    #expect(reusedAfterDeletion == first)
    let rows = oauth.state.withLock { state in
        state.channelRecords.filter {
            $0.type == "thread" && $0.parentChannelId == storageChannelId && $0.parentMessageId == "message-1"
        }
    }
    #expect(rows.map(\.id) == [id])
    #expect(rows.first?.serverId == "server-1")
    let reused = try #require(store.postableChannel(id: id))
    #expect(reused.serverId == "server-2")
    #expect(reused.deletedAt != nil)
    #expect(reused.memberIds == ["user-1"], "the existing canonical branch does not refresh its members")
    #expect(store.threadOrder.isEmpty)
    #expect(store.jointProjections.isEmpty)
}

@Test func actionCardReplyThreadProjectsTheOriginalJointParents() throws {
    let store = ServersAndChannelsStore()
    let oauth = OAuthLedger()
    oauth.addOwnedServer(id: "server-1", slug: "thread-host", name: "Thread Host", ownerId: "user-1")
    oauth.addOwnedServer(id: "server-2", slug: "thread-peer", name: "Thread Peer", ownerId: "user-1")
    let threadChannels = ThreadChannelCommand(oauth: oauth)
    let canonical = oauth.createChannel(serverId: "server-1", name: "storage", creatorUserId: "user-1")
    let host = oauth.createChannel(serverId: "server-1", name: "host", creatorUserId: "user-1", type: "joint")
    let peer = oauth.createChannel(serverId: "server-2", name: "peer", creatorUserId: "user-1", type: "joint")
    for (parent, server, member) in [(canonical, "server-1", "agent-a"), (host, "server-1", "agent-b"), (peer, "server-2", "user-1")] {
        store.addPostableChannel(serverId: server, channelId: parent, memberId: member)
    }
    store.addJointChannelProjection(localChannelId: host, canonicalChannelId: canonical, serverId: "server-1")
    store.addJointChannelProjection(localChannelId: peer, canonicalChannelId: canonical, serverId: "server-2")

    let result = store.findOrCreateActionCardReplyThread(
        storageChannelId: canonical, messageId: "message-1",
        requesterAgentId: "agent-1", confirmerUserId: "user-1",
        fallbackServerId: "server-1", threadChannels: threadChannels
    )
    let canonicalThread = try #require(result)
    let parents: Set<String> = [canonical, host, peer]
    let rows = oauth.state.withLock { state in
        state.channelRecords.filter {
            $0.type == "thread" && parents.contains($0.parentChannelId ?? "") && $0.parentMessageId == "message-1"
        }
    }
    #expect(rows.count == 3)
    #expect(Set(rows.compactMap(\.parentChannelId)) == parents)
    let hostThread = try #require(rows.first { $0.parentChannelId == host })
    let peerThread = try #require(rows.first { $0.parentChannelId == peer })
    #expect(rows.first { $0.id == canonicalThread }?.serverId == "server-1")
    #expect(hostThread.serverId == "server-1")
    #expect(peerThread.serverId == "server-2")
    #expect(rows.allSatisfy { $0.name == "" })
    #expect(store.postableChannel(id: canonicalThread)?.memberIds == ["agent-a", "agent-1", "user-1"])
    #expect(store.postableChannel(id: hostThread.id)?.memberIds == ["agent-b", "agent-1", "user-1"])
    #expect(store.postableChannel(id: peerThread.id)?.memberIds == ["agent-1", "user-1"])
    #expect(store.postableChannel(id: hostThread.id)?.serverId == "server-1")
    #expect(store.postableChannel(id: peerThread.id)?.serverId == "server-2")
    #expect(store.postableChannels.values.filter { $0.kind == "thread" }.count == 3)
    #expect(store.threadOrder.isEmpty)
    let projections = store.jointProjections
    #expect(projections.map(\.localChannelId) == [host, peer, hostThread.id, peerThread.id])
    #expect(projections.map(\.canonicalChannelId) == [canonical, canonical, canonicalThread, canonicalThread])
    #expect(projections.map(\.serverId) == ["server-1", "server-2", "server-1", "server-2"])

    let repeated = store.findOrCreateActionCardReplyThread(
        storageChannelId: canonical, messageId: "message-1",
        requesterAgentId: "agent-1", confirmerUserId: "user-1",
        fallbackServerId: "server-1", threadChannels: threadChannels
    )
    #expect(repeated == canonicalThread)
    let after = oauth.state.withLock { $0.channelRecords.filter { $0.type == "thread" } }
    #expect(Set(after.map(\.id)) == Set(rows.map(\.id)))
    #expect(after.allSatisfy { parents.contains($0.parentChannelId ?? "") }, "new thread projections do not become nested parents")
    #expect(store.jointProjections.map(\.localChannelId) == projections.map(\.localChannelId))
    #expect(store.threadOrder.isEmpty)
}

@Test func actionCardReplyThreadKeepsFallbackForAMissingCarrier() throws {
    for primaryParentExists in [false, true] {
        let store = ServersAndChannelsStore()
        let oauth = OAuthLedger()
        oauth.addOwnedServer(id: "server-2", slug: "fallback-parent", name: "Fallback Parent", ownerId: "user-1")
        let threadChannels = ThreadChannelCommand(oauth: oauth)
        let parent = primaryParentExists
            ? oauth.createChannel(serverId: "server-2", name: "storage", creatorUserId: "user-1")
            : "storage-1"
        let result = store.findOrCreateActionCardReplyThread(
            storageChannelId: parent, messageId: "message-1",
            requesterAgentId: "agent-1", confirmerUserId: "user-1",
            fallbackServerId: "server-1", threadChannels: threadChannels
        )
        let id = try #require(result)
        let rows = oauth.state.withLock { state in
            state.channelRecords.filter {
                $0.type == "thread" && $0.parentChannelId == parent && $0.parentMessageId == "message-1"
            }
        }
        #expect(rows.map(\.id) == [id])
        #expect(rows.first?.serverId == (primaryParentExists ? "server-2" : ""))
        #expect(rows.first?.name == "")
        let local = try #require(store.postableChannel(id: id))
        #expect(local.serverId == "server-1")
        #expect(local.kind == "thread")
        #expect(local.parentChannelId == parent)
        #expect(local.parentMessageId == "message-1")
        #expect(local.memberIds == ["agent-1", "user-1"])
        #expect(local.name == "thread")
        #expect(store.threadOrder.isEmpty)
        #expect(store.jointProjections.isEmpty)
    }
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
