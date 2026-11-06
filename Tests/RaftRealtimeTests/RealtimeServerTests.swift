import Foundation
import NIOCore
import NIOPosix
import RaftHTTP
import Testing
@testable import RaftRealtime
import TestSupport

@Suite(.serialized)
struct RealtimeTransportTests {
@Test func handshakeParserMatchesTheUpstreamShapes() throws {
    let web = parseSocketHandshakeAuth(Data("{\"token\":\"tok\",\"serverId\":\"srv\"}".utf8))
    #expect(try web.get() == SocketHandshakeAuth(token: "tok", serverId: "srv", clientKind: .web))

    let mobile = parseSocketHandshakeAuth(Data("{\"token\":\"tok\",\"serverId\":\"srv\",\"clientKind\":\"mobile\"}".utf8))
    #expect(try mobile.get() == SocketHandshakeAuth(token: "tok", serverId: "srv", clientKind: .mobile))

    let userOnly = parseSocketHandshakeAuth(Data("{\"token\":\"tok\",\"clientKind\":\"cli\"}".utf8))
    #expect(try userOnly.get() == SocketHandshakeAuth(token: "tok", serverId: nil, clientKind: .cli))

    #expect(parseSocketHandshakeAuth(Data("[]".utf8)) == .failure(.authNotObject))
    #expect(parseSocketHandshakeAuth(Data("{}".utf8)) == .failure(.tokenMissing))
    #expect(parseSocketHandshakeAuth(Data("{\"token\":\"tok\",\"serverId\":\"\"}".utf8)) == .failure(.serverIdInvalid))
    #expect(parseSocketHandshakeAuth(Data("{\"token\":\"tok\",\"clientKind\":\"tv\"}".utf8)) == .failure(.clientKindInvalid))
}

@Test func protocolFramesUseTheSocketIOShapes() {
    #expect(engineIOOpenFrame(sid: "abc") == "0{\"sid\":\"abc\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000,\"maxPayload\":1000000}")
    #expect(socketIOConnectFrame(sid: "abc") == "40{\"sid\":\"abc\"}")
    #expect(socketIOEventFrame("rooms:joined") == "42[\"rooms:joined\"]")
    #expect(socketIOEventFrame("message:new", payloadJSON: "{\"id\":\"m1\"}") == "42[\"message:new\",{\"id\":\"m1\"}]")
    #expect(socketIOErrorFrame(socketNotServerMemberMessage) == "44{\"message\":\"Not a member of this server\"}")
}

@Test func authAndRoomsAndEventsRoundTrip() async throws {
    let auth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    let open = try #require(await client.waitForText { $0.hasPrefix("0") })
    #expect(open.contains("\"upgrades\":[]"))
    #expect(open.contains("\"pingInterval\":25000"))
    #expect(open.contains("\"pingTimeout\":20000"))
    #expect(open.contains("\"maxPayload\":1000000"))

    client.send("40{\"token\":\"good\",\"serverId\":\"s1\",\"clientKind\":\"web\"}")
    let connected = try #require(await client.waitForText { $0.hasPrefix("40") })
    #expect(connected.hasPrefix("40{\"sid\":"))
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    client.send("2")
    #expect(await client.waitForText { $0 == "3" } != nil)

    server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"m1\"}")
    #expect(await client.waitForText { $0 == "42[\"message:new\",{\"id\":\"m1\"}]" } != nil)

    server.hub.emitScopeReadUpdated(serverId: "s1", scopeId: "c1", agentId: "a1", maxReadSeq: 7)
    #expect(await client.waitForText {
        $0 == "42[\"scope_read:updated\",{\"scopeId\":\"c1\",\"peerKind\":\"agent\",\"peerId\":\"a1\",\"maxReadSeq\":7}]"
    } != nil)

    client.send("41")
    #expect(await client.waitForClose())
}

@Test func nonMemberGetsTheSharedConnectError() async throws {
    let auth = StubAuth(tokens: ["good": "user-1"], roles: [:], channels: [:])
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
    let error = try #require(await client.waitForText { $0.hasPrefix("44") })
    #expect(error == "44{\"message\":\"Not a member of this server\"}")
}

@Test func guestsStayOutOfTheServerRoomAndJoinTheirOwn() async throws {
    let auth = StubAuth(
        tokens: ["guest": "user-2"],
        roles: ["s1\nuser-2": "guest"],
        channels: ["s1\nuser-2": ["c1"]]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"guest\",\"serverId\":\"s1\"}")
    _ = await client.waitForText { $0.hasPrefix("40") }
    _ = await client.waitForText { $0 == "42[\"rooms:joined\"]" }

    server.hub.emit(room: "server:s1", event: "channel:updated", payloadJSON: "{\"hidden\":true}")
    server.hub.emit(room: "server:s1:guests", event: "channel:updated", payloadJSON: "{\"hidden\":false}")
    #expect(await client.waitForText { $0.contains("\"hidden\":false") } != nil)
    #expect(client.textFrames.contains { $0.contains("\"hidden\":true") } == false)
}

@Test func joinChannelOnlyAddsVisibleChannelsAndStaysSilentOnFailure() async throws {
    let auth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
    _ = await client.waitForText { $0.hasPrefix("40") }
    _ = await client.waitForText { $0 == "42[\"rooms:joined\"]" }

    client.send("42[\"join:channel\",\"c2\"]")
    server.hub.emit(room: "channel:c2", event: "message:new", payloadJSON: "{\"hidden\":true}")
    server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"visible\":true}")
    #expect(await client.waitForText { $0.contains("\"visible\":true") } != nil)
    #expect(client.textFrames.contains { $0.contains("\"hidden\":true") } == false)
    #expect(client.textFrames.contains { $0 == "42[\"join:channel\"]" } == false)
}

@Test func familyRevocationClosesOnlyThatSessionFamily() async throws {
    let auth = StubAuth(
        tokens: ["family-a": "user-1", "family-b": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]],
        families: ["family-a": "fam-a", "family-b": "fam-b"]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let first = try await RawSocketIOClient(port: server.port)
    defer { first.close() }
    let second = try await RawSocketIOClient(port: server.port)
    defer { second.close() }

    for (client, token) in [(first, "family-a"), (second, "family-b")] {
        _ = await client.waitForText { $0.hasPrefix("0") }
        client.send("40{\"token\":\"\(token)\",\"serverId\":\"s1\"}")
        _ = await client.waitForText { $0.hasPrefix("40") }
        _ = await client.waitForText { $0 == "42[\"rooms:joined\"]" }
    }

    server.hub.revokeFamily(userId: "user-1", familyId: "fam-a")
    #expect(await first.waitForClose())
    #expect(await second.waitForClose(timeout: 0.2) == false)
    server.hub.emit(room: "user:user-1", event: "message:new", payloadJSON: "{\"id\":\"m-survivor\"}")
    #expect(await second.waitForText { $0.contains("m-survivor") } != nil)
}

@Test func membershipRemovalSendsTheNoticeLastAndOnlyToThatServer() async throws {
    let auth = StubAuth(
        tokens: ["removed": "user-1", "other": "user-2"],
        roles: [
            "s1\nuser-1": "member",
            "s2\nuser-1": "member",
            "s1\nuser-2": "member",
        ],
        channels: [
            "s1\nuser-1": ["c1"],
            "s2\nuser-1": ["c2"],
            "s1\nuser-2": ["c1"],
        ]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let removedS1 = try await RawSocketIOClient(port: server.port)
    defer { removedS1.close() }
    let removedS2 = try await RawSocketIOClient(port: server.port)
    defer { removedS2.close() }
    let otherS1 = try await RawSocketIOClient(port: server.port)
    defer { otherS1.close() }

    for (client, token, serverId) in [
        (removedS1, "removed", "s1"),
        (removedS2, "removed", "s2"),
        (otherS1, "other", "s1"),
    ] {
        _ = await client.waitForText { $0.hasPrefix("0") }
        client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
        _ = await client.waitForText { $0.hasPrefix("40") }
        _ = await client.waitForText { $0 == "42[\"rooms:joined\"]" }
    }

    server.hub.removeServerMembership(serverId: "s1", userId: "user-1")
    #expect(await removedS1.waitForClose())
    #expect(removedS1.textFrames.last == "42[\"server:membership-removed\",{\"serverId\":\"s1\"}]")
    #expect(await removedS2.waitForClose(timeout: 0.2) == false)
    #expect(await otherS1.waitForClose(timeout: 0.2) == false)

    server.hub.emit(room: "server:s1", event: "message:new", payloadJSON: "{\"id\":\"m-other\"}")
    #expect(await otherS1.waitForText { $0.contains("m-other") } != nil)
}

@Test func roomNamesAndChannelAccessMatchTheSocketContract() {
    #expect(requiresSocketChannelAccessCheck("channel"))
    #expect(requiresSocketChannelAccessCheck("thread"))
    #expect(requiresSocketChannelAccessCheck("dm"))
    #expect(socketClientKindRoom(userId: "u1", clientKind: .mobile) == "user:u1:clientKind:mobile")
    #expect(socketUserServerRoom(userId: "u1", serverId: "s1") == "user:u1:server:s1")
    #expect(socketServerGuestsRoom(serverId: "s1") == "server:s1:guests")
    #expect(socketServerAllRooms(serverId: "s1") == ["server:s1", "server:s1:guests"])
}

@Test func notificationPushIsScopedToMobileWhileOtherEventsReachEveryClientKind() async throws {
    let auth = StubAuth(
        tokens: ["web": "user-1", "mobile": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let web = try await RawSocketIOClient(port: server.port)
    defer { web.close() }
    let mobile = try await RawSocketIOClient(port: server.port)
    defer { mobile.close() }

    for (client, kind) in [(web, "web"), (mobile, "mobile")] {
        _ = await client.waitForText { $0.hasPrefix("0") }
        client.send("40{\"token\":\"\(kind)\",\"serverId\":\"s1\",\"clientKind\":\"\(kind)\"}")
        _ = await client.waitForText { $0.hasPrefix("40") }
        _ = await client.waitForText { $0 == "42[\"rooms:joined\"]" }
    }

    emitPlatformScopedUserEvent(hub: server.hub, userId: "user-1", event: "notification:push", payloadJSON: "{\"id\":\"n1\"}")
    emitPlatformScopedUserEvent(hub: server.hub, userId: "user-1", event: "message:new", payloadJSON: "{\"id\":\"m1\"}")
    #expect(await mobile.waitForText { $0.contains("\"notification:push\"") } != nil)
    #expect(await mobile.waitForText { $0.contains("\"message:new\"") } != nil)
    #expect(await web.waitForText { $0.contains("\"message:new\"") } != nil)
    #expect(web.textFrames.contains { $0.contains("\"notification:push\"") } == false)
}

@Test func humanMessageSendEmitsMessageNewOnTheChannelRoom() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111626"
    let serverId = "33333333-3333-4333-8333-333333333670"
    accounts.addAccount(id: ownerId, email: "realtime-send@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "realtime-send", name: "Realtime Send", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "realtime-send", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "realtime-send")
    let login = accounts.login(body: "{\"email\":\"realtime-send@slock.test\",\"password\":\"password123\"}")
    let token = (try JSONSerialization.jsonObject(with: Data(login.body.utf8)) as? [String: Any])?["accessToken"] as? String ?? ""

    let box = RealtimeEventBox()
    accounts.realtimeEmitter = { room, event, payload in
        box.append(room: room, event: event, payload: payload)
    }
    let reply = accounts.createHumanMessage(
        body: "{\"channelId\":\"\(channel)\",\"content\":\"hello over the wire\"}",
        authorization: "Bearer \(token)",
        serverId: serverId
    )
    #expect(reply.status == 200)
    let event = try #require(box.events.first { $0.event == "message:new" })
    #expect(event.room == "channel:\(channel)")
    #expect(event.payload?.contains("\"content\":\"hello over the wire\"") == true)
    #expect(event.payload?.contains("\"channelId\":\"\(channel)\"") == true)
}

@Test func reactionMutationEmitsMessageUpdatedOnTheChannelRoom() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111627"
    let serverId = "33333333-3333-4333-8333-333333333671"
    accounts.addAccount(id: ownerId, email: "realtime-reaction@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "realtime-reaction", name: "Realtime Reaction", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "realtime-reaction", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "realtime-reaction")
    let messageId = accounts.addHumanMessageForTesting(channelId: channel, senderId: ownerId, content: "react to me")
    let login = accounts.login(body: "{\"email\":\"realtime-reaction@slock.test\",\"password\":\"password123\"}")
    let token = (try JSONSerialization.jsonObject(with: Data(login.body.utf8)) as? [String: Any])?["accessToken"] as? String ?? ""

    let box = RealtimeEventBox()
    accounts.realtimeEmitter = { room, event, payload in
        box.append(room: room, event: event, payload: payload)
    }
    let reply = accounts.addMessageReaction(
        messageId: messageId,
        body: "{\"emoji\":\"👍\"}",
        authorization: "Bearer \(token)",
        serverId: serverId
    )
    #expect(reply.status == 200)
    let event = try #require(box.events.first { $0.event == "message:updated" })
    #expect(event.room == "channel:\(channel)")
    let payload = try JSONSerialization.jsonObject(with: Data((event.payload ?? "").utf8)) as? [String: Any]
    #expect(payload?["id"] as? String == messageId)
    #expect(payload?["channelId"] as? String == channel)
    #expect(payload?["content"] as? String == "react to me")
    #expect(payload?["commentRef"] is NSNull)
    #expect(payload?["agentSendKey"] == nil)
    #expect(payload?["searchText"] == nil)
    #expect(payload?["searchVector"] == nil)
    #expect(payload?["reactionViewer"] == nil)
    #expect(payload?["viewerVersion"] == nil)
    #expect(payload?["reactedEmojis"] == nil)
    let reactions = payload?["reactions"] as? [[String: Any]] ?? []
    #expect(reactions.first?["emoji"] as? String == "👍")
}


@Test func aDesktopSocketAttentionReportMarksOnlyItsOwnUser() async throws {
    let auth = StubAuth(
        tokens: ["owner-token": "owner-1", "browser-token": "follower-1"],
        roles: ["s1\nowner-1": "member", "s1\nfollower-1": "member"],
        channels: [:]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    server.desktopAttention.resetForTests()

    let browser = try await RawSocketIOClient(port: server.port)
    defer { browser.close() }
    _ = await browser.waitForText { $0.hasPrefix("0") }
    browser.send("40{\"token\":\"browser-token\",\"serverId\":\"s1\",\"clientKind\":\"web\"}")
    #expect(await browser.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    let desktop = try await RawSocketIOClient(port: server.port)
    defer { desktop.close() }
    _ = await desktop.waitForText { $0.hasPrefix("0") }
    desktop.send("40{\"token\":\"owner-token\",\"serverId\":\"s1\",\"clientKind\":\"desktop\"}")
    #expect(await desktop.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    browser.send("42[\"desktop:attention\",{\"attended\":true}]")
    desktop.send("42[\"desktop:attention\",{\"attended\":true}]")

    var attended: Set<String> = []
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        attended = server.desktopAttention.usersWithRecentDesktopAttention(["owner-1", "follower-1"])
        if !attended.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(attended == ["owner-1"])

    // The browser report had the same time to land; it must still be absent.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(server.desktopAttention.usersWithRecentDesktopAttention(["follower-1"]).isEmpty)
}

@Test func aDesktopSocketAwayReportClearsItsUserOverARealConnection() async throws {
    let auth = StubAuth(
        tokens: ["owner-token": "owner-1"],
        roles: ["s1\nowner-1": "member"],
        channels: [:]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    server.desktopAttention.resetForTests()

    let desktop = try await RawSocketIOClient(port: server.port)
    defer { desktop.close() }
    _ = await desktop.waitForText { $0.hasPrefix("0") }
    desktop.send("40{\"token\":\"owner-token\",\"serverId\":\"s1\",\"clientKind\":\"desktop\"}")
    #expect(await desktop.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    desktop.send("42[\"desktop:attention\",{\"attended\":true}]")
    var seen: Set<String> = []
    let attendDeadline = Date().addingTimeInterval(2)
    while Date() < attendDeadline {
        seen = server.desktopAttention.usersWithRecentDesktopAttention(["owner-1"])
        if !seen.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(seen == ["owner-1"])

    desktop.send("42[\"desktop:attention\",{\"attended\":false}]")
    let clearDeadline = Date().addingTimeInterval(2)
    while Date() < clearDeadline {
        seen = server.desktopAttention.usersWithRecentDesktopAttention(["owner-1"])
        if seen.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(seen.isEmpty)
}

}
private struct StubAuth: RealtimeAuthorizing {
    var tokens: [String: String]
    var roles: [String: String]
    var channels: [String: [String]]
    var families: [String: String] = [:]

    func userId(forAccessToken token: String) -> String? { tokens[token] }
    func sessionFamilyId(forAccessToken token: String) -> String? { families[token] }
    func serverRole(serverId: String, userId: String) -> String? { roles["\(serverId)\n\(userId)"] }
    func visibleChannelIds(serverId: String, userId: String) -> [String] { channels["\(serverId)\n\(userId)"] ?? [] }
}

private final class RawSocketIOClient: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let collector: SocketIOCollector

    init(port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = SocketIOCollector()
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

    var textFrames: [String] { collector.textFrames }

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

private final class SocketIOCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var http: [UInt8] = []
    private var frames: [UInt8] = []
    private var upgraded = false
    private var collected: [String] = []
    private var isClosed = false

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
                frames.append(contentsOf: http[(end + 4)...])
                http = []
                upgraded = true
            }
        }
        while let frame = readServerFrame(&frames) {
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

private struct ServerFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func readServerFrame(_ buffer: inout [UInt8]) -> ServerFrame? {
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
    return ServerFrame(opcode: opcode, payload: payload)
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

private struct RealtimeEvent {
    var room: String
    var event: String
    var payload: String?
}

private final class RealtimeEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RealtimeEvent] = []

    func append(room: String, event: String, payload: String?) {
        lock.lock()
        storage.append(RealtimeEvent(room: room, event: event, payload: payload))
        lock.unlock()
    }

    var events: [RealtimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
