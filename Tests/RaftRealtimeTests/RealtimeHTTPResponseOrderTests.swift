import Foundation
import Synchronization
import NIOCore
import NIOPosix
import RaftRealtime
import Testing

/// Engine.IO polling is a sequence of independent HTTP requests that may share
/// one keep-alive TCP connection. Node's HTTP server only attaches the socket
/// to the first outstanding `ServerResponse`, so a later poll's payload waits
/// behind the earlier request even when its engine emits first. These tests use
/// the real listener and raw HTTP so request order, payload ownership, closure
/// and the pinned Node 431 header-limit response are observable at the socket.
@Suite(.serialized)
struct RealtimeHTTPResponseOrderTests {
    // MARK: - Late probe poll followed by a pipelined POST

    @Test func lateProbePollAndPipelinedPongOnTheSameKeepAliveConnectionStayOrdered() async throws {
        let server = try await RealtimeServer.start(auth: OrderAuth())
        defer { Task { try? await server.close() } }
        let http = try OrderHTTPClient(port: server.port)
        defer { http.close() }
        let sid = try await orderConnect(http, token: "alpha")

        let socket = try await OrderUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))
        for _ in 0..<3 { socket.send("2probe") }
        #expect(await socket.waitForTexts("3probe", count: 3))
        #expect(socket.closed == false)

        // The late GET arrives after the probe was acknowledged. engine.io
        // answers it with the noop synchronously from `attachPoll`; the
        // following pong POST is a separate HTTP request on the same
        // connection and must still receive its `ok` acknowledgement.
        let poll = orderGetRequestBytes(sid: sid)
        let pong = orderPostRequestBytes(sid: sid, body: Array("3".utf8))
        http.send(poll + pong)

        let pollResponse = try await http.nextResponse(timeout: 2)
        #expect(pollResponse.status == 200, "status=\(pollResponse.status) body=\(pollResponse.text)")
        #expect(pollResponse.text == "6")
        #expect(pollResponse.header("connection") == "keep-alive")

        let ack = try await http.nextResponse(timeout: 2)
        #expect(ack.status == 200, "status=\(ack.status) body=\(ack.text)")
        #expect(ack.text == "ok")

        // The session and its upgrading transport are intact.
        socket.send("5")
        server.hub.emit(
            room: "channel:c1", event: "message:new",
            payloadJSON: #"{"id":"after-late-pong"}"#
        )
        #expect(await socket.waitForText({ $0.contains("after-late-pong") }, timeout: 2) != nil)
        #expect(server.hub.connectionCount == 1)
    }

    // MARK: - Two pipelined polls with distinct payloads

    @Test func pipelinedPollsForTwoSessionsAnswerInRequestOrderWithTheirOwnPayloads() async throws {
        let server = try await RealtimeServer.start(auth: OrderAuth())
        defer { Task { try? await server.close() } }

        let alphaSetup = try OrderHTTPClient(port: server.port)
        let sidA = try await orderConnect(alphaSetup, token: "alpha")
        alphaSetup.close()
        let betaSetup = try OrderHTTPClient(port: server.port)
        let sidB = try await orderConnect(betaSetup, token: "beta")
        betaSetup.close()
        #expect(server.hub.connectionCount == 2)

        let http = try OrderHTTPClient(port: server.port)
        defer { http.close() }
        // Both long polls are attached, in this order, on one TCP connection.
        http.send(orderGetRequestBytes(sid: sidA) + orderGetRequestBytes(sid: sidB))
        try await Task.sleep(for: .milliseconds(250))

        // B's frame is produced first. Node still answers A's earlier request
        // first, because A owns the first response position on the connection.
        server.hub.emit(
            room: "channel:c2", event: "message:new",
            payloadJSON: #"{"id":"b-first"}"#
        )
        try await Task.sleep(for: .milliseconds(150))
        server.hub.emit(
            room: "channel:c1", event: "message:new",
            payloadJSON: #"{"id":"a-second"}"#
        )

        let first = try await http.nextResponse(timeout: 3)
        let second = try await http.nextResponse(timeout: 3)
        #expect(first.status == 200, "status=\(first.status) body=\(first.text)")
        #expect(second.status == 200, "status=\(second.status) body=\(second.text)")

        // Each response is one complete polling payload, in request order, and
        // neither frame crossed into or duplicated on the other request.
        #expect(first.packets == [#"42["message:new",{"id":"a-second"}]"#])
        #expect(second.packets == [#"42["message:new",{"id":"b-first"}]"#])
        let allPackets = first.packets + second.packets
        #expect(allPackets.filter { $0.contains("a-second") }.count == 1)
        #expect(allPackets.filter { $0.contains("b-first") }.count == 1)
        #expect(server.hub.connectionCount == 2)
    }

    // MARK: - Connection close cleanup for every pending poll on the stream

    @Test func closingAConnectionWithTwoPendingPollsClosesBothSessions() async throws {
        let server = try await RealtimeServer.start(auth: OrderAuth())
        defer { Task { try? await server.close() } }

        let alphaSetup = try OrderHTTPClient(port: server.port)
        let sidA = try await orderConnect(alphaSetup, token: "alpha")
        alphaSetup.close()
        let betaSetup = try OrderHTTPClient(port: server.port)
        let sidB = try await orderConnect(betaSetup, token: "beta")
        betaSetup.close()
        #expect(server.hub.connectionCount == 2)

        let http = try OrderHTTPClient(port: server.port)
        http.send(orderGetRequestBytes(sid: sidA) + orderGetRequestBytes(sid: sidB))
        try await Task.sleep(for: .milliseconds(250))
        http.close()

        // Both engines had a long poll attached to this one connection. Closing
        // it must release both sessions, not only the last one the handler saw.
        _ = await orderWait(timeout: 3) { server.hub.connectionCount == 0 }
        #expect(server.hub.connectionCount == 0)

        // The same SIDs on fresh TCP connections are unknown, like Node after
        // every affected engine was closed.
        for sid in [sidA, sidB] {
            let fresh = try OrderHTTPClient(port: server.port)
            defer { fresh.close() }
            fresh.send(orderGetRequestBytes(sid: sid))
            let response = try await fresh.nextResponse(timeout: 2)
            #expect(response.status == 400, "sid=\(sid) status=\(response.status) body=\(response.text)")
            #expect(response.text.contains("\"code\":1"), "sid=\(sid) body=\(response.text)")
        }
    }

    // MARK: - HTTP header limit

    @Test func oversizedHeaderReturnsNode431AndListenerStaysHealthy() async throws {
        let server = try await RealtimeServer.start(auth: OrderAuth())
        defer { Task { try? await server.close() } }

        let oversized = try OrderHTTPClient(port: server.port)
        oversized.send(orderHeadRequestBytes(countedHeadBytes: 18_000))
        let response = try await oversized.nextResponse(timeout: 2)
        // Pinned Node 22.22.3 llhttp overflow response: 431, empty body, close.
        #expect(response.status == 431, "status=\(response.status) body=\(response.text)")
        #expect(response.text.isEmpty)
        #expect(response.header("connection") == "close")
        #expect(response.header("content-length") == nil)
        #expect(response.header("transfer-encoding") == nil)
        #expect(await oversized.waitForClose(timeout: 2))
        oversized.close()

        // A valid request at the 16 KiB boundary is still routed normally.
        let boundary = try OrderHTTPClient(port: server.port)
        defer { boundary.close() }
        boundary.send(orderHeadRequestBytes(countedHeadBytes: 16 * 1_024))
        let accepted = try await boundary.nextResponse(timeout: 2)
        #expect(accepted.status == 200, "status=\(accepted.status) body=\(accepted.text)")
        #expect(try #require(accepted.sid).isEmpty == false)

        // An unterminated head that keeps growing is rejected once the bounded
        // limit is crossed; the listener stays healthy.
        let growing = try OrderHTTPClient(port: server.port)
        growing.send(orderUnterminatedHeadBytes(initialBytes: 8 * 1_024))
        try await Task.sleep(for: .milliseconds(30))
        growing.send([UInt8](repeating: UInt8(ascii: "a"), count: 12 * 1_024))
        let grown = try await growing.nextResponse(timeout: 2)
        #expect(grown.status == 431, "status=\(grown.status) body=\(grown.text)")
        #expect(grown.text.isEmpty)
        #expect(await growing.waitForClose(timeout: 2))
        growing.close()

        let fresh = try OrderHTTPClient(port: server.port)
        defer { fresh.close() }
        fresh.send(orderHandshakeRequestBytes())
        let handshake = try await fresh.nextResponse(timeout: 2)
        #expect(handshake.status == 200)
        #expect(try #require(handshake.sid).isEmpty == false)
    }
}

// MARK: - Auth fixture

private final class OrderAuth: RealtimeAuthorizing, Sendable {
    func sessionIdentity(forAccessToken token: String) -> RealtimeSessionIdentity? {
        guard let userId = userId(forAccessToken: token) else { return nil }
        return RealtimeSessionIdentity(userId: userId, familyId: sessionFamilyId(forAccessToken: token))
    }

    func userId(forAccessToken token: String) -> String? {
        ["alpha": "user-1", "beta": "user-2"][token]
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        ["alpha": "fam-1", "beta": "fam-2"][token]
    }

    func serverRole(serverId: String, userId: String) -> String? {
        ["s1\nuser-1": "member", "s1\nuser-2": "member"]["\(serverId)\n\(userId)"]
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        ["user-1": ["c1"], "user-2": ["c2"]][userId] ?? []
    }

    func maxMessageSeq(serverId: String) -> Int? { 7 }
}

// MARK: - Raw HTTP client

private struct OrderHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: [UInt8]

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var text: String { String(decoding: body, as: UTF8.self) }
    var packets: [String] {
        text.split(separator: "\u{1e}", omittingEmptySubsequences: false).map(String.init)
    }

    var sid: String? {
        guard let open = packets.first(where: { $0.hasPrefix("0{") }),
              let data = String(open.dropFirst()).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["sid"] as? String
    }
}

private enum OrderHTTPError: Error {
    case closed
    case incomplete
    case timeout
}

private final class OrderHTTPClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: OrderHTTPCollector
    private var pending: [UInt8] = []

    init(port: Int) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = OrderHTTPCollector()
        do {
            let channel = try ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(collector)
                }
                .connect(host: "127.0.0.1", port: port)
                .wait()
            self.group = group
            self.channel = channel
            self.collector = collector
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func send(_ bytes: [UInt8]) {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func nextResponse(timeout: TimeInterval = 3) async throws -> OrderHTTPResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let response = parseNextResponse() { return response }
            let incoming = collector.take()
            if !incoming.isEmpty {
                pending.append(contentsOf: incoming)
                continue
            }
            if collector.isClosed {
                throw pending.isEmpty ? OrderHTTPError.closed : OrderHTTPError.incomplete
            }
            if Date() >= deadline { throw OrderHTTPError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForClose(timeout: TimeInterval = 2) async -> Bool {
        await orderWait(timeout: timeout) { collector.isClosed }
    }

    func close() {
        channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }

    private func parseNextResponse() -> OrderHTTPResponse? {
        guard let headEnd = orderFindHeaderEnd(pending) else { return nil }
        let head = String(decoding: pending[..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var offset = headEnd + 4
        var body: [UInt8] = []
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                guard let lineEnd = orderFindCRLF(pending, from: offset) else { return nil }
                let line = String(decoding: pending[offset..<lineEnd], as: UTF8.self)
                let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                offset = lineEnd + 2
                if size == 0 {
                    guard pending.count >= offset + 2,
                          pending[offset] == 13, pending[offset + 1] == 10
                    else { return nil }
                    offset += 2
                    break
                }
                guard pending.count >= offset + size + 2 else { return nil }
                body.append(contentsOf: pending[offset..<(offset + size)])
                offset += size
                guard pending[offset] == 13, pending[offset + 1] == 10 else { return nil }
                offset += 2
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard pending.count >= offset + length else { return nil }
            body = Array(pending[offset..<(offset + length)])
            offset += length
        }
        pending.removeFirst(offset)
        return OrderHTTPResponse(status: status, headers: headers, body: body)
    }
}

private final class OrderHTTPCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private struct State {
        var bytes: [UInt8] = []
        var closed = false
    }
    private let state = Mutex(State())

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        state.withLock { $0.bytes.append(contentsOf: bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.withLock { $0.closed = true }
    }

    func take() -> [UInt8] {
        state.withLock { state in
            let bytes = state.bytes
            state.bytes.removeAll(keepingCapacity: true)
            return bytes
        }
    }

    var isClosed: Bool { state.withLock { $0.closed } }
}

// MARK: - Raw WebSocket probe

private final class OrderUpgradeSocket: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: OrderUpgradeCollector

    init(port: Int, sid: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = OrderUpgradeCollector()
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
        await orderWait(timeout: timeout) { collector.statusCode == expected }
    }

    func send(_ text: String) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count + 8)
        buffer.writeBytes(orderMaskedClientTextFrame(text))
        channel.writeAndFlush(buffer, promise: nil)
    }

    func waitForText(_ predicate: (String) -> Bool, timeout: TimeInterval = 3) async -> String? {
        _ = await orderWait(timeout: timeout) { collector.textFrames.contains(where: predicate) }
        return collector.textFrames.first(where: predicate)
    }

    func waitForTexts(_ text: String, count: Int, timeout: TimeInterval = 3) async -> Bool {
        await orderWait(timeout: timeout) {
            collector.textFrames.filter { $0 == text }.count >= count
        }
    }

    func close() {
        channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }
}

private final class OrderUpgradeCollector: ChannelInboundHandler, @unchecked Sendable {
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
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if upgraded {
            frames.append(contentsOf: bytes)
        } else {
            http.append(contentsOf: bytes)
            guard let end = orderFindHeaderEnd(http) else { return }
            let head = String(decoding: http[..<end], as: UTF8.self)
            if let statusLine = head.split(separator: "\r\n").first {
                let parts = statusLine.split(separator: " ")
                if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
            }
            frames.append(contentsOf: http[(end + 4)...])
            http = []
            upgraded = true
        }
        while let frame = orderReadWebSocketFrame(&frames) {
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

// MARK: - Helpers

private func orderWait(timeout: TimeInterval, until predicate: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

private struct OrderWebSocketFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func orderReadWebSocketFrame(_ buffer: inout [UInt8]) -> OrderWebSocketFrame? {
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
    return OrderWebSocketFrame(opcode: opcode, payload: payload)
}

private func orderMaskedClientTextFrame(_ text: String) -> [UInt8] {
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

private func orderFindHeaderEnd(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    var index = 0
    while index + 3 < bytes.count {
        if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
            return index
        }
        index += 1
    }
    return nil
}

private func orderFindCRLF(_ bytes: [UInt8], from: Int) -> Int? {
    guard bytes.count >= from + 2 else { return nil }
    var index = from
    while index + 1 < bytes.count {
        if bytes[index] == 13, bytes[index + 1] == 10 { return index }
        index += 1
    }
    return nil
}

private func orderGetRequestBytes(sid: String) -> [UInt8] {
    orderRequestHeadBytes(
        method: "GET", query: "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)"
    )
}

private func orderPostRequestBytes(sid: String, body: [UInt8]) -> [UInt8] {
    var bytes = orderRequestHeadBytes(
        method: "POST", query: "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)",
        extraHeaders: ["Content-Type: text/plain;charset=UTF-8", "Content-Length: \(body.count)"]
    )
    bytes.append(contentsOf: body)
    return bytes
}

private func orderHandshakeRequestBytes() -> [UInt8] {
    orderRequestHeadBytes(
        method: "GET", query: "EIO=4&transport=polling&t=\(UUID().uuidString)"
    )
}

private func orderRequestHeadBytes(
    method: String, query: String, extraHeaders: [String] = [], connection: String = "keep-alive"
) -> [UInt8] {
    var lines = ["\(method) /socket.io/?\(query) HTTP/1.1", "Host: 127.0.0.1"]
    lines.append(contentsOf: extraHeaders)
    lines.append("Connection: \(connection)")
    return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
}

/// A request head whose bytes before the final blank line, excluding the last
/// header's CRLF, equal `countedHeadBytes`.
private func orderHeadRequestBytes(countedHeadBytes: Int) -> [UInt8] {
    let prefix = "GET /socket.io/?EIO=4&transport=polling&t=big HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    let tail = "Connection: close\r\n"
    let fixed = prefix.utf8.count + "X-Big: ".utf8.count + tail.utf8.count
    let pad = max(0, countedHeadBytes - fixed)
    let head = prefix + "X-Big: " + String(repeating: "a", count: pad) + "\r\n" + tail
    return Array((head + "\r\n").utf8)
}

private func orderUnterminatedHeadBytes(initialBytes: Int) -> [UInt8] {
    var head = "GET /socket.io/?EIO=4&transport=polling&t=grow HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Big: "
    head += String(repeating: "a", count: max(0, initialBytes - head.utf8.count))
    return Array(head.utf8)
}

private func orderConnect(_ http: OrderHTTPClient, token: String) async throws -> String {
    http.send(orderHandshakeRequestBytes())
    let handshake = try await http.nextResponse()
    #expect(handshake.status == 200)
    let sid = try #require(handshake.sid)

    let body = Array(#"40{"token":"\#(token)","serverId":"s1","clientKind":"web"}"#.utf8)
    http.send(orderPostRequestBytes(sid: sid, body: body))
    let ack = try await http.nextResponse()
    #expect(ack.status == 200)
    #expect(ack.text == "ok")

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        http.send(orderGetRequestBytes(sid: sid))
        let connected = try await http.nextResponse(timeout: max(0.2, deadline.timeIntervalSinceNow))
        let packets = connected.packets
        if packets.contains(where: { $0.hasPrefix("40{") })
            && packets.contains(#"42["rooms:joined"]"#) {
            return sid
        }
    }
    throw OrderHTTPError.timeout
}
