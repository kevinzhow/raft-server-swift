import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct CMFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111655"
    let peerId = "11111111-1111-4111-8111-111111111656"
    let serverId = "33333333-3333-4333-8333-333333333693"
    let ownerToken: String
    let peerToken: String

    init() {
        for (id, email) in [(ownerId, "cm-owner"), (peerId, "cm-peer")] {
            accounts.addAccount(id: id, email: "\(email)@slock.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "cm", name: "CM", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
        ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
        peerToken = accounts.mintAccessTokenForTesting(userId: peerId)
    }

    func headers(_ token: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return headers
    }
}

@Test func dmListCarriesLastMessageSenderAndPreview() async throws {
    let f = CMFixture()
    let agentId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "DM Bot", creatorUserId: f.ownerId, runtime: "claude")
    let agentDm = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: agentId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: agentDm, memberId: f.ownerId, kind: "dm", name: "dm")
    f.accounts.oauth.addChannelHuman(channelId: agentDm, userId: f.ownerId)
    f.accounts.oauth.addChannelAgent(channelId: agentDm, agentId: agentId)
    f.accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: agentDm, senderId: agentId, content: "from the agent", senderType: "agent")
    let peerDm = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.peerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: peerDm, memberId: f.ownerId, kind: "dm", name: "dm")
    f.accounts.oauth.addChannelHuman(channelId: peerDm, userId: f.ownerId)
    f.accounts.oauth.addChannelHuman(channelId: peerDm, userId: f.peerId)
    f.accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: peerDm, senderId: f.peerId, content: "from the peer")
    let selfDm = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.ownerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: selfDm, memberId: f.ownerId, kind: "dm", name: "dm")
    f.accounts.oauth.addChannelHuman(channelId: selfDm, userId: f.ownerId)
    f.accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: selfDm, senderId: "system", content: "a system notice", messageType: "system")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/channels/dm"), headers: f.headers(f.ownerToken))
            #expect(response.status == .ok)
            let rows = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            let byId = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
                guard let id = row["id"] as? String else { return nil }
                return (id, row)
            })
            #expect(byId[agentDm]?["lastMessageSenderName"] as? String == "DM Bot", Comment(rawValue: "\(String(describing: byId[agentDm]))"))
            #expect(byId[peerDm]?["lastMessageSenderName"] as? String == "cm-peer")
            #expect(byId[selfDm]?["lastMessagePreview"] as? String == "a system notice")
            #expect(byId[selfDm]?["lastMessageSenderName"] is NSNull)
        }
    }
}

@Test func newUserDmIsHiddenForPassivePeerOnly() async throws {
    let f = CMFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await client.send(.post, headers: f.headers(f.ownerToken), to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(f.peerId)\"}")
            }
            #expect(created.status == .ok)
            let dm = (try? JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let dmId = try #require(dm["id"] as? String)
            let peerSidebar = try await client.get(URI(string: "/api/servers/\(f.serverId)/sidebar-order"), headers: f.headers(f.peerToken))
            let peerState = (try? JSONSerialization.jsonObject(with: Data((peerSidebar.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect((peerState["hiddenDmIds"] as? [String])?.contains(dmId) == true)
            let ownerSidebar = try await client.get(URI(string: "/api/servers/\(f.serverId)/sidebar-order"), headers: f.headers(f.ownerToken))
            let ownerState = (try? JSONSerialization.jsonObject(with: Data((ownerSidebar.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect((ownerState["hiddenDmIds"] as? [String])?.contains(dmId) == false)

            var order = f.accounts.oauth.sanitizedSidebarOrder(serverId: f.serverId, userId: f.peerId)
            order.hiddenDmIds.removeAll { $0 == dmId }
            f.accounts.oauth.setSidebarOrder(serverId: f.serverId, userId: f.peerId, order: order)
            let reopened = try await client.send(.post, headers: f.headers(f.ownerToken), to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(f.peerId)\"}")
            }
            let reopenedBody = (try? JSONSerialization.jsonObject(with: Data((reopened.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(reopenedBody["id"] as? String == dmId)
            let after = f.accounts.oauth.sanitizedSidebarOrder(serverId: f.serverId, userId: f.peerId)
            #expect(after.hiddenDmIds.contains(dmId) == false)
        }
    }
}

@Test func dmCreationCannotBypassHiddenHumanDirectory() async throws {
    let f = CMFixture()
    f.accounts.setHideHumansFromMembers(serverId: f.serverId, hidden: true)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let blocked = try await client.send(.post, headers: f.headers(f.ownerToken), to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(f.peerId)\"}")
            }
            #expect(blocked.status == .notFound)
            let blockedBody = (try? JSONSerialization.jsonObject(with: Data((blocked.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(blockedBody["error"] as? String == "DM target not found")

            let selfDm = try await client.send(.post, headers: f.headers(f.ownerToken), to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(f.ownerId)\"}")
            }
            #expect(selfDm.status == .ok)

            let existing = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.peerId)
            f.accounts.addPostableChannel(serverId: f.serverId, channelId: existing, memberId: f.ownerId, kind: "dm", name: "dm")
            f.accounts.oauth.addChannelHuman(channelId: existing, userId: f.ownerId)
            f.accounts.oauth.addChannelHuman(channelId: existing, userId: f.peerId)
            let reopened = try await client.send(.post, headers: f.headers(f.ownerToken), to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(f.peerId)\"}")
            }
            #expect(reopened.status == .ok)
            let reopenedBody = (try? JSONSerialization.jsonObject(with: Data((reopened.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(reopenedBody["id"] as? String == existing)
        }
    }
}

@Test func messagePayloadCarriesAuthoritativeSenderMembershipStatus() async throws {
    let f = CMFixture()
    let channelId = f.accounts.oauth.createChannel(serverId: f.serverId, name: "all", creatorUserId: f.ownerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: channelId, memberId: f.ownerId, name: "all")
    f.accounts.oauth.addChannelHuman(channelId: channelId, userId: f.ownerId)
    f.accounts.oauth.addChannelHuman(channelId: channelId, userId: f.peerId)
    let messageId = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: messageId, channelId: channelId, senderId: f.peerId, content: "hello right after joining")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            func status() async throws -> String? {
                let response = try await client.get(URI(string: "/api/messages/channel/\(channelId)?limit=50"), headers: f.headers(f.ownerToken))
                #expect(response.status == .ok)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                let messages = body["messages"] as? [[String: Any]] ?? []
                return messages.first { $0["id"] as? String == messageId }?["senderMembershipStatus"] as? String
            }
            #expect(try await status() == "active")
            let removed = try await client.send(.delete, headers: f.headers(f.ownerToken), to: "/api/servers/\(f.serverId)/members/\(f.peerId)")
            #expect(removed.status == .ok)
            #expect(try await status() == "removed")
            f.accounts.oauth.addMember(serverId: f.serverId, userId: f.peerId, role: "member")
            #expect(try await status() == "active")
            let left = try await client.send(.post, headers: f.headers(f.peerToken), to: "/api/servers/\(f.serverId)/leave")
            #expect(left.status == .ok)
            #expect(try await status() == "left")
        }
    }
}

@Test func privateChannelCreatorLeavesEveryVisibilitySurface() async throws {
    let f = CMFixture()
    let channelId = f.accounts.oauth.createChannel(serverId: f.serverId, name: "private-room", creatorUserId: f.ownerId, type: "private")
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: channelId, memberId: f.ownerId, kind: "private", name: "private-room")
    f.accounts.oauth.addChannelHuman(channelId: channelId, userId: f.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let before = try await client.get(URI(string: "/api/channels"), headers: f.headers(f.ownerToken))
            let beforeRows = (try? JSONSerialization.jsonObject(with: Data((before.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            #expect(beforeRows.contains { $0["id"] as? String == channelId })
            let left = try await client.send(.post, headers: f.headers(f.ownerToken), to: "/api/channels/\(channelId)/leave")
            #expect(left.status == .ok)
            let after = try await client.get(URI(string: "/api/channels"), headers: f.headers(f.ownerToken))
            let afterRows = (try? JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            #expect(!afterRows.contains { $0["id"] as? String == channelId })
            let detail = try await client.get(URI(string: "/api/channels/\(channelId)"), headers: f.headers(f.ownerToken))
            #expect(detail.status == .notFound)
        }
    }
}

@Test func removingAgentFromAllWritesNoMembershipNotice() async throws {
    let f = CMFixture()
    let allId = f.accounts.oauth.createChannel(serverId: f.serverId, name: "all", creatorUserId: f.ownerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: allId, memberId: f.ownerId, name: "all")
    f.accounts.oauth.addChannelHuman(channelId: allId, userId: f.ownerId)
    let agentId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "AllBot", creatorUserId: f.ownerId, runtime: "claude")
    f.accounts.oauth.addChannelAgent(channelId: allId, agentId: agentId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: allId, memberId: agentId, name: "all")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            func messages() async throws -> [[String: Any]] {
                let response = try await client.get(URI(string: "/api/messages/channel/\(allId)?limit=200"), headers: f.headers(f.ownerToken))
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return body["messages"] as? [[String: Any]] ?? []
            }
            let before = try await messages()
            let remove = try await client.send(.delete, headers: f.headers(f.ownerToken), to: "/api/channels/\(allId)/members/agent/\(agentId)")
            #expect(remove.status == .ok)
            let after = try await messages()
            #expect(after.count == before.count, "removing an agent from #all must write no membership notice")
        }
    }
}
