import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct TaskRealtimeAuth: RealtimeAuthorizing {
    let auth: AuthCoreService
    let membership: SocketMembershipService

    func userId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
}

/// The nonce bounds received RFC6455 data on this session's FIFO transport.
/// Every assertion reads the socket; no producer-side event recorder is used.
private func taskFramesThroughFence(_ socket: SocketIOTestClient, hub: RealtimeHub, userId: String, start: Int) async throws -> [String] {
    let nonce = UUID().uuidString.lowercased()
    let payload = "{\"nonce\":\"\(nonce)\"}"
    let fence = "42[\"test:task-fence\",\(payload)]"
    hub.emit(room: "user:\(userId)", event: "test:task-fence", payloadJSON: payload)
    _ = try #require(await socket.waitForText { $0 == fence })
    let frames = socket.textFrames
    let end = try #require(frames.indices.first { $0 >= start && frames[$0] == fence })
    return Array(frames[start..<end].filter { $0.hasPrefix("42") })
}

@Test func taskClaimEmitsOnlyTheTaskBoardEvent() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001035001"
    let ownerId = "11111111-1111-4111-8111-000001035001"
    let ownerEmail = "task-realtime-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-realtime", name: "Task Realtime", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "task-realtime-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "task-realtime-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let ids = accounts.taskCatalog.addTasks(channelId: channel, titles: ["canonical task"])
    let messageOnly = accounts.addChannelMessageForTesting(channelId: channel, content: "not a task", senderId: ownerId)
    let realtime = try await RealtimeServer.start(auth: TaskRealtimeAuth(auth: accounts.authCore, membership: accounts.socketMembership))
    do {
        let socket = try await SocketIOTestClient(port: realtime.port)
        defer { socket.close() }
        let hub = realtime.hub
        // The production RaftServer relay bridge forwards to a real Hub. It
        // records nothing; assertions below observe only received wire data.
        accounts.realtimeRelay.install { room, event, payload in
            hub.emit(room: room, event: event, payloadJSON: payload)
        }
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts,
                realtime: hub
            ))
            try await app.testing { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/json"
                let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
                }
                #expect(login.status == .ok)
                let loginBody = try #require(login.body.string)
                let loginObject = try #require(try JSONSerialization.jsonObject(with: Data(loginBody.utf8)) as? [String: Any])
                let token = try #require(loginObject["accessToken"] as? String)
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId

                _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
                socket.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
                _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
                // The authenticated membership handshake subscribes this real
                // session to the channel; verify its channel-room reachability.
                let roomProbe = "42[\"test:task-room\",{\"channelId\":\"\(channel)\"}]"
                hub.emit(room: "channel:\(channel)", event: "test:task-room", payloadJSON: "{\"channelId\":\"\(channel)\"}")
                _ = try #require(await socket.waitForText { $0 == roomProbe })

                let missingStart = socket.textFrames.count
                let refused = try await client.send(.patch, headers: headers, to: URI(string: "/api/tasks/\(messageOnly)/claim"))
                #expect(refused.status == .notFound)
                #expect(try await taskFramesThroughFence(socket, hub: hub, userId: ownerId, start: missingStart) == [])

                let claimStart = socket.textFrames.count
                let claimed = try await client.send(.patch, headers: headers, to: URI(string: "/api/tasks/\(ids[0])/claim"))
                #expect(claimed.status == .ok)
                let envelopeJSON = try #require(claimed.body.string)
                let envelope = try #require(try JSONSerialization.jsonObject(with: Data(envelopeJSON.utf8)) as? [String: Any])
                #expect(Set(envelope.keys) == ["task"])
                let task = try #require(envelope["task"] as? [String: Any])
                #expect(envelopeJSON.hasPrefix("{\"task\":"))
                let taskJSON = String(envelopeJSON.dropFirst(8).dropLast())
                #expect(Set(task.keys) == Set(["id", "messageId", "channelId", "channelName", "channelType", "taskNumber", "title", "description", "status", "createdByType", "createdById", "createdByName", "createdByMembershipStatus", "claimedByType", "claimedById", "claimedByName", "claimedAt", "completedAt", "requiresResourceReceipt", "resourceReceipt", "resourceReceiptRecordedAt", "resourceTeardownOwnerAgentId", "resourceExpiryFollowupId", "createdAt", "updatedAt", "revision", "taskCurrentProjection", "isLegacy"]))
                #expect(task["id"] as? String == ids[0])
                #expect(task["channelId"] as? String == channel)
                #expect(task["title"] as? String == "canonical task")
                #expect(task["status"] as? String == "in_progress")
                #expect(task["taskNumber"] as? Int == 1)
                #expect(task["claimedById"] as? String == ownerId)
                #expect(task["claimedByType"] as? String == "user")
                #expect((task["claimedAt"] as? String)?.isEmpty == false)
                #expect((task["messageId"] as? String)?.isEmpty == false)
                #expect(task["revision"] as? Int == 1)
                let updated = "42[\"task:updated\",{\"channelId\":\"\(channel)\",\"task\":\(taskJSON)}]"
                #expect(try await taskFramesThroughFence(socket, hub: hub, userId: ownerId, start: claimStart) == [updated], "the only application frame is the exact task board update, with no message update")

                let deleteStart = socket.textFrames.count
                let deleted = try await client.send(.delete, headers: headers, to: URI(string: "/api/channels/\(channel)"))
                #expect(deleted.status == .ok)
                // Drain deletion's own output before observing the next claim;
                // this test does not constrain legitimate cleanup frames.
                _ = try await taskFramesThroughFence(socket, hub: hub, userId: ownerId, start: deleteStart)

                let deletedClaimStart = socket.textFrames.count
                let deletedClaim = try await client.send(.patch, headers: headers, to: URI(string: "/api/tasks/\(ids[0])/claim"))
                #expect(deletedClaim.status == .conflict)
                #expect(deletedClaim.body.string == #"{"error":"This channel was deleted; the task can only be closed","code":"channel_deleted_terminal_only"}"#)
                #expect(try await taskFramesThroughFence(socket, hub: hub, userId: ownerId, start: deletedClaimStart) == [], "the rejected claim emits neither a task update nor a message update")
            }
        }
    } catch {
        try? await realtime.close()
        throw error
    }
    try await realtime.close()
}
