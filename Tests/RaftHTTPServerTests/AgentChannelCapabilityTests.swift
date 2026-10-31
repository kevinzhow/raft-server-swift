import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentChannelWritesRespectServerRole() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111500"
    let targetId = "11111111-1111-4111-8111-111111111501"
    let serverId = "33333333-3333-4333-8333-333333333596"
    accounts.addAccount(id: ownerId, email: "cap-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: targetId, email: "cap-target@slock.test", password: "password123")
    accounts.markEmailVerified(userId: targetId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "cap", name: "Capability Server", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: targetId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "cap-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "cap-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: targetId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "cap-agent")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let peer = accounts.oauth.createAgent(serverId: serverId, name: "cap-peer")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["channels", "server"], name: "cap")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func json(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            let deniedChannel = try await client.send(.patch, headers: headers, to: "/internal/agent-api/channels/\(channel)") { request in
                request.body = .init(string: "{\"name\":\"#denied-rename\"}")
            }
            #expect(deniedChannel.status == .forbidden)
            let deniedBody = try json(deniedChannel)
            #expect(deniedBody["error"] as? String == "Agent requires editChannelMetadata or changeChannelVisibility capability to update channels")
            #expect(deniedBody["code"] as? String == "server_role_required")
            #expect(deniedBody["currentRole"] as? String == "member")
            #expect(((deniedBody["suggestedNextAction"] as? String) ?? "").contains("your role is member"))

            let deniedRemove = try await client.send(.delete, headers: headers, to: "/internal/agent-api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"user\":\"cap-owner\"}")
            }
            #expect(deniedRemove.status == .forbidden)
            #expect(try json(deniedRemove)["error"] as? String == "Agent requires removeChannelMembers capability to remove channel members")
            #expect(accounts.oauth.channelHumanIds(channelId: channel).contains(ownerId))

            let deniedServer = try await client.send(.patch, headers: headers, to: "/internal/agent-api/server") { request in
                request.body = .init(string: "{\"name\":\"Denied Server\"}")
            }
            #expect(deniedServer.status == .forbidden)
            #expect(try json(deniedServer)["error"] as? String == "Agent requires editServerSettings capability to edit the server profile")

            accounts.oauth.setAgentRole(serverId: serverId, agentId: agent, role: "admin")
            let allowedRename = try await client.send(.patch, headers: headers, to: "/internal/agent-api/channels/\(channel)") { request in
                request.body = .init(string: "{\"name\":\"#cap-renamed\"}")
            }
            #expect(allowedRename.status == .ok)
            #expect(try json(allowedRename)["name"] as? String == "cap-renamed")

            let addHuman = try await client.send(.post, headers: headers, to: "/internal/agent-api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"user\":\"cap-target\"}")
            }
            #expect(addHuman.status == .ok)
            #expect(accounts.oauth.channelHumanIds(channelId: channel).contains(targetId))
            #expect(try await client.send(.delete, headers: headers, to: "/internal/agent-api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"user\":\"cap-target\"}")
            }.status == .ok)
            #expect(!accounts.oauth.channelHumanIds(channelId: channel).contains(targetId))

            let addAgent = try await client.send(.post, headers: headers, to: "/internal/agent-api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"agent\":\"cap-peer\"}")
            }
            #expect(addAgent.status == .ok)
            #expect(accounts.oauth.channelAgentIds(channelId: channel).contains(peer))

            let allowedServer = try await client.send(.patch, headers: headers, to: "/internal/agent-api/server") { request in
                request.body = .init(string: "{\"name\":\"Capability Server Renamed\"}")
            }
            #expect(allowedServer.status == .ok)
        }
    }
}
