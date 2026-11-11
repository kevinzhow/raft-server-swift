import Foundation
import NIOCore
import NIOPosix
import RaftRealtime
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A repeated `2probe` on the WebSocket being upgraded is a valid probe ping,
/// not an upgrade failure: engine.io replies with `3probe` every time and does
/// not restart the upgrade timeout. These are public HTTP/WebSocket tests
/// against the real listener; the raw client makes the frames and the closed
/// upgrade socket observable.
@Suite(.serialized)
struct RealtimeRepeatedProbeTests {
    @Test func repeatedProbeBeforeAndAfterTheLatePollNoopKeepsTheUpgrade() async throws {
        let server = try await RealtimeServer.start(auth: RepeatedProbeAuth())
        defer { Task { try? await server.close() } }
        let http = RepeatedProbeHTTP(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectRepeatedProbe(http)
        let socket = try await RepeatedProbeUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))

        // Ordinary probe: one pong.
        socket.send("2probe")
        #expect(await socket.waitForText("3probe", count: 1))

        // Duplicate probe before any polling GET attaches. The upgrade must
        // stay in progress and answer with a second pong, not fail and close.
        socket.send("2probe")
        #expect(await socket.waitForText("3probe", count: 2))
        #expect(socket.closed == false)

        // The late GET, on a fresh TCP connection, is still this probe's
        // polling cycle and is released with the noop for the same SID.
        let firstLate = try await http.get(sid: sid, timeout: 1)
        #expect(firstLate.status == 200)
        #expect(firstLate.text == "6")

        // Duplicate probe after the noop was written: still a pong, still the
        // same upgrading transport, not a new session.
        socket.send("2probe")
        #expect(await socket.waitForText("3probe", count: 3))
        #expect(socket.closed == false)
        #expect(socket.textFrames.contains { $0.hasPrefix("0{") } == false)

        let secondLate = try await http.get(sid: sid, timeout: 1)
        #expect(secondLate.status == 200)
        #expect(secondLate.text == "6")

        // `5` completes the upgrade of this same Engine.IO and namespace
        // session. The business frame is delivered exactly once, over the
        // WebSocket, with no second namespace connect.
        socket.send("5")
        server.hub.emit(
            room: "channel:c1", event: "message:new",
            payloadJSON: "{\"id\":\"repeated-probe\"}"
        )
        let frames = await socket.waitForMessageFrames(count: 1)
        #expect(frames.count == 1)
        #expect(frames.first == "42[\"message:new\",{\"id\":\"repeated-probe\"}]")
        #expect(server.hub.connectionCount == 1)
        #expect(socket.textFrames.contains { $0.hasPrefix("40{") } == false)
        #expect(socket.textFrames.contains { $0.hasPrefix("0{") } == false)
    }

    @Test func nonProbePacketOnTheUpgradeStillFailsOnlyTheUpgrade() async throws {
        let server = try await RealtimeServer.start(auth: RepeatedProbeAuth())
        defer { Task { try? await server.close() } }
        let http = RepeatedProbeHTTP(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectRepeatedProbe(http)
        let socket = try await RepeatedProbeUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))

        socket.send("2probe")
        #expect(await socket.waitForText("3probe", count: 1))

        // Anything that is neither the probe ping nor `5` still fails the
        // probe transport; it is not an engine ping and gets no pong.
        socket.send("9not-a-probe")
        #expect(await socket.waitForClose(timeout: 2))

        // Only the upgrade failed: the Engine.IO session is still polling.
        server.hub.emit(
            room: "channel:c1", event: "message:new",
            payloadJSON: "{\"id\":\"after-invalid-probe\"}"
        )
        let poll = try await http.get(sid: sid, timeout: 2)
        #expect(poll.packets.contains("42[\"message:new\",{\"id\":\"after-invalid-probe\"}]"))
        #expect(server.hub.connectionCount == 1)
    }

    @Test func probePingAfterUpgradeIsStillAnInvalidClientPing() async throws {
        let server = try await RealtimeServer.start(auth: RepeatedProbeAuth())
        defer { Task { try? await server.close() } }
        let http = RepeatedProbeHTTP(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectRepeatedProbe(http)
        let socket = try await RepeatedProbeUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))

        socket.send("2probe")
        #expect(await socket.waitForText("3probe", count: 1))
        _ = try await http.get(sid: sid, timeout: 1)
        socket.send("5")
        server.hub.emit(
            room: "channel:c1", event: "message:new",
            payloadJSON: "{\"id\":\"upgraded\"}"
        )
        #expect(await socket.waitForText("42[\"message:new\",{\"id\":\"upgraded\"}]", count: 1))

        // Once upgraded this is the current transport, not an upgrade being
        // probed. The server owns pings, so a client `2probe` is still invalid
        // and closes the session instead of being answered.
        socket.send("2probe")
        #expect(await socket.waitForClose(timeout: 2))
        #expect(socket.textFrames.filter { $0 == "3probe" }.count == 1)
    }
}

// MARK: - Fixtures

private final class RepeatedProbeAuth: RealtimeAuthorizing, Sendable {
    func sessionIdentity(forAccessToken token: String) -> RealtimeSessionIdentity? {
        guard let userId = userId(forAccessToken: token) else { return nil }
        return RealtimeSessionIdentity(userId: userId, familyId: sessionFamilyId(forAccessToken: token))
    }

    func userId(forAccessToken token: String) -> String? {
        ["good": "user-1"][token]
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        ["good": "fam-1"][token]
    }

    func serverRole(serverId: String, userId: String) -> String? {
        ["s1\nuser-1": "member"]["\(serverId)\n\(userId)"]
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] { ["c1"] }

    func maxMessageSeq(serverId: String) -> Int? { 7 }

    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        "{\"messages\":[],\"currentSeq\":3,\"hasMore\":false}"
    }
}

private struct RepeatedProbeHTTPResponse: Sendable {
    var status: Int
    var body: [UInt8]

    var text: String { String(decoding: body, as: UTF8.self) }

    var packets: [String] {
        text.split(separator: "\u{1e}", omittingEmptySubsequences: false).map(String.init)
    }

    var sid: String? {
        guard let open = packets.first(where: { $0.hasPrefix("0{") }) else { return nil }
        let json = String(open.dropFirst())
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["sid"] as? String
    }
}

private final class RepeatedProbeHTTP: @unchecked Sendable {
    let port: Int
    private let session: URLSession

    init(port: Int) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration)
    }

    func shutdown() {
        session.invalidateAndCancel()
    }

    func get(_ query: String, timeout: TimeInterval = 5) async throws -> RepeatedProbeHTTPResponse {
        try await request(method: "GET", query: query, timeout: timeout)
    }

    func get(sid: String, timeout: TimeInterval = 5) async throws -> RepeatedProbeHTTPResponse {
        try await get(
            "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)", timeout: timeout
        )
    }

    func post(sid: String, packets: [String]) async throws -> RepeatedProbeHTTPResponse {
        let body = Data(packets.joined(separator: "\u{1e}").utf8)
        return try await request(
            method: "POST",
            query: "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)",
            body: body, contentType: "text/plain;charset=UTF-8", timeout: 5
        )
    }

    private func request(
        method: String, query: String, body: Data? = nil, contentType: String? = nil,
        timeout: TimeInterval
    ) async throws -> RepeatedProbeHTTPResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/socket.io/"
        components.percentEncodedQuery = query
        let url = try #require(components.url)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        return RepeatedProbeHTTPResponse(status: httpResponse.statusCode, body: [UInt8](data))
    }
}

private func connectRepeatedProbe(_ http: RepeatedProbeHTTP) async throws -> String {
    let handshake = try await http.get("EIO=4&transport=polling&t=\(UUID().uuidString)")
    let sid = try #require(handshake.sid)
    let post = try await http.post(
        sid: sid,
        packets: ["40{\"token\":\"good\",\"serverId\":\"s1\",\"clientKind\":\"web\"}"]
    )
    #expect(post.text == "ok")
    let deadline = Date().addingTimeInterval(3)
    var connected = false
    while Date() < deadline, !connected {
        let response = try await http.get(sid: sid, timeout: max(0.2, deadline.timeIntervalSinceNow))
        connected = response.packets.contains { $0.hasPrefix("40{") }
            && response.packets.contains("42[\"rooms:joined\"]")
    }
    #expect(connected)
    return sid
}

private final class RepeatedProbeUpgradeSocket: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: RepeatedProbeUpgradeCollector

    init(port: Int, sid: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = RepeatedProbeUpgradeCollector()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(collector)
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        self.group = group
        self.channel = channel
        self.collector = collector
        let request = [
            "GET /socket.io/?EIO=4&transport=websocket&sid=\(sid) HTTP/1.1",
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

    var textFrames: [String] { collector.textFrames }

    var closed: Bool { collector.closed }

    func waitForStatus(_ expected: Int, timeout: TimeInterval = 3) async -> Bool {
        await repeatedProbeWait(timeout: timeout) { collector.statusCode == expected }
    }

    func send(_ text: String) {
        var payload: [UInt8] = []
        for packet in [text] { payload.append(contentsOf: repeatedProbeMaskedClientTextFrame(packet)) }
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func waitForText(_ text: String, count: Int, timeout: TimeInterval = 2) async -> Bool {
        await repeatedProbeWait(timeout: timeout) {
            collector.textFrames.filter { $0 == text }.count >= count
        }
    }

    func waitForMessageFrames(count: Int, timeout: TimeInterval = 3) async -> [String] {
        _ = await repeatedProbeWait(timeout: timeout) {
            collector.textFrames.filter { $0.hasPrefix("42[\"message:new\"") }.count >= count
        }
        return collector.textFrames.filter { $0.hasPrefix("42[\"message:new\"") }
    }

    func waitForClose(timeout: TimeInterval = 3) async -> Bool {
        await repeatedProbeWait(timeout: timeout) { collector.closed }
    }

    func close() {
        channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }
}

private func repeatedProbeWait(timeout: TimeInterval, until predicate: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

private final class RepeatedProbeUpgradeCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var http: [UInt8] = []
    private var frames: [UInt8] = []
    private var upgraded = false
    private var collected: [String] = []
    private var isClosed = false
    private var status = 0

    var statusCode: Int {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    var textFrames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if upgraded {
            frames.append(contentsOf: bytes)
        } else {
            http.append(contentsOf: bytes)
            guard let end = repeatedProbeFind([13, 10, 13, 10], in: http, from: 0) else { return }
            let head = String(decoding: http[..<end], as: UTF8.self)
            if let statusLine = head.split(separator: "\r\n").first {
                let parts = statusLine.split(separator: " ")
                if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
            }
            frames.append(contentsOf: http[(end + 4)...])
            http = []
            upgraded = true
        }
        while let frame = repeatedProbeReadWebSocketFrame(&frames) {
            if frame.opcode == 0x1 {
                collected.append(String(decoding: frame.payload, as: UTF8.self))
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        isClosed = true
        lock.unlock()
    }
}

private struct RepeatedProbeWebSocketFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func repeatedProbeReadWebSocketFrame(_ buffer: inout [UInt8]) -> RepeatedProbeWebSocketFrame? {
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
    return RepeatedProbeWebSocketFrame(opcode: opcode, payload: payload)
}

private func repeatedProbeMaskedClientTextFrame(_ text: String) -> [UInt8] {
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

private func repeatedProbeFind(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count, start >= 0 else { return nil }
    var index = start
    while index <= haystack.count - needle.count {
        if Array(haystack[index..<(index + needle.count)]) == needle { return index }
        index += 1
    }
    return nil
}
