import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func hiddenDirectoryMemberProfileNeedsASharedVisibleChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111358"
    let requesterId = "11111111-1111-4111-8111-111111111359"
    let peerId = "11111111-1111-4111-8111-111111111360"
    let serverId = "33333333-3333-4333-8333-333333333508"
    for (id, email) in [
        (ownerId, "hidden-profile-owner@slock.test"),
        (requesterId, "hidden-profile-requester@slock.test"),
        (peerId, "hidden-profile-peer@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "hidden-profile", name: "Hidden Profile", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: requesterId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)

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
            let ownerToken = try await login("hidden-profile-owner@slock.test")
            let requesterToken = try await login("hidden-profile-requester@slock.test")
            func profile(_ token: String, _ memberId: String) async throws -> ClientResponse {
                try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/members/\(memberId)/profile")
            }

            let ownerView = try await profile(ownerToken, peerId)
            #expect(ownerView.status == .ok)

            let hidden = try await profile(requesterToken, peerId)
            #expect(hidden.status == .notFound)
            #expect((try JSONSerialization.jsonObject(with: Data((hidden.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "User not found")

            #expect(try await profile(requesterToken, requesterId).status == .ok)

            let shared = accounts.oauth.createChannel(serverId: serverId, name: "hidden-profile-shared", creatorUserId: ownerId)
            accounts.oauth.addChannelHuman(channelId: shared, userId: requesterId)
            accounts.oauth.addChannelHuman(channelId: shared, userId: peerId)
            let visible = try await profile(requesterToken, peerId)
            #expect(visible.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((visible.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["userId"] as? String == peerId)
            #expect(body?["email"] == nil || body?["email"] is NSNull)
        }
    }
}
