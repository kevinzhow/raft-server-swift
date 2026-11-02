import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
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
