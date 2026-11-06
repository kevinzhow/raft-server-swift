import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelVisibilityNeedsServerAuthorityAndMembership() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111471"
    let insiderId = "11111111-1111-4111-8111-111111111472"
    let serverId = "33333333-3333-4333-8333-333333333579"
    accounts.addAccount(id: ownerId, email: "visibility-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: insiderId, email: "visibility-insider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: insiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "visibility", name: "Visibility", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: insiderId, role: "member")
    let target = accounts.oauth.createChannel(serverId: serverId, name: "not-mine", creatorUserId: insiderId)
    accounts.addPostableChannel(serverId: serverId, channelId: target, memberId: insiderId, name: "not-mine")

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
            let ownerToken = try await login("visibility-owner@slock.test")
            let insiderToken = try await login("visibility-insider@slock.test")
            func patch(_ token: String, _ channelId: String, _ visibility: String) async throws -> ([String: Any], Int) {
                let response = try await client.send(.patch, headers: headers(token), to: "/api/channels/\(channelId)") { request in
                    request.body = .init(string: "{\"visibility\":\"\(visibility)\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:], response.status.code)
            }

            let outsiderOwner = try await patch(ownerToken, target, "private")
            #expect(outsiderOwner.1 == 403)
            #expect(outsiderOwner.0["code"] as? String == "channel_membership_required")
            #expect(try await patch(insiderToken, target, "private").1 == 403)

            accounts.addPostableChannel(serverId: serverId, channelId: target, memberId: ownerId, name: "not-mine")
            accounts.oauth.addChannelHuman(channelId: target, userId: ownerId)
            #expect(try await patch(ownerToken, target, "private").1 == 200)
            #expect(try await patch(ownerToken, target, "public").1 == 200)
            #expect(accounts.oauth.channelType(id: target) == "channel")

            let allChannel = accounts.oauth.allChannelId(serverId: serverId) ?? ""
            let allAttempt = try await patch(ownerToken, allChannel, "private")
            #expect(allAttempt.1 == 403)
            #expect(allAttempt.0["code"] as? String == "all_channel_visibility_managed_separately")
            #expect(((allAttempt.0["error"] as? String) ?? "").contains("Only a human can do it, from channel settings or server settings"))
        }
    }
}
