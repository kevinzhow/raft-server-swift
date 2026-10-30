import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func allChannelHideIsIdempotentAndAdminOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111291"
    let memberId = "11111111-1111-4111-8111-111111111292"
    let serverId = "33333333-3333-4333-8333-333333333473"
    accounts.addAccount(id: ownerId, email: "all-hide-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "all-hide-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "all-hide", name: "All Hide", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let allChannelId = accounts.oauth.allChannelId(serverId: serverId) ?? ""

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
            let ownerToken = try await login("all-hide-owner@slock.test")
            let memberToken = try await login("all-hide-member@slock.test")

            let restore = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/system/all/restore")
            #expect(restore.status == .ok)
            #expect(accounts.oauth.channelType(id: allChannelId) == "channel")

            let hide = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/system/all/hide")
            #expect(hide.status == .ok)
            #expect(accounts.oauth.channelType(id: allChannelId) == "private")

            let hideAgain = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/system/all/hide")
            #expect(hideAgain.status == .ok)
            #expect(accounts.oauth.channelType(id: allChannelId) == "private")

            let forbidden = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/system/all/hide")
            #expect(forbidden.status == .forbidden)
        }
    }
}
