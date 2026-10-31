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

@Test(.enabled(if: e2eEnabled))
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
    let server = try ServerProcess(
        executable: serverBinary,
        environment: [
            "PORT": String(httpPort),
            "DAEMON_CONNECT_PORT": String(daemonPort),
            "NODE_ENV": "test",
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
        body: "{\"email\":\(json(email)),\"password\":\"password123\",\"name\":\"Startup Owner\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}"
    )
    #expect(registerStatus == 200)
    let token = try jsonObject(registerBody)["accessToken"] as? String ?? ""
    #expect(!token.isEmpty)

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

    let accepted = try await probeDaemonConnect(port: daemonPort, authorization: "Bearer \(apiKey)")
    let acceptedText = String(decoding: accepted, as: UTF8.self)
    #expect(acceptedText.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
    #expect(acceptedText.contains("\"type\":\"machine:context\""))
    #expect(acceptedText.contains("\"machineId\":\"\(machineId)\""))
    #expect(acceptedText.contains("\"serverId\":\"\(serverId)\""))

    let daemon = try ServerProcess(
        executable: daemonBinary,
        environment: [
            "SERVER_URL": "http://127.0.0.1:\(daemonPort)",
            "MACHINE_KEY": apiKey,
        ]
    )
    defer { daemon.stop() }
    try daemon.start()
    guard await daemon.waitForOutput("daemon connected", timeout: 15) else {
        Issue.record("daemon did not connect: \(daemon.output.text)")
        return
    }
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
    let channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
    var buffer = channel.allocator.buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    try await channel.writeAndFlush(buffer).get()
    let data: Data
    do {
        data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await promise.futureResult.get() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw StartupTestError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    } catch {
        try? await channel.close()
        try? await group.shutdownGracefully()
        throw error
    }
    try? await channel.close()
    try? await group.shutdownGracefully()
    return data
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
        finish(result: .success(collected))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(result: collected.isEmpty ? .failure(error) : .success(collected))
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
        let rest = collected[headerEnd.upperBound...]
        guard rest.count >= 2 else { return false }
        let length = Int(rest[rest.startIndex + 1])
        guard length < 126 else { return rest.count >= 4 }
        return rest.count >= 2 + length
    }
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
