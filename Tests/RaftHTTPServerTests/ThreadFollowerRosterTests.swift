import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadFollowerRosterIsReadOnlyForAnOrdinaryViewer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111446"
    let viewerId = "11111111-1111-4111-8111-111111111447"
    let serverId = "33333333-3333-4333-8333-333333333562"
    accounts.addAccount(id: ownerId, email: "roster-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: viewerId, email: "roster-viewer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: viewerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "roster", name: "Roster", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: viewerId, role: "member")

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
            let ownerToken = try await login("roster-owner@slock.test")
            let viewerToken = try await login("roster-viewer@slock.test")
            let channel = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"roster-channel\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let parent = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"parent task\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let threadId = UUID().uuidString.lowercased()
            accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: ownerId, kind: "thread", parentChannelId: channelId, parentMessageId: parentId, name: "thread")
            let agentA = accounts.oauth.createAgent(serverId: serverId, name: "RosterAgentA")
            let agentB = accounts.oauth.createAgent(serverId: serverId, name: "RosterAgentB")
            accounts.oauth.addChannelAgent(channelId: threadId, agentId: agentA)
            accounts.oauth.addChannelAgent(channelId: threadId, agentId: agentB)

            func roster(_ token: String) async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers(token), to: URI(string: "/api/channels/threads/followers?threadChannelIds=\(threadId)"))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return body?["threads"] as? [[String: Any]] ?? []
            }

            let viewerRoster = try await roster(viewerToken)
            #expect(viewerRoster.count == 1)
            #expect(viewerRoster[0]["threadChannelId"] as? String == threadId)
            #expect(viewerRoster[0]["canManage"] as? Bool == false)
            let names = (viewerRoster[0]["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            #expect(Set(names) == [agentA, agentB])

            let ownerRoster = try await roster(ownerToken)
            #expect(ownerRoster[0]["canManage"] as? Bool == true)
        }
    }
}
