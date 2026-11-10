import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import Vapor
import VaporTesting

/// Locks the channel-messaging task creation operation and the realtime frame
/// it owns, both before and after the Feature -> Service -> Store migration.
///
/// `POST /api/tasks/channel/:channelId` is the `task:created` producer. The
/// upstream contract is the exact reply JSON, the usual JSON headers, and the
/// `channel:<id>` / `task:created` frame whose payload is sorted-key JSON.

private struct ChannelMessagingSocketAuth: RealtimeAuthorizing {
    let core: AuthCoreService
    let membership: SocketMembershipService
    func userId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
}

private func channelMessagingLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    let body = (response.body.string ?? "").data(using: .utf8) ?? Data()
    return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func channelMessagingHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

@Test func createChannelTasksPublishesTheTypedTaskCreatedFrame() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111772001"
    let serverId = "33333333-3333-4333-8333-333333772001"
    accounts.addAccount(id: ownerId, email: "channel-messaging-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-messaging", name: "Channel Messaging", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "builder", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "builder")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    let realtime = try await RealtimeServer.start(auth: ChannelMessagingSocketAuth(core: accounts.authCore, membership: accounts.socketMembership))
    let socket = try await SocketIOTestClient(port: realtime.port)
    defer { socket.close(); Task { try? await realtime.close() } }
    _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
    let socketToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    socket.send("40{\"token\":\"\(socketToken)\",\"serverId\":\"\(serverId)\"}")
    _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
    let frameStart = socket.textFrames.count
    let hub = realtime.hub
    accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelMessagingLogin(client, email: "channel-messaging-owner@slock.test")
            let headers = channelMessagingHeaders(token, serverId)
            let created = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"ship it\",\"description\":\"with tests\"}]}")
            }
            #expect(created.status == .ok)
            #expect(created.headers[.contentType] == "application/json; charset=utf-8")
            #expect(created.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            let body = created.body.string ?? ""
            #expect(body.hasPrefix(#"{"tasks":[{"#))
            #expect(created.headers[.contentLength] == String(body.utf8.count))
            let response = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            #expect(Set(response.keys) == ["tasks"])
            let tasks = try #require(response["tasks"] as? [[String: Any]])
            #expect(tasks.count == 1)
            let task = try #require(tasks.first)
            #expect(task["title"] as? String == "ship it")
            #expect(task["description"] as? String == "with tests")
            #expect(task["status"] as? String == "todo")
            let hostId = try #require(task["messageId"] as? String)
            #expect(task["id"] as? String != hostId)
            let fence = #"42["test:task68-fence",{}]"#
            hub.emit(room: "user:\(ownerId)", event: "test:task68-fence", payloadJSON: "{}")
            _ = try #require(await socket.waitForText { $0 == fence })
            let frames = socket.textFrames.dropFirst(frameStart).prefix { $0 != fence }
            #expect(frames.count == 3)
            let decoded = try frames.map { try #require(try JSONSerialization.jsonObject(with: Data($0.dropFirst(2).utf8)) as? [Any]) }
            #expect(decoded.compactMap { $0.first as? String } == ["message:new", "task:created", "message:new"])
            let host = try #require(decoded.first?[1] as? [String: Any])
            #expect(host["id"] as? String == hostId)
            #expect(host["content"] as? String == "ship it")
            #expect(host["channelId"] as? String == channelId)
            #expect(host["senderId"] as? String == ownerId)
            #expect(host["messageType"] as? String == "chat")
            let hostSeq = try #require(host["seq"] as? Int)
            #expect(hostSeq > 0)
            let board = try #require(decoded[1][1] as? [String: Any])
            #expect(Set(board.keys) == ["channelId", "tasks"])
            #expect(board["channelId"] as? String == channelId)
            let boardTasks = try #require(board["tasks"] as? [[String: Any]])
            let omitted: Set<String> = ["createdByMembershipStatus", "requiresResourceReceipt", "resourceReceipt", "resourceReceiptRecordedAt", "resourceTeardownOwnerAgentId", "resourceExpiryFollowupId"]
            #expect(boardTasks.count == 1)
            #expect(NSDictionary(dictionary: try #require(boardTasks.first)) == NSDictionary(dictionary: task.filter { !omitted.contains($0.key) }))
            let summary = try #require(decoded.last?[1] as? [String: Any])
            #expect(summary["messageType"] as? String == "system")
            #expect(summary["senderType"] as? String == "user")
            #expect(summary["senderId"] as? String == "system")
            #expect(summary["senderName"] as? String == "System")
            #expect(summary["senderDescription"] is NSNull)
            #expect(summary["senderMembershipStatus"] is NSNull)
            #expect((summary["attachments"] as? [Any])?.isEmpty == true)
            #expect((summary["mentions"] as? [Any])?.isEmpty == true)
            #expect((summary["reactions"] as? [Any])?.isEmpty == true)
            #expect(summary["commentRef"] is NSNull)
            #expect(summary["externalAuthor"] is NSNull)
            #expect(summary["causalActorType"] as? String == "user")
            #expect(summary["causalActorId"] as? String == ownerId)
            #expect(summary["systemSubtype"] as? String == "task.created_summary")
            #expect(summary["conversationContext"] as? [String: String] == ["channelType": "channel"])
            #expect(try #require(summary["seq"] as? Int) > hostSeq)
            #expect(boardTasks.allSatisfy { $0["seq"] == nil })
            #expect(summary["content"] as? String == #"📋 1 new task created: #1 "ship it""#)

        }
    }
}

@Test func createChannelTasksKeepsEveryPublishedErrorByteIdentical() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111772002"
    let memberId = "11111111-1111-4111-8111-111111772003"
    let serverId = "33333333-3333-4333-8333-333333772002"
    for (id, email) in [
        (ownerId, "channel-messaging-errors-owner@slock.test"),
        (memberId, "channel-messaging-errors-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-messaging-errors", name: "Errors", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "errors", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "errors")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelMessagingLogin(client, email: "channel-messaging-errors-owner@slock.test")
            let memberToken = try await channelMessagingLogin(client, email: "channel-messaging-errors-member@slock.test")
            let headers = channelMessagingHeaders(token, serverId)
            let memberHeaders = channelMessagingHeaders(memberToken, serverId)

            // Missing auth: 401 before any policy read.
            let unauthorized = try await client.send(.post, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(unauthorized.status == .unauthorized)
            #expect(unauthorized.body.string == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")

            // Not a server member: 403.
            accounts.oauth.removeMember(serverId: serverId, userId: memberId)
            let notMember = try await client.send(.post, headers: memberHeaders, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(notMember.status == .forbidden)
            #expect(notMember.body.string == "{\"error\":\"Not a member of this server\"}")
            accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

            // Unknown channel: 404.
            let missing = try await client.send(.post, headers: headers, to: "/api/tasks/channel/not-a-channel") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(missing.status == .notFound)
            #expect(missing.body.string == "{\"error\":\"Channel not found\"}")

            // Public channel non-member: 403 before the archived and body checks.
            let readOnly = try await client.send(.post, headers: memberHeaders, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(readOnly.status == .forbidden)
            #expect(readOnly.body.string == "{\"error\":\"You must join this channel to modify tasks\"}")

            // Archived channel: 409 with the machine-readable code.
            accounts.oauth.setChannelArchived(id: channelId, archivedAt: Date())
            let archived = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(archived.status == .conflict)
            #expect(archived.body.string == "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
            accounts.oauth.setChannelArchived(id: channelId, archivedAt: nil)

            // Malformed and empty task lists keep the 400.
            for (bodyJSON, error) in [
                ("{}", "tasks array is required"),
                ("{\"tasks\":[]}", "tasks array is required"),
                ("{\"tasks\":[\"nope\"]}", "Each task must have a non-empty title"),
                ("{\"tasks\":null}", "tasks array is required"),
            ] {
                let invalid = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                    request.body = .init(string: bodyJSON)
                }
                #expect(invalid.status == .badRequest, "expected 400 for \(bodyJSON)")
                #expect(invalid.body.string == "{\"error\":\"\(error)\"}")
            }
        }
    }
}

@Test func createChannelTasksRejectsTheEntireBatchForAnInvalidTitle() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111772004"
    let serverId = "33333333-3333-4333-8333-333333772003"
    accounts.addAccount(id: ownerId, email: "channel-messaging-lenient@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-messaging-lenient", name: "Lenient", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "lenient", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "lenient")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelMessagingLogin(client, email: "channel-messaging-lenient@slock.test")
            let headers = channelMessagingHeaders(token, serverId)
            let created = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                // Node rejects the whole batch before writing any task or message.
                request.body = .init(string: "{\"tasks\":[{\"title\":\"\"},{\"title\":5},{\"title\":\"kept\"}]}")
            }
            #expect(created.status == .badRequest)
            #expect(created.body.string == "{\"error\":\"Each task must have a non-empty title\"}")
            let listed = try await client.get(URI(string: "/api/tasks/channel/\(channelId)"), headers: headers)
            #expect(listed.body.string == "{\"tasks\":[]}")

        }
    }
}
