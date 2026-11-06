import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func nonAssigneeMemberCanUnclaimATask() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111503"
    let memberId = "11111111-1111-4111-8111-111111111504"
    let serverId = "33333333-3333-4333-8333-333333333598"
    accounts.addAccount(id: ownerId, email: "unclaim-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "unclaim-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "unclaim", name: "Unclaim", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "unclaim-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "unclaim-room")
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: memberId, name: "unclaim-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: memberId)
    let taskId = UUID().uuidString.lowercased()
    accounts.addTaskForTesting(channelId: channel, title: "unclaim me", messageId: UUID().uuidString.lowercased(), assigneeType: "user", assigneeId: ownerId)

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
                request.body = .init(string: "{\"email\":\"unclaim-member@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let tasks = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channel)")
            let body = try JSONSerialization.jsonObject(with: Data((tasks.body.string ?? "").utf8)) as? [String: Any]
            let rows = body?["tasks"] as? [[String: Any]] ?? []
            guard let row = rows.first(where: { $0["title"] as? String == "unclaim me" }), let id = row["id"] as? String else {
                Issue.record("task fixture missing")
                return
            }
            #expect(row["claimedById"] as? String == ownerId)
            let unclaim = try await client.send(.patch, headers: headers, to: "/api/tasks/\(id)/unclaim")
            #expect(unclaim.status.code == 200)
            let unclaimBody = try JSONSerialization.jsonObject(with: Data((unclaim.body.string ?? "").utf8)) as? [String: Any]
            #expect(unclaimBody?["claimedById"] == nil || unclaimBody?["claimedById"] is NSNull)
        }
    }
}
