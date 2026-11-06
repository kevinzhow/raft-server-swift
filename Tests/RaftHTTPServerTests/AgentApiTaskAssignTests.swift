import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func agentTaskAssignIsOpaqueAndReservesWithoutStarting() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001029001"
    let ownerId = "11111111-1111-4111-8111-000001029001"
    let outsiderId = "11111111-1111-4111-8111-000001029002"
    accounts.addAccount(id: ownerId, email: "assign-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: outsiderId, email: "assign-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "assign", name: "Assign", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "assign-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "assign-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "AssignBot", runtime: "codex")
    let peer = accounts.oauth.createAgent(serverId: serverId, name: "PeerBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: peer)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "assign")

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

            let created = try await post("/internal/agent-api/tasks", "{\"channel\":\"#assign-room\",\"tasks\":[{\"title\":\"assign me\"}]}")
            #expect(created.status == .ok)
            let tasks = try #require(object(created)["tasks"] as? [[String: Any]])
            let task = try #require(tasks.first)
            let taskNumber = try #require(task["taskNumber"] as? Int)
            #expect(task["status"] as? String == "todo")

            let outsider = try await post("/internal/agent-api/tasks/assign", "{\"channel\":\"#assign-room\",\"task_number\":\(taskNumber),\"assignee\":\"@assign-outsider\"}")
            #expect(outsider.status == .notFound)
            #expect(object(outsider)["code"] as? String == "assignee_not_assignable")

            let missing = try await post("/internal/agent-api/tasks/assign", "{\"channel\":\"#assign-room\",\"task_number\":\(taskNumber),\"assignee\":\"@no-such-member\"}")
            #expect(missing.status == .notFound)
            #expect(object(missing)["code"] as? String == "assignee_not_assignable")

            let assigned = try await post("/internal/agent-api/tasks/assign", "{\"channel\":\"#assign-room\",\"task_number\":\(taskNumber),\"assignee\":\"@PeerBot\"}")
            #expect(assigned.status == .ok)
            #expect(object(assigned)["claimedById"] as? String == peer)
            #expect(object(assigned)["claimedByType"] as? String == "agent")
            #expect(object(assigned)["claimedAt"] is NSNull)
            #expect(object(assigned)["status"] as? String == "todo")
        }
    }
}

@Test func agentTaskAssignmentReturnsAReceiptAndPersonalInboxFact() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001029003"
    let ownerId = "11111111-1111-4111-8111-000001029003"
    let humanId = "11111111-1111-4111-8111-000001029004"
    accounts.addAccount(id: ownerId, email: "receipt-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: humanId, email: "receipt-human@slock.test", password: "password123")
    accounts.markEmailVerified(userId: humanId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "receipt", name: "Receipt", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: humanId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "receipt-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "receipt-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: humanId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "AssignBot", runtime: "codex")
    let peer = accounts.oauth.createAgent(serverId: serverId, name: "ReceiptTarget", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: peer)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "receipt")

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
            func create(_ assignee: String) async throws -> [String: Any] {
                let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks") { request in
                    request.body = .init(string: "{\"channel\":\"#receipt-room\",\"tasks\":[{\"title\":\"directed work\"}],\"assignee\":\"@\(assignee)\"}")
                }
                #expect(response.status == .ok)
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            for (assignee, receiverId, receiverType) in [("ReceiptTarget", peer, "agent"), ("receipt-human", humanId, "user")] {
                let body = try await create(assignee)
                let receipt = try #require(body["assignmentReceipt"] as? [String: Any])
                let messageId = try #require(receipt["messageId"] as? String)
                #expect(receipt["state"] as? String == "assigned")
                #expect(receipt["assignee"] as? String == "@\(assignee)")
                #expect((receipt["content"] as? String ?? "").contains("@\(assignee)"))
                let task = try #require((body["tasks"] as? [[String: Any]])?.first)
                #expect(task["claimedById"] as? String == receiverId)
                #expect(task["claimedByType"] as? String == receiverType)
                let facts = accounts.inboxFactsForTesting(messageId: messageId)
                #expect(facts.contains { $0.receiverType == receiverType && $0.receiverId == receiverId && $0.personalMention && $0.unreadEligible })
            }
        }
    }
}

@Test func agentIntegrationListHidesRetiredBuiltInRows() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001029005"
    let ownerId = "11111111-1111-4111-8111-000001029005"
    accounts.addAccount(id: ownerId, email: "builtin-retired-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "builtin-retired", name: "Builtin Retired", ownerId: ownerId)
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Slock Survey",
        clientId: "slock-survey",
        appType: "slock_builtin",
        returnUrl: "https://survey.slock.test/login/callback"
    )
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "BuiltinBot", runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "builtin")

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
            let list = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: headers)
            #expect(list.status == .ok)
            let listBody = (try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect((listBody["services"] as? [[String: Any]] ?? []).isEmpty)
            let login = try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/login") { request in
                request.body = .init(string: "{\"service\":\"slock-survey\"}")
            }
            #expect(login.status == .notFound)
        }
    }
}
