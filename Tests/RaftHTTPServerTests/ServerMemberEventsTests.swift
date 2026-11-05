import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct MemberEventsFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001115001"
    let ownerId = "11111111-1111-4111-8111-000001115001"
    let memberId = "11111111-1111-4111-8111-000001115002"
    let agentId: String

    init() {
        accounts.addAccount(id: ownerId, email: "events-owner@test.invalid", password: "password123")
        accounts.addAccount(id: memberId, email: "events-member@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.markEmailVerified(userId: memberId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "events-server", name: "Events Server", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "EventsBot", creatorUserId: ownerId, runtime: "claude")
    }
}

private func eventJSON(_ provenance: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(provenance.utf8))) as? [String: Any] ?? [:]
}

@Test func removalsLeavesAndServerDeletionQueueMemberEvents() async throws {
    let fixture = MemberEventsFixture()
    let accounts = fixture.accounts
    let ownerToken = accounts.mintAccessTokenForTesting(userId: fixture.ownerId)
    let memberToken = accounts.mintAccessTokenForTesting(userId: fixture.memberId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func call(_ method: String, _ path: String, token: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
                headers[.contentType] = "application/json"
                return try await client.send(method == "DELETE" ? .delete : .post, headers: headers, to: URI(string: path))
            }
            let removed = try await call("DELETE", "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)", token: ownerToken)
            #expect(removed.status == .ok)
            let removedEvents = accounts.serverMemberEventsForTesting(serverId: fixture.serverId, eventType: "server.member_removed")
            #expect(removedEvents.count == 1)
            #expect(removedEvents.first?.subjectType == "member")
            #expect(removedEvents.first?.subjectId == fixture.memberId)
            var provenance = eventJSON(removedEvents.first?.provenanceJSON ?? "{}")
            #expect(provenance["reason"] as? String == "removed")
            #expect(provenance["role"] as? String == "member")
            #expect(provenance["principal_type"] as? String == "human")
            #expect(removedEvents.first?.deliveryQueued == true)

            // Rejoin and leave.
            accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.memberId, role: "member")
            let rejoinedToken = accounts.mintAccessTokenForTesting(userId: fixture.memberId)
            let left = try await call("POST", "/api/servers/\(fixture.serverId)/leave", token: rejoinedToken)
            #expect(left.status == .ok)
            let removedAll = accounts.serverMemberEventsForTesting(serverId: fixture.serverId, eventType: "server.member_removed")
            #expect(removedAll.count == 2)
            provenance = eventJSON(removedAll.last?.provenanceJSON ?? "{}")
            #expect(provenance["reason"] as? String == "left")

            // Deleting the server announces each member and the agent, once.
            accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.memberId, role: "member")
            let deleted = try await call("DELETE", "/api/servers/\(fixture.serverId)", token: ownerToken)
            #expect(deleted.status == .ok)
            let deletedEvents = accounts.serverMemberEventsForTesting(serverId: fixture.serverId, eventType: "server.member_removed")
            let deletion = deletedEvents.filter { (eventJSON($0.provenanceJSON)["reason"] as? String) == "server_deleted" }
            #expect(Set(deletion.map(\.subjectId)) == [fixture.ownerId, fixture.memberId, fixture.agentId])
            let repeated = try await call("DELETE", "/api/servers/\(fixture.serverId)", token: ownerToken)
            #expect(repeated.status == .ok)
            let after = accounts.serverMemberEventsForTesting(serverId: fixture.serverId, eventType: "server.member_removed")
            #expect(after.filter { (eventJSON($0.provenanceJSON)["reason"] as? String) == "server_deleted" }.count == 3)
        }
    }
}

@Test func joinLinkRoleAgentDeletionQueueMemberEvents() async throws {
    let fixture = MemberEventsFixture()
    let accounts = fixture.accounts
    let joinerId = "11111111-1111-4111-8111-000001115003"
    accounts.addAccount(id: joinerId, email: "events-joiner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: joinerId)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: fixture.ownerId)
    let joinerToken = accounts.mintAccessTokenForTesting(userId: joinerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ method: String, _ path: String, token: String?, body: String?, serverId: String? = nil) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                if let token { headers[.authorization] = "Bearer \(token)" }
                if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
                headers[.contentType] = "application/json"
                let response = try await client.send(method == "PATCH" ? .patch : method == "DELETE" ? .delete : .post, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let link = try await send("POST", "/api/servers/\(fixture.serverId)/join-links", token: ownerToken, body: "{\"maxUses\":1}", serverId: fixture.serverId)
            #expect(link.0.status == .ok, Comment(rawValue: link.0.body.string ?? ""))
            let joinToken = try #require(link.1["token"] as? String)
            let accepted = try await send("POST", "/api/auth/accept-invite", token: joinerToken, body: "{\"token\":\"\(joinToken)\"}")
            #expect(accepted.0.status == .ok, Comment(rawValue: accepted.0.body.string ?? ""))
            let added = accounts.serverMemberEventsForTesting(serverId: fixture.serverId, eventType: "server.member_added")
            #expect(added.contains { $0.subjectId == joinerId && $0.subjectType == "member" })

            let promoted = try await send("PATCH", "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)", token: ownerToken, body: "{\"role\":\"admin\"}", serverId: fixture.serverId)
            #expect(promoted.0.status == .ok, Comment(rawValue: promoted.0.body.string ?? ""))
            let changed = accounts.serverMemberEventsForTesting(serverId: fixture.serverId, eventType: "server.member_role_changed")
            #expect(changed.count == 1)
            #expect(changed.first?.subjectId == fixture.memberId)
            let provenance = eventJSON(changed.first?.provenanceJSON ?? "{}")
            #expect(provenance["previous_role"] as? String == "member")
            #expect(provenance["role"] as? String == "admin")
            #expect(provenance["principal_type"] as? String == "human")

            let deleted = try await send("DELETE", "/api/agents/\(fixture.agentId)", token: ownerToken, body: nil, serverId: fixture.serverId)
            #expect(deleted.0.status == .ok, Comment(rawValue: deleted.0.body.string ?? ""))
            let removed = accounts.serverMemberEventsForTesting(serverId: fixture.serverId, eventType: "server.member_removed")
            let agentRemoval = removed.first { $0.subjectId == fixture.agentId }
            #expect(agentRemoval?.subjectType == "agent")
            #expect((eventJSON(agentRemoval?.provenanceJSON ?? "{}")["principal_type"] as? String) == "agent")
        }
    }
}
