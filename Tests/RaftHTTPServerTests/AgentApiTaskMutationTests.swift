import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentApiTaskClaimStatusDeleteAndConvert() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001026001"
    let ownerId = "11111111-1111-4111-8111-000001026001"
    accounts.addAccount(id: ownerId, email: "agent-task-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-task", name: "Agent Task", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "agent-task-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "agent-task-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "TaskBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "tasks")
    let knownMessage = "11111111-1111-4111-8111-000001026099"
    accounts.addTaskForTesting(channelId: channel, title: "first task", messageId: knownMessage, assigneeType: nil, assigneeId: nil)
    _ = accounts.addTasks(channelId: channel, titles: ["second task"])

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let channelRef = "#agent-task-room"

            let claim = try await post("/internal/agent-api/tasks/claim", "{\"channel\":\"\(channelRef)\",\"task_numbers\":[1]}")
            #expect(claim.status == .ok)
            let claimResults = object(claim)["results"] as? [[String: Any]] ?? []
            #expect(claimResults.first?["success"] as? Bool == true)
            #expect(claimResults.first?["taskNumber"] as? Int == 1)

            let already = try await post("/internal/agent-api/tasks/claim", "{\"channel\":\"\(channelRef)\",\"task_numbers\":[1]}")
            #expect((object(already)["results"] as? [[String: Any]] ?? []).first?["reason"] as? String == "already claimed by you")

            let idless = try await post("/internal/agent-api/tasks/claim", "{\"channel\":\"\(channelRef)\",\"message_ids\":[\"\(String(knownMessage.prefix(8)))\"]}")
            let idlessResult = (object(idless)["results"] as? [[String: Any]] ?? []).first
            #expect(idlessResult?["reason"] as? String == "already claimed by you")
            #expect(idlessResult?["taskNumber"] as? Int == 1)

            let demote = try await post("/internal/agent-api/tasks/update-status", "{\"channel\":\"\(channelRef)\",\"task_number\":1,\"status\":\"todo\"}")
            #expect(demote.status == .ok)
            #expect(object(demote)["status"] as? String == "todo")
            #expect(object(demote)["claimedById"] as? String == agent)
            #expect(object(demote)["claimedAt"] is NSNull)

            let memberDone = try await post("/internal/agent-api/tasks/update-status", "{\"channel\":\"\(channelRef)\",\"task_number\":2,\"status\":\"done\"}")
            #expect(memberDone.status == .conflict)
            #expect(((object(memberDone)["error"] as? String) ?? "").contains("cannot transition from todo to done"))

            accounts.oauth.setAgentRole(serverId: serverId, agentId: agent, role: "admin")
            let adminDone = try await post("/internal/agent-api/tasks/update-status", "{\"channel\":\"\(channelRef)\",\"task_number\":2,\"status\":\"done\"}")
            #expect(adminDone.status == .ok)
            #expect(object(adminDone)["status"] as? String == "done")

            let message = accounts.addChannelMessageForTesting(channelId: channel, content: "convert me", senderId: ownerId)
            let converted = try await post("/internal/agent-api/tasks/convert", "{\"channel\":\"\(channelRef)\",\"message_id\":\"\(message)\"}")
            #expect(converted.status == .ok)
            let task = try #require(object(converted)["task"] as? [String: Any])
            #expect(task["messageId"] as? String == message)
            #expect(task["status"] as? String == "todo")
            #expect(task["claimedById"] is NSNull)
            let taskNumber = try #require(task["taskNumber"] as? Int)

            let again = try await post("/internal/agent-api/tasks/convert", "{\"channel\":\"\(channelRef)\",\"message_id\":\"\(message)\"}")
            #expect(again.status == .conflict)

            let deleted = try await post("/internal/agent-api/tasks/delete", "{\"channel\":\"\(channelRef)\",\"task_number\":\(taskNumber)}")
            #expect(deleted.status == .ok)
            let deletedAgain = try await post("/internal/agent-api/tasks/delete", "{\"channel\":\"\(channelRef)\",\"task_number\":\(taskNumber)}")
            #expect(deletedAgain.status == .notFound)
        }
    }
}
