import Foundation
import RaftHTTP
import RaftRealtime
import Testing

private struct PublisherBindingSocket {
    let client: SocketIOTestClient
    let hub: RealtimeHub
    let userId: String
    let start: Int

    var reset: Self { Self(client: client, hub: hub, userId: userId, start: client.textFrames.count) }
}

private func publisherBindingConnect(_ fixture: PublisherBindingFixture, server: RealtimeServer) async throws -> PublisherBindingSocket {
    let client = try await SocketIOTestClient(port: server.port)
    do {
        _ = try #require(await client.waitForText { $0.hasPrefix("0") })
        client.send("40{\"token\":\"\(fixture.token)\",\"serverId\":\"\(fixture.serverId)\"}")
        _ = try #require(await client.waitForText { $0 == "42[\"rooms:joined\"]" })
        server.hub.joinUserSessions(userId: fixture.userId, room: "channel:\(fixture.threadId)")
        for channelId in [fixture.channelId, fixture.threadId] {
            let nonce = UUID().uuidString.lowercased()
            let payload = "{\"channelId\":\"\(channelId)\",\"nonce\":\"\(nonce)\"}"
            let probe = "42[\"test:publisher-room\",\(payload)]"
            server.hub.emit(room: "channel:\(channelId)", event: "test:publisher-room", payloadJSON: payload)
            _ = try #require(await client.waitForText { $0 == probe })
        }
        return PublisherBindingSocket(client: client, hub: server.hub, userId: fixture.userId, start: client.textFrames.count)
    } catch {
        client.close()
        throw error
    }
}

/// Fence the real session queue after the synchronous service call returned.
private func publisherBindingFrames(_ socket: PublisherBindingSocket) async throws -> [String] {
    let nonce = UUID().uuidString.lowercased()
    let payload = "{\"nonce\":\"\(nonce)\"}"
    let fence = "42[\"test:publisher-fence\",\(payload)]"
    socket.hub.emit(room: "user:\(socket.userId)", event: "test:publisher-fence", payloadJSON: payload)
    _ = try #require(await socket.client.waitForText { $0 == fence })
    let frames = socket.client.textFrames
    let end = try #require(frames.indices.first { $0 >= socket.start && frames[$0] == fence })
    return Array(frames[socket.start..<end].filter { $0.hasPrefix("42") })
}

private func publisherBindingTaskJSON(_ response: ChannelTaskResponse, fact: PublisherBindingTask, fixture: PublisherBindingFixture) throws -> String {
    let task = response.task
    let claimedAt = try #require(task.claimedAt)
    #expect(task.id == fact.id)
    #expect(task.channelId == fixture.channelId)
    #expect(task.messageId == fact.messageId)
    #expect(task.title == fact.title)
    #expect(task.status == "in_progress")
    #expect(task.taskNumber == fact.number)
    #expect(task.claimedById == fixture.userId)
    #expect(task.claimedByType == "user")
    #expect(task.revision == 1)
    #expect(!claimedAt.isEmpty)
    #expect(task.createdById == fixture.userId)
    #expect(task.createdByType == "user")
    #expect(task.createdByMembershipStatus == "active")
    let envelope = try #require(try JSONSerialization.jsonObject(with: Data(response.jsonBody.render().utf8)) as? [String: Any])
    #expect(Set(envelope.keys) == ["task"])
    return task.jsonBody.render()
}

private func publisherBindingTaskRow(_ response: ServerTasksResponse, id: String) throws -> [String: Any] {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(response.jsonBody.render().utf8)) as? [String: Any])
    let rows = try #require(object["tasks"] as? [[String: Any]])
    return try #require(rows.first { $0["id"] as? String == id })
}

@Test func sameOwnerThreadAndTaskPublisherBindingsKeepSilentAndPublishedFrames() async throws {
    let fixture = PublisherBindingFixture()
    try #require(fixture.taskFacts.count == 3)
    let serverA = try await RealtimeServer.start(auth: fixture.realtimeAuth)
    let serverB: RealtimeServer
    do { serverB = try await RealtimeServer.start(auth: fixture.realtimeAuth) }
    catch { try? await serverA.close(); throw error }
    do {
        var socketA = try await publisherBindingConnect(fixture, server: serverA)
        defer { socketA.client.close() }
        var socketB = try await publisherBindingConnect(fixture, server: serverB)
        defer { socketB.client.close() }
        let hubA = serverA.hub
        let hubB = serverB.hub
        fixture.services.messaging.realtime.install { room, event, payload in
            hubA.emit(room: room, event: event, payloadJSON: payload)
        }
        let hostA = fixture.services.channels.messaging.bindingUserDelivery(
            emitToUser: { userId, event, payload in hubA.emit(room: "user:\(userId)", event: event, payloadJSON: payload) },
            joinUserSessions: hubA.joinUserSessions
        )
        let hostNil = fixture.services.channels.messaging.bindingUserDelivery(
            emitToUser: { _, _, _ in }, joinUserSessions: { _, _ in }
        )
        let publishedThreads = fixture.services.channels.threads
        let publishedAssignments = fixture.services.channels.assignments
        let silentThreads = publishedThreads.bindingFollowersPublication(publishFollowersUpdated: { _ in })
        let silentAssignments = publishedAssignments.bindingTaskPublication(publishTaskUpdated: { _ in })
        let customThreads = fixture.timedThreads.bindingFollowersPublication(publishFollowersUpdated: hostA.publishThreadFollowers)
        let customAssignments = fixture.timedAssignments.bindingTaskPublication(publishTaskUpdated: hostNil.publishCommittedTaskUpdated)
        let named = ThreadFollowMutationDTO(threadChannelId: fixture.threadId)
        let followerFrame = "42[\"thread:followers-updated\",{\"threadChannelId\":\"\(fixture.threadId)\"}]"
        let initialFollowed = try publishedThreads.followedThreads(authorization: fixture.authorization, serverId: fixture.serverId)
        #expect(initialFollowed.threads.isEmpty)

        let silentFollow = try silentThreads.setThreadFollow(named, authorization: fixture.authorization, serverId: fixture.serverId, follow: true)
        #expect(silentFollow.jsonBody.render() == "{\"ok\":true,\"threadChannelId\":\"\(fixture.threadId)\"}")
        let followed = try publishedThreads.followedThreads(authorization: fixture.authorization, serverId: fixture.serverId)
        #expect(followed.threads.map(\.threadChannelId) == [fixture.threadId])
        let silentClaim = try silentAssignments.claimTask(authorization: fixture.authorization, serverId: fixture.serverId, taskId: fixture.taskFacts[0].id)
        _ = try publisherBindingTaskJSON(silentClaim, fact: fixture.taskFacts[0], fixture: fixture)
        let silentRow = try publisherBindingTaskRow(publishedAssignments.listServerTasks(authorization: fixture.authorization, serverId: fixture.serverId, rawQuery: nil), id: fixture.taskFacts[0].id)
        #expect(silentRow["status"] as? String == "in_progress")
        #expect(silentRow["revision"] as? Int == 1)
        #expect(try await publisherBindingFrames(socketA) == [])
        #expect(try await publisherBindingFrames(socketB) == [])

        socketA = socketA.reset
        socketB = socketB.reset
        let publishedUnfollow = try publishedThreads.setThreadFollow(named, authorization: fixture.authorization, serverId: fixture.serverId, follow: false)
        #expect(publishedUnfollow.jsonBody.render() == "{\"ok\":true}")
        let publishedClaim = try publishedAssignments.claimTask(authorization: fixture.authorization, serverId: fixture.serverId, taskId: fixture.taskFacts[1].id)
        let publishedJSON = try publisherBindingTaskJSON(publishedClaim, fact: fixture.taskFacts[1], fixture: fixture)
        let publishedFrame = "42[\"task:updated\",{\"channelId\":\"\(fixture.channelId)\",\"task\":\(publishedJSON)}]"
        #expect(try await publisherBindingFrames(socketA) == [followerFrame, publishedFrame])
        #expect(try await publisherBindingFrames(socketB) == [])

        socketA = socketA.reset
        socketB = socketB.reset
        let parentOnly = try publishedThreads.setThreadFollow(ThreadFollowMutationDTO(parentMessageId: fixture.parentMessageId), authorization: fixture.authorization, serverId: fixture.serverId, follow: true)
        #expect(parentOnly.jsonBody.render() == "{\"ok\":true,\"threadChannelId\":\"\(fixture.threadId)\"}")
        let parentFollowed = try publishedThreads.followedThreads(authorization: fixture.authorization, serverId: fixture.serverId)
        #expect(parentFollowed.threads.map(\.threadChannelId) == [fixture.threadId])
        // `POST /channels/threads/follow` emits for the resolved thread whether
        // the body named `threadChannelId` or `parentMessageId`.
        #expect(try await publisherBindingFrames(socketA) == [followerFrame])
        #expect(try await publisherBindingFrames(socketB) == [])

        socketA = socketA.reset
        socketB = socketB.reset
        fixture.services.messaging.realtime.install { room, event, payload in
            hubB.emit(room: room, event: event, payloadJSON: payload)
        }
        let customUnfollow = try customThreads.setThreadFollow(named, authorization: fixture.authorization, serverId: fixture.serverId, follow: false)
        #expect(customUnfollow.jsonBody.render() == "{\"ok\":true}")
        let customClaim = try customAssignments.claimTask(authorization: fixture.authorization, serverId: fixture.serverId, taskId: fixture.taskFacts[2].id)
        #expect(customClaim.task.claimedAt == "1970-01-01T00:20:34.000Z")
        let customJSON = try publisherBindingTaskJSON(customClaim, fact: fixture.taskFacts[2], fixture: fixture)
        let customFrame = "42[\"task:updated\",{\"channelId\":\"\(fixture.channelId)\",\"task\":\(customJSON)}]"
        let unfollowed = try publishedThreads.unfollowedInbox(authorization: fixture.authorization, serverId: fixture.serverId, limit: nil, query: nil)
        #expect(unfollowed.items.map(\.threadChannelId) == [fixture.threadId])
        #expect(unfollowed.items.first?.unfollowedAt == "1970-01-01T00:20:34Z")
        let customRow = try publisherBindingTaskRow(silentAssignments.listServerTasks(authorization: fixture.authorization, serverId: fixture.serverId, rawQuery: "detail=summary"), id: fixture.taskFacts[2].id)
        #expect(customRow["claimedAt"] as? String == "1970-01-01T00:20:34.000Z")
        #expect(customRow["status"] as? String == "in_progress")
        #expect(try await publisherBindingFrames(socketA) == [])
        #expect(try await publisherBindingFrames(socketB) == [followerFrame, customFrame])
    } catch {
        try? await serverA.close()
        try? await serverB.close()
        throw error
    }
    try await serverA.close()
    try await serverB.close()
}
