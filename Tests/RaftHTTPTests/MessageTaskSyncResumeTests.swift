import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// `sync:resume` is the socket catch-up outlet of upstream
/// `messageService.syncMessages`, whose explicit SELECT includes the six
/// `messages.task_*` columns. The frame must therefore publish those keys on
/// every row, not only on a task projection.

private struct SyncResumeFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111692"
    let serverId = "33333333-3333-4333-8333-333333333692"
    let channelId: String
    let sentinelId = "aaaaaaaa-2222-4222-8222-222222222692"
    let ordinaryId = "cccccccc-2222-4222-8222-222222222692"

    init() {
        accounts.addAccount(id: ownerId, email: "sync-resume-owner@task-sync.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "task-sync", name: "Task Sync", ownerId: ownerId)
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "sync-room", creatorUserId: ownerId)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "sync-room")
        accounts.insertHumanMessage(id: sentinelId, channelId: channelId, senderId: ownerId, content: "resume sentinel")
    }
}

@Test func socketSyncResumePublishesSixTaskKeysForOrdinaryAndTaskRows() throws {
    let fixture = SyncResumeFixture()
    let taskMessageId = "bbbbbbbb-2222-4222-8222-222222222692"
    fixture.accounts.insertHumanMessage(id: fixture.ordinaryId, channelId: fixture.channelId,
        senderId: fixture.ownerId, content: "ordinary resume row")
    fixture.accounts.insertHumanMessage(id: taskMessageId, channelId: fixture.channelId,
        senderId: fixture.ownerId, content: "resume task row")
    let task = fixture.accounts.tasksAndRemindersStore.ensureMessageTask(
        channelId: fixture.channelId, messageId: taskMessageId, title: "resume task row",
        creatorId: fixture.ownerId, legacyMessageMaxNumber: 0, now: Date())
    guard case .created = task else {
        Issue.record("expected a new canonical task")
        return
    }

    let resume = try #require(fixture.accounts.socketMembership.syncMessages(
        serverId: fixture.serverId, userId: fixture.ownerId, lastSeq: 1, limit: 50))
    let body = try #require(try JSONSerialization.jsonObject(with: Data(resume.jsonBody().utf8)) as? [String: Any])
    let rows = try #require(body["messages"] as? [[String: Any]])
    let ordinary = try #require(rows.first { $0["id"] as? String == fixture.ordinaryId })
    for key in ["taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId", "taskClaimedAt", "taskCompletedAt"] {
        #expect(ordinary[key] is NSNull, "sync:resume ordinary row publishes \(key) as null")
    }
    let taskRow = try #require(rows.first { $0["id"] as? String == taskMessageId })
    #expect(taskRow["taskStatus"] as? String == "todo")
    #expect(taskRow["taskNumber"] as? Int == 1)
    #expect(taskRow["taskAssigneeType"] is NSNull)
    #expect(taskRow["taskAssigneeId"] is NSNull)
    #expect(taskRow["taskClaimedAt"] is NSNull)
    #expect(taskRow["taskCompletedAt"] is NSNull)
}

@Test func forwardDestinationRowsOmitTheSixTaskKeysLikeUpstreamProjection() throws {
    let fixture = SyncResumeFixture()
    let forwardId = "dddddddd-2222-4222-8222-222222222692"
    fixture.accounts.insertHumanMessage(id: forwardId, channelId: fixture.channelId,
        senderId: fixture.ownerId, content: "forwarded bundle")
    let record = StoredForwardRecord(sourceIds: [], items: [], destinationTargetId: fixture.channelId)
    _ = fixture.accounts.messagesAndThreadsStore.commitForward(
        messageId: forwardId, bundle: [], record: record, projections: [],
        destinationChannelId: fixture.channelId)
    let row = try #require(fixture.accounts.messagesAndThreadsStore.humanMessageRow(id: forwardId))
    let facts = fixture.accounts.messageReadProjection.readFacts(
        row, channelId: fixture.channelId, commentsVisible: false,
        serverId: fixture.serverId, userId: fixture.ownerId)
    for key in ["taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId", "taskClaimedAt", "taskCompletedAt"] {
        #expect(facts.fields.contains { $0.key == key } == false, "forward destination read omits \(key)")
    }
    let resume = try #require(fixture.accounts.socketMembership.syncMessages(
        serverId: fixture.serverId, userId: fixture.ownerId, lastSeq: row.seq - 1, limit: 50))
    let body = resume.jsonBody()
    #expect(!body.contains("taskStatus"), "forward destination sync:resume omits the task group")
    #expect(!body.contains("taskNumber"))
}
