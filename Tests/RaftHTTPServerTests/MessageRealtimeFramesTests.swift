import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The transport authorizer every real-socket test in this file uses: the
/// in-memory ledger is the session, role and room-membership authority.
private struct RealtimeFramesAuth: RealtimeAuthorizing {
    let auth: AuthCoreService
    let membership: SocketMembershipService
    func userId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        membership.syncMessages(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)?.jsonBody()
    }
}

private struct RealtimeFramesFixture: Sendable {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111901"
    let memberId = "11111111-1111-4111-8111-111111111902"
    let outsiderId = "11111111-1111-4111-8111-111111111903"
    let serverId = "33333333-3333-4333-8333-333333333901"

    init() {
        for (id, email) in [
            (ownerId, "realtime-frames-owner@slock.test"),
            (memberId, "realtime-frames-member@slock.test"),
            (outsiderId, "realtime-frames-outsider@slock.test"),
        ] {
            accounts.addAccount(id: id, email: email, password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "realtime-frames", name: "Realtime Frames", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
        accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    }

    var auth: RealtimeFramesAuth {
        RealtimeFramesAuth(auth: accounts.authCore, membership: accounts.socketMembership)
    }

    var ownerToken: String { accounts.mintAccessTokenForTesting(userId: ownerId) }
    var memberToken: String { accounts.mintAccessTokenForTesting(userId: memberId) }
    var outsiderToken: String { accounts.mintAccessTokenForTesting(userId: outsiderId) }

    func headers(_ token: String) -> HTTPFields {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        fields[.authorization] = "Bearer \(token)"
        fields[HTTPField.Name("X-Server-Id")!] = serverId
        return fields
    }

    /// A public channel whose owner and member may both post; the outsider is a
    /// server member who has not joined it.
    func addChannel(name: String) -> String {
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId)
        for id in [ownerId, memberId] {
            accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: name)
        }
        return channelId
    }

    /// A human-to-human DM; both participants are postable rows.
    func addDirectMessage() -> String {
        let channelId = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: ownerId, secondUserId: memberId
        )
        for id in [ownerId, memberId] {
            accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
            accounts.addPostableChannel(
                serverId: serverId, channelId: channelId, memberId: id, kind: "dm", name: "dm"
            )
        }
        return channelId
    }

    /// A managed agent that can post in the channel through the legacy machine
    /// send route. Returns `(agentId, machineKey)`.
    func addAgent(channelId: String, channelName: String, name: String) -> (agentId: String, machineKey: String) {
        let agentId = accounts.oauth.createAgent(
            serverId: serverId, name: name, creatorUserId: ownerId, runtime: "managed"
        )
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        accounts.addPostableChannel(
            serverId: serverId, channelId: channelId, memberId: agentId, name: channelName
        )
        return (agentId, accounts.registerMachineForAgent(serverId: serverId, agentId: agentId))
    }
}

private func realtimeFramesConnect(
    _ fixture: RealtimeFramesFixture,
    server: RealtimeServer,
    userId: String
) async throws -> SocketIOTestClient {
    let client = try await SocketIOTestClient(port: server.port)
    _ = try #require(await client.waitForText { $0.hasPrefix("0") })
    let token = fixture.accounts.mintAccessTokenForTesting(userId: userId)
    client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(fixture.serverId)\"}")
    _ = try #require(await client.waitForText { $0 == "42[\"rooms:joined\"]" })
    return client
}

private func realtimeFramesInstall(_ fixture: RealtimeFramesFixture, hub: RealtimeHub) {
    fixture.accounts.realtimeRelay.install { room, event, payload in
        hub.emit(room: room, event: event, payloadJSON: payload)
    }
    fixture.accounts.realtimeRelay.installRoomJoiner { userId, room in
        hub.joinUserSessions(userId: userId, room: room)
    }
    fixture.accounts.realtimeRelay.installServerRoomJoiner { userId, serverId, room in
        hub.joinUserSessions(userId: userId, serverId: serverId, room: room)
    }
}

private func realtimeFramesBody(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func realtimeFramesObject(_ body: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
}

/// One `42["event",payload]` frame.
private func realtimeFramesEvent(_ frame: String) throws -> (event: String, payload: [String: Any]) {
    let array = try #require(try JSONSerialization.jsonObject(with: Data(frame.dropFirst(2).utf8)) as? [Any])
    return (
        try #require(array.first as? String),
        try #require(array.count == 2 ? array[1] as? [String: Any] : nil)
    )
}

private func realtimeFramesPOST(
    _ client: any Client,
    path: String,
    body: String,
    headers: HTTPFields
) async throws -> ClientResponse {
    try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private let realtimeCanonicalKeys: Set<String> = [
    "id", "seq", "channelId", "senderType", "senderId", "randomId", "messageType", "content",
    "actionMetadata", "threadId", "taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId",
    "taskClaimedAt", "taskCompletedAt", "createdAt", "updatedAt", "senderName", "senderDescription",
    "senderMembershipStatus", "attachments", "mentions", "reactions", "commentRef", "externalAuthor",
]

private let realtimeStorageOnlyKeys: Set<String> = [
    "agentSendKey", "searchText", "searchVector", "senderHandle", "serverId", "senderTimezone",
]

private func realtimeFramesAssertMessage(
    _ payload: [String: Any],
    channelId: String,
    senderId: String,
    senderType: String,
    content: String
) {
    #expect(Set(payload.keys) == realtimeCanonicalKeys.union(["conversationContext"]))
    #expect(realtimeStorageOnlyKeys.isDisjoint(with: Set(payload.keys)))
    #expect(payload["channelId"] as? String == channelId)
    #expect(payload["senderId"] as? String == senderId)
    #expect(payload["senderType"] as? String == senderType)
    #expect(payload["messageType"] as? String == "chat")
    #expect(payload["content"] as? String == content)
    #expect(payload["seq"] is Int)
    #expect(payload["threadId"] is NSNull)
    #expect(payload["actionMetadata"] is NSNull)
    #expect((payload["reactions"] as? [Any])?.isEmpty == true)
    #expect(payload["commentRef"] is NSNull)
    #expect(payload["externalAuthor"] is NSNull)
}

/// The upstream `syncCoreReplyWindow` envelope carried by `thread:updated`
/// (`packages/shared/src/discussionGraph.ts`, `buildThreadRepliesSyncWindow`).
private func realtimeFramesAssertSyncWindow(
    _ payload: [String: Any],
    serverId: String,
    parentChannelId: String,
    parentMessageId: String
) throws {
    let envelope = try #require(payload["syncCoreReplyWindow"] as? [String: Any])
    #expect(Set(envelope.keys) == ["producer", "discussion", "window"])
    #expect(envelope["producer"] as? String == "message-service.thread-replies-window.v1")
    let discussion = try #require(envelope["discussion"] as? [String: Any])
    #expect(Set(discussion.keys) == ["root", "relation", "parentScopeKey", "backing"])
    let root = try #require(discussion["root"] as? [String: Any])
    #expect(Set(root.keys) == ["kind", "serverId", "id"])
    #expect(root["kind"] as? String == "message")
    #expect(root["serverId"] as? String == serverId)
    #expect(root["id"] as? String == parentMessageId)
    let relation = try #require(discussion["relation"] as? [String: Any])
    #expect(relation["kind"] as? String == "replies")
    let scopeKey = try #require(discussion["parentScopeKey"] as? [String: Any])
    #expect(Set(scopeKey.keys) == ["serverId", "scopeKind", "scopeId"])
    #expect(scopeKey["serverId"] as? String == serverId)
    #expect(scopeKey["scopeKind"] as? String == "channel")
    #expect(scopeKey["scopeId"] as? String == parentChannelId)
    #expect(discussion["backing"] as? String == "sync-scope")
    let window = try #require(envelope["window"] as? [String: Any])
    #expect(Set(window.keys) == ["kind", "scopeCursor", "epoch"])
    #expect(window["kind"] as? String == "sync-scope-window")
    #expect(window["scopeCursor"] is NSNull)
    #expect(window["epoch"] is NSNull)
}

@Suite(.serialized)
struct MessageRealtimeFramesTests {
    /// The first reply of `POST /api/channels/:channelId/threads` is an ordinary
    /// message post upstream (`broadcastAndDeliver`): it records the sender and
    /// parent-author follows, joins every eligible follower to the thread room
    /// before publishing `message:new`, and then publishes the parent's
    /// `thread:updated` summary with the new reply count.
    @Test func threadCreationFirstReplyJoinsParentAuthorAndEmitsThreadUpdate() async throws {
        let fixture = RealtimeFramesFixture()
        let channelId = fixture.addChannel(name: "thread-first-reply")
        let parentId = fixture.accounts.addChannelMessageForTesting(
            channelId: channelId, content: "thread first reply parent", senderId: fixture.ownerId
        )
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let ownerSocket = try await realtimeFramesConnect(fixture, server: realtime, userId: fixture.ownerId)
        let memberSocket = try await realtimeFramesConnect(fixture, server: realtime, userId: fixture.memberId)
        defer {
            ownerSocket.close()
            memberSocket.close()
            Task { try? await realtime.close() }
        }
        realtimeFramesInstall(fixture, hub: realtime.hub)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let created = try await realtimeFramesPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\",\"content\":\"first reply body\"}",
                    headers: fixture.headers(fixture.memberToken)
                )
                #expect(created.status == .ok, "\(realtimeFramesBody(created))")
                let createdBody = try realtimeFramesObject(realtimeFramesBody(created))
                #expect(Set(createdBody.keys) == ["threadChannelId", "replyCount", "lastReplyAt", "participantIds"])
                let threadId = try #require(createdBody["threadChannelId"] as? String)
                #expect(createdBody["replyCount"] as? Int == 1)
                #expect(createdBody["participantIds"] as? [String] == [fixture.memberId])
                let responseLastReplyAt = try #require(createdBody["lastReplyAt"] as? String)
                #expect(responseLastReplyAt.hasSuffix("Z"))

                // The parent author was never in the thread room: only the
                // follow-before-broadcast join can deliver the first reply.
                let messageFrame = try #require(await ownerSocket.waitForText {
                    $0.hasPrefix(#"42["message:new""#) && $0.contains("\"first reply body\"")
                })
                let message = try realtimeFramesEvent(messageFrame)
                #expect(message.event == "message:new")
                realtimeFramesAssertMessage(
                    message.payload, channelId: threadId,
                    senderId: fixture.memberId, senderType: "user", content: "first reply body"
                )
                let context = try #require(message.payload["conversationContext"] as? [String: Any])
                #expect(Set(context.keys) == ["channelType", "parentChannelId", "parentMessageId", "parentChannelType"])
                #expect(context["channelType"] as? String == "thread")
                #expect(context["parentChannelId"] as? String == channelId)
                #expect(context["parentMessageId"] as? String == parentId)
                #expect(context["parentChannelType"] as? String == "channel")

                let updateFrame = try #require(await ownerSocket.waitForText {
                    $0.hasPrefix(#"42["thread:updated""#)
                })
                let update = try realtimeFramesEvent(updateFrame)
                #expect(update.payload["parentMessageId"] as? String == parentId)
                #expect(update.payload["threadChannelId"] as? String == threadId)
                #expect(update.payload["replyCount"] as? Int == 1)
                #expect(update.payload["lastReplyAt"] as? String == responseLastReplyAt)
                #expect(update.payload["participantIds"] as? [String] == [fixture.memberId])
                try realtimeFramesAssertSyncWindow(
                    update.payload, serverId: fixture.serverId,
                    parentChannelId: channelId, parentMessageId: parentId
                )
                let latest = try #require(update.payload["latestReply"] as? [String: Any])
                #expect(Set(latest.keys) == realtimeCanonicalKeys.union([
                    "conversationContext", "senderDisplayName", "senderAvatarUrl",
                ]))
                #expect(latest["id"] as? String == message.payload["id"] as? String)
                #expect(latest["seq"] as? Int == message.payload["seq"] as? Int)
                #expect(latest["content"] as? String == "first reply body")
                #expect(latest["channelId"] as? String == threadId)
                #expect(latest["senderId"] as? String == fixture.memberId)
                #expect(latest["senderDisplayName"] as? String == "realtime-frames-member")
                #expect(latest["senderAvatarUrl"] is NSNull)
                let latestContext = try #require(latest["conversationContext"] as? [String: Any])
                #expect(latestContext["parentMessageId"] as? String == parentId)

                // `message:new` precedes the parent summary frame.
                let frames = ownerSocket.textFrames
                let messageIndex = try #require(frames.firstIndex(of: messageFrame))
                let updateIndex = try #require(frames.firstIndex(of: updateFrame))
                #expect(messageIndex < updateIndex)

                // The create response and the thread-info read publish the same
                // retained summary; `messageId` is not part of the upstream body.
                let info = try await client.get(
                    URI(string: "/api/channels/\(channelId)/threads/\(parentId)"),
                    headers: fixture.headers(fixture.memberToken)
                )
                #expect(info.status == .ok)
                let infoBody = try realtimeFramesObject(realtimeFramesBody(info))
                #expect(infoBody["threadChannelId"] as? String == threadId)
                #expect(infoBody["replyCount"] as? Int == 1)
                #expect(infoBody["lastReplyAt"] as? String == responseLastReplyAt)
                #expect(Set(fixture.accounts.threadFollowerIdsForTesting(threadChannelId: threadId))
                    == Set([fixture.ownerId, fixture.memberId]))
            }
        }
    }

    /// The first reply is an ordinary post, so the parent's posting gate runs
    /// before the thread row exists: a non-member cannot post and leaves no
    /// thread behind, and over-length content is refused before materialization.
    @Test func threadCreationAppliesThePostingGateBeforeMaterializing() async throws {
        let fixture = RealtimeFramesFixture()
        let channelId = fixture.addChannel(name: "thread-first-reply-gate")
        let parentId = fixture.accounts.addChannelMessageForTesting(
            channelId: channelId, content: "gated first reply parent", senderId: fixture.ownerId
        )
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        defer { Task { try? await realtime.close() } }
        realtimeFramesInstall(fixture, hub: realtime.hub)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let outsider = try await realtimeFramesPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\",\"content\":\"reply from a non-member\"}",
                    headers: fixture.headers(fixture.outsiderToken)
                )
                #expect(outsider.status == .forbidden)
                #expect(try realtimeFramesBody(outsider) == #"{"error":"You must join this channel to send messages"}"#)
                #expect(!fixture.accounts.serversAndChannelsStore.state.postableChannels.values.contains {
                    $0.kind == "thread" && $0.parentMessageId == parentId
                })

                let long = try await realtimeFramesPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\",\"content\":\"\(String(repeating: "x", count: 32_001))\"}",
                    headers: fixture.headers(fixture.memberToken)
                )
                #expect(long.status == .badRequest)
                #expect(try realtimeFramesBody(long)
                    == #"{"error":"Message content exceeds maximum length of 32000 characters"}"#)
                #expect(!fixture.accounts.serversAndChannelsStore.state.postableChannels.values.contains {
                    $0.kind == "thread" && $0.parentMessageId == parentId
                })
            }
        }
    }

    /// Threads are not parents: a caller who can see a thread gets the
    /// published nested-thread refusal instead of a thread under a thread.
    @Test func threadCreationRefusesANestedThread() async throws {
        let fixture = RealtimeFramesFixture()
        let channelId = fixture.addChannel(name: "thread-nested-refusal")
        let parentId = fixture.accounts.addChannelMessageForTesting(
            channelId: channelId, content: "nested thread parent", senderId: fixture.ownerId
        )
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let created = try await realtimeFramesPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\"}",
                    headers: fixture.headers(fixture.ownerToken)
                )
                #expect(created.status == .ok)
                let threadId = try #require(
                    try realtimeFramesObject(realtimeFramesBody(created))["threadChannelId"] as? String
                )
                let nested = try await realtimeFramesPOST(
                    client, path: "/api/channels/\(threadId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\"}",
                    headers: fixture.headers(fixture.ownerToken)
                )
                #expect(nested.status == .badRequest)
                #expect(try realtimeFramesBody(nested)
                    == #"{"error":"Cannot create a thread inside a thread"}"#)
            }
        }
    }

    /// The legacy machine send is the same upstream `broadcastAndDeliver`
    /// pipeline as a normal post: it records the reply follows, joins the
    /// thread's human followers before `message:new`, and publishes the
    /// parent's `thread:updated` summary.
    @Test func legacyAgentSendEmitsCanonicalThreadFrames() async throws {
        let fixture = RealtimeFramesFixture()
        let channelName = "legacy-send-thread"
        let channelId = fixture.addChannel(name: channelName)
        let parentId = fixture.accounts.addChannelMessageForTesting(
            channelId: channelId, content: "legacy send parent", senderId: fixture.ownerId
        )
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let ownerSocket = try await realtimeFramesConnect(fixture, server: realtime, userId: fixture.ownerId)
        defer {
            ownerSocket.close()
            Task { try? await realtime.close() }
        }
        realtimeFramesInstall(fixture, hub: realtime.hub)
        let agent = fixture.addAgent(channelId: channelId, channelName: channelName, name: "LegacySender")

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let created = try await realtimeFramesPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\"}",
                    headers: fixture.headers(fixture.ownerToken)
                )
                #expect(created.status == .ok)
                let threadId = try #require(
                    try realtimeFramesObject(realtimeFramesBody(created))["threadChannelId"] as? String
                )

                var agentHeaders = HTTPFields()
                agentHeaders[.contentType] = "application/json"
                agentHeaders[.authorization] = "Bearer \(agent.machineKey)"
                let sent = try await realtimeFramesPOST(
                    client, path: "/internal/agent/\(agent.agentId)/send",
                    body: "{\"target\":\"#\(channelName):\(parentId.prefix(8))\",\"content\":\"legacy agent reply\"}",
                    headers: agentHeaders
                )
                #expect(sent.status == .ok, "\(realtimeFramesBody(sent))")
                let sentBody = try realtimeFramesObject(realtimeFramesBody(sent))
                #expect(sentBody["ok"] as? Bool == true)
                #expect(sentBody["state"] as? String == "sent")
                let messageId = try #require(sentBody["messageId"] as? String)

                // The parent author is followed by the reply path and joined
                // before the broadcast, so this socket receives the frame.
                let messageFrame = try #require(await ownerSocket.waitForText {
                    $0.hasPrefix(#"42["message:new""#) && $0.contains("\"legacy agent reply\"")
                })
                let message = try realtimeFramesEvent(messageFrame)
                realtimeFramesAssertMessage(
                    message.payload, channelId: threadId,
                    senderId: agent.agentId, senderType: "agent", content: "legacy agent reply"
                )
                #expect(message.payload["id"] as? String == messageId)
                #expect(message.payload["senderName"] as? String == "LegacySender")
                #expect(message.payload["senderMembershipStatus"] is NSNull)
                let context = try #require(message.payload["conversationContext"] as? [String: Any])
                #expect(context["channelType"] as? String == "thread")
                #expect(context["parentMessageId"] as? String == parentId)

                let updateFrame = try #require(await ownerSocket.waitForText {
                    $0.hasPrefix(#"42["thread:updated""#)
                })
                let update = try realtimeFramesEvent(updateFrame)
                #expect(update.payload["parentMessageId"] as? String == parentId)
                #expect(update.payload["replyCount"] as? Int == 1)
                let latest = try #require(update.payload["latestReply"] as? [String: Any])
                #expect(latest["id"] as? String == messageId)
                #expect(latest["senderType"] as? String == "agent")
                #expect(latest["senderDisplayName"] as? String == "LegacySender")
                try realtimeFramesAssertSyncWindow(
                    update.payload, serverId: fixture.serverId,
                    parentChannelId: channelId, parentMessageId: parentId
                )
            }
        }
    }

    /// A DM send joins both participants' sockets and publishes `message:new`
    /// with the DM context plus the list-refresh `dm:new` frame.
    @Test func legacyAgentDMSendEmitsMessageAndDmNew() async throws {
        let fixture = RealtimeFramesFixture()
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let ownerSocket = try await realtimeFramesConnect(fixture, server: realtime, userId: fixture.ownerId)
        defer {
            ownerSocket.close()
            Task { try? await realtime.close() }
        }
        realtimeFramesInstall(fixture, hub: realtime.hub)
        let agent = fixture.addAgent(channelId: fixture.addChannel(name: "legacy-send-dm"), channelName: "legacy-send-dm", name: "DmSender")

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                var agentHeaders = HTTPFields()
                agentHeaders[.contentType] = "application/json"
                agentHeaders[.authorization] = "Bearer \(agent.machineKey)"
                let sent = try await realtimeFramesPOST(
                    client, path: "/internal/agent/\(agent.agentId)/send",
                    body: "{\"target\":\"dm:@realtime-frames-owner\",\"content\":\"legacy dm reply\"}",
                    headers: agentHeaders
                )
                #expect(sent.status == .ok, "\(realtimeFramesBody(sent))")
                let sentBody = try realtimeFramesObject(realtimeFramesBody(sent))
                let messageId = try #require(sentBody["messageId"] as? String)
                let channelId = try #require(
                    fixture.accounts.messageChannelIdForTesting(messageId: messageId)
                )

                let messageFrame = try #require(await ownerSocket.waitForText {
                    $0.hasPrefix(#"42["message:new""#) && $0.contains("\"legacy dm reply\"")
                })
                let message = try realtimeFramesEvent(messageFrame)
                realtimeFramesAssertMessage(
                    message.payload, channelId: channelId,
                    senderId: agent.agentId, senderType: "agent", content: "legacy dm reply"
                )
                let context = try #require(message.payload["conversationContext"] as? [String: Any])
                #expect(Set(context.keys) == ["channelType"])
                #expect(context["channelType"] as? String == "dm")

                let dmFrame = try #require(await ownerSocket.waitForText {
                    $0.hasPrefix(#"42["dm:new""#)
                })
                let dm = try realtimeFramesEvent(dmFrame)
                #expect(dm.event == "dm:new")
                #expect(dm.payload["channelId"] as? String == channelId)
            }
        }
    }

    /// An ordinary human thread reply publishes the parent summary frame with
    /// the canonical latest-reply projection.
    @Test func humanThreadReplyEmitsThreadUpdatedOnParent() async throws {
        let fixture = RealtimeFramesFixture()
        let channelId = fixture.addChannel(name: "human-thread-update")
        let parentId = fixture.accounts.addChannelMessageForTesting(
            channelId: channelId, content: "human thread update parent", senderId: fixture.ownerId
        )
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let ownerSocket = try await realtimeFramesConnect(fixture, server: realtime, userId: fixture.ownerId)
        defer {
            ownerSocket.close()
            Task { try? await realtime.close() }
        }
        realtimeFramesInstall(fixture, hub: realtime.hub)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let created = try await realtimeFramesPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\"}",
                    headers: fixture.headers(fixture.ownerToken)
                )
                #expect(created.status == .ok)
                let threadId = try #require(
                    try realtimeFramesObject(realtimeFramesBody(created))["threadChannelId"] as? String
                )
                let sent = try await realtimeFramesPOST(
                    client, path: "/api/messages",
                    body: "{\"channelId\":\"\(threadId)\",\"content\":\"human thread reply\"}",
                    headers: fixture.headers(fixture.memberToken)
                )
                #expect(sent.status == .ok, "\(realtimeFramesBody(sent))")
                let sentId = try #require(try realtimeFramesObject(realtimeFramesBody(sent))["id"] as? String)

                let updateFrame = try #require(await ownerSocket.waitForText {
                    $0.hasPrefix(#"42["thread:updated""#)
                })
                let update = try realtimeFramesEvent(updateFrame)
                #expect(update.payload["parentMessageId"] as? String == parentId)
                #expect(update.payload["threadChannelId"] as? String == threadId)
                #expect(update.payload["replyCount"] as? Int == 1)
                let latest = try #require(update.payload["latestReply"] as? [String: Any])
                #expect(latest["id"] as? String == sentId)
                #expect(latest["content"] as? String == "human thread reply")
                #expect(latest["senderDisplayName"] as? String == "realtime-frames-member")
            }
        }
    }

    /// A human DM send refreshes the DM list: upstream publishes `dm:new` to the
    /// channel room and each participant's user room after `message:new`.
    @Test func humanDMSendEmitsDmNew() async throws {
        let fixture = RealtimeFramesFixture()
        let dmId = fixture.addDirectMessage()
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let ownerSocket = try await realtimeFramesConnect(fixture, server: realtime, userId: fixture.ownerId)
        let memberSocket = try await realtimeFramesConnect(fixture, server: realtime, userId: fixture.memberId)
        defer {
            ownerSocket.close()
            memberSocket.close()
            Task { try? await realtime.close() }
        }
        realtimeFramesInstall(fixture, hub: realtime.hub)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let sent = try await realtimeFramesPOST(
                    client, path: "/api/messages",
                    body: "{\"channelId\":\"\(dmId)\",\"content\":\"human dm body\"}",
                    headers: fixture.headers(fixture.ownerToken)
                )
                #expect(sent.status == .ok, "\(realtimeFramesBody(sent))")
                for socket in [ownerSocket, memberSocket] {
                    let messageFrame = try #require(await socket.waitForText {
                        $0.hasPrefix(#"42["message:new""#) && $0.contains("\"human dm body\"")
                    })
                    let message = try realtimeFramesEvent(messageFrame)
                    #expect(message.payload["channelId"] as? String == dmId)
                    let dmFrame = try #require(await socket.waitForText {
                        $0.hasPrefix(#"42["dm:new""#)
                    })
                    let dm = try realtimeFramesEvent(dmFrame)
                    #expect(dm.event == "dm:new")
                    #expect(dm.payload["channelId"] as? String == dmId)
                }
            }
        }
    }
}
