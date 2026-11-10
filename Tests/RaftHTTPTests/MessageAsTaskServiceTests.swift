import Foundation
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

/// `asTask` writes two owners — the message row and the canonical task — inside
/// one request transaction. These tests use the production transaction context
/// to prove the pair is accepted and discarded together; they do not claim a
/// PostgreSQL commit.
@Suite(.serialized)
struct MessageAsTaskServiceTests {
    private struct Fixture: Sendable {
        let accounts: EmailLoginDirectory
        let ownerId: String
        let serverId: String
        let channelId: String
        let token: String

        init() {
            let accounts = EmailLoginDirectory()
            let ownerId = "11111111-1111-4111-8111-111111111671"
            let serverId = "33333333-3333-4333-8333-333333333691"
            accounts.addAccount(id: ownerId, email: "as-task-service@message-as-task.test", password: "password123")
            accounts.markEmailVerified(userId: ownerId)
            accounts.oauth.addOwnedServer(id: serverId, slug: "message-as-task-service", name: "Message As Task Service", ownerId: ownerId)
            let channelId = accounts.oauth.createChannel(serverId: serverId, name: "as-task-service", creatorUserId: ownerId)
            accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "as-task-service")
            self.accounts = accounts
            self.ownerId = ownerId
            self.serverId = serverId
            self.channelId = channelId
            self.token = accounts.mintAccessTokenForTesting(userId: ownerId)
        }

        func request(content: String, asTask: Bool, randomId: String? = nil) throws -> HumanMessageCreateRequest {
            var fields: [String: JSONValue] = [
                "channelId": .string(channelId),
                "content": .string(content),
                "asTask": .bool(asTask),
            ]
            if let randomId { fields["randomId"] = .string(randomId) }
            return try JSONDecoder().decode(
                HumanMessageCreateRequest.self,
                from: JSONEncoder().encode(JSONValue.object(fields))
            )
        }
    }

    @Test func asTaskMessageAndTaskRollBackTogether() async throws {
        let f = Fixture()
        let context = TransactionContext()
        try await withTransactionContext(context) {
            defer { context.discard() }
            let response = try f.accounts.humanMessageCreate.createHumanMessage(
                try f.request(content: "atomic asTask", asTask: true),
                authorization: "Bearer \(f.token)", serverId: f.serverId
            )
            let message = try #require(
                try JSONSerialization.jsonObject(with: Data(response.messageJSON.utf8)) as? [String: Any]
            )
            #expect(message["taskStatus"] as? String == "todo")
            #expect(message["taskNumber"] as? Int == 1)
            let messageId = try #require(message["id"] as? String)
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == 1)
            let task = try #require(f.accounts.tasksAndRemindersStore.task(messageId: messageId))
            #expect(task.status == "todo")
            #expect(task.channelId == f.channelId)
            #expect(task.creatorId == f.ownerId)
        }
        // A discarded request transaction leaves neither durable owner changed.
        #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
        #expect(f.accounts.tasksAndRemindersStore.taskRecords.isEmpty)
    }

    @Test func asTaskReplayInsideOneTransactionCreatesOneTask() async throws {
        let f = Fixture()
        let context = TransactionContext()
        try await withTransactionContext(context) {
            defer { context.discard() }
            let first = try f.accounts.humanMessageCreate.createHumanMessage(
                try f.request(content: "replay asTask", asTask: true, randomId: "as-task-replay"),
                authorization: "Bearer \(f.token)", serverId: f.serverId
            )
            let replay = try f.accounts.humanMessageCreate.createHumanMessage(
                try f.request(content: "different retry body", asTask: true, randomId: "as-task-replay"),
                authorization: "Bearer \(f.token)", serverId: f.serverId
            )
            let firstMessage = try #require(
                try JSONSerialization.jsonObject(with: Data(first.messageJSON.utf8)) as? [String: Any]
            )
            let replayMessage = try #require(
                try JSONSerialization.jsonObject(with: Data(replay.messageJSON.utf8)) as? [String: Any]
            )
            #expect(firstMessage["id"] as? String == replayMessage["id"] as? String)
            #expect(replayMessage["content"] as? String == "replay asTask")
            #expect(replayMessage["taskStatus"] as? String == "todo")
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == 1)
            #expect(f.accounts.tasksAndRemindersStore.taskRecords.count == 1)
            #expect(f.accounts.tasksAndRemindersStore.taskRecords.first?.title == "replay asTask")
        }
        #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
        #expect(f.accounts.tasksAndRemindersStore.taskRecords.isEmpty)
    }

    @Test func ordinarySendKeepsTheMessageOwnerAsTheOnlyWrite() async throws {
        let f = Fixture()
        let context = TransactionContext()
        try await withTransactionContext(context) {
            defer { context.discard() }
            let response = try f.accounts.humanMessageCreate.createHumanMessage(
                try f.request(content: "plain body", asTask: false),
                authorization: "Bearer \(f.token)", serverId: f.serverId
            )
            let message = try #require(
                try JSONSerialization.jsonObject(with: Data(response.messageJSON.utf8)) as? [String: Any]
            )
            for key in ["taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId", "taskClaimedAt", "taskCompletedAt"] {
                #expect(message[key] is NSNull)
            }
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == 1)
            #expect(f.accounts.tasksAndRemindersStore.taskRecords.isEmpty)
        }
    }
}
