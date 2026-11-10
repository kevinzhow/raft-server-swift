import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ChannelCompositionAuth: RealtimeAuthorizing {
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

private struct ChannelCompositionFixture: Sendable {
    let accounts = EmailLoginDirectory()
    let ownerId = UUID().uuidString.lowercased()
    let memberId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    var memberEmail: String { "\(memberId)@channel-composition.test" }
    init() {
        for id in [ownerId, memberId] {
            accounts.addAccount(id: id, email: "\(id)@channel-composition.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "channel-composition", name: "Channel Composition", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    }
    var auth: ChannelCompositionAuth {
        ChannelCompositionAuth(auth: accounts.authCore, membership: accounts.socketMembership)
    }
    func headers(token: String) -> HTTPFields {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        fields[.authorization] = "Bearer \(token)"
        fields[HTTPField.Name("X-Server-Id")!] = serverId
        return fields
    }
}

private struct ChannelCompositionSocket {
    let client: SocketIOTestClient
    let userId: String
    var start: Int
    var reset: Self { Self(client: client, userId: userId, start: client.textFrames.count) }
}

private func channelCompositionConnect(_ fixture: ChannelCompositionFixture, server: RealtimeServer) async throws -> ChannelCompositionSocket {
    let client = try await SocketIOTestClient(port: server.port)
    _ = try #require(await client.waitForText { $0.hasPrefix("0") })
    let token = fixture.accounts.mintAccessTokenForTesting(userId: fixture.ownerId)
    client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(fixture.serverId)\"}")
    _ = try #require(await client.waitForText { $0 == "42[\"rooms:joined\"]" })
    return ChannelCompositionSocket(client: client, userId: fixture.ownerId, start: client.textFrames.count)
}

/// Bound the wire window using a frame on the same session queue. This observes
/// all application frames over the real socket, without an emitter recorder.
private func channelCompositionFrames(_ sockets: [ChannelCompositionSocket], hub: RealtimeHub) async throws -> [[String]] {
    let nonce = UUID().uuidString.lowercased()
    let fence = "42[\"test:channel-composition-fence\",{\"nonce\":\"\(nonce)\"}]"
    for userId in Set(sockets.map(\.userId)) {
        hub.emit(room: "user:\(userId)", event: "test:channel-composition-fence", payloadJSON: "{\"nonce\":\"\(nonce)\"}")
    }
    var result: [[String]] = []
    for socket in sockets {
        _ = try #require(await socket.client.waitForText { $0 == fence })
        let frames = socket.client.textFrames
        let end = try #require(frames.indices.first { $0 >= socket.start && frames[$0] == fence })
        result.append(try frames[socket.start..<end].filter { $0.hasPrefix("42") }.map { frame in
            if frame.hasPrefix(#"42["message:new""#) || frame.hasPrefix(#"42["task:created""#) {
                let json = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(2).utf8))
                return "42" + String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
            }
            return frame
        })
    }
    return result
}

private func channelCompositionObject(_ body: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
}

private func channelCompositionTaskIDs(_ body: String) throws -> [String] {
    let response = try channelCompositionObject(body)
    #expect(Set(response.keys) == ["tasks"])
    return try #require(response["tasks"] as? [[String: Any]]).map { try #require($0["id"] as? String) }
}

/// Node emits plain host messages, a canonical task-board batch and the
/// persisted system summary. IDs/timestamps are checked against public history.
private func channelCompositionCreationFrames(_ client: any Client, channelId: String, body: String, headers: HTTPFields) async throws -> [String] {
    let tasks = try #require(channelCompositionObject(body)["tasks"] as? [[String: Any]])
    let history = try await client.get(URI(string: "/api/messages/channel/\(channelId)?limit=50"), headers: headers)
    #expect(history.status == .ok)
    let messages = try #require(channelCompositionObject(history.body.string ?? "")["messages"] as? [[String: Any]])
    func frame(_ event: String, _ payload: [String: Any]) throws -> String {
        "42" + String(decoding: try JSONSerialization.data(withJSONObject: [event, payload], options: [.sortedKeys]), as: UTF8.self)
    }
    func messageFrame(_ row: [String: Any], content: String, senderName: String, system: Bool = false) throws -> String {
        let id = try #require(row["id"] as? String)
        let seq = try #require(row["seq"] as? Int)
        #expect(seq > 0)
        let senderId = try #require(row["senderId"] as? String)
        let senderType = try #require(row["senderType"] as? String)
        let type = try #require(row["messageType"] as? String)
        let at = try #require(row["createdAt"] as? String)
        var payload: [String: Any] = [
            "id": id, "seq": seq, "channelId": channelId, "senderType": senderType, "senderId": senderId,
            "randomId": NSNull(), "messageType": type, "content": content,
            "actionMetadata": NSNull(), "threadId": NSNull(), "taskStatus": NSNull(), "taskNumber": NSNull(),
            "taskAssigneeType": NSNull(), "taskAssigneeId": NSNull(), "taskClaimedAt": NSNull(), "taskCompletedAt": NSNull(),
            "createdAt": at, "updatedAt": at, "senderName": senderName,
        ]
        if system {
            #expect(senderId == "system")
            #expect(senderType == "user")
            #expect(row["senderMembershipStatus"] is NSNull)
            payload["senderDescription"] = NSNull()
            payload["senderMembershipStatus"] = NSNull()
            payload["attachments"] = [Any]()
            payload["mentions"] = [Any]()
            payload["reactions"] = [Any]()
            payload["commentRef"] = NSNull()
            payload["externalAuthor"] = NSNull()
            payload["causalActorType"] = "user"
            payload["causalActorId"] = try #require(tasks.first?["createdById"] as? String)
            payload["systemSubtype"] = "task.created_summary"
            payload["conversationContext"] = ["channelType": try #require(tasks.first?["channelType"] as? String)]
        }
        return try frame("message:new", payload)
    }
    var result: [String] = []
    for task in tasks {
        let id = try #require(task["messageId"] as? String)
        let message = try #require(messages.first { $0["id"] as? String == id })
        let title = try #require(task["title"] as? String)
        #expect(message["content"] as? String == title)
        result.append(try messageFrame(message, content: title, senderName: try #require(task["createdByName"] as? String)))
    }
    let eventKeys: Set<String> = ["id", "messageId", "channelId", "channelName", "channelType", "taskNumber", "title", "description", "status", "claimedByType", "claimedById", "claimedByName", "claimedAt", "completedAt", "createdByType", "createdById", "createdByName", "createdAt", "updatedAt", "revision", "taskCurrentProjection", "isLegacy"]
    let eventTasks = tasks.map { $0.filter { eventKeys.contains($0.key) } }
    #expect(eventTasks.allSatisfy { Set($0.keys) == eventKeys })
    result.append(try frame("task:created", ["channelId": channelId, "tasks": eventTasks]))
    let list = try tasks.map { task in
        "#\(try #require(task["taskNumber"] as? Int)) \"\(try #require(task["title"] as? String))\""
    }.joined(separator: ", ")
    let summaryText = "📋 \(tasks.count) new task\(tasks.count > 1 ? "s" : "") created: \(list)"
    let summary = try #require(messages.last { $0["content"] as? String == summaryText })
    #expect(summary["messageType"] as? String == "system")
    result.append(try messageFrame(summary, content: summaryText, senderName: "System", system: true))
    return result
}

@Suite(.serialized)
struct ChannelMessagingCompositionSocketTests {
    @Test(arguments: [false, true])
    func fixedOptionalUserHubAndReplaceableGeneralRelayKeepTheirDistinctFrames(hasFallbackHub: Bool) async throws {
        let fixture = ChannelCompositionFixture()
        let fixed = try await RealtimeServer.start(auth: fixture.auth)
        let replacement = try await RealtimeServer.start(auth: fixture.auth)
        var fixedSockets = [try await channelCompositionConnect(fixture, server: fixed), try await channelCompositionConnect(fixture, server: fixed)]
        var replacementSockets = [try await channelCompositionConnect(fixture, server: replacement)]
        defer {
            for socket in fixedSockets + replacementSockets { socket.client.close() }
            Task { try? await fixed.close(); try? await replacement.close() }
        }
        let replacementHub = replacement.hub
        fixture.accounts.realtimeRelay.install { room, event, payload in
            replacementHub.emit(room: room, event: event, payloadJSON: payload)
        }
        let ownerToken = fixture.accounts.mintAccessTokenForTesting(userId: fixture.ownerId)
        let headers = fixture.headers(token: ownerToken)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts, realtime: hasFallbackHub ? fixed.hub : nil))
            try await app.testing { client in
                let created = try await client.send(.post, headers: headers, to: "/api/channels") {
                    $0.body = .init(string: "{\"name\":\"composed-room\",\"description\":\"stored description\"}")
                }
                #expect(created.status == .ok)
                let channelId = try #require(channelCompositionObject(created.body.string ?? "")["id"] as? String)
                let updated = "42[\"channel:updated\",{\"channel\":{\"description\":null,\"id\":\"\(channelId)\",\"joined\":true,\"name\":\"composed-room\"}}]"
                // Probe the actual new channel room before fencing. Existing
                // sessions must already have been joined by the fixed Hub.
                fixed.hub.emit(room: "channel:\(channelId)", event: "test:room-probe", payloadJSON: "{}")
                let expectedFixed = hasFallbackHub ? [updated, "42[\"test:room-probe\",{}]"] : []
                #expect(try await channelCompositionFrames(fixedSockets, hub: fixed.hub) == [expectedFixed, expectedFixed])
                #expect(try await channelCompositionFrames(replacementSockets, hub: replacement.hub) == [[]])

                fixedSockets = fixedSockets.map(\.reset)
                replacementSockets = replacementSockets.map(\.reset)
                // A new socket obtains the newly-created channel through the
                // normal membership handshake, on the replacement server.
                replacementSockets.append(try await channelCompositionConnect(fixture, server: replacement))
                let fixedHub = fixed.hub
                fixture.accounts.realtimeRelay.install { room, event, payload in
                    fixedHub.emit(room: room, event: event, payloadJSON: payload)
                }
                let tasks = try await client.send(.post, headers: headers, to: URI(string: "/api/tasks/channel/\(channelId)")) {
                    $0.body = .init(string: "{\"tasks\":[{\"title\":\"first\",\"description\":\"first detail\"},{\"title\":\"second\",\"description\":\"second detail\"}]}")
                }
                #expect(tasks.status == .ok)
                let ids = try channelCompositionTaskIDs(tasks.body.string ?? "")
                try #require(ids.count == 2)
                let expectedCreated = try await channelCompositionCreationFrames(client, channelId: channelId, body: tasks.body.string ?? "", headers: headers)
                #expect(try await channelCompositionFrames(fixedSockets, hub: fixed.hub) == [hasFallbackHub ? expectedCreated : [], hasFallbackHub ? expectedCreated : []])
                #expect(try await channelCompositionFrames(replacementSockets, hub: replacement.hub) == [[], []])
                for (index, title) in ["first", "second"].enumerated() {
                    let numbered = try await client.get(URI(string: "/api/tasks/channel/\(channelId)/number/\(index + 1)"), headers: headers)
                    #expect(numbered.status == .ok)
                    let row = try #require(channelCompositionObject(numbered.body.string ?? "")["task"] as? [String: Any])
                    #expect(row["id"] as? String == ids[index])
                    #expect(row["title"] as? String == title)
                    #expect(row["description"] as? String == "\(title) detail")
                }

                fixedSockets = fixedSockets.map(\.reset)
                replacementSockets = replacementSockets.map(\.reset)
                fixture.accounts.realtimeRelay.install { room, event, payload in
                    replacementHub.emit(room: room, event: event, payloadJSON: payload)
                }
                let claimed = try await client.send(.patch, headers: headers, to: URI(string: "/api/tasks/\(ids[0])/claim"))
                #expect(claimed.status == .ok)
                let envelopeJSON = try #require(claimed.body.string)
                let envelope = try channelCompositionObject(envelopeJSON)
                #expect(Set(envelope.keys) == ["task"])
                let task = try #require(envelope["task"] as? [String: Any])
                #expect(envelopeJSON.hasPrefix("{\"task\":"))
                let canonicalTask = String(envelopeJSON.dropFirst(8).dropLast())
                #expect(task["id"] as? String == ids[0])
                #expect(task["status"] as? String == "in_progress")
                let expectedUpdated = "42[\"task:updated\",{\"channelId\":\"\(channelId)\",\"task\":\(canonicalTask)}]"
                #expect(try await channelCompositionFrames(fixedSockets, hub: fixed.hub) == [[], []])
                #expect(try await channelCompositionFrames(replacementSockets, hub: replacement.hub) == [[], [expectedUpdated]])

                fixedSockets = fixedSockets.map(\.reset)
                replacementSockets = replacementSockets.map(\.reset)
                let refused = try await client.send(.patch, headers: headers, to: "/api/tasks/not-a-task/claim")
                #expect(refused.status == .notFound)
                #expect(try await channelCompositionFrames(fixedSockets, hub: fixed.hub) == [[], []])
                #expect(try await channelCompositionFrames(replacementSockets, hub: replacement.hub) == [[], []])
            }
        }
    }

    @Test func taskAccessArchiveRawRoleAndSessionRevocationStayLiveAfterRegistration() async throws {
        let fixture = ChannelCompositionFixture()
        let channelId = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "live-policy", creatorUserId: fixture.ownerId)
        fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: channelId, memberId: fixture.ownerId, name: "live-policy")
        fixture.accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.ownerId)
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        var sockets = [try await channelCompositionConnect(fixture, server: realtime)]
        defer {
            for socket in sockets { socket.client.close() }
            Task { try? await realtime.close() }
        }
        let hub = realtime.hub
        fixture.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts, realtime: hub))
            try await app.testing { client in
                var jsonHeaders = HTTPFields()
                jsonHeaders[.contentType] = "application/json"
                let login = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/login") {
                    $0.body = .init(string: "{\"email\":\"\(fixture.memberEmail)\",\"password\":\"password123\"}")
                }
                #expect(login.status == .ok)
                let session = try channelCompositionObject(login.body.string ?? "")
                let token = try #require(session["accessToken"] as? String)
                let refreshToken = try #require(session["refreshToken"] as? String)
                let headers = fixture.headers(token: token)
                let path = URI(string: "/api/tasks/channel/\(channelId)")
                let readOnly = try await client.send(.post, headers: headers, to: path) { $0.body = .init(string: "{}") }
                #expect(readOnly.status == .forbidden)
                #expect(readOnly.body.string == "{\"error\":\"You must join this channel to modify tasks\"}")
                #expect(try await channelCompositionFrames(sockets, hub: hub) == [[]])

                sockets = sockets.map(\.reset)
                fixture.accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.memberId)
                fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: channelId, memberId: fixture.memberId, name: "live-policy")
                let allowed = try await client.send(.post, headers: headers, to: path) { $0.body = .init(string: "{\"tasks\":[{\"title\":\"allowed\"}]}") }
                #expect(allowed.status == .ok)
                let allowedIds = try channelCompositionTaskIDs(allowed.body.string ?? "")
                let allowedFrames = try await channelCompositionCreationFrames(client, channelId: channelId, body: allowed.body.string ?? "", headers: headers)
                #expect(try await channelCompositionFrames(sockets, hub: hub) == [allowedFrames])

                sockets = sockets.map(\.reset)
                fixture.accounts.oauth.setChannelArchived(id: channelId, archivedAt: Date())
                let archived = try await client.send(.post, headers: headers, to: path) { $0.body = .init(string: "{}") }
                #expect(archived.status == .conflict)
                #expect(archived.body.string == "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
                #expect(try await channelCompositionFrames(sockets, hub: hub) == [[]])

                sockets = sockets.map(\.reset)
                fixture.accounts.oauth.setChannelArchived(id: channelId, archivedAt: nil)
                fixture.accounts.oauth.removeMember(serverId: fixture.serverId, userId: fixture.memberId)
                let removed = try await client.send(.post, headers: headers, to: path) { $0.body = .init(string: "{}") }
                #expect(removed.status == .forbidden)
                #expect(removed.body.string == "{\"error\":\"Not a member of this server\"}")
                #expect(try await channelCompositionFrames(sockets, hub: hub) == [[]])

                sockets = sockets.map(\.reset)
                fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.memberId, role: "custom-member")
                let rawRole = try await client.send(.post, headers: headers, to: path) { $0.body = .init(string: "{\"tasks\":[{\"title\":\"raw role\"}]}") }
                #expect(rawRole.status == .ok)
                let rawIds = try channelCompositionTaskIDs(rawRole.body.string ?? "")
                let rawFrames = try await channelCompositionCreationFrames(client, channelId: channelId, body: rawRole.body.string ?? "", headers: headers)
                #expect(try await channelCompositionFrames(sockets, hub: hub) == [rawFrames])

                sockets = sockets.map(\.reset)
                let logout = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/logout") {
                    $0.body = .init(string: "{\"refreshToken\":\"\(refreshToken)\"}")
                }
                #expect(logout.status == .ok)
                let revoked = try await client.send(.post, headers: headers, to: path) { $0.body = .init(string: "{}") }
                #expect(revoked.status == .unauthorized)
                #expect(revoked.body.string == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
                #expect(try await channelCompositionFrames(sockets, hub: hub) == [[]])
                let ownerHeaders = fixture.headers(token: fixture.accounts.mintAccessTokenForTesting(userId: fixture.ownerId))
                let list = try await client.get(path, headers: ownerHeaders)
                #expect(list.status == .ok)
                let rows = try #require(channelCompositionObject(list.body.string ?? "")["tasks"] as? [[String: Any]])
                #expect(Set(rows.compactMap { $0["id"] as? String }) == Set(allowedIds + rawIds))
            }
        }
    }

    @Test func sameRootFallbacksKeepHubAHubBAndNilSeparateAfterAllAreRegistered() async throws {
        let fixture = ChannelCompositionFixture()
        let serverA = try await RealtimeServer.start(auth: fixture.auth)
        let serverB = try await RealtimeServer.start(auth: fixture.auth)
        var socketsA = [try await channelCompositionConnect(fixture, server: serverA)]
        var socketsB = [try await channelCompositionConnect(fixture, server: serverB)]
        defer {
            for socket in socketsA + socketsB { socket.client.close() }
            Task { try? await serverA.close(); try? await serverB.close() }
        }
        let hubB = serverB.hub
        fixture.accounts.realtimeRelay.install { room, event, payload in hubB.emit(room: room, event: event, payloadJSON: payload) }
        let headers = fixture.headers(token: fixture.accounts.mintAccessTokenForTesting(userId: fixture.ownerId))
        try await withApp { appA in
            try await withApp { appB in
                try await withApp { appNil in
                    // All three Fallback values share the same owners. The last
                    // registration must not replace the earlier fixed user sink.
                    configure(appA, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts, realtime: serverA.hub))
                    configure(appB, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts, realtime: serverB.hub))
                    configure(appNil, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
                    let channelA = try await appA.testing { client in
                        let response = try await client.send(.post, headers: headers, to: "/api/channels") { $0.body = .init(string: "{\"name\":\"only-a\"}") }
                        #expect(response.status == .ok)
                        return try #require(channelCompositionObject(response.body.string ?? "")["id"] as? String)
                    }
                    serverA.hub.emit(room: "channel:\(channelA)", event: "test:room-a", payloadJSON: "{}")
                    serverB.hub.emit(room: "channel:\(channelA)", event: "test:wrong-room", payloadJSON: "{}")
                    let updatedA = "42[\"channel:updated\",{\"channel\":{\"description\":null,\"id\":\"\(channelA)\",\"joined\":true,\"name\":\"only-a\"}}]"
                    #expect(try await channelCompositionFrames(socketsA, hub: serverA.hub) == [[updatedA, "42[\"test:room-a\",{}]"]])
                    #expect(try await channelCompositionFrames(socketsB, hub: serverB.hub) == [[]])

                    socketsA = socketsA.map(\.reset)
                    socketsB = socketsB.map(\.reset)
                    let channelB = try await appB.testing { client in
                        let response = try await client.send(.post, headers: headers, to: "/api/channels") { $0.body = .init(string: "{\"name\":\"only-b\"}") }
                        #expect(response.status == .ok)
                        return try #require(channelCompositionObject(response.body.string ?? "")["id"] as? String)
                    }
                    serverB.hub.emit(room: "channel:\(channelB)", event: "test:room-b", payloadJSON: "{}")
                    serverA.hub.emit(room: "channel:\(channelB)", event: "test:wrong-room", payloadJSON: "{}")
                    let updatedB = "42[\"channel:updated\",{\"channel\":{\"description\":null,\"id\":\"\(channelB)\",\"joined\":true,\"name\":\"only-b\"}}]"
                    #expect(try await channelCompositionFrames(socketsB, hub: serverB.hub) == [[updatedB, "42[\"test:room-b\",{}]"]])
                    #expect(try await channelCompositionFrames(socketsA, hub: serverA.hub) == [[]])

                    socketsA = socketsA.map(\.reset)
                    socketsB = socketsB.map(\.reset)
                    let channelNil = try await appNil.testing { client in
                        let response = try await client.send(.post, headers: headers, to: "/api/channels") { $0.body = .init(string: "{\"name\":\"no-user-hub\"}") }
                        #expect(response.status == .ok)
                        return try #require(channelCompositionObject(response.body.string ?? "")["id"] as? String)
                    }
                    for hub in [serverA.hub, serverB.hub] {
                        hub.emit(room: "channel:\(channelNil)", event: "test:wrong-room", payloadJSON: "{}")
                    }
                    #expect(try await channelCompositionFrames(socketsA, hub: serverA.hub) == [[]])
                    #expect(try await channelCompositionFrames(socketsB, hub: serverB.hub) == [[]])
                }
            }
        }
    }
}
