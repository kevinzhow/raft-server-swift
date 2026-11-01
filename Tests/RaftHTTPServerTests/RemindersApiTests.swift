import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func reminderLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func reminderHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private struct ReminderFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let creatorId: String
    let bystanderId: String
    let agentX: String
    let agentY: String
}

private func makeReminderFixture(suffix: String) -> ReminderFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-33333388\(suffix)"
    let ownerId = "11111111-1111-4111-8111-11111188\(suffix)"
    let creatorId = "11111111-1111-4111-8111-22222288\(suffix)"
    let bystanderId = "11111111-1111-4111-8111-33333388\(suffix)"
    for (id, email, role) in [
        (ownerId, "reminders-owner-\(suffix)@slock.test", "owner"),
        (creatorId, "reminders-creator-\(suffix)@slock.test", "member"),
        (bystanderId, "reminders-bystander-\(suffix)@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "reminders-\(suffix)", name: "Reminders \(suffix)", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let agentX = accounts.oauth.createAgent(serverId: serverId, name: "r-agent-x-\(suffix)")
    let agentY = accounts.oauth.createAgent(serverId: serverId, name: "r-agent-y-\(suffix)", creatorUserId: creatorId)
    accounts.addReminder(serverId: serverId, ownerAgentId: agentX, title: "x-standup", fireAt: Date().addingTimeInterval(60_000))
    accounts.addReminder(serverId: serverId, ownerAgentId: agentY, title: "y-review", fireAt: Date().addingTimeInterval(60_000))
    return ReminderFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        creatorId: creatorId,
        bystanderId: bystanderId,
        agentX: agentX,
        agentY: agentY
    )
}

@Test func reminderWritesStayUnexposedToHumans() async throws {
    let fixture = makeReminderFixture(suffix: "801")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await reminderLogin(client, email: "reminders-owner-801@slock.test")
            let headers = reminderHeaders(token, fixture.serverId)
            let create = try await client.send(.post, headers: headers, to: "/api/reminders") { request in
                request.body = .init(string: "{\"ownerAgentId\":\"\(fixture.agentX)\",\"title\":\"nope\",\"fireAt\":\"2026-11-01T00:00:00.000Z\"}")
            }
            #expect(create.status == .notFound)

            let listing = try await client.get(URI(string: "/api/reminders?ownerAgentId=\(fixture.agentX)"), headers: headers)
            let listingBody = try JSONSerialization.jsonObject(with: Data((listing.body.string ?? "").utf8)) as? [String: Any]
            let reminderId = ((listingBody?["reminders"] as? [[String: Any]])?.first)?["id"] as? String ?? ""
            let remove = try await client.send(.delete, headers: headers, to: URI(string: "/api/reminders/\(reminderId)"))
            #expect(remove.status == .notFound)
        }
    }
}

@Test func reminderListingReturnsTheReadOnlyRows() async throws {
    let fixture = makeReminderFixture(suffix: "802")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await reminderLogin(client, email: "reminders-owner-802@slock.test")
            let headers = reminderHeaders(token, fixture.serverId)
            let response = try await client.get(URI(string: "/api/reminders?ownerAgentId=\(fixture.agentY)"), headers: headers)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let reminders = body?["reminders"] as? [[String: Any]] ?? []
            #expect(reminders.count == 1)
            #expect(reminders.first?["title"] as? String == "y-review")
            #expect(reminders.first?["ownerAgentId"] as? String == fixture.agentY)
        }
    }
}

@Test func reminderListingScopesToAgentsTheCallerMayInspect() async throws {
    let fixture = makeReminderFixture(suffix: "803")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await reminderLogin(client, email: "reminders-owner-803@slock.test")
            let creator = try await reminderLogin(client, email: "reminders-creator-803@slock.test")
            let bystander = try await reminderLogin(client, email: "reminders-bystander-803@slock.test")
            func titles(_ token: String, query: String = "") async throws -> [String] {
                let response = try await client.get(URI(string: "/api/reminders\(query)"), headers: reminderHeaders(token, fixture.serverId))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["reminders"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }.sorted()
            }
            #expect(try await titles(owner) == ["x-standup", "y-review"])
            #expect(try await titles(creator) == ["y-review"])
            #expect(try await titles(bystander) == [])
            let foreign = try await client.get(URI(string: "/api/reminders?ownerAgentId=\(fixture.agentX)"), headers: reminderHeaders(bystander, fixture.serverId))
            #expect(foreign.status == .forbidden)
            #expect(try await titles(creator, query: "?ownerAgentId=\(fixture.agentY)") == ["y-review"])
        }
    }
}
