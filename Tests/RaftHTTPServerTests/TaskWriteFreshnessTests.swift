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
