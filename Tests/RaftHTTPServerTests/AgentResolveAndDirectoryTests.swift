import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ResolveFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let agentId: String
    let agentName: String
    let readKey: String
    let sendKey: String
    let channelId: String
    let channelName: String
    let privateChannelId: String
}

private func makeResolveFixture(_ suffix: String) -> ResolveFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001260\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001260\(suffix)"
    let ownerName = "resolve-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "resolve-\(suffix)", name: "Resolve \(suffix)", ownerId: ownerId)
    let channelName = "resolve-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let privateChannelId = accounts.oauth.createChannel(serverId: serverId, name: "resolve-private-\(suffix)", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: "resolve-private-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: ownerId)
    let agentName = "ResolveBot\(suffix)"
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    return ResolveFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        agentId: agentId,
        agentName: agentName,
        readKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "resolve-\(suffix)"),
        sendKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["send"], name: "resolve-send-\(suffix)"),
        channelId: channelId,
        channelName: channelName,
        privateChannelId: privateChannelId
    )
}

private func resolveGet(
    _ client: any Client,
    key: String,
    path: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    let response = try await client.get(URI(string: path), headers: headers)
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func agentMessageResolveReturnsTheTypedEnvelopeForShortIdsAndDMs() async throws {
    let f = makeResolveFixture("901")
    let humanMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: humanMessage, channelId: f.channelId, senderId: f.ownerId, content: "agent-api resolve target")
    let dmId = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.agentId)
    for member in [f.ownerId, f.agentId] {
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: dmId, memberId: member, kind: "dm", name: "dm")
    }
    f.accounts.oauth.addChannelHuman(channelId: dmId, userId: f.agentId)
    let dmMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: dmMessage, channelId: dmId, senderId: f.agentId, content: "agent to human dm target", senderType: "agent")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let resolved = try await resolveGet(client, key: f.readKey, path: "/internal/agent-api/messages/\(String(humanMessage.prefix(8)))/resolve")
            #expect(resolved.status == .ok)
            let message = try #require(resolved.body["message"] as? [String: Any])
            #expect(message["message_id"] as? String == humanMessage)
            #expect(message["channel_name"] as? String == f.channelName)
            #expect(message["channel_type"] as? String == "channel")
            #expect(message["sender_type"] as? String == "human")
            #expect(message["content"] as? String == "agent-api resolve target")

            let dmResolved = try await resolveGet(client, key: f.readKey, path: "/internal/agent-api/messages/\(String(dmMessage.prefix(8)))/resolve")
            #expect(dmResolved.status == .ok)
            let dmBody = try #require(dmResolved.body["message"] as? [String: Any])
            #expect(dmBody["channel_type"] as? String == "dm")
            #expect(dmBody["channel_name"] as? String == f.ownerName)

            let denied = try await resolveGet(client, key: f.sendKey, path: "/internal/agent-api/messages/\(String(humanMessage.prefix(8)))/resolve")
            #expect(denied.status == .forbidden)
            #expect(denied.body["code"] as? String == "capability_not_authorized")
        }
    }
}

@Test func agentMessageResolveComputesAmbiguityOnlyAcrossVisibleMessages() async throws {
    let f = makeResolveFixture("902")
    f.accounts.insertHumanMessage(
        id: "bbbbbbbb-1111-4111-8111-111111111111",
        channelId: f.privateChannelId,
        senderId: f.ownerId,
        content: "private resolve collision one"
    )
    f.accounts.insertHumanMessage(
        id: "bbbbbbbb-2222-4222-8222-222222222222",
        channelId: f.privateChannelId,
        senderId: f.ownerId,
        content: "private resolve collision two"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let inaccessible = try await resolveGet(client, key: f.readKey, path: "/internal/agent-api/messages/bbbbbbbb/resolve")
            #expect(inaccessible.status == .notFound)
            #expect(inaccessible.body["errorCode"] as? String == "NOT_FOUND")
            #expect((inaccessible.body["error"] as? String)?.contains("Message not found") == true)

            let visible = "bbbbbbbb-3333-4333-8333-333333333333"
            f.accounts.insertHumanMessage(id: visible, channelId: f.channelId, senderId: f.ownerId, content: "visible resolve collision")
            let resolved = try await resolveGet(client, key: f.readKey, path: "/internal/agent-api/messages/bbbbbbbb/resolve")
            #expect(resolved.status == .ok)
            let message = try #require(resolved.body["message"] as? [String: Any])
            #expect(message["message_id"] as? String == visible)
            #expect(message["content"] as? String == "visible resolve collision")
        }
    }
}

@Test func agentChannelMembersListsTheBoundRunnerDirectory() async throws {
    let f = makeResolveFixture("903")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let encoded = "#\(f.channelName)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let result = try await resolveGet(client, key: f.readKey, path: "/internal/agent-api/channel-members?channel=\(encoded)")
            #expect(result.status == .ok)
            let channel = try #require(result.body["channel"] as? [String: Any])
            #expect(channel["ref"] as? String == "#\(f.channelName)")
            #expect(channel["type"] as? String == "channel")
            let agents = try #require(result.body["agents"] as? [[String: Any]])
            let ownAgent = try #require(agents.first { $0["name"] as? String == f.agentName })
            // Upstream `toServerInfoAgentSummary` serves the stored `a.status`.
            #expect(ownAgent["status"] as? String == "inactive")
            f.accounts.oauth.setAgentStatus(id: f.agentId, status: "stopped")
            let stopped = try await resolveGet(client, key: f.readKey, path: "/internal/agent-api/channel-members?channel=\(encoded)")
            let stoppedAgent = try #require((stopped.body["agents"] as? [[String: Any]] ?? []).first { $0["name"] as? String == f.agentName })
            #expect(stoppedAgent["status"] as? String == "stopped")
            let humans = try #require(result.body["humans"] as? [[String: Any]])
            let ownHuman = try #require(humans.first { $0["name"] as? String == f.ownerName })
            #expect(ownHuman["role"] as? String == "owner")
        }
    }
}

@Test func agentThreadListReturnsOnlyActiveVisibleFollows() async throws {
    let f = makeResolveFixture("904")
    func thread(_ parentId: String, channelId: String) -> String {
        f.accounts.insertHumanMessage(id: parentId, channelId: channelId, senderId: f.ownerId, content: "thread parent \(parentId.prefix(4))")
        let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parentId)
        f.accounts.addPostableChannel(
            serverId: f.serverId,
            channelId: threadId,
            memberId: f.ownerId,
            kind: "thread",
            parentChannelId: channelId,
            parentMessageId: parentId,
            name: "thread"
        )
        return threadId
    }
    let activeParent = UUID().uuidString.lowercased()
    let activeThread = thread(activeParent, channelId: f.channelId)
    let unfollowedParent = UUID().uuidString.lowercased()
    let unfollowedThread = thread(unfollowedParent, channelId: f.channelId)
    let otherParent = UUID().uuidString.lowercased()
    let otherThread = thread(otherParent, channelId: f.channelId)
    let hiddenParent = UUID().uuidString.lowercased()
    let hiddenThread = thread(hiddenParent, channelId: f.privateChannelId)
    let followedAt = Date(timeIntervalSince1970: 1_789_070_400) // 2026-09-10T12:00:00Z
    f.accounts.followThreadForAgentTesting(
        serverId: f.serverId,
        agentId: f.agentId,
        threadChannelId: activeThread,
        parentMessageId: activeParent,
        reason: "manual",
        followedAt: followedAt
    )
    f.accounts.followThreadForAgentTesting(
        serverId: f.serverId,
        agentId: f.agentId,
        threadChannelId: unfollowedThread,
        parentMessageId: unfollowedParent,
        reason: "mentioned",
        followedAt: followedAt.addingTimeInterval(-3600),
        unfollowedAt: followedAt.addingTimeInterval(-1800)
    )
    f.accounts.followThreadForAgentTesting(
        serverId: f.serverId,
        agentId: f.agentId,
        threadChannelId: hiddenThread,
        parentMessageId: hiddenParent,
        reason: "manual",
        followedAt: followedAt.addingTimeInterval(3600)
    )
    let otherAgent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "OtherFollowBot\(904)", creatorUserId: f.ownerId, runtime: "claude")
    f.accounts.oauth.addChannelAgent(channelId: f.channelId, agentId: otherAgent)
    f.accounts.followThreadForAgentTesting(
        serverId: f.serverId,
        agentId: otherAgent,
        threadChannelId: otherThread,
        parentMessageId: otherParent,
        reason: "manual",
        followedAt: followedAt
    )

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let result = try await resolveGet(client, key: f.readKey, path: "/internal/agent-api/threads")
            #expect(result.status == .ok)
            let threads = try #require(result.body["threads"] as? [[String: Any]])
            #expect(threads.count == 1)
            let row = try #require(threads.first)
            #expect(row["target"] as? String == "#\(f.channelName):\(activeParent.prefix(8))")
            #expect(row["threadChannelId"] as? String == activeThread)
            #expect(row["parentChannelRef"] as? String == "#\(f.channelName)")
            #expect(row["parentMessageId"] as? String == activeParent)
            #expect(row["parentMessageShortId"] as? String == String(activeParent.prefix(8)))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(row["followedAt"] as? String == formatter.string(from: followedAt))
            #expect(row["reason"] as? String == "manual")
            #expect(row["doneAt"] == nil || row["doneAt"] is NSNull)
        }
    }
}
