import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverUsageCountsLiveAgentsMachinesAndHumanChannels() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111644"
    let memberId = "11111111-1111-4111-8111-111111111645"
    let guestId = "11111111-1111-4111-8111-111111111646"
    let outsiderId = "11111111-1111-4111-8111-111111111647"
    let serverId = "33333333-3333-4333-8333-333333333678"
    for (id, email, role) in [
        (ownerId, "usage-owner@slock.test", "owner"),
        (memberId, "usage-member@slock.test", "member"),
        (guestId, "usage-guest@slock.test", "guest"),
        (outsiderId, "usage-outsider@slock.test", nil),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "usage", name: "Usage", ownerId: id)
        } else if let role {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    _ = accounts.oauth.createChannel(serverId: serverId, name: "usage-public", creatorUserId: ownerId)
    _ = accounts.oauth.createChannel(serverId: serverId, name: "usage-private", creatorUserId: ownerId, type: "private")
    _ = accounts.oauth.createChannel(serverId: serverId, name: "usage-thread", creatorUserId: ownerId, type: "thread")
    _ = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: memberId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "usage-agent-one")
    _ = accounts.oauth.createAgent(serverId: serverId, name: "usage-agent-two")
    _ = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "usage-machine")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func usage(_ bearer: String?) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                return try await client.get("/api/servers/\(serverId)/usage", headers: headers)
            }

            let owner = try await token("usage-owner@slock.test")
            let member = try await token("usage-member@slock.test")
            let guest = try await token("usage-guest@slock.test")
            let outsider = try await token("usage-outsider@slock.test")

            let ownerResponse = try await usage(owner)
            #expect(ownerResponse.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((ownerResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["agents"] as? Int == 2)
            #expect(body?["machines"] as? Int == 1)
            #expect(body?["channels"] as? Int == 2)
            #expect(try await usage(member).status == .ok)
            #expect(try await usage(guest).status == .forbidden)
            #expect(try await usage(outsider).status == .notFound)
            #expect(try await usage(nil).status == .unauthorized)
        }
    }
}
