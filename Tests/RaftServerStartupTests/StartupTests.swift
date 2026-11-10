import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif
import NIOCore
import NIOPosix
import Testing

private let e2eEnabled = ProcessInfo.processInfo.environment["RAFT_E2E"] == "1"

@Test(.enabled(if: e2eEnabled), .serialized)
func theServerProcessServesHealthAndAcceptsADaemon() async throws {
    let root = repositoryRoot()
    let serverBinary = ProcessInfo.processInfo.environment["RAFT_SERVER_BIN"]
        ?? root.appendingPathComponent(".build/debug/RaftServer").path
    let daemonBinary = ProcessInfo.processInfo.environment["RAFT_DAEMON_BIN"]
        ?? root.appendingPathComponent(".build/debug/RaftDaemon").path
    #expect(FileManager.default.isExecutableFile(atPath: serverBinary))
    #expect(FileManager.default.isExecutableFile(atPath: daemonBinary))

    let httpPort = try await freePort()
    let daemonPort = try await freePort()
    let socketPort = try await freePort()
    let server = try ServerProcess(
        executable: serverBinary,
        environment: [
            "PORT": String(httpPort),
            "DAEMON_CONNECT_PORT": String(daemonPort),
            "SOCKET_PORT": String(socketPort),
            "NODE_ENV": "test",
            "SLOCK_E2E_AUTO_VERIFY_EMAIL": "1",
            "JWT_SECRET": "test-jwt-secret",
            "SERVER_URL": "http://127.0.0.1:\(httpPort)",
        ]
    )
    defer { server.stop() }
    try server.start()
    guard await server.waitForOutput("raft-server ready") else {
        Issue.record("server did not print its ready line: \(server.output.text)")
        return
    }
    #expect(server.output.text.contains("daemon-connect=127.0.0.1:\(daemonPort)"))

    try await waitForHTTP(port: httpPort)

    let (healthStatus, healthBody) = try await http(
        port: httpPort,
        method: "GET",
        path: "/health"
    )
    #expect(healthStatus == 503)
    #expect(String(decoding: healthBody, as: UTF8.self) == "{\"status\":\"error\",\"detail\":\"database unreachable\"}")

    let (livezStatus, livezBody) = try await http(
        port: httpPort,
        method: "GET",
        path: "/livez"
    )
    #expect(livezStatus == 200)
    #expect(String(decoding: livezBody, as: UTF8.self).contains("\"status\":\"ok\""))

    let missingKey = try await probeDaemonConnect(port: daemonPort, authorization: nil)
    #expect(String(decoding: missingKey, as: UTF8.self) == "HTTP/1.1 401 Unauthorized\r\nSlock-Reason: missing_key\r\n\r\n")

    let email = "startup-\(UUID().uuidString.lowercased())@slock.test"
    let (registerStatus, registerBody) = try await http(
        port: httpPort,
        method: "POST",
        path: "/api/auth/register",
        body: "{\"email\":\(json(email)),\"password\":\"password123\",\"name\":\"Startup Owner\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\",\"__e2eAutoVerify\":true}"
    )
    #expect(registerStatus == 200)
    let token = try jsonObject(registerBody)["accessToken"] as? String ?? ""
    #expect(!token.isEmpty)
    try await completeStartupProfile(
        port: httpPort, token: token, registrationBody: registerBody,
        email: email, displayName: "Startup Owner"
    )

    let slug = "startup-\(UUID().uuidString.lowercased().prefix(8))"
    let (createStatus, createBody) = try await http(
        port: httpPort,
        method: "POST",
        path: "/api/servers",
        token: token,
        body: "{\"name\":\"Startup Server\",\"slug\":\(json(slug))}"
    )
    #expect(createStatus == 200)
    let serverId = try jsonObject(createBody)["id"] as? String ?? ""
    #expect(!serverId.isEmpty)

    let (attachStatus, attachBody) = try await http(
        port: httpPort,
        method: "POST",
        path: "/api/computer/attach",
        token: token,
        serverId: serverId,
        body: "{\"serverSlug\":\(json(slug)),\"name\":\"startup-computer\"}"
    )
    #expect(attachStatus == 201)
    let attach = try jsonObject(attachBody)
    let apiKey = attach["apiKey"] as? String ?? ""
    let machineId = attach["machineId"] as? String ?? ""
    #expect(apiKey.hasPrefix("sk_computer_"))
    #expect(!machineId.isEmpty)

    let socket = try await StartupSocketClient(port: socketPort)
    defer { socket.close() }
    _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
    socket.send("40{\"token\":\(json(token)),\"serverId\":\(json(serverId)),\"clientKind\":\"web\"}")
    _ = try #require(await socket.waitForText { $0.hasPrefix("40{\"sid\":") })
    _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })

    let (channelStatus, channelBody) = try await http(
        port: httpPort,
        method: "POST",
        path: "/api/channels",
        token: token,
        serverId: serverId,
        body: "{\"name\":\"live-updates\",\"description\":\"created during startup test\"}"
    )
    #expect(channelStatus == 200)
    let channel = try jsonObject(channelBody)
    let channelId = channel["id"] as? String ?? ""
    #expect(!channelId.isEmpty)
    let created = try #require(await socket.waitForText { $0.contains("\"channel:updated\"") })
    #expect(created.contains("\"id\":\"\(channelId)\""))
    #expect(created.contains("\"name\":\"live-updates\""))
    #expect(created.contains("\"joined\":true"))

    let (taskStatus, taskBody) = try await http(
        port: httpPort,
        method: "POST",
        path: "/api/tasks/channel/\(channelId)",
        token: token,
        serverId: serverId,
        body: "{\"tasks\":[{\"title\":\"socket task\"}]}"
    )
    try #require(taskStatus == 200)
    let taskReply = try jsonObject(taskBody)
    let createdTasks = try #require(taskReply["tasks"] as? [[String: Any]])
    try #require(createdTasks.count == 1)
    let createdTask = try #require(createdTasks.first)
    let taskId = try #require(createdTask["id"] as? String)
    try #require(UUID(uuidString: taskId) != nil)
    #expect(createdTask["title"] as? String == "socket task")
    #expect(createdTask["channelId"] as? String == channelId)
    #expect(createdTask["status"] as? String == "todo")
    let creatorId = try #require(createdTask["createdById"] as? String)
    try #require(!creatorId.isEmpty)
    let taskEvent = try #require(await socket.waitForText { $0.contains("\"task:created\"") })
    #expect(taskEvent.contains("\"title\":\"socket task\""))
    #expect(taskEvent.contains(taskId))
    let createdPayload = try startupEventPayload(taskEvent, event: "task:created")
    #expect(createdPayload["channelId"] as? String == channelId)
    let eventTasks = try #require(createdPayload["tasks"] as? [[String: Any]])
    try #require(eventTasks.count == 1)
    let eventTask = try #require(eventTasks.first)
    #expect(eventTask["id"] as? String == taskId)
    #expect(eventTask["title"] as? String == "socket task")

    let (claimStatus, claimBody) = try await http(
        port: httpPort,
        method: "PATCH",
        path: "/api/tasks/\(taskId)/claim",
        token: token,
        serverId: serverId
    )
    try #require(claimStatus == 200)
    let claimReply = try jsonObject(claimBody)
    let claimedTask = try #require(claimReply["task"] as? [String: Any])
    #expect(claimedTask["id"] as? String == taskId)
    #expect(claimedTask["title"] as? String == "socket task")
    #expect(claimedTask["channelId"] as? String == channelId)
    #expect(claimedTask["status"] as? String == "in_progress")
    #expect(claimedTask["claimedByType"] as? String == "user")
    #expect(claimedTask["claimedById"] as? String == creatorId)
    let taskUpdate = try #require(await socket.waitForText { $0.contains("\"task:updated\"") })
    #expect(taskUpdate.contains(taskId))
    #expect(taskUpdate.contains("\"status\":\"in_progress\""))
    let updatedPayload = try startupEventPayload(taskUpdate, event: "task:updated")
    #expect(updatedPayload["channelId"] as? String == channelId)
    let updatedTask = try #require(updatedPayload["task"] as? [String: Any])
    #expect(updatedTask["id"] as? String == taskId)
    #expect(updatedTask["status"] as? String == "in_progress")

    let accepted = try await probeDaemonConnect(port: daemonPort, authorization: "Bearer \(apiKey)")
    let acceptedText = String(decoding: accepted, as: UTF8.self)
    #expect(acceptedText.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
    #expect(acceptedText.contains("\"type\":\"machine:context\""))
    #expect(acceptedText.contains("\"machineId\":\"\(machineId)\""))
    #expect(acceptedText.contains("\"serverId\":\"\(serverId)\""))

    // Legacy daemon adoption: one exchange turns an sk_machine_* daemon into a
    // Computer attachment, and the legacy key stops authenticating immediately
    // — no TTL window — with the typed migration reason.
    let (registerMachineStatus, registerMachineBody) = try await http(
        port: httpPort,
        method: "POST",
        path: "/api/servers/\(serverId)/machines",
        token: token,
        serverId: serverId,
        body: "{\"name\":\"legacy-startup-daemon\"}"
    )
    #expect(registerMachineStatus == 200)
    let legacyKey = try jsonObject(registerMachineBody)["apiKey"] as? String ?? ""
    #expect(legacyKey.hasPrefix("sk_machine_"))
    let legacyBefore = try await probeDaemonConnect(port: daemonPort, authorization: "Bearer \(legacyKey)")
    #expect(String(decoding: legacyBefore, as: UTF8.self).hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))

    let (adoptStatus, adoptBody) = try await http(
        port: httpPort,
        method: "POST",
        path: "/api/computer/adopt-legacy",
        token: token,
        serverId: serverId,
        body: "{\"legacyApiKey\":\(json(legacyKey)),\"name\":\"adopted-startup-computer\"}"
    )
    #expect(adoptStatus == 201)
    let adopted = try jsonObject(adoptBody)
    #expect((adopted["apiKey"] as? String)?.hasPrefix("sk_computer_") == true)
    #expect(adopted["resumed"] as? Bool == false)

    let legacyAfter = try await probeDaemonConnect(port: daemonPort, authorization: "Bearer \(legacyKey)")
    let legacyAfterText = String(decoding: legacyAfter, as: UTF8.self)
    #expect(legacyAfterText.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    #expect(legacyAfterText.contains("Slock-Reason: legacy_machine_key_migrated"))

    let daemon = try ServerProcess(
        executable: daemonBinary,
        environment: [
            "SERVER_URL": "http://127.0.0.1:\(daemonPort)",
            "MACHINE_KEY": apiKey,
        ]
    )
    defer { daemon.stop() }
    let daemonFramePosition = socket.framePosition()
    try daemon.start()
    guard await daemon.waitForOutput("daemon connected machine=\(machineId) server=\(serverId)", timeout: 15) else {
        Issue.record("daemon did not connect: \(daemon.output.text)")
        return
    }
    #expect(daemon.output.text.contains("daemon connected machine=\(machineId) server=\(serverId)"))
    let online = try #require(await socket.waitForText({
        $0.contains("\"machine:status\"") && $0.contains(machineId) && $0.contains("\"status\":\"online\"")
    }, after: daemonFramePosition))
    #expect(online.contains("\"statusVersion\":"))
    let onlinePayload = try startupEventPayload(online, event: "machine:status")
    #expect(onlinePayload["machineId"] as? String == machineId)
    #expect(onlinePayload["status"] as? String == "online")
    let statusVersion = try #require(onlinePayload["statusVersion"] as? Int)
    #expect(statusVersion > 0)
}

@Test(.enabled(if: e2eEnabled), .serialized)
func twoRaftServerProcessesStartAndStayIndependent() async throws {
    let root = repositoryRoot()
    let serverBinary = ProcessInfo.processInfo.environment["RAFT_SERVER_BIN"]
        ?? root.appendingPathComponent(".build/debug/RaftServer").path
    #expect(FileManager.default.isExecutableFile(atPath: serverBinary))

    let httpA = try await freePort()
    let daemonA = try await freePort()
    let socketA = try await freePort()
    let httpB = try await freePort()
    let daemonB = try await freePort()
    let socketB = try await freePort()
    func process(_ httpPort: Int, _ daemonPort: Int, _ socketPort: Int) throws -> ServerProcess {
        try ServerProcess(
            executable: serverBinary,
            environment: [
                "PORT": String(httpPort),
                "DAEMON_CONNECT_PORT": String(daemonPort),
                "SOCKET_PORT": String(socketPort),
                "NODE_ENV": "test",
                "SLOCK_E2E_AUTO_VERIFY_EMAIL": "1",
                "JWT_SECRET": "test-jwt-secret",
                "SERVER_URL": "http://127.0.0.1:\(httpPort)",
            ]
        )
    }
    let first = try process(httpA, daemonA, socketA)
    let second = try process(httpB, daemonB, socketB)
    defer { first.stop() }
    defer { second.stop() }
    try first.start()
    try second.start()
    guard await first.waitForOutput("raft-server ready") else {
        Issue.record("first server did not print its ready line: \(first.output.text)")
        return
    }
    guard await second.waitForOutput("raft-server ready") else {
        Issue.record("second server did not print its ready line: \(second.output.text)")
        return
    }
    #expect(first.output.text.contains("http=127.0.0.1:\(httpA)"))
    #expect(first.output.text.contains("daemon-connect=127.0.0.1:\(daemonA)"))
    #expect(second.output.text.contains("http=127.0.0.1:\(httpB)"))
    #expect(second.output.text.contains("daemon-connect=127.0.0.1:\(daemonB)"))
    try await waitForHTTP(port: httpA)
    try await waitForHTTP(port: httpB)

    for port in [httpA, httpB] {
        let (healthStatus, healthBody) = try await http(port: port, method: "GET", path: "/health")
        #expect(healthStatus == 503)
        #expect(String(decoding: healthBody, as: UTF8.self) == "{\"status\":\"error\",\"detail\":\"database unreachable\"}")
        let (livezStatus, _) = try await http(port: port, method: "GET", path: "/livez")
        #expect(livezStatus == 200)
    }

    let email = "two-server-\(UUID().uuidString.lowercased())@slock.test"
    let (registerStatus, registerBody) = try await http(
        port: httpA,
        method: "POST",
        path: "/api/auth/register",
        body: "{\"email\":\(json(email)),\"password\":\"password123\",\"name\":\"Two Server Owner\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\",\"__e2eAutoVerify\":true}"
    )
    #expect(registerStatus == 200)
    let token = try jsonObject(registerBody)["accessToken"] as? String ?? ""
    #expect(!token.isEmpty)
    try await completeStartupProfile(
        port: httpA, token: token, registrationBody: registerBody,
        email: email, displayName: "Two Server Owner"
    )
    let slug = "two-server-\(UUID().uuidString.lowercased().prefix(8))"
    let (createStatus, _) = try await http(
        port: httpA,
        method: "POST",
        path: "/api/servers",
        token: token,
        body: "{\"name\":\"Two Server\",\"slug\":\(json(slug))}"
    )
    #expect(createStatus == 200)

    // The second process keeps its own in-memory directory: the first
    // process's user and session do not exist there.
    let (foreignLogin, _) = try await http(
        port: httpB,
        method: "POST",
        path: "/api/auth/login",
        body: "{\"email\":\(json(email)),\"password\":\"password123\"}"
    )
    #expect(foreignLogin == 401)
    let (localServers, localServersBody) = try await http(port: httpA, method: "GET", path: "/api/servers", token: token)
    #expect(localServers == 200)
    #expect(String(decoding: localServersBody, as: UTF8.self).contains(slug))
    let (foreignServers, _) = try await http(port: httpB, method: "GET", path: "/api/servers", token: token)
    #expect(foreignServers == 401)

    print("two-RaftServer gate complete: A=http://127.0.0.1:\(httpA) B=http://127.0.0.1:\(httpB)")
}

/// Complete the same published profile flow as a new browser account. The
/// register name is only a suggestion; it never substitutes for this request.
private func completeStartupProfile(
    port: Int, token: String, registrationBody: Data, email: String, displayName: String
) async throws {
    let registration = try jsonObject(registrationBody)
    let pending = try #require(registration["user"] as? [String: Any])
    let userId = try #require(pending["id"] as? String)
    #expect(pending["email"] as? String == email)
    try #require(pending["emailVerified"] as? Bool == true)
    #expect((pending["name"] as? String)?.lowercased().hasPrefix("pending_") == true)
    #expect(pending["profileSetupCompletedAt"] is NSNull)

    // Auto-verification does not bypass profile admission to business routes.
    let (blockedStatus, blockedBody) = try await http(
        port: port, method: "POST", path: "/api/servers", token: token,
        body: "{\"name\":\"Admission Probe\",\"slug\":\"startup-admission-probe\"}"
    )
    try #require(blockedStatus == 403)
    #expect(try jsonObject(blockedBody)["code"] as? String == "PROFILE_SETUP_REQUIRED")

    let name = "startup-owner-\(UUID().uuidString.lowercased().prefix(8))"
    let (status, body) = try await http(
        port: port, method: "POST", path: "/api/auth/me/complete-profile", token: token,
        body: "{\"name\":\(json(name)),\"displayName\":\(json(displayName))}"
    )
    try #require(status == 200)
    let completion = try jsonObject(body)
    #expect(completion["name"] as? String == name)
    #expect(completion["displayName"] as? String == displayName)
    let completedAt = try #require(completion["profileSetupCompletedAt"] as? String)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(formatter.date(from: completedAt) != nil)
    try #require(!completion.keys.contains("user"))
    let user = completion
    #expect(user["id"] as? String == userId)
    #expect(user["email"] as? String == email)
    #expect(user["name"] as? String == name)
    #expect(user["displayName"] as? String == displayName)
    #expect(user["emailVerified"] as? Bool == true)
    #expect(user["profileSetupCompletedAt"] as? String == completedAt)

    let (meStatus, meBody) = try await http(port: port, method: "GET", path: "/api/auth/me", token: token)
    try #require(meStatus == 200)
    let persisted = try jsonObject(meBody)
    let completedJSON = try JSONSerialization.data(withJSONObject: user, options: [.sortedKeys])
    let persistedJSON = try JSONSerialization.data(withJSONObject: persisted, options: [.sortedKeys])
    #expect(completedJSON == persistedJSON)
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func json(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

private func startupEventPayload(_ text: String, event expectedEvent: String) throws -> [String: Any] {
    try #require(text.hasPrefix("42"))
    let decoded = try JSONSerialization.jsonObject(with: Data(text.dropFirst(2).utf8))
    let event = try #require(decoded as? [Any])
    try #require((event.first as? String) == expectedEvent)
    return try #require(event.dropFirst().first as? [String: Any])
}

private func freePort() async throws -> Int {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let channel = try await ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = channel.localAddress?.port ?? 0
        try await channel.close()
        try await group.shutdownGracefully()
        return port
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

private func waitForHTTP(port: Int) async throws {
    for _ in 0..<200 {
        if let (status, _) = try? await http(port: port, method: "GET", path: "/livez"), status == 200 {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw StartupTestError.httpNotReady
}

private func http(
    port: Int,
    method: String,
    path: String,
    token: String? = nil,
    serverId: String? = nil,
    body: String? = nil
) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    if let body {
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let serverId {
        request.setValue(serverId, forHTTPHeaderField: "X-Server-Id")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

private func probeDaemonConnect(port: Int, authorization: String?) async throws -> Data {
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    var request = [
        "GET /daemon/connect HTTP/1.1",
        "Host: 127.0.0.1",
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Key: \(key)",
    ]
    if let authorization {
        request.append("Authorization: \(authorization)")
    }
    let text = request.joined(separator: "\r\n") + "\r\n\r\n"

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let promise = group.any().makePromise(of: Data.self)
    let bootstrap = ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandler(DaemonProbeHandler(promise: promise))
        }
    var channel: (any Channel)?
    do {
        let connected = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
        channel = connected
        var buffer = connected.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await connected.writeAndFlush(buffer).get()
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await promise.futureResult.getAbandoningOnCancel() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw StartupTestError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        try? await connected.close()
        try? await group.shutdownGracefully()
        return data
    } catch {
        promise.fail(error)
        if let channel { try? await channel.close() }
        try? await group.shutdownGracefully()
        throw error
    }
}

private struct StartupTestError: Error {
    static let httpNotReady = StartupTestError()
    static let timeout = StartupTestError()
}

private final class DaemonProbeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var collected = Data()
    private let promise: EventLoopPromise<Data>
    private var finished = false

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            collected.append(contentsOf: bytes)
        }
        if complete() {
            finish(result: .success(collected))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(result: complete() ? .success(collected) : .failure(StartupTestError.timeout))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(result: complete() ? .success(collected) : .failure(error))
    }

    private func finish(result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success(let data): promise.succeed(data)
        case .failure(let error): promise.fail(error)
        }
    }

    private func complete() -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = collected.range(of: separator) else { return false }
        let header = String(decoding: collected[..<headerEnd.upperBound], as: UTF8.self)
        if header.hasPrefix("HTTP/1.1 401") || header.hasPrefix("HTTP/1.1 404")
            || header.hasPrefix("HTTP/1.1 500") || header.hasPrefix("HTTP/1.1 400") {
            return true
        }
        guard header.hasPrefix("HTTP/1.1 101") else { return false }
        var bytes = Array(collected[headerEnd.upperBound...])
        return startupReadFrame(&bytes) != nil
    }
}

private final class StartupSocketClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: StartupSocketCollector

    init(port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = StartupSocketCollector()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in channel.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: port)
            .get()
        self.group = group
        self.channel = channel
        self.collector = collector
        let request = [
            "GET /socket.io/?EIO=4&transport=websocket HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await channel.writeAndFlush(buffer).get()
    }

    func send(_ text: String) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count + 8)
        buffer.writeBytes(startupMaskedFrame(text))
        channel.writeAndFlush(buffer, promise: nil)
    }

    func framePosition() -> Int {
        collector.frames.count
    }

    func waitForText(_ predicate: (String) -> Bool, after position: Int = 0, timeout: TimeInterval = 5) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = collector.frames.dropFirst(position).first(where: predicate) { return frame }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return collector.frames.dropFirst(position).first(where: predicate)
    }

    func close() {
        channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }
}

private final class StartupSocketCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var http: [UInt8] = []
    private var bytes: [UInt8] = []
    private var upgraded = false
    private var collected: [String] = []

    var frames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let incoming = buffer.readBytes(length: buffer.readableBytes), !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if upgraded {
            bytes.append(contentsOf: incoming)
        } else {
            http.append(contentsOf: incoming)
            let separator: [UInt8] = [13, 10, 13, 10]
            if let end = startupFind(separator, in: http) {
                bytes.append(contentsOf: http[(end + 4)...])
                http = []
                upgraded = true
            }
        }
        while let frame = startupReadFrame(&bytes) {
            if frame.opcode == 0x1 {
                collected.append(String(decoding: frame.payload, as: UTF8.self))
            }
        }
    }
}

private struct StartupServerFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func startupFind(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    for index in 0...(haystack.count - needle.count) {
        if Array(haystack[index..<(index + needle.count)]) == needle { return index }
    }
    return nil
}

private func startupReadFrame(_ buffer: inout [UInt8]) -> StartupServerFrame? {
    guard buffer.count >= 2 else { return nil }
    let opcode = buffer[0] & 0x0f
    var length = Int(buffer[1] & 0x7f)
    var offset = 2
    if length == 126 {
        guard buffer.count >= 4 else { return nil }
        length = (Int(buffer[2]) << 8) | Int(buffer[3])
        offset = 4
    } else if length == 127 {
        guard buffer.count >= 10 else { return nil }
        var value: UInt64 = 0
        for index in 2..<10 { value = (value << 8) | UInt64(buffer[index]) }
        guard value <= UInt64(Int.max) else { return nil }
        length = Int(value)
        offset = 10
    }
    guard buffer.count >= offset + length else { return nil }
    let payload = Array(buffer[offset..<(offset + length)])
    buffer.removeFirst(offset + length)
    return StartupServerFrame(opcode: opcode, payload: payload)
}

private func startupMaskedFrame(_ text: String) -> [UInt8] {
    let payload = Array(text.utf8)
    var frame: [UInt8] = [0x81]
    if payload.count < 126 {
        frame.append(0x80 | UInt8(payload.count))
    } else if payload.count <= Int(UInt16.max) {
        frame.append(0x80 | 126)
        frame.append(UInt8((payload.count >> 8) & 0xff))
        frame.append(UInt8(payload.count & 0xff))
    } else {
        frame.append(0x80 | 127)
        let length = UInt64(payload.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((length >> shift) & 0xff))
        }
    }
    let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    frame.append(contentsOf: mask)
    for (index, byte) in payload.enumerated() {
        frame.append(byte ^ mask[index % 4])
    }
    return frame
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

private final class ServerProcess: @unchecked Sendable {
    let process = Process()
    let output = OutputBuffer()
    private let pipe = Pipe()
    private let errorPipe = Pipe()

    init(executable: String, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        process.environment = merged
        process.standardOutput = pipe
        process.standardError = errorPipe
        pipe.fileHandleForReading.readabilityHandler = { [output] handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [output] handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data) }
        }
    }

    func start() throws {
        try process.run()
    }

    func waitForOutput(_ needle: String, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if output.text.contains(needle) { return true }
            if !process.isRunning { return output.text.contains(needle) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return output.text.contains(needle)
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
