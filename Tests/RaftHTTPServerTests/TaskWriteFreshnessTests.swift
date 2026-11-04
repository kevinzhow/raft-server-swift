import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func taskClaimFreshnessHoldAndRerun() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001106001"
    let ownerId = "11111111-1111-4111-8111-000001106001"
    accounts.addAccount(id: ownerId, email: "task-freshness@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-freshness", name: "Task Freshness", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "BoardBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "board", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "board", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read", "tasks"], name: "task-freshness")
    let taskId = accounts.addTaskWithDescriptionForTesting(channelId: channelId, title: "human task", description: "body")
    let seenMessage = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "seen by the agent")
    let unseenMessage = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "posted after the agent read")
    let seenSeq = accounts.messageSeqForTesting(messageId: seenMessage) ?? 0

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func claim(_ seen: Int?) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                var body = "{\"channel\":\"#board\",\"task_numbers\":[1]"
                if let seen { body += ",\"seenUpToSeq\":\(seen)" }
                body += "}"
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/tasks/claim")) { request in
                    request.body = .init(string: body)
                }
                let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response, json)
            }
            // No attestation: applied even with unread messages.
            let withoutAttestation = try await claim(nil)
            #expect(withoutAttestation.0.status == .ok)
            #expect(withoutAttestation.1["state"] as? String != "held")
            #expect(accounts.taskAssigneeForTesting(taskId: taskId) == agentId)

            // Reset the claim so the stale-boundary flow can run.
            accounts.assignTaskForTesting(taskId: taskId, assigneeId: nil)
            let held = try await claim(seenSeq)
            #expect(held.0.status == .ok)
            #expect(held.1["state"] as? String == "held")
            #expect(held.1["decision"] as? String == "syncing_hold")
            #expect(held.1["available_actions"] as? [String] == ["check_messages", "retry_action"])
            #expect(held.1["newMessageCount"] as? Int == 1)
            let heldMessages = held.1["heldMessages"] as? [[String: Any]] ?? []
            #expect(heldMessages.contains { $0["id"] as? String == unseenMessage })
            #expect(accounts.taskAssigneeForTesting(taskId: taskId) == nil)
            let boundary = held.1["seenUpToSeq"] as? Int ?? 0

            let rerun = try await claim(boundary)
            #expect(rerun.0.status == .ok)
            #expect(rerun.1["state"] as? String != "held")
            #expect(accounts.taskAssigneeForTesting(taskId: taskId) == agentId)
        }
    }
}

@Test func taskUpdateAmendAndOneHoldPerCatchUp() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001106002"
    let ownerId = "11111111-1111-4111-8111-000001106002"
    accounts.addAccount(id: ownerId, email: "task-freshness-2@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-freshness-2", name: "Task Freshness 2", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "BoardBot2", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "board2", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "board2", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read", "tasks"], name: "task-freshness-2")
    let taskId = accounts.addTaskWithDescriptionForTesting(channelId: channelId, title: "human task", description: "body")
    accounts.assignTaskForTesting(taskId: taskId, assigneeId: agentId)
    let seen = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "seen")
    let unseen = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "unseen")
    let seenSeq = accounts.messageSeqForTesting(messageId: seen) ?? 0
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func post(_ path: String, _ fields: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let body = try JSONSerialization.data(withJSONObject: fields)
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(data: body)
                }
                let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response, json)
            }
            let heldUpdate = try await post("/internal/agent-api/tasks/update-status", ["channel": "#board2", "task_number": 1, "status": "done", "seenUpToSeq": seenSeq])
            #expect(heldUpdate.1["state"] as? String == "held")
            #expect(accounts.taskStatusForTesting(taskId: taskId) == "todo")
            let boundary = heldUpdate.1["seenUpToSeq"] as? Int ?? 0

            // One hold per catch-up: a newer message after the hold does not hold the rerun again.
            _ = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "newer after hold")
            let rerunUpdate = try await post("/internal/agent-api/tasks/update-status", ["channel": "#board2", "task_number": 1, "status": "done", "seenUpToSeq": boundary])
            #expect(rerunUpdate.1["state"] as? String != "held")

            // A rerun that did not catch up to its last hold is held again.
            _ = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "regap")
            let regap = try await post("/internal/agent-api/tasks/amend", ["channel": "#board2", "task_number": 1, "title": "renamed", "seenUpToSeq": seenSeq])
            #expect(regap.1["state"] as? String == "held")
            let regapBoundary = regap.1["seenUpToSeq"] as? Int ?? 0
            let amended = try await post("/internal/agent-api/tasks/amend", ["channel": "#board2", "task_number": 1, "title": "renamed", "seenUpToSeq": regapBoundary])
            #expect(amended.1["state"] as? String != "held")
            _ = unseen
        }
    }
}
