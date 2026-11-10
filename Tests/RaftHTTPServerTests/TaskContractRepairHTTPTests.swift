import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ContractTaskSocketAuth: RealtimeAuthorizing {
    let accounts: EmailLoginDirectory
    func userId(forAccessToken token: String) -> String? { accounts.authCore.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { accounts.authCore.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { accounts.socketMembership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        accounts.socketMembership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        accounts.socketMembership.syncMessages(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)?.jsonBody()
    }
}

private struct ContractTaskActors {
    let accounts = EmailLoginDirectory()
    let serverA = UUID().uuidString.lowercased()
    let serverB = UUID().uuidString.lowercased()
    let ownerA = UUID().uuidString.lowercased()
    let ownerB = UUID().uuidString.lowercased()
    let memberA = UUID().uuidString.lowercased()
    let guestB = UUID().uuidString.lowercased()

    init(enableGuestFlag: Bool = true) {
        for (id, name) in [(ownerA, "task-owner-a"), (ownerB, "task-owner-b"), (memberA, "task-member-a"), (guestB, "task-guest-b")] {
            accounts.addAccount(id: id, email: "\(name)-\(id)@slock.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverA, slug: "task-a-\(serverA)", name: "A", ownerId: ownerA)
        accounts.oauth.addOwnedServer(id: serverB, slug: "task-b-\(serverB)", name: "B", ownerId: ownerB)
        accounts.oauth.addMember(serverId: serverA, userId: memberA, role: "member")
        accounts.oauth.addMember(serverId: serverB, userId: guestB, role: "guest")
        accounts.enableGuestRoleTransitions(serverId: serverB)
        if enableGuestFlag {
            accounts.createFeatureFlagForTesting(key: "server_guest_v0", defaultEnabled: false, enabled: true, killSwitch: false)
            accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [serverB], priority: 0)
        }
    }

    func headers(_ userId: String, _ serverId: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))"
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return headers
    }
}

private func contractTaskObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

// Compare every JSON field and JSON type; NSDictionary bridging is not the oracle.
private func contractTaskExpectJSONEqual(_ actual: [String: Any], _ expected: [String: Any],
    sourceLocation: SourceLocation = #_sourceLocation) throws {
    let actualJSON = String(decoding: try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]), as: UTF8.self)
    let expectedJSON = String(decoding: try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]), as: UTF8.self)
    #expect(actualJSON == expectedJSON, sourceLocation: sourceLocation)
}

private func contractTaskConnect(_ server: RealtimeServer, actors: ContractTaskActors, userId: String, serverId: String) async throws -> SocketIOTestClient {
    let socket = try await SocketIOTestClient(port: server.port)
    _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
    let token = actors.accounts.mintAccessTokenForTesting(userId: userId)
    socket.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
    _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
    return socket
}

private func contractTaskFrames(_ socket: SocketIOTestClient, hub: RealtimeHub, userId: String, start: Int) async throws -> [[Any]] {
    let marker = "task-contract-\(UUID().uuidString.lowercased())"
    let fence = "42[\"\(marker)\",{}]"
    hub.emit(room: "user:\(userId)", event: marker, payloadJSON: "{}")
    _ = try #require(await socket.waitForText { $0 == fence })
    let frames = socket.textFrames
    let end = try #require(frames.indices.first { $0 >= start && frames[$0] == fence })
    return try frames[start..<end].filter { $0.hasPrefix("42") }.map {
        try #require(JSONSerialization.jsonObject(with: Data($0.dropFirst(2).utf8)) as? [Any])
    }
}

private func contractTaskResume(_ socket: SocketIOTestClient, lastSeq: Int) async throws -> [String: Any] {
    let start = socket.textFrames.count
    let prefix = "42[\"sync:resume:response\","
    socket.send("42[\"sync:resume\",{\"lastSeq\":\(lastSeq)}]")
    _ = try #require(await socket.waitForText { _ in socket.textFrames.dropFirst(start).contains { $0.hasPrefix(prefix) } })
    let frame = try #require(socket.textFrames.dropFirst(start).first { $0.hasPrefix(prefix) })
    let values = try #require(JSONSerialization.jsonObject(with: Data(frame.dropFirst(2).utf8)) as? [Any])
    return try #require(values[1] as? [String: Any])
}

@Test func taskContractForeignPublicAndPrivateNullAssignmentsHaveNoReturnMutationOrFrames() async throws {
    let actors = ContractTaskActors()
    let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: actors.accounts))
    do {
        let socketA = try await contractTaskConnect(realtime, actors: actors, userId: actors.memberA, serverId: actors.serverA)
        let socketB = try await contractTaskConnect(realtime, actors: actors, userId: actors.ownerB, serverId: actors.serverB)
        defer { socketA.close(); socketB.close() }
        let hub = realtime.hub
        actors.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts, realtime: hub))
            try await app.testing { client in
                let a = actors.headers(actors.memberA, actors.serverA)
                let b = actors.headers(actors.ownerB, actors.serverB)
                for kind in ["channel", "private"] {
                    let channel = try await client.send(.post, headers: b, to: "/api/channels") {
                        $0.body = .init(string: "{\"name\":\"foreign-\(kind)\",\"type\":\"\(kind)\"}")
                    }
                    #expect(channel.status == .ok)
                    let channelId = try #require(try contractTaskObject(channel)["id"] as? String)
                    // These sessions predate creation, so join via the actual hub's
                    // existing session transport; assertions still read received frames.
                    hub.joinUserSessions(userId: actors.ownerB, room: "channel:\(channelId)")
                    let created = try await client.send(.post, headers: b, to: URI(string: "/api/tasks/channel/\(channelId)")) {
                        $0.body = .init(string: "{\"tasks\":[{\"title\":\"B-SECRET-\(kind)\",\"description\":\"B-only description\"}]}")
                    }
                    #expect(created.status == .ok)
                    let task = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
                    let taskId = try #require(task["id"] as? String)
                    let number = try #require(task["taskNumber"] as? Int)
                    func readB() async throws -> [String: Any] {
                        let response = try await client.get(URI(string: "/api/tasks/channel/\(channelId)/number/\(number)"), headers: b)
                        #expect(response.status == .ok)
                        return try #require(try contractTaskObject(response)["task"] as? [String: Any])
                    }
                    func denyForeign(_ body: String) async throws {
                        let before = try await readB()
                        let messagePage = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: b)
                        let messageBody = try contractTaskObject(messagePage)
                        let startA = socketA.textFrames.count
                        let startB = socketB.textFrames.count
                        let response = try await client.send(.patch, headers: a, to: URI(string: "/api/tasks/\(taskId)/assignee")) {
                            $0.body = .init(string: body)
                        }
                        #expect(response.status == .notFound)
                        #expect(response.body.string == #"{"error":"Task not found"}"#)
                        #expect(!(response.body.string ?? "").contains("B-SECRET"))
                        #expect(try contractTaskObject(response)["task"] == nil)
                        try contractTaskExpectJSONEqual(try await readB(), before)
                        let afterMessages = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: b)
                        try contractTaskExpectJSONEqual(try contractTaskObject(afterMessages), messageBody)
                        #expect(try await contractTaskFrames(socketA, hub: hub, userId: actors.memberA, start: startA).isEmpty)
                        #expect(try await contractTaskFrames(socketB, hub: hub, userId: actors.ownerB, start: startB).isEmpty)
                    }
                    // The unchanged-null branch previously leaked the foreign task.
                    try await denyForeign(#"{"assignee":null}"#)
                    let assigned = try await client.send(.patch, headers: b, to: URI(string: "/api/tasks/\(taskId)/assignee")) {
                        $0.body = .init(string: "{\"assignee\":{\"type\":\"user\",\"id\":\"\(actors.ownerB)\"}}")
                    }
                    #expect(assigned.status == .ok)
                    _ = try await contractTaskFrames(socketB, hub: hub, userId: actors.ownerB, start: 0)
                    // Changed-null and set branches must fail before state/effects.
                    try await denyForeign(#"{"assignee":null}"#)
                    try await denyForeign("{\"assignee\":{\"type\":\"user\",\"id\":\"\(actors.memberA)\"}}")
                }
            }
        }
    } catch { try? await realtime.close(); throw error }
    try await realtime.close()
}

@Test func taskContractMutationsReturnCanonicalTaskAndMatchColdReadsAndTaskBoardFrames() async throws {
    let actors = ContractTaskActors()
    let owner = actors.headers(actors.ownerA, actors.serverA)
    let member = actors.headers(actors.memberA, actors.serverA)
    let description = "Full instructions: \"keep these\"\n" + String(repeating: "work ", count: 60)
    // Node tasks.ts309 trims the final ASCII space; internal text stays exact.
    let expectedDescription = String(description.dropLast())
    try await withApp { app in
        let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: actors.accounts))
        do {
            let hub = realtime.hub
            actors.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts, realtime: hub))
            try await app.testing { client in
                let channel = try await client.send(.post, headers: owner, to: "/api/channels") { $0.body = .init(string: #"{"name":"contract-lifecycle"}"#) }
                let channelId = try #require(try contractTaskObject(channel)["id"] as? String)
                #expect(try await client.send(.post, headers: member, to: URI(string: "/api/channels/\(channelId)/join")).status == .ok)
                let socket = try await contractTaskConnect(realtime, actors: actors, userId: actors.memberA, serverId: actors.serverA)
                defer { socket.close() }
                let createBody = try JSONSerialization.data(withJSONObject: ["tasks": [["title": "Lifecycle task", "description": description]]])
                let created = try await client.send(.post, headers: owner, to: URI(string: "/api/tasks/channel/\(channelId)")) { $0.body = .init(data: createBody) }
                let initial = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
                let taskId = try #require(initial["id"] as? String)
                let messageId = try #require(initial["messageId"] as? String)
                let number = try #require(initial["taskNumber"] as? Int)
                _ = try await contractTaskFrames(socket, hub: hub, userId: actors.memberA, start: 0)
                func checkCurrent(_ task: [String: Any], expectedStatus: String) async throws {
                    #expect(task["id"] as? String == taskId)
                    #expect(task["messageId"] as? String == messageId)
                    #expect(task["channelId"] as? String == channelId)
                    #expect(task["title"] as? String == "Lifecycle task")
                    #expect(task["description"] as? String == expectedDescription)
                    #expect(task["status"] as? String == expectedStatus)
                    #expect(task["createdById"] as? String == actors.ownerA)
                    #expect(task["createdByType"] as? String == "user")
                    #expect((task["createdByName"] as? String)?.isEmpty == false)
                    #expect(task["createdByMembershipStatus"] as? String == "active")
                    #expect((task["createdAt"] as? String)?.isEmpty == false)
                    #expect((task["updatedAt"] as? String)?.isEmpty == false)
                    let current = try #require(task["taskCurrentProjection"] as? [String: Any])
                    #expect(current["description"] as? String == expectedDescription)
                    for path in ["/api/tasks/channel/\(channelId)", "/api/tasks/channel/\(channelId)/number/\(number)", "/api/tasks/server"] {
                        let response = try await client.get(URI(string: path), headers: member)
                        #expect(response.status == .ok)
                        let body = try contractTaskObject(response)
                        let read = (body["task"] as? [String: Any]) ?? (body["tasks"] as? [[String: Any]])?.first { $0["id"] as? String == taskId }
                        let expected = path == "/api/tasks/server" ? task.filter { $0.key != "taskCurrentProjection" } : task
                        try contractTaskExpectJSONEqual(try #require(read), expected)
                    }
                    let messages = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: member)
                    let host = try #require((try contractTaskObject(messages)["messages"] as? [[String: Any]])?.first { $0["id"] as? String == messageId })
                    #expect(host["content"] as? String == "Lifecycle task")
                    #expect(host["senderId"] as? String == actors.ownerA)
                    #expect(host["taskStatus"] as? String == expectedStatus)
                    #expect(host["taskNumber"] as? Int == number)
                    for (messageKey, taskKey) in [("taskAssigneeId", "claimedById"), ("taskAssigneeType", "claimedByType"), ("taskClaimedAt", "claimedAt"), ("taskCompletedAt", "completedAt")] {
                        try contractTaskExpectJSONEqual(["value": try #require(host[messageKey])], ["value": try #require(task[taskKey])])
                    }
                    try contractTaskExpectJSONEqual(try #require(host["taskCurrentProjection"] as? [String: Any]), current)
                }
                for (suffix, body, status) in [("claim", "{}", "in_progress"), ("status", #"{"status":"in_review"}"#, "in_review"), ("unclaim", "{}", "in_review"), ("claim", "{}", "in_review"), ("status", #"{"status":"done"}"#, "done")] {
                    let start = socket.textFrames.count
                    let response = try await client.send(.patch, headers: member, to: URI(string: "/api/tasks/\(taskId)/\(suffix)")) { $0.body = .init(string: body) }
                    #expect(response.status == .ok)
                    let envelope = try contractTaskObject(response)
                    #expect(Set(envelope.keys) == ["task"])
                    let task = try #require(envelope["task"] as? [String: Any])
                    try await checkCurrent(task, expectedStatus: status)
                    if suffix == "unclaim" { #expect(task["claimedById"] is NSNull) }
                    else { #expect(task["claimedById"] as? String == actors.memberA) }
                    if status == "done" { #expect((task["completedAt"] as? String)?.isEmpty == false) }
                    let events = try await contractTaskFrames(socket, hub: hub, userId: actors.memberA, start: start)
                    let updates = events.filter { $0.first as? String == "task:updated" }
                    #expect(updates.count == 1)
                    let payload = try #require(updates.first?[1] as? [String: Any])
                    #expect(payload["channelId"] as? String == channelId)
                    try contractTaskExpectJSONEqual(try #require(payload["task"] as? [String: Any]), task)
                    #expect(!events.contains { $0.first as? String == "message:updated" })
                }
                let sent = try await client.send(.post, headers: owner, to: "/api/messages") { $0.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"Convert the actual host text\"}") }
                let hostId = try #require(try contractTaskObject(sent)["id"] as? String)
                let start = socket.textFrames.count
                let converted = try await client.send(.post, headers: member, to: "/api/tasks/convert-message") { $0.body = .init(string: "{\"messageId\":\"\(hostId)\"}") }
                #expect(converted.status == .ok)
                let envelope = try contractTaskObject(converted)
                #expect(Set(envelope.keys) == ["task"])
                let task = try #require(envelope["task"] as? [String: Any])
                #expect(task["id"] as? String != hostId)
                #expect(task["messageId"] as? String == hostId)
                #expect(task["title"] as? String == "Convert the actual host text")
                #expect(task["createdById"] as? String == actors.memberA)
                let events = try await contractTaskFrames(socket, hub: hub, userId: actors.memberA, start: start)
                let createdEvents = events.filter { $0.first as? String == "task:created" }
                #expect(createdEvents.count == 1)
                let payload = try #require(createdEvents.first?[1] as? [String: Any])
                let eventTask = try #require((payload["tasks"] as? [[String: Any]])?.first)
                try contractTaskExpectJSONEqual(eventTask, task)
                let repeated = try await client.send(.post, headers: member, to: "/api/tasks/convert-message") { $0.body = .init(string: "{\"messageId\":\"\(hostId)\"}") }
                #expect(repeated.status == .conflict)
                #expect(repeated.body.string == #"{"error":"already converted"}"#)
            }
        } catch { try? await realtime.close(); throw error }
        try await realtime.close()
    }
}

@Test func taskContractRegisteredGuestCanReadVisibleTaskButCannotMutateAnyTaskRoute() async throws {
    let actors = ContractTaskActors()
    let owner = actors.headers(actors.ownerB, actors.serverB)
    let guest = actors.headers(actors.guestB, actors.serverB)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts))
        try await app.testing { client in
            let channel = try await client.send(.post, headers: owner, to: "/api/channels") { $0.body = .init(string: #"{"name":"guest-task-policy"}"#) }
            let channelId = try #require(try contractTaskObject(channel)["id"] as? String)
            actors.accounts.setChannelGuestVisibleForTesting(channelId: channelId, visible: true)
            actors.accounts.oauth.addChannelHuman(channelId: channelId, userId: actors.guestB)
            actors.accounts.addPostableChannel(serverId: actors.serverB, channelId: channelId, memberId: actors.guestB, name: "guest-task-policy")
            let created = try await client.send(.post, headers: owner, to: URI(string: "/api/tasks/channel/\(channelId)")) { $0.body = .init(string: #"{"tasks":[{"title":"Guest can read, cannot mutate"}]}"#) }
            let task = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
            let taskId = try #require(task["id"] as? String)
            let messageId = try #require(task["messageId"] as? String)
            for path in ["/api/tasks/channel/\(channelId)", "/api/tasks/channel/\(channelId)/number/1", "/api/tasks/server"] {
                let readable = try await client.get(URI(string: path), headers: guest)
                #expect(readable.status == .ok)
                #expect((readable.body.string ?? "").contains(taskId))
            }
            for (method, path, body) in [
                (HTTPRequest.Method.patch, "/api/tasks/\(taskId)/claim", "{}"),
                (.patch, "/api/tasks/\(taskId)/unclaim", "{}"),
                (.patch, "/api/tasks/\(taskId)/status", #"{"status":"done"}"#),
                (.patch, "/api/tasks/\(taskId)/assignee", #"{"assignee":null}"#),
                (.delete, "/api/tasks/\(taskId)", "{}"),
                (.post, "/api/tasks/convert-message", "{\"messageId\":\"\(messageId)\"}"),
                (.post, "/api/tasks/channel/\(channelId)", #"{"tasks":[{"title":"Forbidden guest task"}]}"#),
            ] {
                let denied = try await client.send(method, headers: guest, to: URI(string: path)) { $0.body = .init(string: body) }
                #expect(denied.status == .forbidden)
                #expect(try contractTaskObject(denied)["task"] == nil)
                let read = try await client.get(URI(string: "/api/tasks/channel/\(channelId)/number/1"), headers: owner)
                try contractTaskExpectJSONEqual(try #require(try contractTaskObject(read)["task"] as? [String: Any]), task)
            }
            actors.accounts.oauth.removeChannelHuman(channelId: channelId, userId: actors.guestB)
            for path in ["/api/tasks/channel/\(channelId)", "/api/tasks/channel/\(channelId)/number/1", "/api/tasks/server"] {
                let visibleUnjoined = try await client.get(URI(string: path), headers: guest)
                #expect(visibleUnjoined.status == .ok)
                #expect((visibleUnjoined.body.string ?? "").contains(taskId))
            }
            actors.accounts.setChannelGuestVisibleForTesting(channelId: channelId, visible: false)
            // Ordinary public joined Guest remains readable per Node, but a hidden
            // unjoined Guest must not inherit ordinary-member public visibility.
            actors.accounts.oauth.removeChannelHuman(channelId: channelId, userId: actors.guestB)
            for path in ["/api/tasks/channel/\(channelId)", "/api/tasks/channel/\(channelId)/number/1"] {
                let denied = try await client.get(URI(string: path), headers: guest)
                #expect(denied.status == .notFound)
                #expect(!(denied.body.string ?? "").contains(taskId))
            }
            let hiddenServer = try await client.get("/api/tasks/server", headers: guest)
            #expect(hiddenServer.status == .ok)
            #expect(!(hiddenServer.body.string ?? "").contains(taskId))
        }
    }
}


@Test func taskContractClaimCannotStealAndHumanDoneCannotBypassAResourceReceipt() async throws {
    let actors = ContractTaskActors()
    let owner = actors.headers(actors.ownerA, actors.serverA)
    let member = actors.headers(actors.memberA, actors.serverA)
    try await withApp { app in
        let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: actors.accounts))
        do {
            let hub = realtime.hub
            actors.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts, realtime: hub))
            try await app.testing { client in
                let createdChannel = try await client.send(.post, headers: owner, to: "/api/channels") { $0.body = .init(string: #"{"name":"resource-invariant"}"#) }
                let channel = try #require(try contractTaskObject(createdChannel)["id"] as? String)
                #expect(try await client.send(.post, headers: member, to: URI(string: "/api/channels/\(channel)/join")).status == .ok)
                let created = try await client.send(.post, headers: owner, to: URI(string: "/api/tasks/channel/\(channel)")) { $0.body = .init(string: #"{"tasks":[{"title":"Resource completion needs evidence"}]}"#) }
                let id = try #require(((try contractTaskObject(created))["tasks"] as? [[String: Any]])?.first?["id"] as? String)
                // Real existing Task-owner business input, identical to the
                // requires-resource marker applied by the agent create writer.
                // This does not claim the resource-receipt HTTP producer was run.
                actors.accounts.tasksAndRemindersStore.markRequiresResourceReceipt(taskIds: [id], flags: [true])
                let claimed = try await client.send(.patch, headers: owner, to: URI(string: "/api/tasks/\(id)/claim"))
                #expect(claimed.status == .ok)
                let before = try #require(try contractTaskObject(claimed)["task"] as? [String: Any])
                #expect(before["requiresResourceReceipt"] as? Bool == true)
                #expect(before["resourceReceipt"] is NSNull)
                let socket = try await contractTaskConnect(realtime, actors: actors, userId: actors.memberA, serverId: actors.serverA)
                defer { socket.close() }
                for (actor, suffix, body) in [(member, "claim", "{}"), (owner, "claim", "{}"), (member, "status", #"{"status":"done"}"#), (owner, "status", #"{"status":"done"}"#)] {
                    let start = socket.textFrames.count
                    let rejected = try await client.send(.patch, headers: actor, to: URI(string: "/api/tasks/\(id)/\(suffix)")) { $0.body = .init(string: body) }
                    #expect(rejected.status == .conflict)
                    #expect(try contractTaskObject(rejected)["task"] == nil)
                    if suffix == "status" { #expect(rejected.body.string == #"{"error":"resource receipt required before task can move to done"}"#) }
                    let loaded = try await client.get(URI(string: "/api/tasks/channel/\(channel)/number/1"), headers: member)
                    try contractTaskExpectJSONEqual(try #require(try contractTaskObject(loaded)["task"] as? [String: Any]), before)
                    #expect(try await contractTaskFrames(socket, hub: hub, userId: actors.memberA, start: start).isEmpty)
                }
                // Current Node policy intentionally allows a different joined
                // ordinary member to release the task; do not restore the old
                // assignee-only restriction from stale route comments.
                let released = try await client.send(.patch, headers: member, to: URI(string: "/api/tasks/\(id)/unclaim"))
                #expect(released.status == .ok)
                #expect((try contractTaskObject(released)["task"] as? [String: Any])?["claimedById"] is NSNull)
            }
        } catch { try? await realtime.close(); throw error }
        try await realtime.close()
    }
}


@Test func taskContractGuestReadsRequireTheActualFlagEvaluatorAndHonorEveryDeny() async throws {
    for gate in ["missing", "disabled", "kill", "user-deny"] {
        let actors = ContractTaskActors(enableGuestFlag: gate != "missing")
        let owner = actors.headers(actors.ownerB, actors.serverB)
        let guest = actors.headers(actors.guestB, actors.serverB)
        if gate == "disabled" { actors.accounts.createFeatureFlagForTesting(key: "server_guest_v0", defaultEnabled: true, enabled: false) }
        if gate == "kill" { actors.accounts.setFeatureFlagKillSwitchForTesting(key: "server_guest_v0", killSwitch: true) }
        if gate == "user-deny" { actors.accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "user", decision: "deny", values: [actors.guestB]) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts))
            try await app.testing { client in
                let createdChannel = try await client.send(.post, headers: owner, to: "/api/channels") { $0.body = .init(string: #"{"name":"guest-flag-authority"}"#) }
                let channel = try #require(try contractTaskObject(createdChannel)["id"] as? String)
                actors.accounts.setChannelGuestVisibleForTesting(channelId: channel, visible: true)
                actors.accounts.oauth.addChannelHuman(channelId: channel, userId: actors.guestB)
                actors.accounts.addPostableChannel(serverId: actors.serverB, channelId: channel, memberId: actors.guestB, name: "guest-flag-authority")
                let created = try await client.send(.post, headers: owner, to: URI(string: "/api/tasks/channel/\(channel)")) { $0.body = .init(string: #"{"tasks":[{"title":"No flag means no guest task read"}]}"#) }
                let task = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
                let id = try #require(task["id"] as? String)
                let beforeResponse = try await client.get(URI(string: "/api/tasks/channel/\(channel)/number/1"), headers: owner)
                let before = try #require(try contractTaskObject(beforeResponse)["task"] as? [String: Any])
                for path in ["/api/tasks/channel/\(channel)", "/api/tasks/channel/\(channel)/number/1"] {
                    let denied = try await client.get(URI(string: path), headers: guest)
                    #expect(denied.status == .notFound, Comment(rawValue: gate))
                    #expect(!(denied.body.string ?? "").contains(id))
                    #expect(!(denied.body.string ?? "").contains("No flag means"))
                }
                let aggregate = try await client.get("/api/tasks/server", headers: guest)
                #expect(aggregate.status == .ok)
                #expect((try contractTaskObject(aggregate)["tasks"] as? [[String: Any]])?.isEmpty == true)
                let afterResponse = try await client.get(URI(string: "/api/tasks/channel/\(channel)/number/1"), headers: owner)
                #expect(afterResponse.status == .ok, "ordinary owner rights survive a guest flag deny")
                try contractTaskExpectJSONEqual(try #require(try contractTaskObject(afterResponse)["task"] as? [String: Any]), before)
            }
        }
    }
}


private struct ContractJointTaskActors {
    let actors: ContractTaskActors
    let canonical: String
    let localA: String
    let localB: String
    let peerHuman: String
    let retiredHuman: String

    init() {
        let actors = ContractTaskActors()
        let accounts = actors.accounts
        let peerHuman = UUID().uuidString.lowercased()
        let retiredHuman = UUID().uuidString.lowercased()
        for (id, prefix) in [(peerHuman, "joint-peer"), (retiredHuman, "joint-retired")] {
            accounts.addAccount(id: id, email: "\(prefix)-\(id)@slock.test", password: "password123")
            accounts.markEmailVerified(userId: id)
            accounts.oauth.addMember(serverId: actors.serverB, userId: id, role: "member")
        }
        let canonical = accounts.oauth.createChannel(serverId: actors.serverA, name: "joint-storage", creatorUserId: actors.ownerA)
        accounts.addPostableChannel(serverId: actors.serverA, channelId: canonical, memberId: actors.ownerA, name: "joint-storage")
        let localA = accounts.oauth.createChannel(serverId: actors.serverA, name: "joint-local-a", creatorUserId: actors.ownerA, type: "joint")
        let localB = accounts.oauth.createChannel(serverId: actors.serverB, name: "joint-local-b", creatorUserId: actors.ownerB, type: "joint")
        let retired = accounts.oauth.createChannel(serverId: actors.serverB, name: "joint-retired", creatorUserId: actors.ownerB, type: "joint")
        for (local, server, owner, member, name) in [(localA, actors.serverA, actors.ownerA, actors.memberA, "joint-local-a"), (localB, actors.serverB, actors.ownerB, peerHuman, "joint-local-b"), (retired, actors.serverB, actors.ownerB, retiredHuman, "joint-retired")] {
            accounts.addPostableChannel(serverId: server, channelId: local, memberId: owner, kind: "joint", name: name)
            accounts.addPostableChannel(serverId: server, channelId: local, memberId: member, kind: "joint", name: name)
            accounts.oauth.addChannelHuman(channelId: local, userId: member)
            accounts.addJointChannelProjection(localChannelId: local, canonicalChannelId: canonical, serverId: server)
        }
        accounts.setJointProjectionStatusForTesting(localChannelId: retired, serverId: actors.serverB, status: "paused")
        self.actors = actors
        self.canonical = canonical
        self.localA = localA
        self.localB = localB
        self.peerHuman = peerHuman
        self.retiredHuman = retiredHuman
    }
}

@Test(arguments: ["fanout", "peer-human"])
func taskContractJointReviewUsesEachRoomProjectionAndActualPeerMembership(_ mode: String) async throws {
    let joint = ContractJointTaskActors()
    let actors = joint.actors
    let a = actors.headers(actors.memberA, actors.serverA)
    let b = actors.headers(joint.peerHuman, actors.serverB)
    let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: actors.accounts))
    do {
        let socketA = try await contractTaskConnect(realtime, actors: actors, userId: actors.memberA, serverId: actors.serverA)
        let socketB = try await contractTaskConnect(realtime, actors: actors, userId: joint.peerHuman, serverId: actors.serverB)
        defer { socketA.close(); socketB.close() }
        let hub = realtime.hub
        actors.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts, realtime: hub))
            try await app.testing { client in
                let created = try await client.send(.post, headers: a, to: URI(string: "/api/tasks/channel/\(joint.localA)")) { $0.body = .init(string: #"{"tasks":[{"title":"One real task shared by two rooms","description":"peer task details"}]}"#) }
                #expect(created.status == .ok)
                let initial = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
                let taskId = try #require(initial["id"] as? String)
                let number = try #require(initial["taskNumber"] as? Int)
                _ = try await contractTaskFrames(socketA, hub: hub, userId: actors.memberA, start: 0)
                _ = try await contractTaskFrames(socketB, hub: hub, userId: joint.peerHuman, start: 0)
                func readTask(_ channel: String, headers: HTTPFields) async throws -> [String: Any] {
                    let response = try await client.get(URI(string: "/api/tasks/channel/\(channel)/number/\(number)"), headers: headers)
                    #expect(response.status == .ok)
                    return try #require(try contractTaskObject(response)["task"] as? [String: Any])
                }
                func checkRooms(_ response: ClientResponse, starts: (Int, Int)) async throws -> [String: Any] {
                    #expect(response.status == .ok)
                    let envelope = try contractTaskObject(response)
                    #expect(Set(envelope.keys) == ["task"])
                    let returned = try #require(envelope["task"] as? [String: Any])
                    #expect(returned["channelId"] as? String == joint.localA)
                    let readA = try await readTask(joint.localA, headers: a)
                    let readB = try await readTask(joint.localB, headers: b)
                    try contractTaskExpectJSONEqual(returned, readA)
                    #expect(readB["id"] as? String == taskId)
                    #expect(readB["channelId"] as? String == joint.localB)
                    #expect(readB["channelName"] as? String == "joint-local-b")
                    #expect(readB["revision"] as? Int == returned["revision"] as? Int)
                    let eventsA = try await contractTaskFrames(socketA, hub: hub, userId: actors.memberA, start: starts.0)
                    let eventsB = try await contractTaskFrames(socketB, hub: hub, userId: joint.peerHuman, start: starts.1)
                    for (events, expected, local) in [(eventsA, readA, joint.localA), (eventsB, readB, joint.localB)] {
                        let updates = events.filter { $0.first as? String == "task:updated" }
                        #expect(updates.count == 1)
                        let event = try #require(updates.first)
                        try #require(event.count == 2)
                        let payload = try #require(event[1] as? [String: Any])
                        #expect(payload["channelId"] as? String == local)
                        try contractTaskExpectJSONEqual(try #require(payload["task"] as? [String: Any]), expected)
                        #expect(!events.contains { $0.first as? String == "message:updated" })
                    }
                    return returned
                }
                if mode == "fanout" {
                    for (suffix, body, expectedStatus) in [("claim", "{}", "in_progress"), ("status", #"{"status":"in_review"}"#, "in_review"), ("unclaim", "{}", "in_review")] {
                        let starts = (socketA.textFrames.count, socketB.textFrames.count)
                        let response = try await client.send(.patch, headers: a, to: URI(string: "/api/tasks/\(taskId)/\(suffix)")) { $0.body = .init(string: body) }
                        let returned = try await checkRooms(response, starts: starts)
                        #expect(returned["status"] as? String == expectedStatus)
                    }
                } else {
                    let starts = (socketA.textFrames.count, socketB.textFrames.count)
                    let assigned = try await client.send(.patch, headers: a, to: URI(string: "/api/tasks/\(taskId)/assignee")) { $0.body = .init(string: "{\"assignee\":{\"type\":\"user\",\"id\":\"\(joint.peerHuman)\"}}") }
                    let returned = try await checkRooms(assigned, starts: starts)
                    #expect(returned["claimedById"] as? String == joint.peerHuman)
                    #expect(returned["revision"] as? Int == 1)
                    // Both actors remain ordinary members in their original server;
                    // the target has no membership in A or in localA.
                    for forbidden in [joint.retiredHuman, actors.guestB] {
                        let before = try await readTask(joint.localA, headers: a)
                        let negativeStarts = (socketA.textFrames.count, socketB.textFrames.count)
                        let denied = try await client.send(.patch, headers: a, to: URI(string: "/api/tasks/\(taskId)/assignee")) { $0.body = .init(string: "{\"assignee\":{\"type\":\"user\",\"id\":\"\(forbidden)\"}}") }
                        #expect(denied.status == .conflict)
                        #expect(try contractTaskObject(denied)["task"] == nil)
                        try contractTaskExpectJSONEqual(try await readTask(joint.localA, headers: a), before)
                        #expect(try await contractTaskFrames(socketA, hub: hub, userId: actors.memberA, start: negativeStarts.0).isEmpty)
                        #expect(try await contractTaskFrames(socketB, hub: hub, userId: joint.peerHuman, start: negativeStarts.1).isEmpty)
                    }
                }
            }
        }
    } catch { try? await realtime.close(); throw error }
    try await realtime.close()
}


@Test func taskContractJointRoomsRejectForeignUnjoinedGuestsAndRevokedMembers() async throws {
    let joint = ContractJointTaskActors()
    let actors = joint.actors
    actors.accounts.oauth.addChannelHuman(channelId: joint.localA, userId: actors.ownerA)
    // A real retained guest join is still insufficient for a joint read/room.
    actors.accounts.oauth.addChannelHuman(channelId: joint.localB, userId: actors.guestB)
    let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: actors.accounts))
    do {
        let socketA = try await contractTaskConnect(realtime, actors: actors, userId: actors.memberA, serverId: actors.serverA)
        let socketB = try await contractTaskConnect(realtime, actors: actors, userId: joint.peerHuman, serverId: actors.serverB)
        let unjoined = try await contractTaskConnect(realtime, actors: actors, userId: actors.ownerB, serverId: actors.serverB)
        let guest = try await contractTaskConnect(realtime, actors: actors, userId: actors.guestB, serverId: actors.serverB)
        let retired = try await contractTaskConnect(realtime, actors: actors, userId: joint.retiredHuman, serverId: actors.serverB)
        defer { socketA.close(); socketB.close(); unjoined.close(); guest.close(); retired.close() }
        let hub = realtime.hub
        actors.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts, realtime: hub))
            try await app.testing { client in
                let a = actors.headers(actors.memberA, actors.serverA)
                let owner = actors.headers(actors.ownerA, actors.serverA)
                let b = actors.headers(joint.peerHuman, actors.serverB)
                let created = try await client.send(.post, headers: a, to: URI(string: "/api/tasks/channel/\(joint.localA)")) { $0.body = .init(string: #"{"tasks":[{"title":"Real room authority"}]}"#) }
                #expect(created.status == .ok)
                let task = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
                let id = try #require(task["id"] as? String)
                for (socket, user) in [(socketA, actors.memberA), (socketB, joint.peerHuman), (unjoined, actors.ownerB), (guest, actors.guestB), (retired, joint.retiredHuman)] {
                    _ = try await contractTaskFrames(socket, hub: hub, userId: user, start: 0)
                }
                // The resume response acknowledges prior incoming join attempts on
                // the same real TCP stream; an outgoing hub fence alone cannot.
                socketA.send("42[\"join:channel\",\"\(joint.localB)\"]")
                _ = try await contractTaskResume(socketA, lastSeq: 1)
                for socket in [unjoined, guest, retired] {
                    socket.send("42[\"join:channel\",\"\(joint.localB)\"]")
                    _ = try await contractTaskResume(socket, lastSeq: 1)
                }
                func checkUpdate(_ socket: SocketIOTestClient, user: String, local: String, headers: HTTPFields, start: Int) async throws {
                    let frames = try await contractTaskFrames(socket, hub: hub, userId: user, start: start)
                    let events = frames.filter { $0.first as? String == "task:updated" }
                    #expect(events.count == 1)
                    let payload = try #require(events.first?[1] as? [String: Any])
                    #expect(payload["channelId"] as? String == local)
                    let read = try await client.get(URI(string: "/api/tasks/channel/\(local)/number/1"), headers: headers)
                    #expect(read.status == .ok)
                    try contractTaskExpectJSONEqual(try #require(payload["task"] as? [String: Any]), try #require(try contractTaskObject(read)["task"] as? [String: Any]))
                    #expect(!frames.contains { $0.first as? String == "message:updated" })
                }
                let startA = socketA.textFrames.count
                let startB = socketB.textFrames.count
                let deniedStarts = [unjoined.textFrames.count, guest.textFrames.count, retired.textFrames.count]
                let changed = try await client.send(.patch, headers: a, to: URI(string: "/api/tasks/\(id)/status")) { $0.body = .init(string: #"{"status":"in_review"}"#) }
                #expect(changed.status == .ok)
                try await checkUpdate(socketA, user: actors.memberA, local: joint.localA, headers: a, start: startA)
                try await checkUpdate(socketB, user: joint.peerHuman, local: joint.localB, headers: b, start: startB)
                for (index, pair) in [(unjoined, actors.ownerB), (guest, actors.guestB), (retired, joint.retiredHuman)].enumerated() {
                    let frames = try await contractTaskFrames(pair.0, hub: hub, userId: pair.1, start: deniedStarts[index])
                    #expect(!frames.contains { ($0.first as? String)?.hasPrefix("task:") == true })
                }
                let left = try await client.send(.post, headers: a, to: URI(string: "/api/channels/\(joint.localA)/leave")) { $0.body = .init(string: "{}") }
                #expect(left.status == .ok)
                socketA.send("42[\"join:channel\",\"\(joint.localA)\"]")
                _ = try await contractTaskResume(socketA, lastSeq: 1)
                let revokedStart = socketA.textFrames.count
                let peerStart = socketB.textFrames.count
                let afterLeave = try await client.send(.patch, headers: owner, to: URI(string: "/api/tasks/\(id)/status")) { $0.body = .init(string: #"{"status":"in_progress"}"#) }
                #expect(afterLeave.status == .ok)
                try await checkUpdate(socketB, user: joint.peerHuman, local: joint.localB, headers: b, start: peerStart)
                let revokedFrames = try await contractTaskFrames(socketA, hub: hub, userId: actors.memberA, start: revokedStart)
                #expect(!revokedFrames.contains { $0.first as? String == "task:updated" })
                let reconnected = try await contractTaskConnect(realtime, actors: actors, userId: actors.memberA, serverId: actors.serverA)
                defer { reconnected.close() }
                let reconnectStart = reconnected.textFrames.count
                let peerAgain = socketB.textFrames.count
                let afterReconnect = try await client.send(.patch, headers: owner, to: URI(string: "/api/tasks/\(id)/status")) { $0.body = .init(string: #"{"status":"in_review"}"#) }
                #expect(afterReconnect.status == .ok)
                try await checkUpdate(socketB, user: joint.peerHuman, local: joint.localB, headers: b, start: peerAgain)
                let reconnectFrames = try await contractTaskFrames(reconnected, hub: hub, userId: actors.memberA, start: reconnectStart)
                #expect(!reconnectFrames.contains { $0.first as? String == "task:updated" })
                let removed = try await client.send(.delete, headers: owner, to: URI(string: "/api/servers/\(actors.serverA)/members/\(actors.memberA)"))
                #expect(removed.status == .ok)
                #expect(await socketA.waitForClose())
                #expect(await reconnected.waitForClose())
            }
        }
    } catch { try? await realtime.close(); throw error }
    try await realtime.close()
}

@Test func taskContractSocketResumeUsesActualAllVisibilityAndFollowedParentAcrossHideRestore() async throws {
    let actors = ContractTaskActors()
    let accounts = actors.accounts
    let all = try #require(accounts.oauth.allChannelId(serverId: actors.serverA))
    accounts.addPostableChannel(serverId: actors.serverA, channelId: all, memberId: actors.ownerA, name: "all")
    let control = accounts.oauth.createChannel(serverId: actors.serverA, name: "resume-control", creatorUserId: actors.ownerA)
    accounts.addPostableChannel(serverId: actors.serverA, channelId: control, memberId: actors.ownerA, name: "resume-control")
    let owner = actors.headers(actors.ownerA, actors.serverA)
    let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: accounts))
    do {
        let socket = try await contractTaskConnect(realtime, actors: actors, userId: actors.ownerA, serverId: actors.serverA)
        defer { socket.close() }
        let hub = realtime.hub
        accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts, realtime: hub))
            try await app.testing { client in
                func send(_ channel: String, _ content: String) async throws -> String {
                    let response = try await client.send(.post, headers: owner, to: "/api/messages") { $0.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"\(content)\"}") }
                    #expect(response.status == .ok)
                    return try #require(try contractTaskObject(response)["id"] as? String)
                }
                let sentinel = try await send(control, "before-resume-cursor")
                let allRoot = try await send(all, "actual-all-root")
                let visible = try await send(control, "visible-resume-control")
                let threadResponse = try await client.send(.post, headers: owner, to: URI(string: "/api/channels/\(all)/threads")) { $0.body = .init(string: "{\"parentMessageId\":\"\(allRoot)\",\"content\":\"actual-all-thread-reply\"}") }
                #expect(threadResponse.status == .ok)
                let thread = try contractTaskObject(threadResponse)
                let threadId = try #require(thread["threadChannelId"] as? String)
                let threadHistory = try await client.send(
                    .get, headers: owner, to: URI(string: "/api/messages/channel/\(threadId)?limit=50")
                )
                #expect(threadHistory.status == .ok)
                let threadRows = try #require(
                    try contractTaskObject(threadHistory)["messages"] as? [[String: Any]]
                )
                let replyRow = try #require(threadRows.first {
                    ($0["content"] as? String) == "actual-all-thread-reply"
                })
                let reply = try #require(replyRow["id"] as? String)
                let followed = try await client.send(.post, headers: owner, to: "/api/channels/threads/follow") { $0.body = .init(string: "{\"threadChannelId\":\"\(threadId)\"}") }
                #expect(followed.status == .ok)
                let cursor = try #require(accounts.messageSeqForTesting(messageId: sentinel))
                func checkResume(_ expected: [String]) async throws {
                    let body = try await contractTaskResume(socket, lastSeq: cursor)
                    let rows = try #require(body["messages"] as? [[String: Any]])
                    #expect(rows.compactMap { $0["id"] as? String } == expected)
                    let seqs = rows.compactMap { $0["seq"] as? Int }
                    #expect(seqs == seqs.sorted())
                    #expect(body["currentSeq"] as? Int == (seqs.last ?? cursor))
                    #expect(body["hasMore"] as? Bool == false)
                }
                try await checkResume([allRoot, visible, reply])
                let hidden = try await client.send(.post, headers: owner, to: "/api/channels/system/all/hide") { $0.body = .init(string: "{}") }
                #expect(hidden.status == .ok)
                // Lock the real representation mismatch, rather than changing the
                // Postable kind to make its stale cached policy look correct.
                #expect(accounts.oauth.channelType(id: all) == "private")
                #expect(accounts.serversAndChannelsStore.postableChannel(id: all)?.kind == "channel")
                #expect(accounts.oauth.isChannelParticipant(channelId: all, userId: actors.ownerA))
                try await checkResume([visible])
                let restored = try await client.send(.post, headers: owner, to: "/api/channels/system/all/restore") { $0.body = .init(string: "{}") }
                #expect(restored.status == .ok)
                try await checkResume([allRoot, visible, reply])
            }
        }
    } catch { try? await realtime.close(); throw error }
    try await realtime.close()
}


private func contractTaskWaitFrameOrClose(_ socket: SocketIOTestClient, prefix: String, start: Int) async throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if socket.textFrames.dropFirst(start).contains(where: { $0.hasPrefix(prefix) }) { return }
        if await socket.waitForClose(timeout: 0.05) { return }
    }
    try #require(false, "Expected an actual socket frame or transport close within the bounded handshake window")
}

@Test func taskContractRoleChangeRevokesEveryUserSocketAndIdempotentRetry() async throws {
    let joint = ContractJointTaskActors()
    let actors = joint.actors
    // A real second membership proves revocation is global to the user,
    // rather than limited to the server whose role was changed.
    actors.accounts.oauth.addMember(serverId: actors.serverA, userId: joint.peerHuman, role: "member")
    let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: actors.accounts))
    do {
        let a = try await contractTaskConnect(realtime, actors: actors, userId: actors.memberA, serverId: actors.serverA)
        let b = try await contractTaskConnect(realtime, actors: actors, userId: joint.peerHuman, serverId: actors.serverB)
        let otherServer = try await contractTaskConnect(realtime, actors: actors, userId: joint.peerHuman, serverId: actors.serverA)
        defer { a.close(); b.close(); otherServer.close() }
        let hub = realtime.hub
        actors.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts, realtime: hub))
            try await app.testing { client in
                let caller = actors.headers(actors.memberA, actors.serverA)
                let ownerB = actors.headers(actors.ownerB, actors.serverB)
                let created = try await client.send(.post, headers: caller, to: URI(string: "/api/tasks/channel/\(joint.localA)")) { $0.body = .init(string: #"{"tasks":[{"title":"Close role-stale task subscriptions"}]}"#) }
                #expect(created.status == .ok)
                let task = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
                let id = try #require(task["id"] as? String)
                _ = try await contractTaskFrames(a, hub: hub, userId: actors.memberA, start: 0)
                _ = try await contractTaskFrames(b, hub: hub, userId: joint.peerHuman, start: 0)
                let before = b.textFrames.count
                let firstAStart = a.textFrames.count
                let first = try await client.send(.patch, headers: caller, to: URI(string: "/api/tasks/\(id)/status")) { $0.body = .init(string: #"{"status":"in_review"}"#) }
                #expect(first.status == .ok)
                let firstAFrames = try await contractTaskFrames(a, hub: hub, userId: actors.memberA, start: firstAStart)
                #expect(firstAFrames.filter { $0.first as? String == "task:updated" }.count == 1)
                let initialFrames = try await contractTaskFrames(b, hub: hub, userId: joint.peerHuman, start: before)
                let updates = initialFrames.filter { $0.first as? String == "task:updated" }
                #expect(updates.count == 1)
                let payload = try #require(updates.first?[1] as? [String: Any])
                #expect(payload["channelId"] as? String == joint.localB)
                let readB = try await client.get(URI(string: "/api/tasks/channel/\(joint.localB)/number/1"), headers: actors.headers(joint.peerHuman, actors.serverB))
                #expect(readB.status == .ok)
                try contractTaskExpectJSONEqual(try #require(payload["task"] as? [String: Any]), try #require(try contractTaskObject(readB)["task"] as? [String: Any]))
                let changed = try await client.send(.patch, headers: ownerB, to: URI(string: "/api/servers/\(actors.serverB)/members/\(joint.peerHuman)")) { $0.body = .init(string: #"{"role":"guest"}"#) }
                #expect(changed.status == .ok)
                #expect(await b.waitForClose())
                #expect(await otherServer.waitForClose())
                #expect(!b.textFrames.contains { $0.contains("server:membership-removed") })
                #expect(!otherServer.textFrames.contains { $0.contains("server:membership-removed") })
                let stopped = b.textFrames.count
                let secondAStart = a.textFrames.count
                let afterDemotion = try await client.send(.patch, headers: caller, to: URI(string: "/api/tasks/\(id)/status")) { $0.body = .init(string: #"{"status":"in_progress"}"#) }
                #expect(afterDemotion.status == .ok)
                let secondAFrames = try await contractTaskFrames(a, hub: hub, userId: actors.memberA, start: secondAStart)
                #expect(secondAFrames.filter { $0.first as? String == "task:updated" }.count == 1)
                #expect(!b.textFrames.dropFirst(stopped).contains { $0.contains("task:updated") })
                let guest = try await contractTaskConnect(realtime, actors: actors, userId: joint.peerHuman, serverId: actors.serverB)
                defer { guest.close() }
                guest.send("42[\"join:channel\",\"\(joint.localB)\"]")
                _ = try await contractTaskResume(guest, lastSeq: 1)
                let guestStart = guest.textFrames.count
                let aStart = a.textFrames.count
                let again = try await client.send(.patch, headers: caller, to: URI(string: "/api/tasks/\(id)/status")) { $0.body = .init(string: #"{"status":"in_review"}"#) }
                #expect(again.status == .ok)
                let aFrames = try await contractTaskFrames(a, hub: hub, userId: actors.memberA, start: aStart)
                #expect(aFrames.filter { $0.first as? String == "task:updated" }.count == 1)
                let denied = try await contractTaskFrames(guest, hub: hub, userId: joint.peerHuman, start: guestStart)
                #expect(!denied.contains { $0.first as? String == "task:updated" })
                // Node also revokes after authorized no-op retries, so a fresh
                // guest socket closes even though the role value is unchanged.
                let retry = try await client.send(.patch, headers: ownerB, to: URI(string: "/api/servers/\(actors.serverB)/members/\(joint.peerHuman)")) { $0.body = .init(string: #"{"role":"guest"}"#) }
                #expect(retry.status == .ok)
                #expect(await guest.waitForClose())
                #expect(!guest.textFrames.contains { $0.contains("server:membership-removed") })
                // Exercise naturally concurrent NIO authentication and real role
                // writes. Either a closed connection or fresh guest admission is
                // valid; stale joint task data after the PATCH response is not.
                for iteration in 0..<8 {
                    let promoted = try await client.send(.patch, headers: ownerB, to: URI(string: "/api/servers/\(actors.serverB)/members/\(joint.peerHuman)")) { $0.body = .init(string: #"{"role":"member"}"#) }
                    #expect(promoted.status == .ok)
                    let racing = try await SocketIOTestClient(port: realtime.port)
                    defer { racing.close() }
                    _ = try #require(await racing.waitForText { $0.hasPrefix("0") })
                    let token = actors.accounts.mintAccessTokenForTesting(userId: joint.peerHuman)
                    racing.send("40{\"token\":\"\(token)\",\"serverId\":\"\(actors.serverB)\"}")
                    let demoted = try await client.send(.patch, headers: ownerB, to: URI(string: "/api/servers/\(actors.serverB)/members/\(joint.peerHuman)")) { $0.body = .init(string: #"{"role":"guest"}"#) }
                    #expect(demoted.status == .ok)
                    try await contractTaskWaitFrameOrClose(racing, prefix: "42[\"rooms:joined\"]", start: 0)
                    let raceStart = racing.textFrames.count
                    let controlStart = a.textFrames.count
                    let status = iteration.isMultiple(of: 2) ? "in_progress" : "in_review"
                    let updated = try await client.send(.patch, headers: caller, to: URI(string: "/api/tasks/\(id)/status")) { $0.body = .init(string: "{\"status\":\"\(status)\"}") }
                    #expect(updated.status == .ok)
                    let controlFrames = try await contractTaskFrames(a, hub: hub, userId: actors.memberA, start: controlStart)
                    #expect(controlFrames.filter { $0.first as? String == "task:updated" }.count == 1)
                    let responseStart = racing.textFrames.count
                    racing.send("42[\"sync:resume\",{\"lastSeq\":1}]")
                    try await contractTaskWaitFrameOrClose(racing, prefix: "42[\"sync:resume:response\",", start: responseStart)
                    #expect(!racing.textFrames.dropFirst(raceStart).contains { $0.contains("task:updated") })
                    let raceRetry = try await client.send(.patch, headers: ownerB, to: URI(string: "/api/servers/\(actors.serverB)/members/\(joint.peerHuman)")) { $0.body = .init(string: #"{"role":"guest"}"#) }
                    #expect(raceRetry.status == .ok)
                    #expect(await racing.waitForClose())
                }
            }
        }
    } catch { try? await realtime.close(); throw error }
    try await realtime.close()
}

@Test func taskContractExplicitUnfollowVetoSurvivesRealReassignmentUntilManualFollow() async throws {
    let actors = ContractTaskActors()
    let owner = actors.headers(actors.ownerA, actors.serverA)
    let realtime = try await RealtimeServer.start(auth: ContractTaskSocketAuth(accounts: actors.accounts))
    do {
        let socket = try await contractTaskConnect(realtime, actors: actors, userId: actors.ownerA, serverId: actors.serverA)
        defer { socket.close() }
        let hub = realtime.hub
        actors.accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: actors.accounts, realtime: hub))
            try await app.testing { client in
                let channelResponse = try await client.send(.post, headers: owner, to: "/api/channels") { $0.body = .init(string: #"{"name":"explicit-unfollow-task"}"#) }
                #expect(channelResponse.status == .ok)
                let channel = try #require(try contractTaskObject(channelResponse)["id"] as? String)
                let sentinelResponse = try await client.send(.post, headers: owner, to: "/api/messages") { $0.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"cursor-before-task\"}") }
                #expect(sentinelResponse.status == .ok)
                let sentinel = try #require(try contractTaskObject(sentinelResponse)["id"] as? String)
                let cursor = try #require(actors.accounts.messageSeqForTesting(messageId: sentinel))
                let created = try await client.send(.post, headers: owner, to: URI(string: "/api/tasks/channel/\(channel)")) { $0.body = .init(string: #"{"tasks":[{"title":"Respect explicit unfollow"}]}"#) }
                #expect(created.status == .ok)
                let task = try #require((try contractTaskObject(created)["tasks"] as? [[String: Any]])?.first)
                let id = try #require(task["id"] as? String)
                let host = try #require(task["messageId"] as? String)
                let assigned = try await client.send(.patch, headers: owner, to: URI(string: "/api/tasks/\(id)/assignee")) { $0.body = .init(string: "{\"assignee\":{\"type\":\"user\",\"id\":\"\(actors.ownerA)\"}}") }
                #expect(assigned.status == .ok)
                let threadResponse = try await client.send(.post, headers: owner, to: URI(string: "/api/channels/\(channel)/threads")) { $0.body = .init(string: "{\"parentMessageId\":\"\(host)\"}") }
                #expect(threadResponse.status == .ok)
                let thread = try #require(try contractTaskObject(threadResponse)["threadChannelId"] as? String)
                func setFollow(_ follow: Bool) async throws {
                    let action = follow ? "follow" : "unfollow"
                    let response = try await client.send(.post, headers: owner, to: URI(string: "/api/channels/threads/\(action)")) { $0.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}") }
                    #expect(response.status == .ok)
                    #expect(try contractTaskObject(response)["following"] as? Bool == follow)
                }
                try await setFollow(true)
                let initial = try await contractTaskResume(socket, lastSeq: cursor)
                let initialRows = try #require(initial["messages"] as? [[String: Any]])
                #expect(initialRows.contains { $0["channelId"] as? String == thread })
                try await setFollow(false)
                // A real reassignment calls the existing thread-notice producer;
                // no follow/unfollow state is hand-written by this fixture.
                let cleared = try await client.send(.patch, headers: owner, to: URI(string: "/api/tasks/\(id)/assignee")) { $0.body = .init(string: #"{"assignee":null}"#) }
                #expect(cleared.status == .ok)
                let scoped = try await client.get(URI(string: "/api/messages/channel/\(thread)"), headers: owner)
                #expect(scoped.status == .ok)
                let scopedRows = try #require(try contractTaskObject(scoped)["messages"] as? [[String: Any]])
                let notices = Set(scopedRows.compactMap { $0["id"] as? String })
                #expect(notices.count >= 2, "explicit scoped reads stay readable; unfollow only removes aggregate attention")
                func aggregateRows() async throws -> [[String: Any]] {
                    let response = try await client.get(URI(string: "/api/messages/sync?since_seq=\(cursor)"), headers: owner)
                    #expect(response.status == .ok)
                    return try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]])
                }
                let suppressed = try await contractTaskResume(socket, lastSeq: cursor)
                let suppressedRows = try #require(suppressed["messages"] as? [[String: Any]])
                #expect(suppressedRows.contains { $0["id"] as? String == host })
                #expect(!suppressedRows.contains { $0["channelId"] as? String == thread })
                #expect(notices.isDisjoint(with: Set(suppressedRows.compactMap { $0["id"] as? String })))
                let httpSuppressed = try await aggregateRows()
                #expect(httpSuppressed.contains { $0["id"] as? String == host })
                #expect(!httpSuppressed.contains { $0["channelId"] as? String == thread })
                try await setFollow(true)
                let restored = try await contractTaskResume(socket, lastSeq: cursor)
                let restoredRows = try #require(restored["messages"] as? [[String: Any]])
                #expect(notices.isSubset(of: Set(restoredRows.compactMap { $0["id"] as? String })))
                let httpRestored = try await aggregateRows()
                #expect(notices.isSubset(of: Set(httpRestored.compactMap { $0["id"] as? String })))
            }
        }
    } catch { try? await realtime.close(); throw error }
    try await realtime.close()
}
