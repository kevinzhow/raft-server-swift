import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ChannelsEntrySocketAuth: RealtimeAuthorizing {
    let core: AuthCoreService
    let membership: SocketMembershipService

    func userId(forAccessToken token: String) -> String? {
        core.sessionIdentity(accessToken: token)?.userId
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        core.sessionIdentity(accessToken: token)?.familyId
    }

    func serverRole(serverId: String, userId: String) -> String? {
        membership.serverRole(serverId: serverId, userId: userId)
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }

    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        membership.syncMessages(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)?.jsonBody()
    }
}

private func channelsEntryHeaders(token: String, serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func channelsEntryJSON(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

private func channelsEntryPost(
    _ client: any Client, _ path: String, headers: HTTPFields, body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: headers, to: URI(string: path)) { $0.body = .init(string: body) }
}

private func channelsEntryConnect(
    _ server: RealtimeServer, token: String, serverId: String
) async throws -> SocketIOTestClient {
    let socket = try await SocketIOTestClient(port: server.port)
    do {
        _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
        socket.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
        _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
        return socket
    } catch {
        socket.close()
        throw error
    }
}

/// A unique received user-room marker bounds all application frames on one queue.
private func channelsEntryFrames(
    _ socket: SocketIOTestClient, hub: RealtimeHub, userId: String, start: Int
) async throws -> [String] {
    let nonce = UUID().uuidString.lowercased()
    let payload = "{\"nonce\":\"\(nonce)\"}"
    let fence = "42[\"test:channels-entry-fence\",\(payload)]"
    hub.emit(room: "user:\(userId)", event: "test:channels-entry-fence", payloadJSON: payload)
    _ = try #require(await socket.waitForText { $0 == fence })
    let frames = socket.textFrames
    let end = try #require(frames.indices.first { $0 >= start && frames[$0] == fence })
    return Array(frames[start..<end].filter { $0.hasPrefix("42") })
}

/// Does not join: the created-channel probe must observe the production grant.
private func channelsEntryProbe(
    _ socket: SocketIOTestClient, hub: RealtimeHub, channelId: String
) async throws -> String {
    let nonce = UUID().uuidString.lowercased()
    let payload = "{\"nonce\":\"\(nonce)\"}"
    let probe = "42[\"test:channels-entry-room-probe\",\(payload)]"
    hub.emit(room: "channel:\(channelId)", event: "test:channels-entry-room-probe", payloadJSON: payload)
    _ = try #require(await socket.waitForText { $0 == probe })
    return probe
}

@Test func channelsExplicitEntryKeepsSharedOwnersLivePoliciesAndHostPublications() async throws {
    let scene = ChannelsScene()
    let ownerId = "11111111-1111-4111-8111-111111111649"
    let memberId = "11111111-1111-4111-8111-111111111650"
    let serverId = "33333333-3333-4333-8333-333333333676"
    for (id, email) in [(ownerId, "channels-entry-owner@slock.test"), (memberId, "channels-entry-member@slock.test")] {
        scene.auth.addAccount(id: id, email: email, password: "password123")
        scene.auth.markEmailVerified(userId: id)
    }
    scene.channels.addOwnedServer(id: serverId, slug: "channels-entry", name: "Channels Entry", ownerId: ownerId)
    scene.channels.setMemberRole(serverId: serverId, userId: memberId, role: "member")
    let ownerToken = scene.auth.mintAccessTokenForTesting(userId: ownerId)
    let memberToken = scene.auth.mintAccessTokenForTesting(userId: memberId)
    let ownerHeaders = channelsEntryHeaders(token: ownerToken, serverId: serverId)
    let memberHeaders = channelsEntryHeaders(token: memberToken, serverId: serverId)
    let auth = ChannelsEntrySocketAuth(core: scene.services.identity.core, membership: scene.services.messaging.socketMembership)
    let serverA = try await RealtimeServer.start(auth: auth)
    let serverB: RealtimeServer
    do {
        serverB = try await RealtimeServer.start(auth: auth)
    } catch {
        try? await serverA.close()
        throw error
    }
    do {
        let socketA = try await channelsEntryConnect(serverA, token: ownerToken, serverId: serverId)
        defer { socketA.close() }
        let socketB = try await channelsEntryConnect(serverB, token: ownerToken, serverId: serverId)
        defer { socketB.close() }
        let hubA = serverA.hub
        let hubB = serverB.hub
        scene.services.messaging.realtime.install { room, event, payload in
            hubB.emit(room: room, event: event, payloadJSON: payload)
        }
        try await withApp { app in
            // This focused mount does not claim full-Fallback's private boundary.
            app.middleware.use(JSONErrorBoundaryMiddleware(), at: .beginning)
            try await app.register(collection: makeChannelsSceneFeature(scene, realtime: hubA))
            try await app.testing { client in
                let createStartA = socketA.textFrames.count
                let createStartB = socketB.textFrames.count
                let created = try await channelsEntryPost(
                    client, "/api/channels", headers: ownerHeaders,
                    body: #"{"name":"entry-room","description":"stored detail"}"#
                )
                #expect(created.status == .ok)
                let channelId = try #require(try channelsEntryJSON(created)["id"] as? String)
                #expect(created.body.string == "{\"id\":\"\(channelId)\",\"name\":\"entry-room\",\"joined\":true,\"activityMuteSupported\":true,\"activityMuted\":false,\"muteFromSeq\":null,\"prefsVersion\":0,\"maxReadSeq\":0,\"readStateVersion\":0}")
                // No test join precedes this probe: fixed user delivery must
                // already have granted A's sessions the actual new channel room.
                let creationProbe = try await channelsEntryProbe(socketA, hub: hubA, channelId: channelId)
                let createdFrame = "42[\"channel:updated\",{\"channel\":{\"description\":null,\"id\":\"\(channelId)\",\"joined\":true,\"name\":\"entry-room\"}}]"
                #expect(try await channelsEntryFrames(socketA, hub: hubA, userId: ownerId, start: createStartA) == [createdFrame, creationProbe])
                #expect(try await channelsEntryFrames(socketB, hub: hubB, userId: ownerId, start: createStartB) == [])

                let renameBody = #"{"name":"entry-renamed"}"#
                let denied = try await client.send(.patch, headers: memberHeaders, to: URI(string: "/api/channels/\(channelId)")) {
                    $0.body = .init(string: renameBody)
                }
                #expect(denied.status == .forbidden)
                #expect(denied.body.string == #"{"error":"Forbidden"}"#)
                scene.channels.setMemberRole(serverId: serverId, userId: memberId, role: "admin")
                let renamed = try await client.send(.patch, headers: memberHeaders, to: URI(string: "/api/channels/\(channelId)")) {
                    $0.body = .init(string: renameBody)
                }
                #expect(renamed.status == .ok)
                let seq = try #require(try channelsEntryJSON(renamed)["systemMessageSeq"] as? Int)
                #expect(seq > 0)
                #expect(renamed.body.string == "{\"id\":\"\(channelId)\",\"name\":\"entry-renamed\",\"description\":\"stored detail\",\"systemMessageSeq\":\(seq)}")
                let detail = try await client.get(URI(string: "/api/channels/\(channelId)"), headers: memberHeaders)
                #expect(detail.status == .ok)
                let detailBody = try channelsEntryJSON(detail)
                #expect(detailBody["id"] as? String == channelId)
                #expect(detailBody["name"] as? String == "entry-renamed")
                #expect(detailBody["channelRole"] as? String == "admin")
                #expect(detailBody["channelAdminBasis"] as? String == "server_role")
                let capabilities = try #require(detailBody["channelCapabilities"] as? [String: Any])
                #expect(capabilities["manageGuestAccess"] as? Bool == true)
                // The detail row publishes the same stored channel description
                // (upstream GET /channels/:id returns the channel row). Its live
                // name and authority prove scene sharing.
                #expect(detailBody["description"] as? String == "stored detail")

                let parentMessageId = scene.channels.appendParentMessage(channelId: channelId, senderId: ownerId, content: "entry parent")
                let thread = try await channelsEntryPost(
                    client, "/api/channels/\(channelId)/threads", headers: ownerHeaders,
                    body: "{\"parentMessageId\":\"\(parentMessageId)\"}"
                )
                #expect(thread.status == .ok)
                let threadId = try #require(try channelsEntryJSON(thread)["threadChannelId"] as? String)
                #expect(thread.body.string == "{\"threadChannelId\":\"\(threadId)\",\"replyCount\":0,\"lastReplyAt\":null,\"participantIds\":[]}")
                // Threads are not automatic handshake rooms. These public Hub
                // joins are transport setup, then each queue proves reachability.
                hubA.joinUserSessions(userId: ownerId, room: "channel:\(threadId)")
                hubB.joinUserSessions(userId: ownerId, room: "channel:\(threadId)")
                _ = try await channelsEntryProbe(socketA, hub: hubA, channelId: threadId)
                _ = try await channelsEntryProbe(socketB, hub: hubB, channelId: threadId)
                let followStartA = socketA.textFrames.count
                let followStartB = socketB.textFrames.count
                let followBody = "{\"threadChannelId\":\"\(threadId)\"}"
                let followed = try await channelsEntryPost(
                    client, "/api/channels/threads/follow", headers: memberHeaders, body: followBody
                )
                #expect(followed.status == .ok)
                #expect(followed.body.string == #"{"ok":true,"following":true}"#)
                let followerFrame = "42[\"thread:followers-updated\",{\"threadChannelId\":\"\(threadId)\"}]"
                #expect(try await channelsEntryFrames(socketA, hub: hubA, userId: ownerId, start: followStartA) == [])
                #expect(try await channelsEntryFrames(socketB, hub: hubB, userId: ownerId, start: followStartB) == [followerFrame])

                scene.services.messaging.realtime.install { room, event, payload in
                    hubA.emit(room: room, event: event, payloadJSON: payload)
                }
                let unfollowStartA = socketA.textFrames.count
                let unfollowStartB = socketB.textFrames.count
                let unfollowed = try await channelsEntryPost(
                    client, "/api/channels/threads/unfollow", headers: memberHeaders, body: followBody
                )
                #expect(unfollowed.status == .ok)
                #expect(unfollowed.body.string == #"{"ok":true,"following":false}"#)
                #expect(try await channelsEntryFrames(socketA, hub: hubA, userId: ownerId, start: unfollowStartA) == [followerFrame])
                #expect(try await channelsEntryFrames(socketB, hub: hubB, userId: ownerId, start: unfollowStartB) == [])
                scene.auth.revokeSessionFamilies(userId: memberId)
                let revoked = try await client.get(URI(string: "/api/channels/\(channelId)"), headers: memberHeaders)
                #expect(revoked.status == .unauthorized)
                #expect(revoked.body.string == #"{"error":"Unauthorized"}"#)
            }
        }
    } catch {
        try? await serverB.close()
        try? await serverA.close()
        throw error
    }
    do {
        try await serverB.close()
    } catch {
        try? await serverA.close()
        throw error
    }
    try await serverA.close()
}
