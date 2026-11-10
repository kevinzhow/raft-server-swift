import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func taskStatusDemotionAndStartRespectTheAssignee() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111505"
    let memberId = "11111111-1111-4111-8111-111111111506"
    let peerId = "11111111-1111-4111-8111-111111111507"
    let serverId = "33333333-3333-4333-8333-333333333599"
    for (id, email) in [
        (ownerId, "status-owner@slock.test"),
        (memberId, "status-member@slock.test"),
        (peerId, "status-peer@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "status", name: "Status", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "status-room", creatorUserId: ownerId)
    for id in [ownerId, memberId, peerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "status-room")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    accounts.addTaskForTesting(channelId: channel, title: "status task", messageId: UUID().uuidString.lowercased(), assigneeType: nil, assigneeId: nil)

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
            let memberToken = try await login("status-member@slock.test")
            let peerToken = try await login("status-peer@slock.test")
            let tasks = try await client.send(.get, headers: headers(memberToken), to: "/api/tasks/channel/\(channel)")
            let tasksBody = try JSONSerialization.jsonObject(with: Data((tasks.body.string ?? "").utf8)) as? [String: Any]
            let taskId = (tasksBody?["tasks"] as? [[String: Any]] ?? []).first?["id"] as? String ?? ""

            #expect(try await client.send(.patch, headers: headers(memberToken), to: "/api/tasks/\(taskId)/claim").status == .ok)
            let peerDemotion = try await client.send(.patch, headers: headers(peerToken), to: "/api/tasks/\(taskId)/status") { request in
                request.body = .init(string: "{\"status\":\"todo\"}")
            }
            #expect(peerDemotion.status == .conflict)

            let selfDemotion = try await client.send(.patch, headers: headers(memberToken), to: "/api/tasks/\(taskId)/status") { request in
                request.body = .init(string: "{\"status\":\"todo\"}")
            }
            #expect(selfDemotion.status == .ok)
            let demotedEnvelope = try #require(try JSONSerialization.jsonObject(with: Data((selfDemotion.body.string ?? "").utf8)) as? [String: Any])
            #expect(Set(demotedEnvelope.keys) == ["task"])
            let demoted: [String: Any]? = try #require(demotedEnvelope["task"] as? [String: Any])
            #expect(demoted?["status"] as? String == "todo")
            #expect(demoted?["claimedById"] as? String == memberId)
            #expect(demoted?["claimedAt"] == nil || demoted?["claimedAt"] is NSNull)

            let selfStart = try await client.send(.patch, headers: headers(memberToken), to: "/api/tasks/\(taskId)/status") { request in
                request.body = .init(string: "{\"status\":\"in_progress\"}")
            }
            #expect(selfStart.status == .ok)
            let startedEnvelope = try #require(try JSONSerialization.jsonObject(with: Data((selfStart.body.string ?? "").utf8)) as? [String: Any])
            #expect(Set(startedEnvelope.keys) == ["task"])
            let started: [String: Any]? = try #require(startedEnvelope["task"] as? [String: Any])
            #expect(started?["claimedAt"] is String)
        }
    }
}
