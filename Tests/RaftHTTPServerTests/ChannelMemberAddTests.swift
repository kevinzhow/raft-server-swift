import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelMemberAddAcceptsHumansAndBatch() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111480"
    let memberId = "11111111-1111-4111-8111-111111111481"
    let serverId = "33333333-3333-4333-8333-333333333585"
    accounts.addAccount(id: ownerId, email: "member-add-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "member-add-target@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "member-add", name: "Member Add", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
                request.body = .init(string: "{\"email\":\"member-add-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"member-add-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            let add = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/members") { request in
                request.body = .init(string: "{\"userId\":\"\(memberId)\"}")
            }
            #expect(add.status == .ok)
            #expect(accounts.oauth.channelHumanIds(channelId: channelId).contains(memberId))

            let agent = accounts.oauth.createAgent(serverId: serverId, name: "member-add-agent")
            let batch = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/members/batch") { request in
                request.body = .init(string: "{\"userIds\":[\"\(memberId)\"],\"agentIds\":[\"\(agent)\"]}")
            }
            #expect(batch.status == .ok)
            let batchBody = try JSONSerialization.jsonObject(with: Data((batch.body.string ?? "").utf8)) as? [String: Any]
            let added = batchBody?["added"] as? [String: Any]
            #expect(batchBody?["ok"] as? Bool == true)
            #expect((added?["agentIds"] as? [String]) == [agent])
            #expect(accounts.oauth.channelAgentIds(channelId: channelId).contains(agent))

            let repeatBatch = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/members/batch") { request in
                request.body = .init(string: "{\"userIds\":[\"\(memberId)\"],\"agentIds\":[\"\(agent)\"]}")
            }
            let repeatBody = try JSONSerialization.jsonObject(with: Data((repeatBatch.body.string ?? "").utf8)) as? [String: Any]
            let already = repeatBody?["alreadyMembers"] as? [String: Any]
            #expect((already?["userIds"] as? [String]) == [memberId])
            #expect((already?["agentIds"] as? [String]) == [agent])

            let members = try await client.send(.get, headers: headers, to: "/api/channels/\(channelId)/members")
            let body = try JSONSerialization.jsonObject(with: Data((members.body.string ?? "").utf8)) as? [String: Any]
            #expect((body?["humans"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == memberId })
            #expect((body?["agents"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == agent })
        }
    }
}
