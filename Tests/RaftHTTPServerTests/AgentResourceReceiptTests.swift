import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func agentResourceTaskRequiresReceiptBeforeDone() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111648"
    let serverId = "33333333-3333-4333-8333-333333333688"
    accounts.addAccount(id: ownerId, email: "resource-receipt@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "resource-receipt", name: "Resource Receipt", ownerId: ownerId)
    let channelName = "resource-receipt"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ResourceBot", creatorUserId: ownerId, runtime: "claude")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "channel", name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.setAgentGrantsForTesting(agentId: agentId, scopes: ["task:write"])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["tasks", "send", "read"], name: "resource-receipt")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func post(_ path: String, _ json: [String: Any]) async throws -> (HTTPResponse.Status, [String: Any]) {
                let data = try JSONSerialization.data(withJSONObject: json)
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(data: data)
                }
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let created = try await post("/internal/agent-api/tasks", [
                "channel": "#\(channelName)",
                "tasks": [["title": "Create staging bucket", "creates_resource": true]],
            ])
            #expect(created.0 == .ok)
            let tasks = created.1["tasks"] as? [[String: Any]] ?? []
            #expect(tasks.first?["requiresResourceReceipt"] as? Bool == true)
            let taskNumber = try #require(tasks.first?["taskNumber"] as? Int)
            let messageId = try #require(tasks.first?["messageId"] as? String)

            let claim = try await post("/internal/agent-api/tasks/claim", ["channel": "#\(channelName)", "task_numbers": [taskNumber]])
            #expect(claim.0 == .ok)
            let review = try await post("/internal/agent-api/tasks/update-status", ["channel": "#\(channelName)", "task_number": taskNumber, "status": "in_review"])
            #expect(review.0 == .ok)
            let premature = try await post("/internal/agent-api/tasks/update-status", ["channel": "#\(channelName)", "task_number": taskNumber, "status": "done"])
            #expect(premature.0 == .conflict)
            #expect(premature.1["error"] as? String == "resource receipt required before task can move to done")

            let baseReceipt: [String: Any] = [
                "object": "staging bucket",
                "purpose": "restore acceptance",
                "teardown_owner": "@ResourceBot",
                "security_privacy": "internal; no secrets",
                "expiry": "2099-09-01T00:00:00.000Z",
                "tracking": "task #\(taskNumber)",
            ]
            var invalid = baseReceipt
            invalid["runbook"] = "   "
            let invalidResponse = try await post("/internal/agent-api/tasks/resource-receipt", ["channel": "#\(channelName)", "task_number": taskNumber, "receipt": invalid])
            #expect(invalidResponse.0 == .badRequest)

            var valid = baseReceipt
            valid["runbook"] = "runbooks/staging-bucket.md"
            let receipt = try await post("/internal/agent-api/tasks/resource-receipt", ["channel": "#\(channelName)", "task_number": taskNumber, "receipt": valid])
            #expect(receipt.0 == .ok)
            let followup = try #require(receipt.1["expiryFollowup"] as? [String: Any])
            #expect(followup["ownerAgentId"] as? String == agentId)
            #expect(followup["owner"] as? String == "@ResourceBot")
            #expect(followup["msgId"] as? String == messageId)
            #expect(followup["targetChannelId"] as? String == channelId)

            let done = try await post("/internal/agent-api/tasks/update-status", ["channel": "#\(channelName)", "task_number": taskNumber, "status": "done"])
            #expect(done.0 == .ok)
        }
    }
}

@Test func bulkAssignedTaskCreatePreservesOneInboxFactPerTask() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111649"
    let serverId = "33333333-3333-4333-8333-333333333689"
    accounts.addAccount(id: ownerId, email: "bulk-facts@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "bulk-facts", name: "Bulk Facts", ownerId: ownerId)
    let channelName = "bulk-facts"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "BulkBot", creatorUserId: ownerId, runtime: "claude")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "channel", name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.setAgentGrantsForTesting(agentId: agentId, scopes: ["task:write"])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["tasks", "send", "read"], name: "bulk-facts")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            let payload: [String: Any] = [
                "channel": "#\(channelName)",
                "assignee": "@BulkBot",
                "tasks": [["title": "batch one"], ["title": "batch two"], ["title": "batch three"]],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks") { request in
                request.body = .init(data: data)
            }
            #expect(response.status == .ok)
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let tasks = body["tasks"] as? [[String: Any]] ?? []
            #expect(tasks.count == 3)
            for task in tasks {
                let messageId = try #require(task["messageId"] as? String)
                let facts = accounts.inboxFactsForTesting(messageId: messageId)
                #expect(facts.contains { $0.receiverType == "agent" && $0.receiverId == agentId })
            }
        }
    }
}
