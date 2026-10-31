import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func archivedAgentsListAllowsMembersButNotGuests() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111589"
    let memberId = "11111111-1111-4111-8111-111111111590"
    let guestId = "11111111-1111-4111-8111-111111111591"
    let serverId = "33333333-3333-4333-8333-333333333645"
    for (id, email) in [
        (ownerId, "archived-list-owner@slock.test"),
        (memberId, "archived-list-member@slock.test"),
        (guestId, "archived-list-guest@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "archived-list", name: "Archived List", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "archive-machine")

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
            let ownerToken = try await login("archived-list-owner@slock.test")
            let memberToken = try await login("archived-list-member@slock.test")
            let guestToken = try await login("archived-list-guest@slock.test")
            let created = try await client.send(.post, headers: headers(ownerToken), to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"ArchivedBot\",\"machineId\":\"\(machine)\"}")
            }
            let agent = (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            #expect(try await client.send(.delete, headers: headers(ownerToken), to: "/api/agents/\(agent)") { request in
                request.body = .init(string: "{\"workspace\":\"keep\"}")
            }.status == .ok)

            let ownerList = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/archived")
            #expect(ownerList.status == .ok)
            let ownerBody = try JSONSerialization.jsonObject(with: Data((ownerList.body.string ?? "").utf8)) as? [String: Any]
            let agents = ownerBody?["agents"] as? [[String: Any]] ?? []
            #expect(agents.count == 1)
            #expect(agents.first?["agentId"] as? String == agent)
            #expect(agents.first?["machineName"] as? String == "archive-machine")
            #expect(agents.first?["workspaceState"] as? String == "on_computer")
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/agents/archived").status == .ok)
            #expect(try await client.send(.get, headers: headers(guestToken), to: "/api/agents/archived").status == .forbidden)
        }
    }
}
