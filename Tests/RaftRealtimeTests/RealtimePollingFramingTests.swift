import Foundation
import Synchronization
import NIOCore
import NIOPosix
import RaftRealtime
import Testing

/// Engine.IO polling HTTP framing: Content-Length validation, chunked request
/// bodies, response ordering on a pipelined connection, and upgrade residual
/// bytes. The listener must reject malformed framing with 400/close without
/// killing its event loop or another session.
@Suite(.serialized)
struct RealtimePollingFramingTests {
    // MARK: - Chunked request bodies

    @Test func chunkedPostCarriesConnectAndBusinessPackets() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }

        let sid = try await handshake(client)
        let connect = #"40{"token":"good","serverId":"s1","clientKind":"web","note":"wéb"}"#
        let join = #"42["join:channel","c1"]"#
        var body = Array(connect.utf8)
        body.append(0x1e)
        body.append(contentsOf: Array(join.utf8))

        // Split inside the UTF-8 encoding of "é" (0xC3 0xA9) as well as on
        // packet and chunk boundaries. The decoded body must still be one
        // text payload, not two lossy strings.
        var chunks: [[UInt8]] = []
        var cursor = 0
        let sizes = [3, 11, 17, 5, 23, 7, 1000]
        for size in sizes where cursor < body.count {
            let end = min(cursor + size, body.count)
            chunks.append(Array(body[cursor..<end]))
            cursor = end
        }
        if cursor < body.count { chunks.append(Array(body[cursor...])) }
        client.send(chunkedRequestBytes(query: pollingQuery(sid: sid), chunks: chunks, trailers: [("X-Trace", "framing")]))

        let ack = try await client.nextResponse()
        #expect(ack.status == 200)
        #expect(ack.text == "ok")
        #expect(ack.header("content-type") == "text/html")

        client.send(getRequestBytes(query: pollingQuery(sid: sid)))
        let connected = try await client.nextResponse()
        #expect(connected.status == 200, "status=\(connected.status) body=\(connected.text)")
        #expect(connected.text.contains(#"40{"sid":""#), "body=\(connected.text)")
        #expect(connected.text.contains(#"42["rooms:joined"]"#), "body=\(connected.text)")

        client.send(getRequestBytes(query: pollingQuery(sid: sid)))
        try await Task.sleep(for: .milliseconds(50))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: #"{"id":"chunked-1"}"#)
        let frame = try await client.nextResponse()
        #expect(frame.text.contains(#"42["message:new",{"id":"chunked-1"}]"#))
    }

    @Test func chunkedPostSeparatedOnEveryByteKeepsIncrementalState() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }

        let sid = try await handshake(client)
        let bytes = chunkedRequestBytes(
            query: pollingQuery(sid: sid),
            chunks: [Array(#"40{"token":"good","serverId":"s1"}"#.utf8)],
            trailers: [("X-Trace", "byte-by-byte")],
            chunkExtension: ";part=1"
        )
        for byte in bytes {
            client.send([byte])
            try await Task.sleep(for: .milliseconds(1))
        }
        let ack = try await client.nextResponse(timeout: 5)
        #expect(ack.status == 200)
        #expect(ack.text == "ok")

        client.send(getRequestBytes(query: pollingQuery(sid: sid)))
        let connected = try await client.nextResponse()
        #expect(connected.text.contains(#"40{"sid":""#))
    }

    @Test func fixedContentLengthBodySplitAcrossReadsKeepsIncrementalState() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }

        let sid = try await handshake(client)
        let body = Array(#"40{"token":"good","serverId":"s1"}"#.utf8)
        let request = contentLengthRequestBytes(
            method: "POST", query: pollingQuery(sid: sid),
            contentLength: "\(body.count)", body: body, connection: "keep-alive"
        )
        for byte in request {
            client.send([byte])
            try await Task.sleep(for: .milliseconds(1))
        }
        let ack = try await client.nextResponse(timeout: 5)
        #expect(ack.status == 200)
        #expect(ack.text == "ok")

        client.send(getRequestBytes(query: pollingQuery(sid: sid)))
        let connected = try await client.nextResponse()
        #expect(connected.text.contains(#"40{"sid":""#))
    }

    @Test func oversizedRequestHeadIsRejectedAndListenerStaysHealthy() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }
        let big = String(repeating: "a", count: 20_000)
        let bytes = requestHeadBytes(
            method: "GET",
            query: "EIO=4&transport=polling&t=bighead",
            extraHeaders: ["X-Big: \(big)"], connection: "close"
        )
        client.send(bytes)
        let rejected = try await client.nextResponse()
        // Pinned Node 22.22.3 llhttp overflow response: 431/close, no body.
        #expect(rejected.status == 431)
        #expect(rejected.text.isEmpty)
        #expect(await client.waitForClose())

        let fresh = try RawHTTPClient(port: server.port)
        defer { fresh.close() }
        #expect(try await handshake(fresh).isEmpty == false)
    }

    @Test func chunkedPostKeepsTheConnectionForTheFollowingPoll() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }

        let sid = try await handshake(client)
        // Same TCP connection: POST then a long poll. The POST must not leave
        // the parser in a state where the next request is swallowed or the
        // decoded chunk bytes are treated as a request head.
        var body = Array(#"40{"token":"good","serverId":"s1"}"#.utf8)
        body.append(0x1e)
        body.append(contentsOf: Array(#"42["join:channel","c1"]"#.utf8))
        client.send(chunkedRequestBytes(
            query: pollingQuery(sid: sid),
            chunks: [Array(body[..<13]), Array(body[13...])],
            trailers: []
        ))
        let ack = try await client.nextResponse()
        #expect(ack.status == 200)
        #expect(ack.text == "ok")

        client.send(getRequestBytes(query: pollingQuery(sid: sid)))
        let connected = try await client.nextResponse()
        #expect(connected.status == 200, "status=\(connected.status) body=\(connected.text)")
        #expect(connected.text.contains(#"40{"sid":""#), "body=\(connected.text)")
        #expect(connected.text.contains(#"42["rooms:joined"]"#), "body=\(connected.text)")

        client.send(getRequestBytes(query: pollingQuery(sid: sid)))
        try await Task.sleep(for: .milliseconds(50))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: #"{"id":"chunked-keepalive"}"#)
        let frame = try await client.nextResponse()
        #expect(frame.text.contains(#"42["message:new",{"id":"chunked-keepalive"}]"#))
    }

    @Test func chunkedOversizeUsesDecodedLengthAndSessionPriority() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let handshakeClient = try RawHTTPClient(port: server.port)
        defer { handshakeClient.close() }
        let sid = try await handshake(handshakeClient)

        // 10 x 100_001 decoded bytes > 1_000_000, sent as ten independent
        // chunks so the limit is accumulated across chunk boundaries.
        let oversizedChunks = Array(repeating: [UInt8](repeating: UInt8(ascii: "a"), count: 100_001), count: 10)

        let valid = try await oneShot(
            port: server.port,
            bytes: chunkedRequestBytes(query: pollingQuery(sid: sid), chunks: oversizedChunks)
        )
        #expect(valid.status == 413)
        #expect(valid.text.isEmpty)

        let unknown = try await oneShot(
            port: server.port,
            bytes: chunkedRequestBytes(query: "EIO=4&transport=polling&sid=nope", chunks: oversizedChunks)
        )
        #expect(unknown.status == 400)
        #expect(unknown.text == #"{"code":1,"message":"Session ID unknown"}"#)

        let handshakeMethod = try await oneShot(
            port: server.port,
            bytes: chunkedRequestBytes(query: "EIO=4&transport=polling", chunks: oversizedChunks)
        )
        #expect(handshakeMethod.status == 400)
        #expect(handshakeMethod.text == #"{"code":2,"message":"Bad handshake method"}"#)

        // The listener is still healthy after rejecting the oversized bodies.
        let fresh = try RawHTTPClient(port: server.port)
        defer { fresh.close() }
        #expect(try await handshake(fresh).isEmpty == false)
    }

    // MARK: - Content-Length validation

    @Test func negativeAndInvalidContentLengthAreRejectedInAChildProcess() async throws {
        let child = try await startChildServer()
        defer { child.stop() }
        let sid = try await childHandshake(child.port)

        // A negative length used to construct a reversed range in the
        // connection handler and take down the whole listener process.
        let negative = try await oneShot(
            port: child.port,
            bytes: contentLengthRequestBytes(
                method: "POST", query: pollingQuery(sid: sid),
                contentLength: "-1", body: Array("3".utf8)
            )
        )
        #expect(negative.status == 400)
        #expect(child.isRunning)

        // A non-numeric length used to be treated as zero, letting the body
        // bytes masquerade as a second HTTP request. The request must be a
        // parser error and the following bytes must never become a handshake.
        let masqueradeBody = Array("GET /socket.io/?EIO=4&transport=polling&t=evil HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        let malformed = contentLengthRequestBytes(
            method: "POST", query: pollingQuery(sid: sid),
            contentLength: "abc", body: masqueradeBody
        )
        let malformedResponse = try await oneShot(port: child.port, bytes: malformed)
        #expect(malformedResponse.status == 400)
        #expect(malformedResponse.text.isEmpty)
        #expect(child.isRunning)

        // Duplicate identical and duplicate conflicting lengths are parser
        // errors in Node's HTTP parser, not last-value-wins.
        var duplicateSame = requestHeadBytes(
            method: "POST", query: pollingQuery(sid: sid),
            extraHeaders: ["Content-Length: 1", "Content-Length: 1"], connection: "close"
        )
        duplicateSame.append(0x33)
        let same = try await oneShot(port: child.port, bytes: duplicateSame)
        #expect(same.status == 400)

        var duplicateConflict = requestHeadBytes(
            method: "POST", query: pollingQuery(sid: sid),
            extraHeaders: ["Content-Length: 1", "Content-Length: 2"], connection: "close"
        )
        duplicateConflict.append(contentsOf: Array("33".utf8))
        let conflict = try await oneShot(port: child.port, bytes: duplicateConflict)
        #expect(conflict.status == 400)

        var commaLength = requestHeadBytes(
            method: "POST", query: pollingQuery(sid: sid),
            extraHeaders: ["Content-Length: 1, 1"], connection: "close"
        )
        commaLength.append(0x33)
        let comma = try await oneShot(port: child.port, bytes: commaLength)
        #expect(comma.status == 400)

        var overflowLength = requestHeadBytes(
            method: "POST", query: pollingQuery(sid: sid),
            extraHeaders: ["Content-Length: 18446744073709551616"], connection: "close"
        )
        overflowLength.append(0x33)
        let overflow = try await oneShot(port: child.port, bytes: overflowLength)
        #expect(overflow.status == 400)
        #expect(child.isRunning)
    }

    @Test func hugeContentLengthOnGetDoesNotCrashTheListener() async throws {
        let child = try await startChildServer()
        defer { child.stop() }
        let _ = try await childHandshake(child.port)

        // Int.max previously overflowed end + 4 + bodyLength. A GET body is
        // framed and discarded by Node; it must at most wait for bytes, never
        // trap. The child is a separate process so a regression is observable
        // without killing the test runner.
        let client = try RawHTTPClient(port: child.port)
        defer { client.close() }
        var request = requestHeadBytes(
            method: "GET", query: "EIO=4&transport=polling&t=huge",
            extraHeaders: ["Content-Length: 9223372036854775807"], connection: "keep-alive"
        )
        request.append(contentsOf: Array("abc".utf8))
        client.send(request)
        try await Task.sleep(for: .milliseconds(300))
        #expect(child.isRunning)

        // The listener still accepts and completes a fresh handshake.
        let fresh = try RawHTTPClient(port: child.port)
        defer { fresh.close() }
        #expect(try await handshake(fresh).isEmpty == false)
        #expect(child.isRunning)
    }

    // MARK: - Transfer-Encoding and chunk framing errors

    @Test func transferEncodingConflictsAndUnsupportedCodingsAreRejected() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }
        let sid = try await handshake(client)

        let cases: [[String]] = [
            ["Content-Length: 1", "Transfer-Encoding: chunked"],
            ["Transfer-Encoding: gzip"],
            ["Transfer-Encoding: chunked, gzip"],
            ["Transfer-Encoding: chunked", "Transfer-Encoding: chunked"],
        ]
        for headers in cases {
            let request = requestHeadBytes(
                method: "POST", query: pollingQuery(sid: sid),
                extraHeaders: headers, connection: "close"
            )
            let response = try await oneShot(port: server.port, bytes: request + Array("0\r\n\r\n".utf8))
            #expect(response.status == 400)
            #expect(response.text.isEmpty)
        }

        // "gzip, chunked" is a legal transfer coding order and reaches the
        // chunked decoder; the empty body is acknowledged.
        let legalOrder = try await oneShot(
            port: server.port,
            bytes: requestHeadBytes(
                method: "POST", query: pollingQuery(sid: sid),
                extraHeaders: ["Transfer-Encoding: gzip, chunked"], connection: "close"
            ) + Array("0\r\n\r\n".utf8)
        )
        #expect(legalOrder.status == 200)
        #expect(legalOrder.text == "ok")
    }

    @Test func malformedChunkFramingIsRejectedWithoutLosingTheListener() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }
        let sid = try await handshake(client)
        let query = pollingQuery(sid: sid)

        let cases: [[UInt8]] = [
            chunkedHeadBytes(query: query) + Array("+5\r\nhello\r\n0\r\n\r\n".utf8),
            chunkedHeadBytes(query: query) + Array("FFFFFFFFFFFFFFFFF\r\n".utf8),
            chunkedHeadBytes(query: query) + Array("5\r\nhelloXX0\r\n\r\n".utf8),
            chunkedHeadBytes(query: query) + Array("5\r\nhello\r\n0\r\nContent-Length: 3\r\n\r\n".utf8),
        ]
        for bytes in cases {
            let response = try await oneShot(port: server.port, bytes: bytes)
            #expect(response.status == 400)
            #expect(response.text.isEmpty)
        }

        // Truncated frames wait for more bytes instead of busy-failing.
        let truncated = try RawHTTPClient(port: server.port)
        defer { truncated.close() }
        truncated.send(chunkedHeadBytes(query: query) + Array("5\r\nhel".utf8))
        try await Task.sleep(for: .milliseconds(150))
        #expect(truncated.isClosed == false)

        let fresh = try RawHTTPClient(port: server.port)
        defer { fresh.close() }
        #expect(try await handshake(fresh).isEmpty == false)
    }

    @Test func invalidContentLengthAndChunkErrorsDoNotDisturbOtherSessions() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let healthy = try RawHTTPClient(port: server.port)
        defer { healthy.close() }
        let healthySid = try await connect(healthy)

        let bad = try RawHTTPClient(port: server.port)
        let badSid = try await handshake(bad)
        // Chunk framing errors are rejected per connection; the session on the
        // other TCP connection must keep receiving ordered frames.
        bad.send(chunkedHeadBytes(query: pollingQuery(sid: badSid)) + Array("+2\r\n".utf8))
        let rejected = try await bad.nextResponse()
        #expect(rejected.status == 400)
        #expect(await bad.waitForClose())
        bad.close()

        // The first session continues to receive its ordered business frames.
        healthy.send(getRequestBytes(query: pollingQuery(sid: healthySid)))
        try await Task.sleep(for: .milliseconds(50))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: #"{"id":"healthy"}"#)
        let frame = try await healthy.nextResponse()
        #expect(frame.text.contains(#"42["message:new",{"id":"healthy"}]"#))
        #expect(server.hub.connectionCount == 1)
    }

    // MARK: - HTTP/1.1 response ordering

    @Test func pipelinedLongPollAndPostKeepResponseOrder() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let setup = try RawHTTPClient(port: server.port)
        let sid = try await handshake(setup)
        setup.close()

        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }
        let poll = getRequestBytes(query: pollingQuery(sid: sid))
        let body = Array(#"40{"token":"good","serverId":"s1"}"#.utf8)
        let post = contentLengthRequestBytes(
            method: "POST", query: pollingQuery(sid: sid), contentLength: "\(body.count)",
            body: body, connection: "keep-alive"
        )
        client.send(poll + post)

        let first = try await client.nextResponse()
        let second = try await client.nextResponse()
        #expect(first.status == 200)
        #expect(first.text.contains(#"40{"sid":""#))
        #expect(second.status == 200)
        #expect(second.text == "ok")
        // The connect payload is delivered exactly once, on the poll that was
        // written before the POST acknowledgement.
        #expect(first.text.components(separatedBy: "40{").count - 1 == 1)

        client.send(getRequestBytes(query: pollingQuery(sid: sid)))
        try await Task.sleep(for: .milliseconds(50))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: #"{"id":"pipeline"}"#)
        let frame = try await client.nextResponse()
        #expect(frame.text.contains(#"42["message:new",{"id":"pipeline"}]"#))
        #expect(frame.text.contains(#"40{"sid":""#) == false)
    }

    @Test func pipelinedPongPostWaitsBehindThePendingPingPoll() async throws {
        let heartbeat = RealtimeHeartbeatConfiguration(
            pingIntervalMilliseconds: 200, pingTimeoutMilliseconds: 2_000,
            applicationIntervalMilliseconds: 0
        )
        let server = try await RealtimeServer.start(auth: FramingAuth(), heartbeat: heartbeat)
        defer { Task { try? await server.close() } }
        let setup = try RawHTTPClient(port: server.port)
        let sid = try await connect(setup)
        setup.close()

        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }
        let poll = getRequestBytes(query: pollingQuery(sid: sid))
        let pong = Array("3".utf8)
        let post = contentLengthRequestBytes(
            method: "POST", query: pollingQuery(sid: sid), contentLength: "1",
            body: pong, connection: "keep-alive"
        )
        client.send(poll + post)

        // The POST itself enqueues nothing; only the heartbeat ping resolves
        // the poll. Its acknowledgement still follows the poll response.
        let first = try await client.nextResponse(timeout: 3)
        let second = try await client.nextResponse(timeout: 3)
        #expect(first.status == 200)
        #expect(first.text == "2")
        #expect(second.status == 200)
        #expect(second.text == "ok")
    }

    // MARK: - WebSocket upgrade residual bytes

    @Test func pipelinedCloseAcknowledgementWaitsForThePollThenCloses() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let setup = try RawHTTPClient(port: server.port)
        let sid = try await handshake(setup)
        setup.close()

        let client = try RawHTTPClient(port: server.port)
        defer { client.close() }
        let poll = getRequestBytes(query: pollingQuery(sid: sid))
        let body = Array(#"40{"token":"good","serverId":"s1"}"#.utf8)
        let post = contentLengthRequestBytes(
            method: "POST", query: pollingQuery(sid: sid), contentLength: "\(body.count)",
            body: body, connection: "close"
        )
        client.send(poll + post)

        let first = try await client.nextResponse()
        let second = try await client.nextResponse()
        #expect(first.status == 200)
        #expect(first.text.contains(#"40{"sid":""#))
        #expect(second.status == 200)
        #expect(second.text == "ok")
        #expect(await client.waitForClose())
    }

    @Test func websocketUpgradeKeepsPreloadedProbeFrame() async throws {
        let server = try await RealtimeServer.start(auth: FramingAuth())
        defer { Task { try? await server.close() } }
        let http = try RawHTTPClient(port: server.port)
        let sid = try await connect(http)
        http.close()

        let socket = try RawWebSocketClient(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))
        #expect(await socket.waitForText { $0 == "3probe" } != nil)

        socket.send("5")
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: #"{"id":"after-pipeline-upgrade"}"#)
        #expect(await socket.waitForText { $0.contains("after-pipeline-upgrade") } != nil)
        #expect(socket.textFrames.filter { $0.contains("after-pipeline-upgrade") }.count == 1)
        #expect(socket.textFrames.contains { $0.hasPrefix("0{") } == false)
        #expect(server.hub.connectionCount == 1)
    }

    // MARK: - Child-process fixture

    @Test func framingChildListener() async throws {
        guard ProcessInfo.processInfo.environment["ENGINEIO_FRAMING_CHILD"] == "1" else { return }
        let auth = FramingAuth()
        let server = try await RealtimeServer.start(auth: auth)
        let portFile = try #require(ProcessInfo.processInfo.environment["ENGINEIO_FRAMING_CHILD_PORT_FILE"])
        try String(server.port).write(toFile: portFile, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["ENGINEIO_FRAMING_CHILD_REVOKE"] == "1" {
            Task {
                try? await Task.sleep(for: .seconds(1))
                auth.revokeToken("good")
                server.hub.revokeSessionAccess(userId: "user-1", familyId: "fam-1")
            }
        }
        try await Task.sleep(for: .seconds(60))
        _ = server
    }
}

// MARK: - Auth fixture

private final class FramingAuth: RealtimeAuthorizing, Sendable {
    private let revoked = Mutex<Set<String>>([])

    func userId(forAccessToken token: String) -> String? {
        if revoked.withLock({ $0.contains(token) }) { return nil }
        return ["good": "user-1", "revoked": "user-2"][token]
    }

    func revokeToken(_ token: String) {
        revoked.withLock { _ = $0.insert(token) }
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
        #"{"messages":[],"currentSeq":3,"hasMore":false}"#
    }
}

// MARK: - Raw HTTP client

private struct RawHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: [UInt8]

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var text: String { String(decoding: body, as: UTF8.self) }
    var packets: [String] { text.split(separator: "\u{1e}", omittingEmptySubsequences: false).map(String.init) }

    var sid: String? {
        guard let open = packets.first(where: { $0.hasPrefix("0{") }),
              let data = String(open.dropFirst()).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["sid"] as? String
    }
}

private enum RawHTTPError: Error {
    case closed
    case incomplete
    case timeout
    case malformed
}

private final class RawHTTPClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: RawHTTPCollector
    private var pending: [UInt8] = []

    init(port: Int) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = RawHTTPCollector()
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

    var isClosed: Bool { collector.isClosed }

    func send(_ bytes: [UInt8]) {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    func nextResponse(timeout: TimeInterval = 3) async throws -> RawHTTPResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let response = parseNextResponse() { return response }
            let incoming = collector.take()
            if !incoming.isEmpty {
                pending.append(contentsOf: incoming)
                continue
            }
            if collector.isClosed {
                throw pending.isEmpty ? RawHTTPError.closed : RawHTTPError.incomplete
            }
            if Date() >= deadline { throw RawHTTPError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForClose(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.isClosed { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return collector.isClosed
    }

    func close() {
        channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }

    private func parseNextResponse() -> RawHTTPResponse? {
        guard let headEnd = findHeaderEnd(pending) else { return nil }
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
                guard let lineEnd = findCRLF(pending, from: offset) else { return nil }
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
        return RawHTTPResponse(status: status, headers: headers, body: body)
    }
}

private final class RawHTTPCollector: ChannelInboundHandler, @unchecked Sendable {
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

private func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
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

private func findCRLF(_ bytes: [UInt8], from: Int) -> Int? {
    guard bytes.count >= from + 2 else { return nil }
    var index = from
    while index + 1 < bytes.count {
        if bytes[index] == 13, bytes[index + 1] == 10 { return index }
        index += 1
    }
    return nil
}

// MARK: - Request builders

private func pollingQuery(sid: String) -> String {
    "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)"
}

private func requestHeadBytes(
    method: String, query: String, extraHeaders: [String] = [],
    connection: String = "keep-alive"
) -> [UInt8] {
    var lines = ["\(method) /socket.io/?\(query) HTTP/1.1", "Host: 127.0.0.1"]
    lines.append(contentsOf: extraHeaders)
    lines.append("Connection: \(connection)")
    return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
}

private func getRequestBytes(query: String) -> [UInt8] {
    requestHeadBytes(method: "GET", query: query)
}

private func contentLengthRequestBytes(
    method: String, query: String, contentLength: String, body: [UInt8],
    connection: String = "close"
) -> [UInt8] {
    var bytes = requestHeadBytes(
        method: method, query: query,
        extraHeaders: ["Content-Length: \(contentLength)"], connection: connection
    )
    bytes.append(contentsOf: body)
    return bytes
}

private func chunkedHeadBytes(query: String) -> [UInt8] {
    requestHeadBytes(
        method: "POST", query: query,
        extraHeaders: ["Transfer-Encoding: chunked"], connection: "close"
    )
}

private func chunkedRequestBytes(
    query: String, chunks: [[UInt8]], trailers: [(String, String)] = [],
    chunkExtension: String = ""
) -> [UInt8] {
    var bytes = requestHeadBytes(
        method: "POST", query: query,
        extraHeaders: ["Transfer-Encoding: chunked"], connection: "keep-alive"
    )
    for chunk in chunks {
        bytes.append(contentsOf: Array(String(chunk.count, radix: 16).utf8))
        bytes.append(contentsOf: Array(chunkExtension.utf8))
        bytes.append(contentsOf: Array("\r\n".utf8))
        bytes.append(contentsOf: chunk)
        bytes.append(contentsOf: Array("\r\n".utf8))
    }
    bytes.append(contentsOf: Array("0\r\n".utf8))
    for (name, value) in trailers {
        bytes.append(contentsOf: Array("\(name): \(value)\r\n".utf8))
    }
    bytes.append(contentsOf: Array("\r\n".utf8))
    return bytes
}

// MARK: - Shared request flows

private func handshake(_ client: RawHTTPClient) async throws -> String {
    client.send(getRequestBytes(query: "EIO=4&transport=polling&t=\(UUID().uuidString)"))
    let response = try await client.nextResponse()
    #expect(response.status == 200)
    return try #require(response.sid)
}

private func connect(_ client: RawHTTPClient) async throws -> String {
    let sid = try await handshake(client)
    let body = Array(#"40{"token":"good","serverId":"s1"}"#.utf8)
    client.send(contentLengthRequestBytes(
        method: "POST", query: pollingQuery(sid: sid),
        contentLength: "\(body.count)", body: body, connection: "keep-alive"
    ))
    let ack = try await client.nextResponse()
    #expect(ack.status == 200)
    client.send(getRequestBytes(query: pollingQuery(sid: sid)))
    let connected = try await client.nextResponse()
    #expect(connected.text.contains(#"40{"sid":""#))
    #expect(connected.text.contains(#"42["rooms:joined"]"#))
    return sid
}

private func oneShot(port: Int, bytes: [UInt8], timeout: TimeInterval = 4) async throws -> RawHTTPResponse {
    let client = try RawHTTPClient(port: port)
    defer { client.close() }
    client.send(bytes)
    return try await client.nextResponse(timeout: timeout)
}

// MARK: - Child process harness

private final class ChildServer {
    let process: Process
    let port: Int
    private let portFile: String

    init(process: Process, port: Int, portFile: String) {
        self.process = process
        self.port = port
        self.portFile = portFile
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: portFile)
    }
}

private func startChildServer() async throws -> ChildServer {
    let portFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("engineio-framing-child-\(UUID().uuidString).port").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--testing-library", "swift-testing", "--no-parallel",
        "--filter", "RealtimePollingFramingTests.framingChildListener",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["ENGINEIO_FRAMING_CHILD"] = "1"
    environment["ENGINEIO_FRAMING_CHILD_PORT_FILE"] = portFile
    process.environment = environment
    process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    try process.run()

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let text = try? String(contentsOfFile: portFile, encoding: .utf8),
           let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return ChildServer(process: process, port: port, portFile: portFile)
        }
        if !process.isRunning {
            throw RawHTTPError.closed
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning { process.terminate() }
    throw RawHTTPError.timeout
}

private func childHandshake(_ port: Int) async throws -> String {
    let client = try RawHTTPClient(port: port)
    defer { client.close() }
    return try await handshake(client)
}

// MARK: - Raw WebSocket upgrade

private final class RawWebSocketClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: UpgradeFrameCollector

    init(port: Int, sid: String) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = UpgradeFrameCollector()
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

        let request = [
            "GET /socket.io/?EIO=4&transport=websocket&sid=\(sid) HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        // The probe frame is part of the same TCP write as the upgrade head:
        // it must land in the WebSocket frame buffer, not the HTTP body.
        var bytes = Array(request.utf8)
        bytes.append(contentsOf: maskedClientTextFrame("2probe"))
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let written = channel.writeAndFlush(buffer)
        written.whenFailure { _ in }
    }

    var textFrames: [String] { collector.textFrames }

    func waitForStatus(_ expected: Int, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.status == expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return collector.status == expected
    }

    func send(_ text: String) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count + 8)
        buffer.writeBytes(maskedClientTextFrame(text))
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

    func close() {
        channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }
}

private final class UpgradeFrameCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private struct State {
        var http: [UInt8] = []
        var frames: [UInt8] = []
        var upgraded = false
        var textFrames: [String] = []
        var status = 0
    }
    private let state = Mutex(State())

    var status: Int { state.withLock { $0.status } }
    var textFrames: [String] { state.withLock { $0.textFrames } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        state.withLock { state in
            if state.upgraded {
                state.frames.append(contentsOf: bytes)
            } else {
                state.http.append(contentsOf: bytes)
                guard let end = findHeaderEnd(state.http) else { return }
                let head = String(decoding: state.http[..<end], as: UTF8.self)
                if let statusLine = head.components(separatedBy: "\r\n").first {
                    let parts = statusLine.split(separator: " ")
                    if parts.count >= 2 { state.status = Int(parts[1]) ?? 0 }
                }
                state.frames.append(contentsOf: state.http[(end + 4)...])
                state.http = []
                state.upgraded = true
            }
            while let frame = readFrame(&state.frames) {
                if frame.opcode == 0x1 {
                    state.textFrames.append(String(decoding: frame.payload, as: UTF8.self))
                }
            }
        }
    }
}

private struct RawWebSocketFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func readFrame(_ buffer: inout [UInt8]) -> RawWebSocketFrame? {
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
    return RawWebSocketFrame(opcode: opcode, payload: payload)
}

private func maskedClientTextFrame(_ text: String) -> [UInt8] {
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
