import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func publicChannelJoinChecksCapabilityAfterIdempotentMembership() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111393"
    let outsiderId = "11111111-1111-4111-8111-111111111394"
    let serverId = "33333333-3333-4333-8333-333333333530"
    accounts.addAccount(id: ownerId, email: "join-cap-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: outsiderId, email: "join-cap-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "join-capability", name: "Join Capability", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "join-capability-public", creatorUserId: ownerId)

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
            let ownerToken = try await login("join-cap-owner@slock.test")
            let outsiderToken = try await login("join-cap-outsider@slock.test")

            let outsiderJoin = try await client.send(.post, headers: headers(outsiderToken), to: "/api/channels/\(channelId)/join")
            #expect(outsiderJoin.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((outsiderJoin.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Server role cannot join public channels")
            #expect(!accounts.oauth.isChannelParticipant(channelId: channelId, userId: outsiderId))

            accounts.oauth.addChannelHuman(channelId: channelId, userId: outsiderId)
            let idempotent = try await client.send(.post, headers: headers(outsiderToken), to: "/api/channels/\(channelId)/join")
            #expect(idempotent.status == .ok)
            #expect(accounts.oauth.isChannelParticipant(channelId: channelId, userId: outsiderId))

            let ownerRepeat = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channelId)/join")
            #expect(ownerRepeat.status == .ok)
        }
    }
}
