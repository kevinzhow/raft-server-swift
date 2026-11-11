import Foundation
import Synchronization
import NIOCore
import NIOPosix
import RaftRealtime
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Real HTTP polling against the SwiftNIO listener, using the same auth
/// provider and hub fanout as the WebSocket transport. No private bypass: the
/// Socket.IO connect packet runs the production `RealtimeAuthorizing` reads.
@Suite(.serialized)
struct RealtimePollingTests {
    // MARK: - Inventory: handshake, auth, business frames, ack, CORS

    @Test func pollingHandshakeAuthBusinessFrameAndAck() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth, corsOrigins: ["http://allowed.example", "http://other.example"])
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)

        let handshake = try await http.get("EIO=4&transport=polling&t=1", origin: "http://allowed.example")
        #expect(handshake.status == 200)
        #expect(handshake.header("content-type") == "text/plain; charset=UTF-8")
        #expect(handshake.header("cache-control") == "no-store")
        #expect(handshake.header("access-control-allow-origin") == "http://allowed.example")
        #expect(handshake.header("access-control-allow-credentials") == "true")
        #expect(handshake.header("vary") == "Origin")
        let open = try #require(handshake.packet(from: "0"))
        #expect(open.contains("\"upgrades\":[\"websocket\"]"))
        #expect(open.contains("\"pingInterval\":25000"))
        #expect(open.contains("\"pingTimeout\":20000"))
        #expect(open.contains("\"maxPayload\":1000000"))
        let sid = try #require(handshake.sid)

        let singleServer = try await RealtimeServer.start(auth: auth, corsOrigins: ["http://only.example"])
        defer { Task { try? await singleServer.close() } }
        let single = try await PollingHTTP(port: singleServer.port)
            .get("EIO=4&transport=polling&t=2", origin: "http://evil.example")
        #expect(single.header("access-control-allow-origin") == "http://only.example")
        #expect(single.header("vary") == "Origin")

        let badOrigin = try await http.get("EIO=4&transport=polling&t=2", origin: "http://evil.example")
        #expect(badOrigin.header("access-control-allow-origin") == nil)
        #expect(badOrigin.header("access-control-allow-credentials") == "true")
        #expect(badOrigin.header("vary") == "Origin")

        let preflight = try await http.request(
            method: "OPTIONS", query: "EIO=4&transport=polling",
            origin: "http://allowed.example", extraHeaders: [
                "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "x-test",
            ]
        )
        #expect(preflight.status == 204)
        #expect(preflight.header("access-control-allow-origin") == "http://allowed.example")
        #expect(preflight.header("access-control-allow-methods") == "GET,HEAD,PUT,PATCH,POST,DELETE")
        #expect(preflight.header("access-control-allow-headers") == "x-test")
        #expect(preflight.header("content-length") == "0")

        let post = try await http.post(sid: sid, packets: ["40{\"token\":\"good\",\"serverId\":\"s1\",\"clientKind\":\"web\"}"])
        #expect(post.status == 200)
        #expect(post.body == "ok")
        #expect(post.header("content-type") == "text/html")
        #expect(post.header("cache-control") == "no-store")

        let connected = try await readPackets(http, sid: sid, until: { packets in
            packets.contains { $0.hasPrefix("40{") } && packets.contains("42[\"rooms:joined\"]")
        })
        let connectPacket = try #require(connected.first { $0.hasPrefix("40{") })
        #expect(connectPacket.contains("\"sid\":\""))
        #expect(connected.contains("42[\"rooms:joined\"]"))

        let pending = Task { try await http.get(sid: sid, timeout: 5) }
        try await Task.sleep(for: .milliseconds(400))
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"m1\"}")
        let frameResponse = try await pending.value
        #expect(frameResponse.status == 200)
        #expect(frameResponse.packets.contains("42[\"message:new\",{\"id\":\"m1\"}]"))

        // The business event itself is accepted over the polling POST body and
        // acknowledged with the engine.io `ok`, exactly like the WS frame path.
        let event = try await http.post(sid: sid, packets: ["42[\"join:channel\",\"c1\"]"])
        #expect(event.status == 200)
        #expect(event.body == "ok")
        #expect(server.hub.connectionCount == 1)
    }

    @Test func userScopedPollingConnectionKeepsTheSameUserRoomScope() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth)
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)
        let handshake = try await http.get("EIO=4&transport=polling&t=1")
        let sid = try #require(handshake.sid)
        _ = try await http.post(sid: sid, packets: ["40{\"token\":\"good\",\"clientKind\":\"cli\"}"])
        let connected = try await readPackets(http, sid: sid, until: { $0.contains { $0.hasPrefix("40{") } })
        #expect(connected.contains { $0.hasPrefix("40{") })
        #expect(connected.contains("42[\"rooms:joined\"]") == false)

        let pending = Task { try await http.get(sid: sid, timeout: 5) }
        try await Task.sleep(for: .milliseconds(400))
        server.hub.emit(room: "user:user-1", event: "notification:push", payloadJSON: "{\"id\":\"n1\"}")
        let frame = try await pending.value
        #expect(frame.packets.contains("42[\"notification:push\",{\"id\":\"n1\"}]"))
        let serverRoom = Task { try await http.get(sid: sid, timeout: 1) }
        try await Task.sleep(for: .milliseconds(150))
        server.hub.emit(room: "server:s1", event: "message:new", payloadJSON: "{\"id\":\"other\"}")
        let missed = try? await serverRoom.value
        #expect(missed == nil)
    }

    @Test func pollingEventDecoderHandlesSyncAndDesktopAttention() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth)
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)
        let handshake = try await http.get("EIO=4&transport=polling&t=1")
        let sid = try #require(handshake.sid)
        _ = try await http.post(
            sid: sid,
            packets: ["40{\"token\":\"good\",\"serverId\":\"s1\",\"clientKind\":\"desktop\"}"]
        )
        _ = try await readPackets(http, sid: sid, until: { packets in
            packets.contains { $0.hasPrefix("40{") } && packets.contains("42[\"rooms:joined\"]")
        })

        _ = try await http.post(sid: sid, packets: ["42[\"desktop:attention\",{\"attended\":true}]"])
        let attendedDeadline = Date().addingTimeInterval(2)
        while Date() < attendedDeadline,
              !server.desktopAttention.usersWithRecentDesktopAttention(["user-1"]).contains("user-1") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.desktopAttention.usersWithRecentDesktopAttention(["user-1"]).contains("user-1"))

        _ = try await http.post(sid: sid, packets: ["42[\"sync:resume\",{\"lastSeq\":2}]"])
        let resume = try await readPackets(http, sid: sid, until: { packets in
            packets.contains { $0.hasPrefix("42[\"sync:resume:response\"") }
        })
        #expect(resume.contains("42[\"sync:resume:response\",{\"messages\":[],\"currentSeq\":3,\"hasMore\":false}]"))
    }

    @Test func pollingHeartbeatTracksPongsAndTimesOut() async throws {
        let auth = PollingAuth()
        let heartbeat = RealtimeHeartbeatConfiguration(
            pingIntervalMilliseconds: 80, pingTimeoutMilliseconds: 120,
            applicationIntervalMilliseconds: 0
        )
        let server = try await RealtimeServer.start(auth: auth, heartbeat: heartbeat)
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)
        let sid = try await connect(http)

        for _ in 0..<3 {
            let ping = try await readPackets(http, sid: sid, until: { $0.contains("2") }, timeout: 2)
            #expect(ping.contains("2"))
            let pong = try await http.post(sid: sid, packets: ["3"])
            #expect(pong.status == 200)
        }

        // Stop answering: the next poll receives the close packet, and the
        // session disappears from the hub without leaking a timer task.
        let ping = try await readPackets(http, sid: sid, until: { $0.contains("2") }, timeout: 2)
        #expect(ping.contains("2"))
        let close = try await readPackets(http, sid: sid, until: { $0.contains("1") }, timeout: 2)
        #expect(close.contains("1"))
        let deadline = Date().addingTimeInterval(2)
        while server.hub.connectionCount > 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.hub.connectionCount == 0)
        let expired = try await http.get(sid: sid)
        #expect(expired.status == 400)
        #expect(expired.body == "{\"code\":1,\"message\":\"Session ID unknown\"}")
    }

    @Test func concurrentPollIsRejectedAndClosesTheSession() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth)
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)
        let sid = try await connect(http)

        let first = Task { try await http.get(sid: sid, timeout: 5) }
        try await Task.sleep(for: .milliseconds(500))
        let overlap = try await http.get(sid: sid, timeout: 2)
        #expect(overlap.status == 400)
        #expect(overlap.body.isEmpty)
        let firstResult = try await first.value
        #expect(firstResult.status == 200)
        #expect(firstResult.body == "1")
        let deadline = Date().addingTimeInterval(2)
        while server.hub.connectionCount > 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.hub.connectionCount == 0)
        let expired = try await http.get(sid: sid)
        #expect(expired.status == 400)
        #expect(expired.body.contains("\"code\":1"))
    }

    @Test func pollingErrorsMatchTheEngineIOResponses() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth, corsOrigins: ["http://allowed.example"])
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)

        let unknown = try await http.get("EIO=4&transport=bogus&t=1", origin: "http://allowed.example")
        #expect(unknown.status == 400)
        #expect(unknown.header("content-type") == "application/json")
        #expect(unknown.header("access-control-allow-origin") == "http://allowed.example")
        #expect(unknown.body == "{\"code\":0,\"message\":\"Transport unknown\"}")

        let eio3 = try await http.get("EIO=3&transport=polling&t=1")
        #expect(eio3.status == 400)
        #expect(eio3.body == "{\"code\":5,\"message\":\"Unsupported protocol version\"}")

        let missingSid = try await http.post(query: "EIO=4&transport=polling&t=1", packets: ["40{}"])
        #expect(missingSid.status == 400)
        #expect(missingSid.body == "{\"code\":2,\"message\":\"Bad handshake method\"}")

        let unknownSid = try await http.get(sid: "nope")
        #expect(unknownSid.status == 400)
        #expect(unknownSid.body == "{\"code\":1,\"message\":\"Session ID unknown\"}")

        let handshake = try await http.get("EIO=4&transport=polling&t=2")
        let sid = try #require(handshake.sid)
        let mismatch = try await http.get(sid: sid, transport: "websocket")
        #expect(mismatch.status == 400)
        #expect(mismatch.body == "{\"code\":3,\"message\":\"Bad request\"}")

        let protocolMismatch = try await http.get("EIO=3&transport=polling&sid=\(sid)")
        #expect(protocolMismatch.status == 400)
        #expect(protocolMismatch.body == "{\"code\":3,\"message\":\"Bad request\"}")

        let oversized = try await http.post(
            sid: sid, body: Data(repeating: UInt8(ascii: "a"), count: 1_000_001),
            origin: "http://allowed.example"
        )
        #expect(oversized.status == 413)
        #expect(oversized.body.isEmpty)
        #expect(oversized.header("access-control-allow-origin") == "http://allowed.example")
        // engine.io verifies transport and sid before reading the body.
        let oversizedUnknownSid = try await http.post(
            sid: "nope", body: Data(repeating: UInt8(ascii: "a"), count: 1_000_001)
        )
        #expect(oversizedUnknownSid.status == 400)
        #expect(oversizedUnknownSid.body == "{\"code\":1,\"message\":\"Session ID unknown\"}")
        let oversizedHandshake = try await http.post(
            query: "EIO=4&transport=polling", body: Data(repeating: UInt8(ascii: "a"), count: 1_000_001)
        )
        #expect(oversizedHandshake.status == 400)
        #expect(oversizedHandshake.body == "{\"code\":2,\"message\":\"Bad handshake method\"}")

        let secondHandshake = try await http.get("EIO=4&transport=polling&t=3")
        let secondSid = try #require(secondHandshake.sid)
        let binary = try await http.post(
            sid: secondSid, body: Data([0x34, 0x30]), contentType: "application/octet-stream"
        )
        #expect(binary.status == 400)
        #expect(binary.body.isEmpty)
        let closed = try await http.get(sid: secondSid)
        #expect(closed.status == 400)
        #expect(closed.body.contains("\"code\":1"))
    }

    @Test func authFailureAndRevocationAreVisibleOnPolling() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth)
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)

        let handshake = try await http.get("EIO=4&transport=polling&t=1")
        let sid = try #require(handshake.sid)
        _ = try await http.post(sid: sid, packets: ["40{\"token\":\"bad\",\"serverId\":\"s1\"}"])
        let error = try await readPackets(http, sid: sid, until: { $0.contains { $0.hasPrefix("44") } })
        #expect(error.contains("44{\"message\":\"Invalid or expired token\"}"))

        let goodHandshake = try await http.get("EIO=4&transport=polling&t=2")
        let goodSid = try #require(goodHandshake.sid)
        _ = try await http.post(sid: goodSid, packets: ["40{\"token\":\"good\",\"serverId\":\"s1\"}"])
        _ = try await readPackets(http, sid: goodSid, until: { packets in
            packets.contains { $0.hasPrefix("40{") } && packets.contains("42[\"rooms:joined\"]")
        })
        let pending = Task { try await http.get(sid: goodSid, timeout: 5) }
        try await Task.sleep(for: .milliseconds(400))
        server.hub.revokeSessionAccess(userId: "user-1", familyId: "fam-1")
        let closed = try await pending.value
        #expect(closed.status == 200)
        #expect(closed.body == "1")
        let deadline = Date().addingTimeInterval(2)
        while server.hub.connectionCount > 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.hub.connectionCount == 0)

        auth.revokeToken("good")
        let revokedHandshake = try await http.get("EIO=4&transport=polling&t=3")
        let revokedSid = try #require(revokedHandshake.sid)
        _ = try await http.post(sid: revokedSid, packets: ["40{\"token\":\"good\",\"serverId\":\"s1\"}"])
        let revoked = try await readPackets(http, sid: revokedSid, until: { $0.contains { $0.hasPrefix("44") } })
        #expect(revoked.contains("44{\"message\":\"Invalid or expired token\"}"))
    }

    // MARK: - Polling to WebSocket upgrade

    @Test func pollingUpgradesToWebSocketOnTheSameAuthenticatedSession() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth)
        defer { Task { try? await server.close() } }
        let http = PollingHTTP(port: server.port)
        let sid = try await connect(http)

        let oldPoll = Task { try await http.get(sid: sid, timeout: 5) }
        try await Task.sleep(for: .milliseconds(400))

        let socket = try await RawUpgradeClient(port: server.port, sid: sid)
        defer { socket.close() }
        #expect(await socket.waitForStatus(101))
        socket.send("2probe")
        #expect(await socket.waitForText { $0 == "3probe" } != nil)

        let oldPollResult = try await oldPoll.value
        #expect(oldPollResult.status == 200)
        #expect(oldPollResult.body == "6")

        // A frame emitted while the transport is still switching must be
        // delivered once, after the upgrade, not to the closed-old poll twice.
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"before-upgrade\"}")
        socket.send("5")
        #expect(await socket.waitForText { $0.contains("before-upgrade") } != nil)

        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"after-upgrade\"}")
        #expect(await socket.waitForText { $0.contains("after-upgrade") } != nil)

        socket.send("421[\"join:channel\",\"c1\"]")
        server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"over-ws\"}")
        #expect(await socket.waitForText { $0.contains("over-ws") } != nil)
        #expect(server.hub.connectionCount == 1)
        #expect(socket.textFrames.contains { $0.contains("before-upgrade") })
        #expect(socket.textFrames.filter { $0.contains("before-upgrade") }.count == 1)
        #expect(socket.textFrames.contains { $0.hasPrefix("0{") } == false)

        socket.send("41")
        #expect(await socket.waitForClose(timeout: 2))
    }

    @Test func serverCloseDrainsPollingSessionsAndStopsAccepting() async throws {
        let auth = PollingAuth()
        let server = try await RealtimeServer.start(auth: auth)
        let port = server.port
        let http = PollingHTTP(port: port)
        let sid = try await connect(http)
        let pending = Task { try await http.get(sid: sid, timeout: 5) }
        try await Task.sleep(for: .milliseconds(300))
        try await server.close()
        // A pending poll is released with the engine.io close packet or the
        // connection is closed by shutdown; neither path may leave a session.
        _ = try? await pending.value
        #expect(server.hub.connectionCount == 0)
        await #expect(throws: (any Error).self) {
            _ = try await http.get(sid: sid, timeout: 1)
        }
    }
}

// MARK: - Helpers

private final class PollingAuth: RealtimeAuthorizing, Sendable {
    private let revoked = Mutex<Set<String>>([])

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

    func revokeToken(_ token: String) {
        revoked.withLock { $0.insert(token) }
    }
}

private struct PollingHTTPResponse {
    var status: Int
    var body: String
    private var headers: [String: String]

    init(status: Int, body: String, headers: [String: String]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var packets: [String] {
        body.split(separator: "\u{1e}", omittingEmptySubsequences: false).map(String.init)
    }

    func packet(from prefix: Character) -> String? {
        packets.first { $0.first == prefix }
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

private final class PollingHTTP: Sendable {
    let port: Int
    private let session: URLSession

    init(port: Int) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func get(_ query: String, origin: String? = nil, timeout: TimeInterval = 10) async throws -> PollingHTTPResponse {
        try await request(method: "GET", query: query, origin: origin, timeout: timeout)
    }

    func get(sid: String, transport: String = "polling", timeout: TimeInterval = 10) async throws -> PollingHTTPResponse {
        try await get("EIO=4&transport=\(transport)&sid=\(sid)&t=\(UUID().uuidString)", timeout: timeout)
    }

    func post(
        sid: String, packets: [String], origin: String? = nil,
        contentType: String = "text/plain;charset=UTF-8"
    ) async throws -> PollingHTTPResponse {
        let body = Data(packets.joined(separator: "\u{1e}").utf8)
        return try await post(
            query: "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)",
            body: body, contentType: contentType, origin: origin
        )
    }

    func post(
        sid: String, body: Data, origin: String? = nil,
        contentType: String = "text/plain;charset=UTF-8"
    ) async throws -> PollingHTTPResponse {
        try await post(
            query: "EIO=4&transport=polling&sid=\(sid)&t=\(UUID().uuidString)",
            body: body, contentType: contentType, origin: origin
        )
    }

    func post(
        query: String, packets: [String], origin: String? = nil,
        contentType: String = "text/plain;charset=UTF-8"
    ) async throws -> PollingHTTPResponse {
        let body = Data(packets.joined(separator: "\u{1e}").utf8)
        return try await post(query: query, body: body, contentType: contentType, origin: origin)
    }

    func post(
        query: String, body: Data, contentType: String = "text/plain;charset=UTF-8",
        origin: String? = nil
    ) async throws -> PollingHTTPResponse {
        try await request(
            method: "POST", query: query, body: body, contentType: contentType,
            origin: origin, timeout: 10
        )
    }

    func request(
        method: String, query: String, body: Data? = nil, contentType: String? = nil,
        origin: String? = nil, timeout: TimeInterval = 10, extraHeaders: [String: String] = [:]
    ) async throws -> PollingHTTPResponse {
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
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (name, value) in httpResponse.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return PollingHTTPResponse(
            status: httpResponse.statusCode,
            body: String(decoding: data, as: UTF8.self),
            headers: headers
        )
    }
}

private func connect(_ http: PollingHTTP, token: String = "good", serverId: String = "s1") async throws -> String {
    let handshake = try await http.get("EIO=4&transport=polling&t=\(UUID().uuidString)")
    let sid = try #require(handshake.sid)
    _ = try await http.post(sid: sid, packets: ["40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}"])
    _ = try await readPackets(http, sid: sid, until: { packets in
        packets.contains { $0.hasPrefix("40{") } && packets.contains("42[\"rooms:joined\"]")
    })
    return sid
}

private func readPackets(
    _ http: PollingHTTP, sid: String,
    until predicate: ([String]) -> Bool, timeout: TimeInterval = 3
) async throws -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    var collected: [String] = []
    while Date() < deadline {
        let response = try await http.get(sid: sid, timeout: max(0.2, deadline.timeIntervalSinceNow))
        collected.append(contentsOf: response.packets.filter { !$0.isEmpty })
        if predicate(collected) { return collected }
    }
    return collected
}

private final class RawUpgradeClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: UpgradeCollector

    init(port: Int, sid: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = UpgradeCollector()
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

    var statusCode: Int { collector.statusCode }
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

private final class UpgradeCollector: ChannelInboundHandler, @unchecked Sendable {
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
            let separator: [UInt8] = [13, 10, 13, 10]
            if let end = find(separator, in: http) {
                let head = String(decoding: http[..<end], as: UTF8.self)
                if let statusLine = head.split(separator: "\r\n").first {
                    let parts = statusLine.split(separator: " ")
                    if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
                }
                frames.append(contentsOf: http[(end + 4)...])
                http = []
                upgraded = true
            }
        }
        while let frame = readUpgradeFrame(&frames) {
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

    private func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for index in 0...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle { return index }
        }
        return nil
    }
}

private struct UpgradeFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func readUpgradeFrame(_ buffer: inout [UInt8]) -> UpgradeFrame? {
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
    return UpgradeFrame(opcode: opcode, payload: payload)
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
