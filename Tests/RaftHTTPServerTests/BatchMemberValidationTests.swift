import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func batchMemberValidationRejectsTheWholeInput() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111532"
    let validId = "11111111-1111-4111-8111-111111111533"
    let serverId = "33333333-3333-4333-8333-333333333613"
    accounts.addAccount(id: ownerId, email: "batch-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: validId, email: "batch-valid@slock.test", password: "password123")
    accounts.markEmailVerified(userId: validId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "batch-atomic", name: "Batch Atomic", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: validId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "batch-atomic-target", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "batch-atomic-target")
    let missingId = UUID().uuidString.lowercased()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"batch-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/members/batch") { request in
                request.body = .init(string: "{\"userIds\":[\"\(validId)\",\"\(missingId)\"],\"agentIds\":[]}")
            }
            #expect(response.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "One or more users are not members of this server")
            #expect(body?["code"] as? String == "users_not_in_server")
            #expect(body?["invalidUserIds"] as? [String] == [missingId])
            #expect(!accounts.oauth.channelHumanIds(channelId: channel).contains(validId))
        }
    }
}
