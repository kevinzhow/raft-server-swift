import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
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
    _ = accounts.taskCatalog.addTasks(channelId: channel, titles: ["second task"])

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

/// The claim-before-work prompt claims an actionable top-level DM message by
/// `dm:@peer`, exactly like the pinned server's `resolveChannelByName`. The
/// task channel resolver must accept the DM arm; answering `400 Invalid task
/// claim request` blocks the agent from starting the attached work at all.
@Test func agentApiTaskClaimAndConvertResolveDMChannelReference() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001026002"
    let ownerId = "11111111-1111-4111-8111-000001026002"
    accounts.addAccount(id: ownerId, email: "agent-task-dm-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "dm-owner")
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-task-dm", name: "Agent Task DM", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "DMTaskBot", runtime: "codex")
    let dm = accounts.oauth.createDirectChannel(
        serverId: serverId, firstUserId: ownerId, secondUserId: agent,
        firstKind: .human, secondKind: .agent
    )
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: dm, memberId: member, kind: "dm", name: "dm")
    }
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "tasks")
    let claimMessage = UUID().uuidString.lowercased()
    let convertMessage = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: claimMessage, channelId: dm, senderId: ownerId, content: "claim this DM message")
    accounts.insertHumanMessage(id: convertMessage, channelId: dm, senderId: ownerId, content: "convert this DM message")

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
            let dmRef = "dm:@dm-owner"

            let claim = try await post(
                "/internal/agent-api/tasks/claim",
                "{\"channel\":\"\(dmRef)\",\"message_ids\":[\"\(String(claimMessage.prefix(8)))\"]}"
            )
            #expect(claim.status == .ok, Comment(rawValue: claim.body.string ?? ""))
            let claimResult = (object(claim)["results"] as? [[String: Any]] ?? []).first
            #expect(claimResult?["success"] as? Bool == true)
            #expect(claimResult?["messageId"] as? String == claimMessage)
            #expect(claimResult?["taskNumber"] as? Int == 1)

            let converted = try await post(
                "/internal/agent-api/tasks/convert",
                "{\"channel\":\"\(dmRef)\",\"message_id\":\"\(convertMessage)\"}"
            )
            #expect(converted.status == .ok, Comment(rawValue: converted.body.string ?? ""))
            let task = try #require(object(converted)["task"] as? [String: Any])
            #expect(task["messageId"] as? String == convertMessage)

            // A peer with no DM is the same 400 the old resolver returned for
            // every DM, so the new arm does not turn a miss into an empty success.
            let missing = try await post(
                "/internal/agent-api/tasks/claim",
                "{\"channel\":\"dm:@missing-peer\",\"message_ids\":[\"\(String(claimMessage.prefix(8)))\"]}"
            )
            #expect(missing.status == .badRequest)
        }
    }
}
