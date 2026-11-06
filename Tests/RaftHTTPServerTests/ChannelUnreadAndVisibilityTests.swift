import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct UnreadVisibilityFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let ownerToken: String
    let peerId: String
    let peerToken: String
    let channelId: String
    let allChannelId: String
    let agentId: String
    let agentKey: String
}

private func makeUnreadVisibilityFixture(_ suffix: String) -> UnreadVisibilityFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001290\(suffix)"
    let peerId = "11111111-1111-4111-8111-000001291\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001290\(suffix)"
    let ownerEmail = "unread-owner-\(suffix)@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (peerId, "unread-peer-\(suffix)@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "unread-vis-\(suffix)", name: "Unread Visibility \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channelName = "unread-vis-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    for id in [ownerId, peerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, kind: "channel", name: channelName)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "UnreadVisBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    return UnreadVisibilityFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        peerId: peerId,
        peerToken: accounts.mintAccessTokenForTesting(userId: peerId),
        channelId: channelId,
        allChannelId: accounts.oauth.allChannelId(serverId: serverId) ?? "",
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "channels", "server"], name: "unread-vis-\(suffix)")
    )
}

private func unreadHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func unreadJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@discardableResult
private func unreadPost(
    _ client: any Client,
    _ f: UnreadVisibilityFixture,
    token: String,
    channelId: String,
    content: String
) async throws -> (id: String, seq: Int) {
    let response = try await client.send(.post, headers: unreadHeaders(token, f.serverId), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
    }
    let id = try #require(try unreadJSON(response)["id"] as? String)
    return (id, try #require(f.accounts.humanMessageSequence(id: id)))
}

private func unreadDM(_ client: any Client, f: UnreadVisibilityFixture) async throws -> String {
    let response = try await client.send(.post, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/dm") { request in
        request.body = .init(string: "{\"userId\":\"\(f.peerId)\"}")
    }
    return try #require(try unreadJSON(response)["id"] as? String)
}

private func unreadSetCursor(
    _ client: any Client,
    f: UnreadVisibilityFixture,
    channelId: String,
    seq: Int
) async throws {
    let response = try await client.send(.post, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/\(channelId)/read") { request in
        request.body = .init(string: "{\"seq\":\(seq)}")
    }
    #expect(response.status == .ok)
}

private func unreadMap(_ client: any Client, f: UnreadVisibilityFixture) async throws -> [String: Any] {
    let response = try await client.get(URI(string: "/api/channels/unread"), headers: unreadHeaders(f.ownerToken, f.serverId))
    #expect(response.status == .ok)
    #expect(response.headers[.cacheControl] == "private, no-store")
    return try unreadJSON(response)
}

@Test func channelUnreadExcludesTheCurrentUsersOwnMessages() async throws {
    let f = makeUnreadVisibilityFixture("901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await unreadPost(client, f, token: f.peerToken, channelId: f.channelId, content: "read baseline")
            _ = try await unreadPost(client, f, token: f.ownerToken, channelId: f.channelId, content: "own channel message")
            let dmId = try await unreadDM(client, f: f)
            _ = try await unreadPost(client, f, token: f.ownerToken, channelId: dmId, content: "own dm message")
            try await unreadSetCursor(client, f: f, channelId: f.channelId, seq: baseline.seq)

            let body = try await unreadMap(client, f: f)
            #expect(body[f.channelId] == nil, "own channel messages are never unread")
            #expect(body[dmId] == nil, "own DM messages are never unread")
        }
    }
}

@Test func channelUnreadRevisitsAPeerMessageBehindASelfAuthoredLatest() async throws {
    let f = makeUnreadVisibilityFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            _ = try await unreadPost(client, f, token: f.peerToken, channelId: f.channelId, content: "message to revisit")
            let ownChannelLatest = try await unreadPost(client, f, token: f.ownerToken, channelId: f.channelId, content: "own latest channel message")
            let dmId = try await unreadDM(client, f: f)
            _ = try await unreadPost(client, f, token: f.peerToken, channelId: dmId, content: "dm message to revisit")
            let ownDmLatest = try await unreadPost(client, f, token: f.ownerToken, channelId: dmId, content: "own latest dm message")
            try await unreadSetCursor(client, f: f, channelId: f.channelId, seq: ownChannelLatest.seq)
            try await unreadSetCursor(client, f: f, channelId: dmId, seq: ownDmLatest.seq)

            for channelId in [f.channelId, dmId] {
                let response = try await client.send(.post, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/\(channelId)/unread")
                #expect(response.status == .ok)
                let body = try unreadJSON(response)
                #expect(body["unreadCount"] as? Int == 1, "the prior peer message stays revisitable")
            }

            let map = try await unreadMap(client, f: f)
            #expect(map[f.channelId] as? Int == 1)
            #expect(map[dmId] as? Int == 1)
        }
    }
}

@Test func allChannelVisibilityIsManagedSeparately() async throws {
    let f = makeUnreadVisibilityFixture("903")
    f.accounts.oauth.setAgentRole(serverId: f.serverId, agentId: f.agentId, role: "admin")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let humanAttempt = try await client.send(.patch, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/\(f.allChannelId)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(humanAttempt.status == .forbidden)
            let humanBody = try unreadJSON(humanAttempt)
            #expect(humanBody["code"] as? String == "all_channel_visibility_managed_separately")
            #expect((humanBody["error"] as? String)?.contains("Only a human can do it, from channel settings or server settings") == true)

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(f.agentKey)"
            agentHeaders[.contentType] = "application/json"
            let agentAttempt = try await client.send(.patch, headers: agentHeaders, to: "/internal/agent-api/channels/\(f.allChannelId)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(agentAttempt.status == .forbidden)
            #expect(try unreadJSON(agentAttempt)["code"] as? String == "all_channel_visibility_managed_separately")

            // The human hide/restore round trip still works and changes the type.
            let hidden = try await client.send(.post, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/system/all/hide")
            #expect(hidden.status == .ok)
            let hiddenDetail = try await client.get(URI(string: "/api/channels/\(f.allChannelId)"), headers: unreadHeaders(f.ownerToken, f.serverId))
            #expect(try unreadJSON(hiddenDetail)["type"] as? String == "private")

            let restored = try await client.send(.post, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/system/all/restore")
            #expect(restored.status == .ok)
            let restoredDetail = try await client.get(URI(string: "/api/channels/\(f.allChannelId)"), headers: unreadHeaders(f.ownerToken, f.serverId))
            #expect(try unreadJSON(restoredDetail)["type"] as? String == "channel")
        }
    }
}

@Test func changingChannelVisibilityRequiresMembership() async throws {
    let f = makeUnreadVisibilityFixture("904")
    f.accounts.oauth.setAgentRole(serverId: f.serverId, agentId: f.agentId, role: "admin")
    // The peer creates the channel, so the server owner is deliberately not a member.
    let target = f.accounts.oauth.createChannel(serverId: f.serverId, name: "not-mine-904", creatorUserId: f.peerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: target, memberId: f.peerId, name: "not-mine-904")
    f.accounts.oauth.addChannelHuman(channelId: target, userId: f.peerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let ownerAttempt = try await client.send(.patch, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/\(target)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(ownerAttempt.status == .forbidden)
            #expect(try unreadJSON(ownerAttempt)["code"] as? String == "channel_membership_required")

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(f.agentKey)"
            agentHeaders[.contentType] = "application/json"
            let agentAttempt = try await client.send(.patch, headers: agentHeaders, to: "/internal/agent-api/channels/\(target)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(agentAttempt.status == .forbidden)
            #expect(try unreadJSON(agentAttempt)["code"] as? String == "channel_membership_required")

            // Membership alone is not the capability: the member peer is still refused.
            let peerAttempt = try await client.send(.patch, headers: unreadHeaders(f.peerToken, f.serverId), to: "/api/channels/\(target)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(peerAttempt.status == .forbidden, "an ordinary member lacks changeChannelVisibility")

            // Once the owner joins, the round trip works in both directions.
            f.accounts.addPostableChannel(serverId: f.serverId, channelId: target, memberId: f.ownerId, name: "not-mine-904")
            f.accounts.oauth.addChannelHuman(channelId: target, userId: f.ownerId)
            for visibility in ["private", "public"] {
                let response = try await client.send(.patch, headers: unreadHeaders(f.ownerToken, f.serverId), to: "/api/channels/\(target)") { request in
                    request.body = .init(string: "{\"visibility\":\"\(visibility)\"}")
                }
                #expect(response.status == .ok)
                #expect(try unreadJSON(response)["visibility"] as? String == visibility)
            }
            let detail = try await client.get(URI(string: "/api/channels/\(target)"), headers: unreadHeaders(f.ownerToken, f.serverId))
            #expect(try unreadJSON(detail)["type"] as? String == "channel")
        }
    }
}
