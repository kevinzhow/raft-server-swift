import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func onlyTheThreadAuthorCanRemoveAndRestoreAnAgentFollower() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111448"
    let viewerId = "11111111-1111-4111-8111-111111111449"
    let serverId = "33333333-3333-4333-8333-333333333563"
    accounts.addAccount(id: ownerId, email: "removal-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: viewerId, email: "removal-viewer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: viewerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "removal", name: "Removal", ownerId: ownerId)
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
            let ownerToken = try await login("removal-owner@slock.test")
            let viewerToken = try await login("removal-viewer@slock.test")
            let channel = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"removal-channel\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let parent = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"parent\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let threadId = UUID().uuidString.lowercased()
            accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: ownerId, kind: "thread", parentChannelId: channelId, parentMessageId: parentId, name: "thread")
            let agentId = accounts.oauth.createAgent(serverId: serverId, name: "FollowerAgent")
            accounts.oauth.addChannelAgent(channelId: threadId, agentId: agentId)

            let viewerRemoval = try await client.send(.delete, headers: headers(viewerToken), to: "/api/channels/threads/\(threadId)/followers/agents/\(agentId)")
            #expect(viewerRemoval.status == .forbidden)
            #expect(accounts.oauth.channelAgentIds(channelId: threadId).contains(agentId))

            let removal = try await client.send(.delete, headers: headers(ownerToken), to: "/api/channels/threads/\(threadId)/followers/agents/\(agentId)")
            #expect(removal.status == .ok)
            let removalBody = try JSONSerialization.jsonObject(with: Data((removal.body.string ?? "").utf8)) as? [String: Any]
            #expect(removalBody?["removed"] as? Bool == true)
            #expect((removalBody?["undoToken"] as? String)?.isEmpty == false)
            #expect(!accounts.oauth.channelAgentIds(channelId: threadId).contains(agentId))

            let token = removalBody?["undoToken"] as? String ?? ""
            let restore = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/threads/\(threadId)/followers/agents/\(agentId)/restore") { request in
                request.body = .init(string: "{\"undoToken\":\"\(token)\"}")
            }
            #expect(restore.status == .ok)
            #expect(accounts.oauth.channelAgentIds(channelId: threadId).contains(agentId))
        }
    }
}
