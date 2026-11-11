import Foundation
import Synchronization
import NIOCore
import NIOPosix
import RaftRealtime
import Testing

/// The polling transport is a sequence of independent HTTP exchanges. During a
/// WebSocket probe the GET that finishes the polling cycle can arrive after the
/// probe packet because it is a different TCP connection; engine.io releases
/// that GET with a noop so the client can pause polling and send `5`.
///
/// These tests use the real `RealtimeServer` listener and the public hub, with
/// raw HTTP/1.1 and WebSocket clients so `Connection: close` and EOF are
/// observable at the socket boundary.
@Suite(.serialized)
struct RealtimeUpgradeArrivalTests {
    @Test func latePollAfterProbeReceivesNoopAndUpgradeKeepsTheSession() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectArrival(http)
        let socket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))

        socket.send("2probe")
        #expect(await socket.waitForText({ $0 == "3probe" }, timeout: 2) != nil)

        // The client is now paused on the polling cycle. Two GETs arrive after
        // the probe, over separate TCP connections. Each one must be released
        // immediately, long before the 25 s heartbeat or the 10 s upgrade
        // timeout, and each TCP exchange must end because it asked for close.
        let first = try await http.get(sid: sid, connectionClose: true, timeout: 1)
        #expect(first.status == 200)
        #expect(first.text == "6")
        #expect(first.header("connection") == "close")
        #expect(first.closed)

        let second = try await http.get(sid: sid, connectionClose: true, timeout: 1)
        #expect(second.status == 200)
        #expect(second.text == "6")
        #expect(second.closed)

        socket.send("5")
        for index in 0..<30 {
            server.hub.emit(
                room: "channel:c1", event: "message:new",
                payloadJSON: "{\"id\":\"m\(index)\"}"
            )
        }
        let frames = await waitForMessageFrames(socket, count: 30)
        #expect(frames.count == 30)
        #expect(frames == (0..<30).map { "42[\"message:new\",{\"id\":\"m\($0)\"}]" })
        #expect(server.hub.connectionCount == 1)
        #expect(socket.textFrames.contains { $0.hasPrefix("0{") } == false)
    }

    @Test func earlyPollBeforeProbeReceivesNoopAndEndsItsHTTPStream() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectArrival(http)

        // This is the ordinary client shape: a GET is already waiting when the
        // probe ping arrives. The probe pong releases that exchange with the
        // same noop, and `Connection: close` still ends only the HTTP stream.
        let pending = Task { try await http.get(sid: sid, connectionClose: true, timeout: 3) }
        try await Task.sleep(for: .milliseconds(200))
        let socket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))
        socket.send("2probe")
        #expect(await socket.waitForText({ $0 == "3probe" }, timeout: 2) != nil)

        let released = try await pending.value
        #expect(released.status == 200)
        #expect(released.text == "6")
        #expect(released.header("connection") == "close")
        #expect(released.closed)

        socket.send("5")
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"early-poll-upgraded\"}")
        #expect(await socket.waitForText({ $0.contains("early-poll-upgraded") }, timeout: 2) != nil)
        #expect(server.hub.connectionCount == 1)
    }

    @Test func upgradeArrivalReleasesAnInFlightPollingGet() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectArrival(http)
        let socket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))

        // Keep a GET in flight and make a business frame compete with the
        // probe/upgrade frames. Depending on which queued task runs first the
        // GET carries the frame or the upgrade's noop; either way it is one
        // complete response, it ends because of `Connection: close`, and the
        // session continues over the WebSocket.
        let pending = Task { try await http.get(sid: sid, connectionClose: true, timeout: 3) }
        try await Task.sleep(for: .milliseconds(200))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"race-frame\"}")
        socket.sendPackets(["2probe", "5"])

        let response = try await pending.value
        #expect(response.status == 200)
        #expect(response.text == "6" || response.text == "42[\"message:new\",{\"id\":\"race-frame\"}]")
        #expect(response.closed)

        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"after-race\"}")
        #expect(await socket.waitForText({ $0.contains("after-race") }, timeout: 2) != nil)
        #expect(server.hub.connectionCount == 1)
    }

    @Test func latePollWithQueuedBusinessFramesDrainsEachFrameOnce() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectArrival(http)
        let socket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))
        socket.send("2probe")
        #expect(await socket.waitForText({ $0 == "3probe" }, timeout: 2) != nil)

        // Frames queued while no poll is attached belong to the old transport.
        // The GET that arrives after the probe must receive them, in order and
        // exactly once; a noop must not displace them.
        for index in 0..<30 {
            server.hub.emit(
                room: "channel:c1", event: "message:new",
                payloadJSON: "{\"id\":\"queued-\(index)\"}"
            )
        }
        let queued = try await http.get(sid: sid, timeout: 1)
        #expect(queued.status == 200)
        #expect(queued.packets == (0..<30).map { "42[\"message:new\",{\"id\":\"queued-\($0)\"}]" })

        // The next polling cycle, still inside the probe window, gets the noop
        // that lets the client finish pausing.
        let noop = try await http.get(sid: sid, connectionClose: true, timeout: 1)
        #expect(noop.text == "6")
        #expect(noop.closed)

        socket.send("5")
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"after-upgrade\"}")
        #expect(await socket.waitForText({ $0.contains("after-upgrade") }, timeout: 2) != nil)
        #expect(socket.textFrames.contains { $0.contains("queued-") } == false)
        #expect(server.hub.connectionCount == 1)
    }

    @Test func cancelledUpgradeLeavesPollingActiveAndUpgradeCanRetry() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectArrival(http)

        let firstSocket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        #expect(await firstSocket.waitForStatus(101))
        firstSocket.send("2probe")
        #expect(await firstSocket.waitForText({ $0 == "3probe" }, timeout: 2) != nil)
        _ = try await http.get(sid: sid, connectionClose: true, timeout: 1)
        firstSocket.close()
        try await Task.sleep(for: .milliseconds(300))

        // Closing the probe transport before `5` is a failed upgrade, not a
        // closed Engine.IO session. The same SID keeps polling.
        let pending = Task { try await http.get(sid: sid, timeout: 3) }
        try await Task.sleep(for: .milliseconds(200))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"after-cancel\"}")
        let afterCancel = try await pending.value
        #expect(afterCancel.packets.contains("42[\"message:new\",{\"id\":\"after-cancel\"}]"))
        #expect(server.hub.connectionCount == 1)

        // The failed probe state is clear: the same session can upgrade again.
        let secondSocket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        defer { secondSocket.close() }
        #expect(await secondSocket.waitForStatus(101))
        secondSocket.send("2probe")
        #expect(await secondSocket.waitForText({ $0 == "3probe" }, timeout: 2) != nil)
        let retryNoop = try await http.get(sid: sid, connectionClose: true, timeout: 1)
        #expect(retryNoop.text == "6")
        secondSocket.send("5")
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"retry\"}")
        #expect(await secondSocket.waitForText({ $0.contains("retry") }, timeout: 2) != nil)
        #expect(server.hub.connectionCount == 1)
    }

    @Test func revocationDuringProbeDrainsFinalPacketAndClosesTheUpgrade() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectArrival(http)

        // Begin the probe but do not answer it: the polling GET is still
        // pending, so the engine close packet must be its final response.
        let socket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))
        let pending = Task { try await http.get(sid: sid, connectionClose: true, timeout: 3) }
        try await Task.sleep(for: .milliseconds(300))

        server.hub.revokeSessionAccess(userId: "user-1", familyId: "fam-1")
        let final = try await pending.value
        #expect(final.status == 200)
        #expect(final.text == "1")
        #expect(final.closed)
        #expect(await socket.waitForClose(timeout: 2))
        await waitForConnectionCount(server, count: 0)
        #expect(server.hub.connectionCount == 0)

        let expired = try await http.get(sid: sid, connectionClose: true)
        #expect(expired.status == 400)
        #expect(expired.text.contains("\"code\":1"))
    }

    @Test func authFailureStillWritesTheFinalErrorFrameBeforeClosing() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }

        let handshake = try await http.get(
            "EIO=4&transport=polling&t=\(UUID().uuidString)", connectionClose: true
        )
        let sid = try #require(handshake.sid)
        let post = try await http.post(
            sid: sid, packets: ["40{\"token\":\"bad\",\"serverId\":\"s1\",\"clientKind\":\"web\"}"],
            connectionClose: true
        )
        #expect(post.text == "ok")
        let error = try await http.get(sid: sid, connectionClose: true, timeout: 2)
        #expect(error.status == 200)
        #expect(error.text.hasPrefix("44"))
        #expect(error.text.contains("Invalid or expired token"))
        #expect(error.closed)

        let expired = try await http.get(sid: sid, connectionClose: true)
        #expect(expired.status == 400)
        #expect(expired.text.contains("\"code\":1"))
    }

    @Test func authFailureDuringProbeWritesFinalFrameAndClosesTheUpgrade() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }

        // Engine.IO handshake without the Socket.IO connect namespace, then a
        // probe. The namespace handshake fails during the probe, which queues a
        // terminal error frame while the polling cycle is still in flight.
        let handshake = try await http.get("EIO=4&transport=polling&t=\(UUID().uuidString)")
        let sid = try #require(handshake.sid)
        let socket = try await ArrivalUpgradeSocket(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))
        socket.send("2probe")
        #expect(await socket.waitForText({ $0 == "3probe" }, timeout: 2) != nil)

        let post = try await http.post(
            sid: sid,
            packets: ["40{\"token\":\"bad\",\"serverId\":\"s1\",\"clientKind\":\"web\"}"],
            connectionClose: true
        )
        #expect(post.text == "ok")
        try await Task.sleep(for: .milliseconds(200))

        let final = try await http.get(sid: sid, connectionClose: true, timeout: 2)
        #expect(final.status == 200)
        #expect(final.text.hasPrefix("44"))
        #expect(final.text.contains("Invalid or expired token"))
        #expect(final.closed)
        #expect(await socket.waitForClose(timeout: 2))

        let expired = try await http.get(sid: sid, connectionClose: true)
        #expect(expired.status == 400)
        #expect(expired.text.contains("\"code\":1"))
    }

    @Test func connectionCloseOnABusinessPollDoesNotCloseTheEngine() async throws {
        let server = try await RealtimeServer.start(auth: ArrivalAuth())
        defer { Task { try? await server.close() } }
        let http = ArrivalHTTPClient(port: server.port)
        defer { http.shutdown() }
        let sid = try await connectArrival(http)

        let pending = Task { try await http.get(sid: sid, connectionClose: true, timeout: 3) }
        try await Task.sleep(for: .milliseconds(300))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"close-poll\"}")
        let closedPoll = try await pending.value
        #expect(closedPoll.text == "42[\"message:new\",{\"id\":\"close-poll\"}]")
        #expect(closedPoll.header("connection") == "close")
        #expect(closedPoll.closed)

        // The HTTP connection ended, but the Engine.IO session did not: a new
        // TCP connection for the same SID still long-polls and receives frames.
        let next = Task { try await http.get(sid: sid, timeout: 3) }
        try await Task.sleep(for: .milliseconds(200))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"second-poll\"}")
        let second = try await next.value
        #expect(second.packets.contains("42[\"message:new\",{\"id\":\"second-poll\"}]"))
        #expect(server.hub.connectionCount == 1)
    }
}

// MARK: - Fixtures

private final class ArrivalAuth: RealtimeAuthorizing, Sendable {
    private let revoked = Mutex<Set<String>>([])

    func sessionIdentity(forAccessToken token: String) -> RealtimeSessionIdentity? {
        guard let userId = userId(forAccessToken: token) else { return nil }
        return RealtimeSessionIdentity(userId: userId, familyId: sessionFamilyId(forAccessToken: token))
    }

    func userId(forAccessToken token: String) -> String? {
        if revoked.withLock({ $0.contains(token) }) { return nil }
        return ["good": "user-1", "revoked": "user-2"][token]
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        ["good": "fam-1", "revoked": "fam-2"][token]
    }

    func serverRole(serverId: String, userId: String) -> String? {
        ["s1\nuser-1": "member", "s1\nuser-2": "member"]["\(serverId)\n\(userId)"]
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] { ["c1"] }

    func maxMessageSeq(serverId: String) -> Int? { 7 }

    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        "{\"messages\":[],\"currentSeq\":3,\"hasMore\":false}"
    }
}

private struct ArrivalHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: [UInt8]
    var closed: Bool

    func header(_ name: String) -> String? { headers[name.lowercased()] }

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

private enum ArrivalHTTPError: Error {
    case timedOut
}

private final class ArrivalHTTPClient: @unchecked Sendable {
    let port: Int
    private let group: MultiThreadedEventLoopGroup

    init(port: Int) {
        self.port = port
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func shutdown() {
        try? group.syncShutdownGracefully()
    }

    func get(
        _ query: String, connectionClose: Bool = false, timeout: TimeInterval = 5
    ) async throws -> ArrivalHTTPResponse {
        try await request(
            method: "GET", query: query, connectionClose: connectionClose, timeout: timeout
        )
    }

    func get(
        sid: String, connectionClose: Bool = false, timeout: TimeInterval = 5
    ) async throws -> ArrivalHTTPResponse {
        try await get(
            "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)",
            connectionClose: connectionClose, timeout: timeout
        )
    }

    func post(
        sid: String, packets: [String], connectionClose: Bool = false
    ) async throws -> ArrivalHTTPResponse {
        let body = Data(packets.joined(separator: "\u{1e}").utf8)
        return try await request(
            method: "POST",
            query: "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)",
            body: body, contentType: "text/plain;charset=UTF-8",
            connectionClose: connectionClose, timeout: 5
        )
    }

    func request(
        method: String, query: String, body: Data? = nil, contentType: String? = nil,
        connectionClose: Bool, timeout: TimeInterval
    ) async throws -> ArrivalHTTPResponse {
        let collector = ArrivalHTTPCollector()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(collector)
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        var head = "\(method) /socket.io/?\(query) HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(port)\r\n"
        head += "Connection: \(connectionClose ? "close" : "keep-alive")\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        let bodyBytes = body.map { [UInt8]($0) } ?? []
        if body != nil { head += "Content-Length: \(bodyBytes.count)\r\n" }
        head += "\r\n"
        var buffer = channel.allocator.buffer(capacity: head.utf8.count + bodyBytes.count)
        buffer.writeString(head)
        buffer.writeBytes(bodyBytes)
        try await channel.writeAndFlush(buffer).get()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !collector.isComplete, !collector.isClosed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard collector.isComplete else {
            channel.close(promise: nil)
            throw ArrivalHTTPError.timedOut
        }
        if connectionClose {
            while Date() < deadline, !collector.isClosed {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let response = collector.response()
        channel.close(promise: nil)
        return response
    }
}

private final class ArrivalHTTPCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var received: [UInt8] = []
    private var payload: [UInt8] = []
    private var headParsed = false
    private var status = 0
    private var headers: [String: String] = [:]
    private var contentLength: Int?
    private var chunked = false
    private var decodedBody: [UInt8] = []
    private var complete = false
    private var inactive = false

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inactive
    }

    func response() -> ArrivalHTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        return ArrivalHTTPResponse(
            status: status, headers: headers, body: decodedBody, closed: inactive
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        received.append(contentsOf: bytes)
        while !complete {
            if !headParsed {
                guard let end = find([13, 10, 13, 10], in: received, from: 0) else { return }
                parseHead(Array(received[..<end]))
                payload = Array(received[(end + 4)...])
                received = payload
                headParsed = true
            }
            guard headParsed else { return }
            if let contentLength {
                guard payload.count >= contentLength else { return }
                decodedBody = Array(payload.prefix(contentLength))
                complete = true
                return
            }
            if chunked {
                guard let body = decodeChunked(payload) else { return }
                decodedBody = body
                complete = true
                return
            }
            if status == 204 {
                complete = true
                return
            }
            // A close-delimited response only completes when the peer closes.
            if inactive {
                decodedBody = payload
                complete = true
            }
            return
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        defer { lock.unlock() }
        inactive = true
        if headParsed, !complete, contentLength == nil, !chunked {
            decodedBody = payload
            complete = true
        }
    }

    private func parseHead(_ bytes: [UInt8]) {
        let head = String(decoding: bytes, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        if let statusLine = lines.first {
            let parts = statusLine.split(separator: " ")
            if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        contentLength = headers["content-length"].flatMap(Int.init)
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
    }

    private func decodeChunked(_ bytes: [UInt8]) -> [UInt8]? {
        var index = 0
        var result: [UInt8] = []
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: index) else { return nil }
            let sizeLine = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
            guard let size = Int(sizeText, radix: 16) else { return nil }
            index = lineEnd + 2
            if size == 0 {
                guard bytes.count >= index + 2 else { return nil }
                return result
            }
            guard bytes.count >= index + size + 2,
                  bytes[index + size] == 13, bytes[index + size + 1] == 10
            else { return nil }
            result.append(contentsOf: bytes[index..<(index + size)])
            index += size + 2
        }
    }
}

private func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count, start >= 0 else { return nil }
    var index = start
    while index <= haystack.count - needle.count {
        if Array(haystack[index..<(index + needle.count)]) == needle { return index }
        index += 1
    }
    return nil
}

private final class ArrivalUpgradeSocket: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: ArrivalUpgradeCollector

    init(port: Int, sid: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = ArrivalUpgradeCollector()
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

    func waitForStatus(_ expected: Int, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.statusCode == expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return collector.statusCode == expected
    }

    func send(_ text: String) {
        sendPackets([text])
    }

    func sendPackets(_ packets: [String]) {
        var payload: [UInt8] = []
        for packet in packets { payload.append(contentsOf: arrivalMaskedClientTextFrame(packet)) }
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func waitForText(_ predicate: (String) -> Bool, timeout: TimeInterval = 3) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = collector.textFrames.first(where: predicate) { return frame }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return collector.textFrames.first(where: predicate)
    }

    func waitForClose(timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.closed { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return collector.closed
    }

    func close() {
        channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }
}

private final class ArrivalUpgradeCollector: ChannelInboundHandler, @unchecked Sendable {
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
            guard let end = find([13, 10, 13, 10], in: http, from: 0) else { return }
            let head = String(decoding: http[..<end], as: UTF8.self)
            if let statusLine = head.split(separator: "\r\n").first {
                let parts = statusLine.split(separator: " ")
                if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
            }
            frames.append(contentsOf: http[(end + 4)...])
            http = []
            upgraded = true
        }
        while let frame = arrivalReadWebSocketFrame(&frames) {
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

private struct ArrivalWebSocketFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func arrivalReadWebSocketFrame(_ buffer: inout [UInt8]) -> ArrivalWebSocketFrame? {
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
    return ArrivalWebSocketFrame(opcode: opcode, payload: payload)
}

private func arrivalMaskedClientTextFrame(_ text: String) -> [UInt8] {
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

private func connectArrival(_ http: ArrivalHTTPClient) async throws -> String {
    let handshake = try await http.get("EIO=4&transport=polling&t=\(UUID().uuidString)")
    #expect(handshake.status == 200)
    let sid = try #require(handshake.sid)
    let post = try await http.post(
        sid: sid,
        packets: ["40{\"token\":\"good\",\"serverId\":\"s1\",\"clientKind\":\"web\"}"]
    )
    #expect(post.status == 200)
    #expect(post.text == "ok")
    _ = try await readArrivalPackets(http, sid: sid, until: { packets in
        packets.contains { $0.hasPrefix("40{") } && packets.contains("42[\"rooms:joined\"]")
    })
    return sid
}

private func readArrivalPackets(
    _ http: ArrivalHTTPClient, sid: String,
    until predicate: ([String]) -> Bool, timeout: TimeInterval = 3
) async throws -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    var collected: [String] = []
    while Date() < deadline {
        let response = try await http.get(
            sid: sid, timeout: max(0.2, deadline.timeIntervalSinceNow)
        )
        collected.append(contentsOf: response.packets.filter { !$0.isEmpty })
        if predicate(collected) { return collected }
    }
    return collected
}

private func waitForMessageFrames(
    _ socket: ArrivalUpgradeSocket, count: Int, timeout: TimeInterval = 3
) async -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let frames = socket.textFrames.filter { $0.hasPrefix("42[\"message:new\"") }
        if frames.count >= count { return frames }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return socket.textFrames.filter { $0.hasPrefix("42[\"message:new\"") }
}

private func waitForConnectionCount(_ server: RealtimeServer, count: Int, timeout: TimeInterval = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if server.hub.connectionCount == count { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
