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
private struct MessagePayloadAuth: RealtimeAuthorizing {
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

/// The canonical manifest key set (`packages/shared/src/canonicalMessageManifest.ts`)
/// plus `updatedAt`, which the producer emits but no canonical client consumes,
/// plus the task-domain projection keys the producer spreads from the row.
private let canonicalMessageKeys: Set<String> = [
    "id", "seq", "channelId", "senderType", "senderId", "randomId", "messageType", "content",
    "actionMetadata", "threadId", "taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId",
    "taskClaimedAt", "taskCompletedAt", "createdAt", "updatedAt", "senderName", "senderDescription",
    "senderMembershipStatus", "attachments", "mentions", "reactions", "commentRef", "externalAuthor",
]

private let storageOnlyMessageKeys: Set<String> = [
    "agentSendKey", "searchText", "searchVector", "senderHandle", "serverId", "senderTimezone",
]

private struct MessagePayloadFixture: Sendable {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111651"
    let peerId = "11111111-1111-4111-8111-111111111652"
    let serverId = "33333333-3333-4333-8333-333333333677"

    init() {
        for (id, email) in [(ownerId, "wire-owner@message-payload.test"), (peerId, "wire-peer@message-payload.test")] {
            accounts.addAccount(id: id, email: email, password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "message-payload", name: "Message Payload", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    }

    var auth: MessagePayloadAuth {
        MessagePayloadAuth(auth: accounts.authCore, membership: accounts.socketMembership)
    }

    var ownerToken: String { accounts.mintAccessTokenForTesting(userId: ownerId) }

    func headers(_ token: String) -> HTTPFields {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        fields[.authorization] = "Bearer \(token)"
        fields[HTTPField.Name("X-Server-Id")!] = serverId
        return fields
    }

    /// A regular channel whose two human participants can both post.
    func addChannel(name: String) -> String {
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: peerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: name)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: peerId, name: name)
        return channelId
    }

    /// A human-to-human DM. The OAuth row is the room-visibility authority and
    /// the postable rows are the write authority, as on the pinned server.
    func addDirectMessage() -> String {
        let channelId = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: ownerId, secondUserId: peerId
        )
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "dm", name: "dm")
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: peerId, kind: "dm", name: "dm")
        return channelId
    }
}

private func messagePayloadBodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func messagePayloadObject(_ body: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
}

/// The `message:new` payload of one `42["message:new",{...}]` frame.
private func messagePayloadFrame(_ frame: String) throws -> (event: String, payload: [String: Any]) {
    let array = try #require(try JSONSerialization.jsonObject(with: Data(frame.dropFirst(2).utf8)) as? [Any])
    return (
        try #require(array.first as? String),
        try #require(array.count == 2 ? array[1] as? [String: Any] : nil)
    )
}

private func messagePayloadPOST(
    _ client: any Client,
    path: String,
    body: String,
    headers: HTTPFields
) async throws -> ClientResponse {
    try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func messagePayloadConnect(_ fixture: MessagePayloadFixture, server: RealtimeServer, userId: String) async throws -> SocketIOTestClient {
    let client = try await SocketIOTestClient(port: server.port)
    _ = try #require(await client.waitForText { $0.hasPrefix("0") })
    let token = fixture.accounts.mintAccessTokenForTesting(userId: userId)
    client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(fixture.serverId)\"}")
    _ = try #require(await client.waitForText { $0 == "42[\"rooms:joined\"]" })
    return client
}

/// Wire the production relay emitters onto the real socket server: the general
/// room emitter and the room-membership grant the DM send path needs.
private func messagePayloadInstall(_ fixture: MessagePayloadFixture, hub: RealtimeHub) {
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

private func messagePayloadAssertCanonical(
    _ payload: [String: Any],
    keys: Set<String>,
    channelId: String,
    senderId: String,
    content: String
) {
    #expect(Set(payload.keys) == keys)
    #expect(storageOnlyMessageKeys.isDisjoint(with: Set(payload.keys)))
    #expect(payload["channelId"] as? String == channelId)
    #expect(payload["senderId"] as? String == senderId)
    #expect(payload["senderType"] as? String == "user")
    #expect(payload["messageType"] as? String == "chat")
    #expect(payload["content"] as? String == content)
    #expect(payload["seq"] is Int)
    #expect((payload["seq"] as? Int ?? 0) > 0)
    #expect(payload["randomId"] is NSNull)
    #expect(payload["threadId"] is NSNull)
    #expect(payload["actionMetadata"] is NSNull)
    #expect(payload["senderName"] as? String == "wire-owner")
    #expect(payload["senderDescription"] is NSNull)
    #expect(payload["senderMembershipStatus"] as? String == "active")
    #expect((payload["reactions"] as? [Any])?.isEmpty == true)
    #expect(payload["commentRef"] is NSNull)
    #expect(payload["externalAuthor"] is NSNull)
    let createdAt = payload["createdAt"] as? String ?? ""
    let updatedAt = payload["updatedAt"] as? String ?? ""
    #expect(createdAt.hasSuffix("Z"))
    #expect(createdAt.contains("."))
    #expect(DateText.isoDate(createdAt) != nil)
    #expect(updatedAt == createdAt)
}

private func messagePayloadHistoryRow(
    _ client: any Client, channelId: String, messageId: String, headers: HTTPFields
) async throws -> [String: Any] {
    let response = try await client.get(URI(string: "/api/messages/channel/\(channelId)?limit=50"), headers: headers)
    #expect(response.status == .ok)
    let body = try messagePayloadObject(messagePayloadBodyText(response))
    let messages = try #require(body["messages"] as? [[String: Any]])
    return try #require(messages.first { $0["id"] as? String == messageId })
}

@Suite(.serialized)
struct HumanMessageWirePayloadTests {
    /// The v2 ack is the canonical message object, byte-rendered in the
    /// producer's published order, and the real socket frame carries the same
    /// values plus the socket-only `conversationContext`.
    @Test func v2AckAndRealSocketFrameCarryTheCanonicalMessage() async throws {
        let fixture = MessagePayloadFixture()
        let channelId = fixture.addChannel(name: "wire-payload")
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let socket = try await messagePayloadConnect(fixture, server: realtime, userId: fixture.ownerId)
        defer {
            socket.close()
            Task { try? await realtime.close() }
        }
        messagePayloadInstall(fixture, hub: realtime.hub)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let headers = fixture.headers(fixture.ownerToken)
                let sent = try await messagePayloadPOST(
                    client, path: "/api/v2/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"hello wire payload\"}",
                    headers: headers
                )
                #expect(sent.status == .ok)
                let envelope = try messagePayloadObject(messagePayloadBodyText(sent))
                #expect(Set(envelope.keys) == ["message"])
                let message = try #require(envelope["message"] as? [String: Any])
                messagePayloadAssertCanonical(
                    message, keys: canonicalMessageKeys, channelId: channelId,
                    senderId: fixture.ownerId, content: "hello wire payload"
                )

                let id = try #require(message["id"] as? String)
                let seq = try #require(message["seq"] as? Int)
                let createdAt = try #require(message["createdAt"] as? String)
                let raw = messagePayloadBodyText(sent)
                let expected = "{\"message\":{\"id\":\"\(id)\",\"seq\":\(seq),\"channelId\":\"\(channelId)\","
                    + "\"senderType\":\"user\",\"senderId\":\"\(fixture.ownerId)\",\"randomId\":null,"
                    + "\"messageType\":\"chat\",\"content\":\"hello wire payload\",\"actionMetadata\":null,"
                    + "\"threadId\":null,\"taskStatus\":null,\"taskNumber\":null,\"taskAssigneeType\":null,"
                    + "\"taskAssigneeId\":null,\"taskClaimedAt\":null,\"taskCompletedAt\":null,"
                    + "\"createdAt\":\"\(createdAt)\",\"updatedAt\":\"\(createdAt)\","
                    + "\"senderName\":\"wire-owner\",\"senderDescription\":null,\"senderMembershipStatus\":\"active\","
                    + "\"attachments\":[],\"mentions\":[],\"reactions\":[],\"commentRef\":null,\"externalAuthor\":null}}"
                #expect(raw == expected)

                let frame = try #require(await socket.waitForText { $0.hasPrefix(#"42["message:new""#) })
                let parsed = try messagePayloadFrame(frame)
                #expect(parsed.event == "message:new")
                messagePayloadAssertCanonical(
                    parsed.payload, keys: canonicalMessageKeys.union(["conversationContext"]),
                    channelId: channelId, senderId: fixture.ownerId, content: "hello wire payload"
                )
                #expect(parsed.payload["seq"] as? Int == seq)
                #expect(parsed.payload["createdAt"] as? String == createdAt)
                let context = try #require(parsed.payload["conversationContext"] as? [String: Any])
                #expect(Set(context.keys) == ["channelType"])
                #expect(context["channelType"] as? String == "channel")

                let history = try await messagePayloadHistoryRow(
                    client, channelId: channelId, messageId: id, headers: headers
                )
                #expect(history["seq"] as? Int == seq)
                #expect(history["createdAt"] as? String == createdAt)
                #expect(history["senderName"] as? String == "wire-owner")
            }
        }
    }

    /// v1 answers with the bare canonical row (no envelope), still without the
    /// socket-only context.
    @Test func v1AckIsTheBareCanonicalMessage() async throws {
        let fixture = MessagePayloadFixture()
        let channelId = fixture.addChannel(name: "wire-payload-v1")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: nil
            ))
            try await app.testing { client in
                let headers = fixture.headers(fixture.ownerToken)
                let sent = try await messagePayloadPOST(
                    client, path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"bare v1 ack\"}",
                    headers: headers
                )
                #expect(sent.status == .ok)
                let message = try messagePayloadObject(messagePayloadBodyText(sent))
                messagePayloadAssertCanonical(
                    message, keys: canonicalMessageKeys, channelId: channelId,
                    senderId: fixture.ownerId, content: "bare v1 ack"
                )
                #expect(Set(message.keys).contains("message") == false)
                #expect(Set(message.keys).contains("conversationContext") == false)
            }
        }
    }

    /// Attachment objects carry the canonical metadata (the reduced payload
    /// only published `id`, which dropped the Web's image preview).
    @Test func attachmentObjectsCarryTheCanonicalMetadata() async throws {
        let fixture = MessagePayloadFixture()
        let channelId = fixture.addChannel(name: "wire-payload-attachment")
        let attachmentId = fixture.accounts.addChannelAttachment(
            channelId: channelId, uploaderId: fixture.ownerId,
            filename: "pixel.png", mimeType: "image/png", sizeBytes: 3
        )
        fixture.accounts.messagesAndThreadsStore.withState { state in
            state.channelAttachments[attachmentId]?.width = 4
            state.channelAttachments[attachmentId]?.height = 5
            state.channelAttachments[attachmentId]?.thumbnailKey = "attachment-thumbnails/pixel.png"
        }
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: nil
            ))
            try await app.testing { client in
                let headers = fixture.headers(fixture.ownerToken)
                let sent = try await messagePayloadPOST(
                    client, path: "/api/v2/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"with attachment\","
                        + "\"attachmentIds\":[\"\(attachmentId)\"]}",
                    headers: headers
                )
                #expect(sent.status == .ok)
                let envelope = try messagePayloadObject(messagePayloadBodyText(sent))
                let message = try #require(envelope["message"] as? [String: Any])
                let attachments = try #require(message["attachments"] as? [[String: Any]])
                #expect(attachments.count == 1)
                let attachment = try #require(attachments.first)
                #expect(Set(attachment.keys) == [
                    "id", "filename", "mimeType", "sizeBytes", "width", "height", "thumbnailUrl",
                ])
                #expect(attachment["id"] as? String == attachmentId)
                #expect(attachment["filename"] as? String == "pixel.png")
                #expect(attachment["mimeType"] as? String == "image/png")
                #expect(attachment["sizeBytes"] as? Int == 3)
                #expect(attachment["width"] as? Int == 4)
                #expect(attachment["height"] as? Int == 5)
                #expect(attachment["thumbnailUrl"] as? String == "/api/attachments/\(attachmentId)/thumbnail")

                let rendered = messagePayloadBodyText(sent)
                let expectedAttachment = "{\"id\":\"\(attachmentId)\",\"filename\":\"pixel.png\","
                    + "\"mimeType\":\"image/png\",\"sizeBytes\":3,\"width\":4,\"height\":5,"
                    + "\"thumbnailUrl\":\"/api/attachments/\(attachmentId)/thumbnail\"}"
                #expect(rendered.contains("\"attachments\":[\(expectedAttachment)]"))
            }
        }
    }

    /// A DM send joins both participants' live sockets into the new channel
    /// room before emitting, so the frame reaches a socket that predates the
    /// DM. The frame also carries `conversationContext.channelType == "dm"`.
    @Test func dmSendJoinsParticipantSocketsAndCarriesDmContext() async throws {
        let fixture = MessagePayloadFixture()
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        // Connect first: a new DM is not part of the handshake snapshot.
        let ownerSocket = try await messagePayloadConnect(fixture, server: realtime, userId: fixture.ownerId)
        let peerSocket = try await messagePayloadConnect(fixture, server: realtime, userId: fixture.peerId)
        defer {
            ownerSocket.close()
            peerSocket.close()
            Task { try? await realtime.close() }
        }
        messagePayloadInstall(fixture, hub: realtime.hub)
        let dmId = fixture.addDirectMessage()

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let headers = fixture.headers(fixture.ownerToken)
                let sent = try await messagePayloadPOST(
                    client, path: "/api/v2/messages",
                    body: "{\"channelId\":\"\(dmId)\",\"content\":\"dm over the wire\"}",
                    headers: headers
                )
                #expect(sent.status == .ok)
                let envelope = try messagePayloadObject(messagePayloadBodyText(sent))
                let message = try #require(envelope["message"] as? [String: Any])
                #expect(Set(message.keys) == canonicalMessageKeys)
                let id = try #require(message["id"] as? String)
                let seq = try #require(message["seq"] as? Int)
                let createdAt = try #require(message["createdAt"] as? String)

                for socket in [ownerSocket, peerSocket] {
                    let frame = try #require(await socket.waitForText {
                        $0.hasPrefix(#"42["message:new""#) && $0.contains("\"dm over the wire\"")
                    })
                    let parsed = try messagePayloadFrame(frame)
                    #expect(parsed.payload["id"] as? String == id)
                    #expect(parsed.payload["seq"] as? Int == seq)
                    #expect(parsed.payload["createdAt"] as? String == createdAt)
                    #expect(parsed.payload["senderName"] as? String == "wire-owner")
                    let context = try #require(parsed.payload["conversationContext"] as? [String: Any])
                    #expect(Set(context.keys) == ["channelType"])
                    #expect(context["channelType"] as? String == "dm")
                }

                let history = try await messagePayloadHistoryRow(
                    client, channelId: dmId, messageId: id, headers: headers
                )
                #expect(history["seq"] as? Int == seq)
                #expect(history["createdAt"] as? String == createdAt)
                #expect(Set(history.keys).isDisjoint(with: ["agentSendKey", "searchText", "searchVector", "serverId", "senderTimezone"]))
            }
        }
    }

    /// A thread reply publishes the parent coordinates on the socket only; the
    /// HTTP ack never carries `conversationContext`.
    @Test func threadReplyCarriesParentConversationContext() async throws {
        let fixture = MessagePayloadFixture()
        let channelId = fixture.addChannel(name: "wire-payload-thread")
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let socket = try await messagePayloadConnect(fixture, server: realtime, userId: fixture.ownerId)
        defer {
            socket.close()
            Task { try? await realtime.close() }
        }
        messagePayloadInstall(fixture, hub: realtime.hub)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let headers = fixture.headers(fixture.ownerToken)
                let parent = try await messagePayloadPOST(
                    client, path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"thread parent\"}",
                    headers: headers
                )
                #expect(parent.status == .ok)
                let parentId = try #require(try messagePayloadObject(messagePayloadBodyText(parent))["id"] as? String)

                let created = try await messagePayloadPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\",\"content\":\"first reply\"}",
                    headers: headers
                )
                #expect(created.status == .ok)
                let thread = try messagePayloadObject(messagePayloadBodyText(created))
                let threadId = try #require(thread["threadChannelId"] as? String)

                let sent = try await messagePayloadPOST(
                    client, path: "/api/v2/messages",
                    body: "{\"channelId\":\"\(threadId)\",\"content\":\"thread reply over the wire\"}",
                    headers: headers
                )
                #expect(sent.status == .ok)
                let envelope = try messagePayloadObject(messagePayloadBodyText(sent))
                let message = try #require(envelope["message"] as? [String: Any])
                #expect(Set(message.keys) == canonicalMessageKeys)
                #expect(message["channelId"] as? String == threadId)
                #expect(Set(message.keys).contains("conversationContext") == false)
                #expect(message["threadId"] is NSNull)

                let frame = try #require(await socket.waitForText {
                    $0.hasPrefix(#"42["message:new""#) && $0.contains("\"thread reply over the wire\"")
                })
                let parsed = try messagePayloadFrame(frame)
                #expect(parsed.payload["id"] as? String == message["id"] as? String)
                #expect(parsed.payload["channelId"] as? String == threadId)
                #expect(parsed.payload["threadId"] is NSNull)
                let context = try #require(parsed.payload["conversationContext"] as? [String: Any])
                #expect(Set(context.keys) == ["channelType", "parentChannelId", "parentMessageId", "parentChannelType"])
                #expect(context["channelType"] as? String == "thread")
                #expect(context["parentChannelId"] as? String == channelId)
                #expect(context["parentMessageId"] as? String == parentId)
                #expect(context["parentChannelType"] as? String == "channel")
            }
        }
    }

    /// A human who follows a thread after connecting must still receive the
    /// next reply: the production send path joins every human follower's live
    /// sockets to the thread room before publishing (`messageService.ts`
    /// `emitPersistedMessageToFrontend`). The follow route itself must not be
    /// the thing that grants the room.
    @Test func threadReplyJoinsFollowerSocketsBeforeBroadcast() async throws {
        let fixture = MessagePayloadFixture()
        let channelId = fixture.addChannel(name: "wire-payload-thread-follower")
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let followerSocket = try await messagePayloadConnect(fixture, server: realtime, userId: fixture.peerId)
        defer {
            followerSocket.close()
            Task { try? await realtime.close() }
        }
        messagePayloadInstall(fixture, hub: realtime.hub)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let ownerHeaders = fixture.headers(fixture.ownerToken)
                let parent = try await messagePayloadPOST(
                    client, path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"follower parent\"}",
                    headers: ownerHeaders
                )
                #expect(parent.status == .ok)
                let parentId = try #require(try messagePayloadObject(messagePayloadBodyText(parent))["id"] as? String)

                let created = try await messagePayloadPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\",\"content\":\"thread seed\"}",
                    headers: ownerHeaders
                )
                #expect(created.status == .ok)
                let threadId = try #require(
                    try messagePayloadObject(messagePayloadBodyText(created))["threadChannelId"] as? String
                )

                let peerToken = fixture.accounts.mintAccessTokenForTesting(userId: fixture.peerId)
                let followed = try await messagePayloadPOST(
                    client, path: "/api/channels/threads/follow",
                    body: "{\"parentMessageId\":\"\(parentId)\"}",
                    headers: fixture.headers(peerToken)
                )
                #expect(followed.status == .ok)

                let sent = try await messagePayloadPOST(
                    client, path: "/api/v2/messages",
                    body: "{\"channelId\":\"\(threadId)\",\"content\":\"follower-visible reply\"}",
                    headers: ownerHeaders
                )
                #expect(sent.status == .ok)

                let frame = try #require(await followerSocket.waitForText {
                    $0.hasPrefix(#"42["message:new""#) && $0.contains("\"follower-visible reply\"")
                })
                let parsed = try messagePayloadFrame(frame)
                #expect(parsed.payload["channelId"] as? String == threadId)
                let context = try #require(parsed.payload["conversationContext"] as? [String: Any])
                #expect(context["channelType"] as? String == "thread")
                #expect(context["parentMessageId"] as? String == parentId)
            }
        }
    }

    /// An agent reply uses the same persisted-message frontend emit. The
    /// thread's human follower receives the frame only because the agent send
    /// path joins follower sockets before publishing.
    @Test func agentThreadReplyJoinsFollowerSocketsBeforeBroadcast() async throws {
        let fixture = MessagePayloadFixture()
        let channelId = fixture.addChannel(name: "wire-payload-agent-thread")
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let followerSocket = try await messagePayloadConnect(fixture, server: realtime, userId: fixture.ownerId)
        defer {
            followerSocket.close()
            Task { try? await realtime.close() }
        }
        messagePayloadInstall(fixture, hub: realtime.hub)
        let agentId = fixture.accounts.oauth.createAgent(
            serverId: fixture.serverId, name: "WireAgent", creatorUserId: fixture.ownerId, runtime: "managed"
        )
        fixture.accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        fixture.accounts.addPostableChannel(
            serverId: fixture.serverId, channelId: channelId, memberId: agentId, name: "wire-payload-agent-thread"
        )
        let agentKey = fixture.accounts.mintAgentCredential(
            agentId: agentId, scopes: ["send", "read"], name: "wire-agent"
        )

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let ownerHeaders = fixture.headers(fixture.ownerToken)
                let parent = try await messagePayloadPOST(
                    client, path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"agent thread parent\"}",
                    headers: ownerHeaders
                )
                #expect(parent.status == .ok)
                let parentId = try #require(try messagePayloadObject(messagePayloadBodyText(parent))["id"] as? String)

                let created = try await messagePayloadPOST(
                    client, path: "/api/channels/\(channelId)/threads",
                    body: "{\"parentMessageId\":\"\(parentId)\",\"content\":\"agent thread seed\"}",
                    headers: ownerHeaders
                )
                #expect(created.status == .ok)
                let createdBody = try messagePayloadObject(messagePayloadBodyText(created))
                let threadId = try #require(createdBody["threadChannelId"] as? String)
                let seedHistory = try await client.get(
                    URI(string: "/api/messages/channel/\(threadId)?limit=50"), headers: ownerHeaders
                )
                #expect(seedHistory.status == .ok)
                let seedMessages = try #require(
                    try messagePayloadObject(messagePayloadBodyText(seedHistory))["messages"] as? [[String: Any]]
                )
                let seed = try #require(seedMessages.first {
                    ($0["content"] as? String) == "agent thread seed"
                })
                let seedMessageId = try #require(seed["id"] as? String)
                let seedSeq = try #require(seed["seq"] as? Int)
                #expect(seedSeq > 0)

                var agentHeaders = HTTPFields()
                agentHeaders[.authorization] = "Bearer \(agentKey)"
                agentHeaders[.contentType] = "application/json"
                let sent = try await messagePayloadPOST(
                    client, path: "/internal/agent-api/send",
                    body: "{\"target\":\"#wire-payload-agent-thread:\(parentId.prefix(8))\",\"content\":\"agent follower-visible reply\",\"seenUpToSeq\":\(seedSeq)}",
                    headers: agentHeaders
                )
                #expect(sent.status == .ok)
                let agentBody = try messagePayloadObject(messagePayloadBodyText(sent))
                #expect(agentBody["state"] as? String == "sent")
                let agentMessageId = try #require(agentBody["messageId"] as? String)
                let agentChannelId = try #require(
                    fixture.accounts.messageChannelIdForTesting(messageId: agentMessageId)
                )
                #expect(agentChannelId == threadId)

                let frame = try #require(await followerSocket.waitForText {
                    $0.hasPrefix(#"42["message:new""#) && $0.contains("\"agent follower-visible reply\"")
                })
                let parsed = try messagePayloadFrame(frame)
                #expect(parsed.payload["channelId"] as? String == threadId)
                #expect(parsed.payload["senderType"] as? String == "agent")
                #expect(parsed.payload["senderId"] as? String == agentId)
            }
        }
    }

    /// A task-assignment notice is a system `message:new` in a freshly created
    /// thread. The actor is followed before the notice is committed, and the
    /// system emit path must join that follower audience before publishing
    /// (`broadcastSystemMessage` in the upstream service).
    @Test func systemThreadNoticeJoinsFollowerSocketsBeforeBroadcast() async throws {
        let fixture = MessagePayloadFixture()
        let channelId = fixture.addChannel(name: "wire-payload-system-thread")
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let actorSocket = try await messagePayloadConnect(fixture, server: realtime, userId: fixture.ownerId)
        defer {
            actorSocket.close()
            Task { try? await realtime.close() }
        }
        messagePayloadInstall(fixture, hub: realtime.hub)
        let agentId = fixture.accounts.oauth.createAgent(
            serverId: fixture.serverId, name: "AssignBot", creatorUserId: fixture.ownerId, runtime: "managed"
        )
        fixture.accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        fixture.accounts.addPostableChannel(
            serverId: fixture.serverId, channelId: channelId, memberId: agentId,
            name: "wire-payload-system-thread"
        )

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: realtime.hub
            ))
            try await app.testing { client in
                let headers = fixture.headers(fixture.ownerToken)
                let created = try await messagePayloadPOST(
                    client, path: "/api/tasks/channel/\(channelId)",
                    body: "{\"tasks\":[{\"title\":\"system join task\"}]}",
                    headers: headers
                )
                #expect(created.status == .ok)
                let createdBody = try messagePayloadObject(messagePayloadBodyText(created))
                let task = try #require((createdBody["tasks"] as? [[String: Any]])?.first)
                let taskId = try #require(task["id"] as? String)

                let assigned = try await client.send(
                    .patch, headers: headers, to: URI(string: "/api/tasks/\(taskId)/assignee")
                ) { request in
                    request.body = .init(string: "{\"assignee\":{\"type\":\"agent\",\"id\":\"\(agentId)\"}}")
                }
                #expect(assigned.status == .ok, "\(assigned.status) \(assigned.body.string ?? "")")

                let frame = try #require(await actorSocket.waitForText {
                    $0.hasPrefix(#"42["message:new""#)
                        && $0.contains("assigned") && $0.contains("AssignBot")
                })
                let parsed = try messagePayloadFrame(frame)
                let threadId = try #require(parsed.payload["channelId"] as? String)
                #expect(fixture.accounts.oauth.channelType(id: threadId) == "thread")
                #expect(parsed.payload["senderId"] as? String == "system")
                #expect(fixture.accounts.threadFollowerIdsForTesting(threadChannelId: threadId)
                    .contains(fixture.ownerId))
            }
        }
    }
}
