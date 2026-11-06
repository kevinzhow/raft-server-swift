import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func remindersAreReadOnlyAndScopedToInspectableAgents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111294"
    let creatorId = "11111111-1111-4111-8111-111111111295"
    let bystanderId = "11111111-1111-4111-8111-111111111296"
    let serverId = "33333333-3333-4333-8333-333333333475"
    for (id, email) in [
        (ownerId, "reminders-owner@slock.test"),
        (creatorId, "reminders-creator@slock.test"),
        (bystanderId, "reminders-bystander@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "reminders-scope", name: "Reminders Scope", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: creatorId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: bystanderId, role: "member")
    let agentX = accounts.oauth.createAgent(serverId: serverId, name: "r-agent-x", creatorUserId: ownerId)
    let agentY = accounts.oauth.createAgent(serverId: serverId, name: "r-agent-y", creatorUserId: creatorId)
    accounts.addReminderForTesting(serverId: serverId, ownerAgentId: agentX, title: "x-standup", fireAt: Date().addingTimeInterval(60))
    accounts.addReminderForTesting(serverId: serverId, ownerAgentId: agentY, title: "y-review", fireAt: Date().addingTimeInterval(120))

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func titles(_ token: String, _ query: String = "") async throws -> [String] {
                let response = try await client.send(.get, headers: headers(token), to: URI(string: "/api/reminders\(query)"))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["reminders"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }.sorted()
            }

            let ownerToken = try await login("reminders-owner@slock.test")
            let creatorToken = try await login("reminders-creator@slock.test")
            let bystanderToken = try await login("reminders-bystander@slock.test")
            #expect(try await titles(ownerToken) == ["x-standup", "y-review"])
            #expect(try await titles(creatorToken) == ["y-review"])
            #expect(try await titles(bystanderToken) == [])

            let forbidden = try await client.send(.get, headers: headers(bystanderToken), to: "/api/reminders?ownerAgentId=\(agentX)")
            #expect(forbidden.status == .forbidden)
            #expect(try await titles(creatorToken, "?ownerAgentId=\(agentY)") == ["y-review"])

            let post = try await client.send(.post, headers: headers(ownerToken), to: "/api/reminders") { request in
                request.body = .init(string: "{\"ownerAgentId\":\"\(agentX)\",\"title\":\"nope\"}")
            }
            #expect(post.status == .notFound)
            let delete = try await client.send(.delete, headers: headers(ownerToken), to: "/api/reminders/not-a-reminder")
            #expect(delete.status == .notFound)
        }
    }
}
