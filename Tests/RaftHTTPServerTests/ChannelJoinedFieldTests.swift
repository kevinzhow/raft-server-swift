import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelDetailReportsJoinedAcrossVisibilityKinds() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111534"
    let memberId = "11111111-1111-4111-8111-111111111535"
    let otherId = "11111111-1111-4111-8111-111111111536"
    let serverId = "33333333-3333-4333-8333-333333333614"
    for (id, email) in [
        (ownerId, "joined-owner@slock.test"),
        (memberId, "joined-member@slock.test"),
        (otherId, "joined-other@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "joined", name: "Joined", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")
    let regular = accounts.oauth.createChannel(serverId: serverId, name: "joined-regular", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: regular, memberId: ownerId, name: "joined-regular")
    accounts.oauth.addChannelHuman(channelId: regular, userId: ownerId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "joined-private", creatorUserId: ownerId, type: "private")
    accounts.oauth.setChannelType(id: privateChannel, type: "private")
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: id, kind: "private", name: "joined-private")
        accounts.oauth.addChannelHuman(channelId: privateChannel, userId: id)
    }
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: otherId)

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
            func joined(_ token: String, _ channel: String) async throws -> Bool? {
                let response = try await client.send(.get, headers: headers(token), to: "/api/channels/\(channel)")
                guard response.status == .ok else { return nil }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["joined"] as? Bool
            }
            let ownerToken = try await login("joined-owner@slock.test")
            let memberToken = try await login("joined-member@slock.test")
            let otherToken = try await login("joined-other@slock.test")

            #expect(try await joined(ownerToken, regular) == true)
            #expect(try await joined(otherToken, regular) == false)
            #expect(try await joined(memberToken, privateChannel) == true)
            #expect(try await joined(otherToken, privateChannel) == nil)
            #expect(try await joined(otherToken, dm) == true)
        }
    }
}
