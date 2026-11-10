import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ExecutionSocketAuth: RealtimeAuthorizing {
    let core: AuthCoreService
    let membership: SocketMembershipService
    func userId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
}

private func executionObject(_ response: ClientResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
}

@Test func taskExecutionCreatesCanonicalTasksWithRealHostMessagesAndSummary() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "task-execution@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-execution", name: "Tasks", ownerId: userId)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let channelResponse = try await client.send(.post, headers: headers, to: "/api/channels") {
                $0.body = .init(string: "{\"name\":\"task-execution\"}")
            }
            #expect(channelResponse.status == .ok)
            let channelId = try #require(try executionObject(channelResponse)["id"] as? String)
            let created = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") {
                $0.body = .init(string: "{\"tasks\":[{\"title\":\"  Write the spec  \",\"description\":\"  durable work  \"},{\"title\":\"Ship it\"}]}")
            }
            #expect(created.status == .ok)
            let body = try executionObject(created)
            #expect(Set(body.keys) == ["tasks"])
            let tasks = try #require(body["tasks"] as? [[String: Any]])
            #expect(tasks.count == 2)
            #expect(tasks.map { $0["title"] as? String } == ["Write the spec", "Ship it"])
            #expect(tasks.first?["description"] as? String == "durable work")
            #expect(tasks.map { $0["taskNumber"] as? Int } == [1, 2])
            #expect(tasks.allSatisfy { $0["status"] as? String == "todo" })
            let hostIds = try tasks.map { try #require($0["messageId"] as? String) }
            let history = try await client.get(URI(string: "/api/messages/channel/\(channelId)?limit=50"), headers: headers)
            #expect(history.status == .ok)
            let messages = try #require(try executionObject(history)["messages"] as? [[String: Any]])
            for (task, hostId) in zip(tasks, hostIds) {
                let host = try #require(messages.first { $0["id"] as? String == hostId })
                #expect(host["content"] as? String == task["title"] as? String)
                #expect(host["messageType"] as? String == "chat")
                #expect(try #require(host["seq"] as? Int) > 0)
                #expect(!(try #require(host["createdAt"] as? String)).isEmpty)
            }
            let summary = try #require(messages.first { ($0["content"] as? String)?.hasPrefix("📋 2 new tasks created:") == true })
            #expect(summary["content"] as? String == "📋 2 new tasks created: #1 \"Write the spec\", #2 \"Ship it\"")
            #expect(summary["messageType"] as? String == "system")
            #expect(summary["senderType"] as? String == "user")
            #expect(summary["senderId"] as? String == "system")
            #expect(summary["senderMembershipStatus"] is NSNull)
            #expect(try #require(summary["seq"] as? Int) > 0)
            #expect(!(try #require(summary["createdAt"] as? String)).isEmpty)
        }
    }
}

@Test func taskExecutionRejectsEmptyTitlesAndOversizedBatchesBeforeCreatingMessages() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "task-validation@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-validation", name: "Tasks", ownerId: userId)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let channelResponse = try await client.send(.post, headers: headers, to: "/api/channels") {
                $0.body = .init(string: "{\"name\":\"task-validation\"}")
            }
            let channelId = try #require(try executionObject(channelResponse)["id"] as? String)
            for (body, error) in [
                ("{\"tasks\":[]}", "tasks array is required"),
                ("{\"tasks\":[{\"title\":\"   \"}]}", "Each task must have a non-empty title"),
                ("{\"tasks\":[{\"title\":17}]}", "Each task must have a non-empty title"),
                ("{\"tasks\":[" + Array(repeating: "{\"title\":\"x\"}", count: 51).joined(separator: ",") + "]}", "Cannot create more than 50 tasks at once"),
            ] {
                let response = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") {
                    $0.body = .init(string: body)
                }
                #expect(response.status == .badRequest)
                #expect(try executionObject(response)["error"] as? String == error)
            }
            let listed = try await client.get(URI(string: "/api/tasks/channel/\(channelId)"), headers: headers)
            #expect(try executionObject(listed)["tasks"] as? [[String: String]] == [])
        }
    }
}

@Test func taskExecutionExplicitControlsRefuseMissingExecutionPipeline() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "task-control@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-control", name: "Control", ownerId: userId)
    let machineId = accounts.registerMachine(serverId: serverId, userId: userId, name: "Computer")
    accounts.setMachineOnline(machineId: machineId, online: true)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let created = try await client.send(.post, headers: headers, to: "/api/agents") {
                $0.body = .init(string: "{\"name\":\"execution-control\",\"machineId\":\"\(machineId)\",\"runtimeConfig\":{\"version\":2,\"runtime\":\"codex\"}}")
            }
            // Node's machine-bound auto-start is best effort, unlike explicit control.
            #expect(created.status == .ok)
            let agentId = try #require(try executionObject(created)["id"] as? String)
            let started = try await client.send(.post, headers: headers, to: "/api/agents/\(agentId)/start")
            #expect(started.status == .internalServerError)
            #expect(try executionObject(started)["error"] as? String == "Failed to start agent")
            #expect(try executionObject(started)["code"] as? String == "internal_error")
            let stopped = try await client.send(.post, headers: headers, to: "/api/agents/\(agentId)/stop")
            #expect(stopped.status == .internalServerError)
            #expect(try executionObject(stopped)["error"] as? String == "Failed to stop agent")
        }
    }
}

@Test func taskExecutionRealAgentSendAndV2ReplayPublishOneMessageOverTheSocket() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "task-cli@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-cli", name: "CLI", ownerId: userId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "cli-agent", creatorUserId: userId, runtime: "codex")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "cli-room", creatorUserId: userId)
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "cli-room", humanIds: [userId], agentIds: [agentId])
    let credential = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "real-cli")
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let realtime = try await RealtimeServer.start(auth: ExecutionSocketAuth(core: accounts.authCore, membership: accounts.socketMembership))
    let socket = try await SocketIOTestClient(port: realtime.port)
    defer { socket.close(); Task { try? await realtime.close() } }
    _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
    socket.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
    _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
    let frameStart = socket.textFrames.count
    let hub = realtime.hub
    accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
    var agentHeaders = HTTPFields()
    agentHeaders[.authorization] = "Bearer \(credential)"
    agentHeaders[.contentType] = "application/json"
    var humanHeaders = HTTPFields()
    humanHeaders[.authorization] = "Bearer \(token)"
    humanHeaders[HTTPField.Name("X-Server-Id")!] = serverId
    let sendHeaders = agentHeaders
    let readHeaders = humanHeaders
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let messageIds = try await withThrowingTaskGroup(of: String.self) { group in
                for path in ["/internal/agent-api/send", "/internal/agent-api/v2/send", "/internal/agent-api/send"] {
                    group.addTask {
                        let sent = try await client.send(.post, headers: sendHeaders, to: URI(string: path)) {
                            $0.body = .init(string: "{\"target\":\"#cli-room\",\"content\":\"The runner explicitly called raft send\",\"idempotencyKey\":\"task68-cli-send\"}")
                        }
                        #expect(sent.status == .ok)
                        return try #require(try executionObject(sent)["messageId"] as? String)
                    }
                }
                var ids: [String] = []
                for try await id in group { ids.append(id) }
                return ids
            }
            #expect(Set(messageIds).count == 1)
            let history = try await client.get(URI(string: "/api/messages/channel/\(channelId)?limit=50"), headers: readHeaders)
            #expect(history.status == .ok)
            let messages = try #require(try executionObject(history)["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages.first?["id"] as? String == messageIds.first)
            #expect(messages.first?["content"] as? String == "The runner explicitly called raft send")
            let fence = #"42["test:task68-send-fence",{}]"#
            hub.emit(room: "user:\(userId)", event: "test:task68-send-fence", payloadJSON: "{}")
            _ = try #require(await socket.waitForText { $0 == fence })
            let frames = socket.textFrames.dropFirst(frameStart).prefix { $0 != fence }
            #expect(frames.count == 1)
            let frame = try #require(frames.first)
            let event = try #require(try JSONSerialization.jsonObject(with: Data(frame.dropFirst(2).utf8)) as? [Any])
            #expect(event.first as? String == "message:new")
            let payload = try #require(event[1] as? [String: Any])
            #expect(payload["id"] as? String == messageIds.first)
            #expect(payload["content"] as? String == "The runner explicitly called raft send")
            #expect(payload["senderId"] as? String == agentId)
        }
    }
}
