import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The agent delivery service owns a few published bodies whose key order is
/// not alphabetical. `JSONEncoder` cannot guarantee that order on Linux, so the
/// DTOs carry the exact legacy bytes; these tests lock them, plus the store
/// critical sections the routes now depend on.

private struct DeliveryFixture {
    let directory: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let machineKey: String
    let channelId: String

    init() {
        let directory = EmailLoginDirectory()
        serverId = "33333333-3333-4333-8333-333333990001"
        ownerId = "11111111-1111-4111-8111-111111990001"
        directory.oauth.addOwnedServer(
            id: serverId,
            slug: "agent-send-bytes",
            name: "Agent Send Bytes",
            ownerId: ownerId
        )
        agentId = directory.oauth.createAgent(serverId: serverId, name: "BytesBot")
        let machineId = directory.registerMachine(serverId: serverId, userId: ownerId, name: "bytes-machine")
        machineKey = directory.machineAPIKey(machineId: machineId) ?? ""
        directory.assignAgentMachineForTesting(agentId: agentId, machineId: machineId)
        channelId = directory.oauth.createChannel(
            serverId: serverId,
            name: "general",
            creatorUserId: ownerId
        )
        directory.addPostableChannel(
            serverId: serverId,
            channelId: channelId,
            memberId: ownerId,
            name: "general"
        )
        directory.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        self.directory = directory
    }

    func service(
        commitSend: @escaping @Sendable (StoredHumanMessage, [String], String, String) throws -> AgentSendAppendOutcome = { _, _, _, _ in .committed(seq: 7) },
        makeMessageId: @escaping @Sendable () -> String = { "fixed-message-id" }
    ) -> AgentSendDeliveryService {
        AgentSendDeliveryService(
            machines: directory.machinesAndComputersStore,
            channels: directory.serversAndChannelsStore,
            messages: directory.messagesAndThreadsStore,
            agents: directory.agentsRuntimeStore,
            threadFollows: directory.threadFollowStore,
            managedMCP: directory.managedMCPAndCardsStore,
            oauth: directory.oauth,
            prepare: directory.actionCardPrepare,
            assistantOwner: { _, _ in nil },
            searchVisible: { _, _, _ in true },
            commitSend: commitSend,
            integrationServices: { _ in [] },
            now: { Date(timeIntervalSince1970: 1_789_000_000) },
            makeMessageId: makeMessageId
        )
    }
}

@Test func agentSendPublishesTheLegacyKeyOrderByteForByte() throws {
    let fixture = DeliveryFixture()
    let service = fixture.service()
    let reply = try service.agentSend(
        authorization: "Bearer \(fixture.machineKey)",
        agentId: fixture.agentId,
        body: AgentSendRequest(target: "#general", content: "hello")
    )
    #expect(
        reply.jsonBody.render()
            == #"{"ok":true,"state":"sent","messageId":"fixed-message-id","messageSeq":7}"#
    )
}

@Test func agentSendRefusalsKeepTheLegacyErrorBytes() throws {
    let fixture = DeliveryFixture()
    let service = fixture.service()
    do {
        _ = try service.agentSend(
            authorization: "Bearer \(fixture.machineKey)",
            agentId: fixture.agentId,
            body: AgentSendRequest(target: "dm:@Twin", content: "hello")
        )
        Issue.record("expected an unknown DM peer")
    } catch let error as AgentSendDeliveryError {
        #expect(error.publishedErrorBody.render() == #"{"error":"User or agent not found: @Twin"}"#)
    }

    fixture.directory.serversAndChannelsStore.postableChannels[fixture.channelId]?.archived = true
    do {
        _ = try service.agentSend(
            authorization: "Bearer \(fixture.machineKey)",
            agentId: fixture.agentId,
            body: AgentSendRequest(target: "#general", content: "hello")
        )
        Issue.record("expected channel archived")
    } catch let error as AgentSendDeliveryError {
        #expect(
            error.publishedErrorBody.render()
                == #"{"error":"This channel is archived","code":"channel_archived"}"#
        )
    }
}

@Test func agentThreadListPublishesTheLegacyEntryKeyOrder() throws {
    let fixture = DeliveryFixture()
    let threadId = "44444444-4444-4444-8444-444444990001"
    fixture.directory.addPostableChannel(
        serverId: fixture.serverId,
        channelId: threadId,
        memberId: fixture.ownerId,
        kind: "thread",
        parentChannelId: fixture.channelId,
        parentMessageId: "abcdefgh12345678",
        name: "thread"
    )
    fixture.directory.threadFollowStore.upsert(AgentThreadFollowRecord(
        serverId: fixture.serverId,
        agentId: fixture.agentId,
        threadChannelId: threadId,
        parentMessageId: "abcdefgh12345678",
        followedAt: Date(timeIntervalSince1970: 1_789_000_000),
        reason: "manual",
        doneAt: nil,
        unfollowedAt: nil
    ))
    let key = fixture.directory.mintAgentCredential(
        agentId: fixture.agentId,
        scopes: ["read"],
        name: "threads"
    )
    let service = fixture.service()
    let reply = try service.agentThreadList(authorization: "Bearer \(key)")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let followedAt = formatter.string(from: Date(timeIntervalSince1970: 1_789_000_000))
    let expected = ##"{"threads":[{"target":"#general:abcdefgh","threadChannelId":"\##(threadId)","parentChannelRef":"#general","parentMessageId":"abcdefgh12345678","parentMessageShortId":"abcdefgh","followedAt":"\##(followedAt)","reason":"manual","doneAt":null}]}"##
    #expect(reply.jsonBody.render() == expected)
}

/// The ack's cursor bump is one locked read-modify-write: concurrent acks all
/// read version `N` only until the first winner writes `N + 1`.
@Test func concurrentDeliveryAcksAdvanceTheCursorVersionOnce() async {
    let directory = EmailLoginDirectory()
    let store = directory.messagesAndThreadsStore
    let agentId = "11111111-1111-4111-8111-111111990002"
    let channelId = "22222222-2222-4222-8222-222222990002"
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<50 {
            group.addTask {
                store.advanceAgentReadCursors(
                    agentId: agentId,
                    maxSeqByChannel: [channelId: 5]
                )
            }
        }
    }
    let cursor = store.agentChannelReadCursors["\(channelId)\n\(agentId)"]
    #expect(cursor?.seq == 5)
    #expect(cursor?.version == 1)
}

/// The activity ingest store applies events in order: an invalid status after a
/// valid one answers 400, keeps the earlier status write, and does not commit
/// the dedupe set (the legacy loop assigned it only after the last event).
@Test func activityIngestKeepsEarlierWritesWhenALaterEventIsInvalid() {
    let store = AgentsRuntimeStore()
    let agentId = "11111111-1111-4111-8111-111111990003"
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let events = [
        AgentActivityEvent(fields: [
            "eventId": .string("first"),
            "occurredAt": .string("2026-09-01T00:00:00.000Z"),
            "status": .string("working"),
        ]),
        AgentActivityEvent(fields: [
            "eventId": .string("second"),
            "occurredAt": .string("2026-09-01T00:00:01.000Z"),
            "status": .string("bogus"),
        ]),
    ]
    let outcome = store.applyActivityIngest(agentId: agentId, events: events, now: { now })
    #expect(outcome == .invalidStatus)
    #expect(store.agentActivities[agentId]?.activity == "working")
    #expect(store.agentActivityEventIds[agentId] == nil)
}
