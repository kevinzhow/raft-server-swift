import Foundation
import HTTPTypes
import NIOCore
import NIOPosix
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Bridges the in-memory ledger onto the realtime server the same way the
/// `RaftServer` executable does, so the socket assertions see production room
/// and replay semantics.
private struct SocketMembershipAuth: RealtimeAuthorizing {
    let accounts: EmailLoginDirectory

    func userId(forAccessToken token: String) -> String? {
        accounts.sessionIdentity(accessToken: token)?.userId
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        accounts.sessionIdentity(accessToken: token)?.familyId
    }

    func serverRole(serverId: String, userId: String) -> String? {
        accounts.oauth.memberRole(serverId: serverId, userId: userId)
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        accounts.socketMembership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }

    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        accounts.socketMembership.syncMessages(
            serverId: serverId,
            userId: userId,
            lastSeq: lastSeq,
            limit: limit
        )?.jsonBody()
    }
}

private func membershipHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func jsonObject(_ frame: String) -> [String: Any]? {
    guard frame.hasPrefix("42") else { return nil }
    let data = Data(frame.dropFirst(2).utf8)
    guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
          array.count > 1
    else { return nil }
    return array[1] as? [String: Any]
}

private func messageIDs(_ frame: String) -> Set<String> {
    guard let payload = jsonObject(frame),
          let messages = payload["messages"] as? [[String: Any]]
    else { return [] }
    return Set(messages.compactMap { $0["id"] as? String })
}

private func connectSocket(
    _ client: SocketIOTestClient,
    token: String,
    serverId: String
) async throws {
    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
}

@Test func guestSocketJoinAndResumeEnforceHiddenChannelAndParentVisibility() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111120001"
    let guestId = "11111111-1111-4111-8111-111111120002"
    let serverId = "33333333-3333-4333-8333-333333340001"
    for (id, email) in [
        (ownerId, "socketmem-owner@slock.test"),
        (guestId, "socketmem-guest@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "socketmem", name: "Socket Membership", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")

    let hidden = accounts.oauth.createChannel(serverId: serverId, name: "audit-hidden", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: hidden, memberId: ownerId, name: "audit-hidden")
    accounts.oauth.addChannelHuman(channelId: hidden, userId: ownerId)

    let visible = accounts.oauth.createChannel(serverId: serverId, name: "audit-visible", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: visible, memberId: ownerId, name: "audit-visible")
    accounts.oauth.addChannelHuman(channelId: visible, userId: ownerId)
    accounts.setChannelGuestVisibleForTesting(channelId: visible, visible: true)

    let sentinel = accounts.addHumanMessageForTesting(channelId: hidden, senderId: ownerId, content: "before-sync-cursor")
    let hiddenMessage = accounts.addHumanMessageForTesting(channelId: hidden, senderId: ownerId, content: "audit-guest-hidden")
    let visibleMessage = accounts.addHumanMessageForTesting(channelId: visible, senderId: ownerId, content: "audit-guest-visible")

    let hiddenThread = UUID().uuidString.lowercased()
    accounts.addThreadChannel(
        serverId: serverId, threadChannelId: hiddenThread,
        parentChannelId: hidden, parentMessageId: hiddenMessage, memberId: ownerId
    )
    accounts.followThreadForTesting(
        serverId: serverId, userId: guestId,
        threadChannelId: hiddenThread, parentMessageId: hiddenMessage
    )
    let hiddenReply = accounts.addHumanMessageForTesting(channelId: hiddenThread, senderId: ownerId, content: "audit-thread-hidden")

    let visibleThread = UUID().uuidString.lowercased()
    accounts.addThreadChannel(
        serverId: serverId, threadChannelId: visibleThread,
        parentChannelId: visible, parentMessageId: visibleMessage, memberId: ownerId
    )
    accounts.followThreadForTesting(
        serverId: serverId, userId: guestId,
        threadChannelId: visibleThread, parentMessageId: visibleMessage
    )
    let visibleReply = accounts.addHumanMessageForTesting(channelId: visibleThread, senderId: ownerId, content: "audit-thread-visible")

    let realtime = try await RealtimeServer.start(auth: SocketMembershipAuth(accounts: accounts))
    let client = try await SocketIOTestClient(port: realtime.port)
    defer {
        client.close()
        Task { try? await realtime.close() }
    }
    try await connectSocket(
        client,
        token: accounts.mintAccessTokenForTesting(userId: guestId),
        serverId: serverId
    )

    // A guest may not subscribe to a hidden channel through `join:channel`.
    client.send("42[\"join:channel\",\"\(hidden)\"]")
    realtime.hub.emit(room: "channel:\(hidden)", event: "message:new", payloadJSON: "{\"content\":\"audit-hidden-live-secret\"}")
    realtime.hub.emit(room: "channel:\(visible)", event: "message:new", payloadJSON: "{\"content\":\"audit-visible-live-control\"}")
    for (channelId, marker) in [(hidden, "audit-hidden-task"), (visible, "audit-visible-task")] {
        realtime.hub.emit(room: "channel:\(channelId)", event: "task:created", payloadJSON: "{\"tasks\":[{\"id\":\"\(marker)\"}]}")
        realtime.hub.emit(room: "channel:\(channelId)", event: "task:updated", payloadJSON: "{\"task\":{\"id\":\"\(marker)\"}}")
        realtime.hub.emit(room: "channel:\(channelId)", event: "task:deleted", payloadJSON: "{\"taskId\":\"\(marker)\"}")
    }
    realtime.hub.emit(room: "user:\(guestId)", event: "audit:barrier", payloadJSON: "{\"step\":1}")
    #expect(await client.waitForText { $0.contains("audit:barrier") } != nil)

    #expect(client.textFrames.contains { $0.contains("audit-visible-live-control") }, "a guest receives visible-channel broadcasts")
    #expect(!client.textFrames.contains { $0.contains("audit-hidden-live-secret") }, "a hidden channel must not reach the guest through join:channel")
    #expect(client.textFrames.filter { $0.contains("audit-visible-task") }.count == 3, "visible task events keep flowing")
    #expect(!client.textFrames.contains { $0.contains("audit-hidden-task") }, "hidden task events must not reach the guest")

    let sentinelSeq = try #require(accounts.messageSeqForTesting(messageId: sentinel))
    client.send("42[\"sync:resume\",{\"lastSeq\":\(sentinelSeq)}]")
    let response = try #require(await client.waitForText { $0.contains("sync:resume:response") })
    let ids = messageIDs(response)
    #expect(ids.contains(visibleMessage), "sync:resume replays the visible channel")
    #expect(!ids.contains(hiddenMessage), "sync:resume filters the hidden channel")
    #expect(ids.contains(visibleReply), "sync:resume replays a followed thread under a visible parent")
    #expect(!ids.contains(hiddenReply), "sync:resume filters a followed thread under a hidden parent")
}

@Test func socketStopsDeliveringPrivateMessagesAfterMembershipTransitions() async throws {
    for transition in ["remove-private-member", "leave-private-channel", "remove-server-member"] {
        let accounts = EmailLoginDirectory()
        let ownerId = "11111111-1111-4111-8111-111111121001"
        let memberId = "11111111-1111-4111-8111-111111121002"
        let serverId = "33333333-3333-4333-8333-333333341001"
        for (id, email) in [
            (ownerId, "socketrevoke-owner@slock.test"),
            (memberId, "socketrevoke-member@slock.test"),
        ] {
            accounts.addAccount(id: id, email: email, password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "socketrevoke", name: "Socket Revoke", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

        let channelId = accounts.oauth.createChannel(serverId: serverId, name: "audit-private", creatorUserId: ownerId, type: "private")
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "private", name: "audit-private")
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, kind: "private")
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)

        let parent = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "audit-private-thread-parent")
        let threadId = UUID().uuidString.lowercased()
        accounts.addThreadChannel(
            serverId: serverId, threadChannelId: threadId,
            parentChannelId: channelId, parentMessageId: parent, memberId: memberId
        )
        accounts.followThreadForTesting(
            serverId: serverId, userId: memberId,
            threadChannelId: threadId, parentMessageId: parent
        )

        let realtime = try await RealtimeServer.start(auth: SocketMembershipAuth(accounts: accounts))
        let client = try await SocketIOTestClient(port: realtime.port)
        let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
        let memberToken = accounts.mintAccessTokenForTesting(userId: memberId)
        try await connectSocket(client, token: memberToken, serverId: serverId)
        // A followed thread joins its own room after connect.
        realtime.hub.joinUserSessions(userId: memberId, room: "channel:\(threadId)")

        realtime.hub.emit(room: "channel:\(threadId)", event: "thread:followers-updated", payloadJSON: "{\"receipt\":\"audit-thread-before-removal\"}")
        #expect(await client.waitForText { $0.contains("audit-thread-before-removal") } != nil)
        realtime.hub.emit(room: "channel:\(channelId)", event: "message:new", payloadJSON: "{\"content\":\"audit-private-control-before-removal\"}")
        #expect(await client.waitForText { $0.contains("audit-private-control-before-removal") } != nil)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts,
                realtime: realtime.hub
            ))
            try await app.testing { http in
                let path: String
                let method: HTTPRequest.Method
                let actorToken: String
                switch transition {
                case "remove-private-member":
                    path = "/api/channels/\(channelId)/members/user/\(memberId)"
                    method = .delete
                    actorToken = ownerToken
                case "leave-private-channel":
                    path = "/api/channels/\(channelId)/leave"
                    method = .post
                    actorToken = memberToken
                default:
                    path = "/api/servers/\(serverId)/members/\(memberId)"
                    method = .delete
                    actorToken = ownerToken
                }
                let removed = try await http.send(method, headers: membershipHeaders(actorToken, serverId), to: URI(string: path)) { request in
                    if method == .post { request.body = .init(string: "{}") }
                }
                #expect(removed.status == .ok, "\(transition): removal must succeed")

                let denied = try await http.send(
                    .get,
                    headers: membershipHeaders(memberToken, serverId),
                    to: URI(string: "/api/messages/channel/\(channelId)")
                )
                #expect(denied.status == .forbidden || denied.status == .notFound, "\(transition): HTTP must deny the removed member")

                realtime.hub.emit(room: "channel:\(channelId)", event: "message:new", payloadJSON: "{\"content\":\"audit-private-secret-after-removal\"}")
                for event in ["thread:followers-updated", "scope_read:updated", "message:updated"] {
                    realtime.hub.emit(room: "channel:\(threadId)", event: event, payloadJSON: "{\"receipt\":\"audit-thread-after-removal\"}")
                }
                realtime.hub.emit(room: "user:\(memberId)", event: "audit:barrier", payloadJSON: "{\"step\":2}")
            }
        }

        if transition == "remove-server-member" {
            #expect(await client.waitForText { $0.contains("server:membership-removed") } != nil, "server removal announces itself before the close")
            #expect(await client.waitForClose(), "server removal closes the socket")
        } else {
            #expect(await client.waitForText { $0.contains("audit:barrier") } != nil, "\(transition): the socket stays connected")
            #expect(!client.textFrames.contains { $0.contains("audit-private-secret-after-removal") }, "\(transition): HTTP denial must also stop the old socket broadcast")
            #expect(!client.textFrames.contains { $0.contains("audit-thread-after-removal") }, "\(transition): losing the parent drops child thread rooms")
        }
        client.close()
        try? await realtime.close()
    }
}
