import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-exact locks for the four routes `InboxAndWakeService` owns.
///
/// The bodies below are the legacy strings the directory produced, including
/// the published member order, the `jsonString` escaping, and the optional
/// trailing members. `respond` renders the `JSONBodyConvertible` DTOs once, so
/// a reordering regression fails here rather than in a decoded-shape test.

private let ownerId = "11111111-1111-4111-8111-111111170001"
private let peerId = "11111111-1111-4111-8111-111111170002"
private let serverId = "33333333-3333-4333-8333-333333170001"
private let channelId = "44444444-4444-4444-8444-444444170001"
private let threadId = "44444444-4444-4444-8444-444444170002"
private let messageId = "66666666-6666-4666-8666-666666170001"
private let firstReplyId = "66666666-6666-4666-8666-666666170002"
private let secondReplyId = "66666666-6666-4666-8666-666666170003"

private struct InboxByteSeed {
    let accounts: EmailLoginDirectory
    let token: String
}

private func inboxByteHeaders(_ token: String, _ server: String = serverId) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = server
    return headers
}

/// A server with one channel, one message carrying an attachment chip, a
/// scoped comment ref, a reaction, a visible mention, and a thread with two
/// replies hanging off that message.
private func inboxByteSeed(withThread: Bool) -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: ownerId, email: "inbox-bytes-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "inbox-bytes-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-bytes", name: "Inbox Bytes", ownerId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "inbox-bytes")
    accounts.insertHumanMessage(
        id: messageId,
        channelId: channelId,
        senderId: ownerId,
        content: "hello \"quoted\"\nline"
    )
    accounts.setMessageAttachmentIdsForTesting(messageId: messageId, attachmentIds: ["att-1"])
    accounts.messagesAndThreadsStore.withState { state in
        state.attachmentCommentRecords["att-1"] = [AttachmentCommentRecord(
            id: messageId,
            attachmentId: "att-1",
            content: "a comment",
            anchorJSON: nil,
            senderId: ownerId,
            senderType: "user",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            threadChannelId: nil,
            hostMessageId: messageId,
            hostChannelId: channelId
        )]
        state.messageReactions = [StoredReaction(
            messageId: messageId,
            emoji: "👍",
            reactorId: "unknown-user",
            reactorType: "user"
        )]
    }
    accounts.addMessageMention(messageId: messageId, targetType: "user", targetId: peerId)
    if withThread {
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: threadId,
            memberId: ownerId,
            kind: "thread",
            parentChannelId: channelId,
            parentMessageId: messageId,
            name: "thread"
        )
        accounts.insertHumanMessage(id: firstReplyId, channelId: threadId, senderId: ownerId, content: "first reply")
        accounts.insertHumanMessage(id: secondReplyId, channelId: threadId, senderId: ownerId, content: "second reply")
    }
    return accounts
}

private func inboxByteToken(_ client: any Client) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"inbox-bytes-owner@slock.test\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func expectByteExact(
    _ response: ClientResponse,
    status: HTTPResponse.Status,
    body: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(response.status == status, sourceLocation: sourceLocation)
    #expect(response.body.string == body, sourceLocation: sourceLocation)
    #expect(
        response.headers[HTTPField.Name("Content-Length")!] == String(body.utf8.count),
        sourceLocation: sourceLocation
    )
    #expect(
        response.headers[HTTPField.Name("Content-Type")!] == "application/json; charset=utf-8",
        sourceLocation: sourceLocation
    )
    #expect(
        response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow",
        sourceLocation: sourceLocation
    )
}

@Test func inboxAndWakePageBodiesAreByteExact() async throws {
    let accounts = inboxByteSeed(withThread: true)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await inboxByteToken(client)
            let headers = inboxByteHeaders(token)

            let commentRef = #"{"attachmentId":"att-1","hostMessageId":"\#(messageId)","hostSource":{"type":"channel","routeKind":"channel","channelId":"\#(channelId)","rootThreadChannelId":null}}"#
            let chips = #"[{"id":"att-1","commentCount":1}]"#
            let syncRow = #"{"id":"\#(messageId)","channelId":"\#(channelId)","seq":1,"content":"hello \"quoted\"\nline","attachments":\#(chips),"commentRef":\#(commentRef)}"#

            let sync = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/sync?channel_id=\(channelId)&since_seq=0")
            )
            expectByteExact(sync, status: .ok, body: "[\(syncRow)]")

            let window = #"{"schemaVersion":1,"domain":"receiver_visible_messages_v1","serverId":"\#(serverId)","receiverKind":"user","receiverId":"\#(ownerId)","scopeId":"\#(channelId)","coveredFromSeq":1,"coveredAfterSeq":0,"coveredThroughSeq":1,"remoteHighWaterSeq":1,"hasGap":false,"hasNewer":false,"completeThroughLatest":true}"#
            let row = #"{"id":"\#(messageId)","senderId":"\#(ownerId)","senderType":"user","senderMembershipStatus":"active","content":"hello \"quoted\"\nline","attachments":\#(chips),"reactions":[{"emoji":"👍","count":1,"reactorIds":["unknown-user"],"reactorNames":["Unknown user"]}],"mentions":[{"type":"user","id":"\#(peerId)","name":""}],"commentRef":\#(commentRef)}"#
            let summaries = #"{"\#(messageId)":{"replyCount":2,"latestReplies":[{"preview":"first reply"},{"preview":"second reply"}]}}"#
            let page = #"{"messages":[\#(row)],"historyLimited":false,"messageWindow":\#(window),"threadSummariesByParentMessageId":\#(summaries)}"#
            let pageResponse = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/channel/\(channelId)")
            )
            expectByteExact(pageResponse, status: .ok, body: page)

            let deliveries = accounts.agentDeliveries(agentId: "agent-1")
            #expect(deliveries.isEmpty)
            accounts.recordAgentMentionDelivery(
                messageId: messageId,
                agentId: "agent-1",
                handle: "agent-handle",
                terminalCode: "QUOTA_LIMITED"
            )
            let mention = try await client.get(
                URI(string: "/api/messages/\(messageId)/mention-deliveries"),
                headers: headers
            )
            expectByteExact(
                mention,
                status: .ok,
                body: #"{"messageId":"\#(messageId)","deliveries":[{"targetId":"agent-1","targetHandle":"agent-handle","outcome":"lost","reasonCategory":"quota"}]}"#
            )
        }
    }
}

@Test func inboxBroadcastSyncAndDoneBodiesAreByteExact() async throws {
    let accounts = inboxByteSeed(withThread: false)
    let doneKey = "\(ownerId)\n\(channelId)"
    accounts.messagesAndThreadsStore.withState { state in
        state.inboxDoneScopes.insert(doneKey)
        state.inboxDoneAt[doneKey] = Date(timeIntervalSince1970: 1_800_000_000.5)
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await inboxByteToken(client)
            let headers = inboxByteHeaders(token)

            let commentRef = #"{"attachmentId":"att-1","hostMessageId":"\#(messageId)","hostSource":{"type":"channel","routeKind":"channel","channelId":"\#(channelId)","rootThreadChannelId":null}}"#
            let row = #"{"id":"\#(messageId)","channelId":"\#(channelId)","seq":1,"content":"hello \"quoted\"\nline","attachments":[{"id":"att-1","commentCount":1}],"commentRef":\#(commentRef)}"#
            let broadcast = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/sync?since_seq=0&limit=100")
            )
            expectByteExact(broadcast, status: .ok, body: "[\(row)]")

            let done = try await client.get(URI(string: "/api/channels/inbox/done?limit=30"), headers: headers)
            expectByteExact(
                done,
                status: .ok,
                body: #"{"items":[{"kind":"channel","channelId":"\#(channelId)","unreadCount":0,"doneAt":"2027-01-15T08:00:00.500Z"}],"hasMore":false,"totalCount":null}"#
            )

            let anonymous = try await client.get(URI(string: "/api/channels/inbox/done"), headers: HTTPFields())
            expectByteExact(anonymous, status: .unauthorized, body: #"{"error":"Unauthorized"}"#)
        }
    }
}

@Test func inboxAndWakeRefusalsAreByteExact() async throws {
    let accounts = inboxByteSeed(withThread: false)
    accounts.addAccount(id: "11111111-1111-4111-8111-111111170003", email: "inbox-bytes-unverified@slock.test", password: "password123")
    accounts.oauth.addMember(serverId: serverId, userId: "11111111-1111-4111-8111-111111170003", role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await inboxByteToken(client)
            let headers = inboxByteHeaders(token)

            let badChannel = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/sync?channel_id=not-a-uuid")
            )
            expectByteExact(badChannel, status: .badRequest, body: #"{"error":"Invalid channel id"}"#)

            let badCursor = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/sync?since_seq=soon")
            )
            expectByteExact(badCursor, status: .badRequest, body: #"{"error":"Invalid sync cursor"}"#)

            let missing = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/messages/sync"))
            expectByteExact(
                missing,
                status: .unauthorized,
                body: #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#
            )

            let invalid = try await client.send(
                .get,
                headers: inboxByteHeaders("not-a-token"),
                to: URI(string: "/api/messages/sync")
            )
            expectByteExact(
                invalid,
                status: .unauthorized,
                body: #"{"error":"Invalid or expired token","code":"auth_required"}"#
            )

            var unverifiedHeaders = HTTPFields()
            unverifiedHeaders[.contentType] = "application/json"
            let unverifiedLogin = try await client.send(.post, headers: unverifiedHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"inbox-bytes-unverified@slock.test\",\"password\":\"password123\"}")
            }
            let unverifiedToken = (try JSONSerialization.jsonObject(with: Data((unverifiedLogin.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            let unverified = try await client.send(
                .get,
                headers: inboxByteHeaders(unverifiedToken),
                to: URI(string: "/api/messages/sync")
            )
            expectByteExact(unverified, status: .forbidden, body: #"{"error":"Email verification required"}"#)

            let badPageCursor = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/channel/\(channelId)?before=1&after=1")
            )
            expectByteExact(
                badPageCursor,
                status: .badRequest,
                body: #"{"error":"Invalid message page cursor","code":"invalid_message_page_cursor"}"#
            )

            let malformedChannel = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/channel/not-a-uuid")
            )
            expectByteExact(malformedChannel, status: .notFound, body: #"{"error":"Channel not found"}"#)

            let invisible = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/channel/44444444-4444-4444-8444-444444179999")
            )
            expectByteExact(
                invisible,
                status: .notFound,
                body: #"{"error":"Channel not found or not visible"}"#
            )

            let notJoinable = try await client.send(
                .get,
                headers: headers,
                to: URI(string: "/api/messages/not-a-uuid/mention-deliveries")
            )
            expectByteExact(notJoinable, status: .notFound, body: #"{"status":"NOT_JOINABLE"}"#)
        }
    }
}
