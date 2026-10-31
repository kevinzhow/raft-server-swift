import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelJoinRequiresServerRoleButIsIdempotentForMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111328"
    let outsiderId = "11111111-1111-4111-8111-111111111329"
    let memberId = "11111111-1111-4111-8111-111111111330"
    let serverId = "33333333-3333-4333-8333-333333333496"
    for (id, email) in [
        (ownerId, "join-owner@slock.test"),
        (outsiderId, "join-outsider@slock.test"),
        (memberId, "join-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "join-capability", name: "Join Capability", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "join-public", creatorUserId: ownerId)

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
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let outsiderToken = try await login("join-outsider@slock.test")

            let refused = try await client.send(.post, headers: headers(outsiderToken), to: "/api/channels/\(channelId)/join")
            #expect(refused.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((refused.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Server role cannot join public channels")
            #expect(accounts.oauth.isChannelParticipant(channelId: channelId, userId: outsiderId) == false)

            accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
            let memberToken = try await login("join-member@slock.test")
            let joined = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/\(channelId)/join")
            #expect(joined.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((joined.body.string ?? "").utf8)) as? [String: Any])?["ok"] as? Bool == true)
            #expect(accounts.oauth.isChannelParticipant(channelId: channelId, userId: memberId))

            accounts.oauth.removeMember(serverId: serverId, userId: memberId)
            let idempotent = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/\(channelId)/join")
            #expect(idempotent.status == .ok)

            var unauth = HTTPFields()
            unauth[HTTPField.Name("X-Server-Id")!] = serverId
            let refusedUnauth = try await client.send(.post, headers: unauth, to: "/api/channels/\(channelId)/join")
            #expect(refusedUnauth.status == .unauthorized)
        }
    }
}
