import Foundation
import Synchronization
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
    let short = RealtimeHeartbeatConfiguration(pingIntervalMilliseconds: 200, pingTimeoutMilliseconds: 150)
    #expect(engineIOOpenFrame(sid: "abc", heartbeat: short) == "0{\"sid\":\"abc\",\"upgrades\":[],\"pingInterval\":200,\"pingTimeout\":150,\"maxPayload\":1000000}")
    #expect(socketIOApplicationHeartbeatFrame(seq: 12, timestampMilliseconds: 1_700_000_000_123)
        == "42[\"heartbeat\",{\"seq\":12,\"ts\":1700000000123}]")
    #expect(RealtimeHeartbeatConfiguration.production.applicationIntervalMilliseconds == 15_000)
    #expect(socketIOConnectFrame(sid: "abc") == "40{\"sid\":\"abc\"}")
    #expect(socketIOEventFrame("rooms:joined") == "42[\"rooms:joined\"]")
    #expect(socketIOEventFrame("message:new", payloadJSON: "{\"id\":\"m1\"}") == "42[\"message:new\",{\"id\":\"m1\"}]")
    #expect(socketIOErrorFrame(socketNotServerMemberMessage) == "44{\"message\":\"Not a member of this server\"}")
}

/// Application-level socket.io `heartbeat`: every connection with a `serverId`
/// gets `42["heartbeat",{"seq":<getMaxSeq>,"ts":<Date.now()>}]` every
/// `HEARTBEAT_INTERVAL_MS` (15 seconds upstream). The sequence is the retained
/// server message max, not a transport counter: a message created after connect
/// advances it, and a message in another server does not.
@Test func applicationHeartbeatPublishesTheRetainedServerMessageSeq() async throws {
    let ledger = ApplicationHeartbeatLedger()
    let heartbeat = RealtimeHeartbeatConfiguration(
        pingIntervalMilliseconds: 60_000,
        pingTimeoutMilliseconds: 60_000,
        applicationIntervalMilliseconds: 100
    )
    let server = try await RealtimeServer.start(auth: ledger.auth, heartbeat: heartbeat)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"\(ledger.token)\",\"serverId\":\"\(ledger.serverId)\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    let empty = try #require(await client.waitForText({ $0.hasPrefix("42[\"heartbeat\",") }, timeout: 2))
    #expect(empty.hasPrefix("42[\"heartbeat\",{\"seq\":0,\"ts\":"))
    #expect(empty.hasSuffix("}]"))
    let emptyTimestamp = try #require(applicationHeartbeatTimestamp(empty))
    #expect(emptyTimestamp > Int(Date().timeIntervalSince1970 * 1000) - 60_000)
    #expect(emptyTimestamp <= Int(Date().timeIntervalSince1970 * 1000) + 60_000)

    ledger.appendMessage(channelId: ledger.channelId, content: "first")
    #expect(await client.waitForText({
        $0.hasPrefix("42[\"heartbeat\",{\"seq\":1,\"ts\":")
    }, timeout: 2) != nil)

    // A higher global sequence in a different server is not this server's max.
    ledger.appendMessage(channelId: ledger.otherChannelId, content: "other server")
    try? await Task.sleep(for: .milliseconds(350))
    let heartbeatSeqs = client.textFrames.compactMap(applicationHeartbeatSeq)
    #expect(heartbeatSeqs.contains(1))
    #expect(heartbeatSeqs.allSatisfy { $0 <= 1 })

    // Messages in the same server advance the published value again.
    let secondChannel = ledger.addChannel(serverId: ledger.serverId, name: "second")
    ledger.appendMessage(channelId: secondChannel, content: "second")
    #expect(await client.waitForText({
        $0.hasPrefix("42[\"heartbeat\",{\"seq\":3,\"ts\":")
    }, timeout: 2) != nil)
}

/// Upstream only creates the timer inside `if (serverId)`. A user-scoped socket
/// must receive no application heartbeat and must not even read the sequence.
@Test func applicationHeartbeatIsAbsentWithoutAServerId() async throws {
    let probe = MaxSeqProbe(seq: 9)
    let auth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]],
        maxSeq: probe
    )
    let heartbeat = RealtimeHeartbeatConfiguration(
        pingIntervalMilliseconds: 60_000,
        pingTimeoutMilliseconds: 60_000,
        applicationIntervalMilliseconds: 80
    )
    let server = try await RealtimeServer.start(auth: auth, heartbeat: heartbeat)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"good\",\"clientKind\":\"cli\"}")
    #expect(await client.waitForText { $0.hasPrefix("40") } != nil)

    try? await Task.sleep(for: .milliseconds(400))
    #expect(client.textFrames.contains { $0.hasPrefix("42[\"heartbeat\",") } == false)
    #expect(probe.readCount == 0)
}

/// `disconnect` clears the heartbeat interval. The Engine.IO ping-timeout close
/// is the same session close, so both paths must stop the application timer.
@Test func applicationHeartbeatStopsOnDisconnectAndOnEngineIOTimeout() async throws {
    let disconnectProbe = MaxSeqProbe(seq: 4)
    let disconnectAuth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]],
        maxSeq: disconnectProbe
    )
    let disconnectHeartbeat = RealtimeHeartbeatConfiguration(
        pingIntervalMilliseconds: 60_000,
        pingTimeoutMilliseconds: 60_000,
        applicationIntervalMilliseconds: 40
    )
    let disconnectServer = try await RealtimeServer.start(auth: disconnectAuth, heartbeat: disconnectHeartbeat)
    do {
        let client = try await RawSocketIOClient(port: disconnectServer.port)
        defer { client.close() }
        _ = await client.waitForText { $0.hasPrefix("0") }
        client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
        #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
        #expect(await client.waitForText({ $0.hasPrefix("42[\"heartbeat\",") }, timeout: 2) != nil)

        client.send("41")
        #expect(await client.waitForClose(timeout: 2))
        let readsAtClose = disconnectProbe.readCount
        try? await Task.sleep(for: .milliseconds(250))
        #expect(disconnectProbe.readCount == readsAtClose)
    } catch {
        try? await disconnectServer.close()
        throw error
    }
    try await disconnectServer.close()

    let timeoutProbe = MaxSeqProbe(seq: 5)
    let timeoutAuth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]],
        maxSeq: timeoutProbe
    )
    let timeoutHeartbeat = RealtimeHeartbeatConfiguration(
        pingIntervalMilliseconds: 50,
        pingTimeoutMilliseconds: 50,
        applicationIntervalMilliseconds: 40
    )
    let timeoutServer = try await RealtimeServer.start(auth: timeoutAuth, heartbeat: timeoutHeartbeat)
    do {
        let client = try await RawSocketIOClient(port: timeoutServer.port)
        defer { client.close() }
        _ = await client.waitForText { $0.hasPrefix("0") }
        client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
        #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
        #expect(await client.waitForPingCount(1, timeout: 2) >= 1)
        #expect(await client.waitForText({ $0.hasPrefix("42[\"heartbeat\",") }, timeout: 2) != nil)

        #expect(await client.waitForClose(timeout: 2))
        let readsAtClose = timeoutProbe.readCount
        try? await Task.sleep(for: .milliseconds(250))
        #expect(timeoutProbe.readCount == readsAtClose)
    } catch {
        try? await timeoutServer.close()
        throw error
    }
    try await timeoutServer.close()
}

/// Engine.IO v4 server-driven heartbeat: `2` every pingInterval, client answers
/// `3`. The pinned upstream is engine.io 6.6.11 (socket.io 4.8.3), which keeps
/// the defaults 25000/20000 that the open packet advertises.
@Test func engineIOV4ServerPingsAtTheConfiguredIntervalAndAdvertisesThoseValues() async throws {
    let auth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]]
    )
    let heartbeat = RealtimeHeartbeatConfiguration(pingIntervalMilliseconds: 200, pingTimeoutMilliseconds: 1_000)
    let server = try await RealtimeServer.start(auth: auth, heartbeat: heartbeat)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    let open = try #require(await client.waitForText { $0.hasPrefix("0") })
    #expect(open.contains("\"upgrades\":[]"))
    #expect(open.contains("\"pingInterval\":200,"))
    #expect(open.contains("\"pingTimeout\":1000,"))
    #expect(open.contains("\"maxPayload\":1000000"))
    #expect(open.contains("\"pingInterval\":25000") == false)

    client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
    #expect(await client.waitForPingCount(1, timeout: 1.5) >= 1, "protocol v4 server must send the first ping")
    #expect(await client.waitForClose(timeout: 0.2) == false)
}

@Test func engineIOV4ClientPongKeepsTheSocketAliveAcrossIntervals() async throws {
    let auth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]]
    )
    let heartbeat = RealtimeHeartbeatConfiguration(pingIntervalMilliseconds: 150, pingTimeoutMilliseconds: 750)
    let server = try await RealtimeServer.start(auth: auth, heartbeat: heartbeat)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    for expected in 1...3 {
        #expect(await client.waitForPingCount(expected, timeout: 1.5) >= expected)
        client.send("3")
    }
    server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"alive\"}")
    #expect(await client.waitForText { $0 == "42[\"message:new\",{\"id\":\"alive\"}]" } != nil)
    #expect(client.isClosed == false)
}

@Test func engineIOV4ServerClosesAClientThatNeverPongsAndCleansUpTheSession() async throws {
    let auth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]]
    )
    let heartbeat = RealtimeHeartbeatConfiguration(pingIntervalMilliseconds: 100, pingTimeoutMilliseconds: 100)
    let server = try await RealtimeServer.start(auth: auth, heartbeat: heartbeat)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
    #expect(await client.waitForPingCount(1, timeout: 1.5) >= 1)

    #expect(await client.waitForClose(timeout: 2))
    #expect(client.textFrames.contains("3") == false)

    let deadline = Date().addingTimeInterval(2)
    while server.hub.connectionCount > 0 && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.hub.connectionCount == 0)
    server.hub.emit(room: "user:user-1", event: "message:new", payloadJSON: "{\"id\":\"after-close\"}")
    try? await Task.sleep(for: .milliseconds(100))
    #expect(client.textFrames.contains { $0.contains("after-close") } == false)
}

/// engine.io 6.6.11 `onPacket` rejects a client `2` in protocol v4 with
/// "invalid heartbeat direction" and closes the transport ("transport error").
@Test func engineIOV4ClientPingIsAnInvalidHeartbeatDirectionAndClosesTheSocket() async throws {
    let auth = StubAuth(
        tokens: ["good": "user-1"],
        roles: ["s1\nuser-1": "member"],
        channels: ["s1\nuser-1": ["c1"]]
    )
    let heartbeat = RealtimeHeartbeatConfiguration(pingIntervalMilliseconds: 5_000, pingTimeoutMilliseconds: 5_000)
    let server = try await RealtimeServer.start(auth: auth, heartbeat: heartbeat)
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }

    _ = await client.waitForText { $0.hasPrefix("0") }
    client.send("40{\"token\":\"good\",\"serverId\":\"s1\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
    client.send("2")

    #expect(await client.waitForClose(timeout: 1))
    #expect(client.textFrames.contains("3") == false)

    let deadline = Date().addingTimeInterval(2)
    while server.hub.connectionCount > 0 && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.hub.connectionCount == 0)
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

@Test func credentialReadPublishesLivePresenceFramesWithDynamicThrottleAndRelay() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111643"
    let serverId = "33333333-3333-4333-8333-333333333668"
    accounts.addAccount(id: ownerId, email: "credential-wire@slock.test", password: "password123")
    accounts.oauth.addOwnedServer(id: serverId, slug: "credential-wire", name: "Credential Wire", ownerId: ownerId)
    let external = accounts.oauth.createAgent(serverId: serverId, name: "wire-external", runtime: "external")
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "wire-managed", runtime: "codex")
    let externalKey = accounts.mintAgentCredential(agentId: external, scopes: ["read"], name: "wire-external")
    let managedKey = accounts.mintAgentCredential(agentId: managed, scopes: ["read"], name: "wire-managed")
    let reads = accounts.reactionsRealtime
    let lifecycle = accounts.agentsLifecycle
    let relay = accounts.realtimeRelay
    accounts.setAgentCredentialUseThrottleMsForTesting(60_000)

    let server = try await RealtimeServer.start(auth: StubAuth(
        tokens: ["credential-viewer": ownerId],
        roles: ["\(serverId)\n\(ownerId)": "owner"],
        channels: [:]
    ))
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }
    #expect(await client.waitForText { $0.hasPrefix("0") } != nil)
    client.send("40{\"token\":\"credential-viewer\",\"serverId\":\"\(serverId)\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
    relay.install { room, event, payload in
        server.hub.emit(room: room, event: event, payloadJSON: payload)
    }

    _ = try reads.agentThirdPartyEvents(authorization: "Bearer \(externalKey)")
    let first = try #require(await client.waitForText { $0.hasPrefix("42[\"agent:seen\",") })
    #expect(first.contains("\"agentId\":\"\(external)\""))
    #expect(first.contains("\"lastSeenAt\":\""))
    _ = try lifecycle.agentApiIdentity(authorization: "Bearer \(externalKey)")
    _ = try reads.agentThirdPartyEvents(authorization: "Bearer \(managedKey)")
    #expect(await client.waitForText({ $0.hasPrefix("42[\"agent:seen\",") && $0 != first }, timeout: 0.15) == nil)
    #expect(client.textFrames.filter { $0.hasPrefix("42[\"agent:seen\",") }.count == 1)

    accounts.setAgentCredentialUseThrottleMsForTesting(0)
    relay.install(nil)
    _ = try reads.agentThirdPartyEvents(authorization: "Bearer \(externalKey)")
    #expect(await client.waitForText({ $0.hasPrefix("42[\"agent:seen\",") && $0 != first }, timeout: 0.15) == nil)
    relay.install { room, event, payload in
        server.hub.emit(room: room, event: event, payloadJSON: payload)
    }
    _ = try reads.agentThirdPartyEvents(authorization: "Bearer \(externalKey)")
    let second = try #require(await client.waitForText { $0.hasPrefix("42[\"agent:seen\",") && $0 != first })
    #expect(second.contains("\"agentId\":\"\(external)\""))
    #expect(client.textFrames.filter { $0.hasPrefix("42[\"agent:seen\",") }.count == 2)

    accounts.revokeAgentCredentialForTesting(apiKey: externalKey)
    _ = try reads.agentThirdPartyEvents(authorization: "Bearer \(externalKey)")
    #expect(await client.waitForText({ $0.hasPrefix("42[\"agent:seen\",") && $0 != first && $0 != second }, timeout: 0.15) == nil)
}

@Test func constructedServerMembersServiceReadsTheLiveRelayForRoleFrames() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111648"
    let memberId = "11111111-1111-4111-8111-111111111649"
    let serverId = "33333333-3333-4333-8333-333333333672"
    for (id, email) in [(ownerId, "channel-wire-owner@slock.test"), (memberId, "channel-wire-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-wire", name: "Channel Wire", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let members = accounts.serverMembersAndSidebar
    let server = try await RealtimeServer.start(auth: StubAuth(
        tokens: [token: ownerId], roles: ["\(serverId)\n\(ownerId)": "owner"], channels: [:]
    ))
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }
    #expect(await client.waitForText { $0.hasPrefix("0") } != nil)
    client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)
    let relay = accounts.realtimeRelay
    relay.install { server.hub.emit(room: $0, event: $1, payloadJSON: $2) }
    _ = try members.patchServerMemberRole(authorization: "Bearer \(token)", serverId: serverId,
        memberId: memberId, body: ServerMemberRolePatchRequest(role: "admin"))
    let promoted = try #require(await client.waitForText { $0.hasPrefix("42[\"server:member-updated\",") })
    #expect(promoted.contains("\"role\":\"admin\""))
    #expect(promoted.contains(memberId))
    relay.install(nil)
    _ = try members.patchServerMemberRole(authorization: "Bearer \(token)", serverId: serverId,
        memberId: memberId, body: ServerMemberRolePatchRequest(role: "member"))
    #expect(await client.waitForText({ $0.hasPrefix("42[\"server:member-updated\",") && $0 != promoted }, timeout: 0.15) == nil)
    relay.install { server.hub.emit(room: $0, event: $1, payloadJSON: $2) }
    _ = try members.patchServerMemberRole(authorization: "Bearer \(token)", serverId: serverId,
        memberId: memberId, body: ServerMemberRolePatchRequest(role: "owner"))
    #expect(await client.waitForText { $0.hasPrefix("42[\"server:member-updated\",") && $0.contains("\"role\":\"owner\"") } != nil)
}

@Test func relayCanUninstallItselfWhileDeliveringMessagesOverTheSocket() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111642"
    let serverId = "33333333-3333-4333-8333-333333333667"
    accounts.addAccount(id: ownerId, email: "relay-socket@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "relay-socket", name: "Relay Socket", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "relay-socket", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "relay-socket")
    let token = try accounts.authIdentities.login(LoginRequest(email: "relay-socket@slock.test", password: "password123")).accessToken
    let server = try await RealtimeServer.start(auth: StubAuth(
        tokens: [token: ownerId],
        roles: ["\(serverId)\n\(ownerId)": "member"],
        channels: ["\(serverId)\n\(ownerId)": [channelId]]
    ))
    defer { Task { try? await server.close() } }
    let client = try await RawSocketIOClient(port: server.port)
    defer { client.close() }
    #expect(await client.waitForText { $0.hasPrefix("0") } != nil)
    client.send("40{\"token\":\"\(token)\",\"serverId\":\"\(serverId)\"}")
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    let relay = accounts.realtimeRelay
    let create = accounts.humanMessageCreate
    relay.install { room, event, payload in
        relay.install(nil)
        server.hub.emit(room: room, event: event, payloadJSON: payload)
    }
    let first = try create.createHumanMessage(
        HumanMessageCreateRequest(channelId: channelId, content: "first relay delivery"),
        authorization: "Bearer \(token)", serverId: serverId
    )
    #expect(first.messageJSON.contains("first relay delivery"))
    let frame = try #require(await client.waitForText { $0.contains("first relay delivery") })
    #expect(frame.hasPrefix("42[\"message:new\","))
    #expect(frame.contains("\"channelId\":\"\(channelId)\""))

    let second = try create.createHumanMessage(
        HumanMessageCreateRequest(channelId: channelId, content: "uninstalled relay delivery"),
        authorization: "Bearer \(token)", serverId: serverId
    )
    #expect(second.messageJSON.contains("uninstalled relay delivery"))
    #expect(await client.waitForText({ $0.contains("uninstalled relay delivery") }, timeout: 0.2) == nil)

    relay.install { room, event, payload in
        server.hub.emit(room: room, event: event, payloadJSON: payload)
    }
    _ = try create.createHumanMessage(
        HumanMessageCreateRequest(channelId: channelId, content: "reinstalled relay delivery"),
        authorization: "Bearer \(token)", serverId: serverId
    )
    #expect(await client.waitForText { $0.contains("reinstalled relay delivery") } != nil)
    #expect(client.textFrames.contains { $0.contains("uninstalled relay delivery") } == false)
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
    let token = try accounts.authIdentities.login(LoginRequest(email: "realtime-send@slock.test", password: "password123")).accessToken

    let box = RealtimeEventBox()
    accounts.realtimeRelay.install { room, event, payload in
        box.append(room: room, event: event, payload: payload)
    }
    let created = try accounts.humanMessageCreate.createHumanMessage(
        HumanMessageCreateRequest(channelId: channel, content: "hello over the wire"),
        authorization: "Bearer \(token)",
        serverId: serverId
    )
    #expect(created.messageJSON.contains("\"content\":\"hello over the wire\""))
    let event = try #require(box.events.first { $0.event == "message:new" })
    #expect(event.room == "channel:\(channel)")
    #expect(event.payload?.contains("\"content\":\"hello over the wire\"") == true)
    #expect(event.payload?.contains("\"channelId\":\"\(channel)\"") == true)
    // The frame is the canonical message manifest body, not the reduced
    // id/channelId/content/attachments projection:
    // seq/createdAt/sender facts must be present for the Web to order and
    // reconcile the row without a reload.
    let payload = try #require(event.payload)
    let decoded = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    #expect(decoded["seq"] is Int)
    #expect((decoded["seq"] as? Int ?? 0) > 0)
    #expect(decoded["senderType"] as? String == "user")
    #expect(decoded["senderId"] as? String == ownerId)
    #expect(decoded["senderName"] as? String == "realtime-send")
    #expect(decoded["messageType"] as? String == "chat")
    #expect(decoded["senderMembershipStatus"] as? String == "active")
    #expect(decoded["threadId"] is NSNull)
    #expect(decoded["randomId"] is NSNull)
    #expect(decoded["actionMetadata"] is NSNull)
    #expect((decoded["reactions"] as? [Any])?.isEmpty == true)
    #expect(decoded["commentRef"] is NSNull)
    #expect(decoded["externalAuthor"] is NSNull)
    #expect((decoded["attachments"] as? [Any])?.isEmpty == true)
    #expect((decoded["mentions"] as? [Any])?.isEmpty == true)
    let createdAt = try #require(decoded["createdAt"] as? String)
    #expect(createdAt.hasSuffix("Z"))
    #expect(createdAt.contains("."))
    #expect(decoded["updatedAt"] as? String == createdAt)
    #expect((decoded["conversationContext"] as? [String: Any])?["channelType"] as? String == "channel")
    #expect(decoded["senderTimezone"] == nil)
    #expect(decoded["searchText"] == nil)
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
    let token = try accounts.authIdentities.login(LoginRequest(email: "realtime-reaction@slock.test", password: "password123")).accessToken

    let box = RealtimeEventBox()
    accounts.realtimeRelay.install { room, event, payload in
        box.append(room: room, event: event, payload: payload)
    }
    let reply = try accounts.profileAndChannelFiles.addMessageReaction(
        messageId: messageId,
        emoji: "👍",
        authorization: "Bearer \(token)",
        serverId: serverId
    )
    #expect(reply.reactions.first?.emoji == "👍")
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

@Test func realtimeStateConcurrentEmitsKeepMembershipRemovalAsTheFinalFrame() async throws {
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
    #expect(await client.waitForText { $0 == "42[\"rooms:joined\"]" } != nil)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<256 {
            group.addTask {
                if index == 128 || index == 129 {
                    server.hub.removeServerMembership(serverId: "s1", userId: "user-1")
                } else if index.isMultiple(of: 3) {
                    client.send("3")
                } else {
                    server.hub.emit(room: "channel:c1", event: "message:new", payloadJSON: "{\"id\":\"race-\(index)\"}")
                }
            }
        }
    }
    #expect(await client.waitForClose())
    let notice = "42[\"server:membership-removed\",{\"serverId\":\"s1\"}]"
    #expect(client.textFrames.filter { $0 == notice }.count == 1)
    #expect(client.textFrames.last == notice)
    let deadline = Date().addingTimeInterval(3)
    while server.hub.connectionCount > 0 && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.hub.connectionCount == 0)
}

@Test func realtimeStateBusySocketYieldsForAnotherSocketsHandshakePingAndClose() async throws {
    let auth = StubAuth(
        tokens: ["hot": "hot-user", "cold": "cold-user"],
        roles: ["s1\nhot-user": "member"],
        channels: ["s1\nhot-user": ["hot"]]
    )
    let server = try await RealtimeServer.start(auth: auth)
    defer { Task { try? await server.close() } }
    let hot = try await RawSocketIOClient(port: server.port)
    defer { hot.close() }
    _ = await hot.waitForText { $0.hasPrefix("0") }
    hot.send("40{\"token\":\"hot\",\"serverId\":\"s1\"}")
    _ = try #require(await hot.waitForText { $0 == "42[\"rooms:joined\"]" })

    let finished = Mutex(0)
    let producerDeadline = ContinuousClock.now.advanced(by: .seconds(4))
    let payload = "{\"content\":\"" + String(repeating: "x", count: 128) + "\"}"
    let producers = (0..<4).map { _ in
        Task.detached {
            var emitted = 0
            // Bound time and volume as well as honoring explicit cancellation,
            // so the regression cannot leave a busy loop running after failure.
            while !Task.isCancelled && ContinuousClock.now < producerDeadline && emitted < 50_000 {
                server.hub.emit(room: "channel:hot", event: "load", payloadJSON: payload)
                emitted += 1
                if emitted.isMultiple(of: 64) { await Task.yield() }
            }
            finished.withLock { $0 += 1 }
            return emitted
        }
    }
    defer { for producer in producers { producer.cancel() } }
    _ = try #require(await hot.waitForText({ $0.hasPrefix("42[\"load\",") }, timeout: 1))

    let cold = try await RawSocketIOClient(port: server.port)
    defer { cold.close() }
    let open = await cold.waitForText({ $0.hasPrefix("0") }, timeout: 0.5)
    cold.send("40{\"token\":\"cold\"}")
    let connected = await cold.waitForText({ $0.hasPrefix("40") }, timeout: 0.5)
    // Engine.IO v4 heartbeat reply direction (client pong). The close below
    // proves the busy loop still processes this socket's protocol traffic.
    cold.send("3")
    cold.send("41")
    let closed = await cold.waitForClose(timeout: 0.5)
    let finishedBeforeClose = finished.withLock { $0 }
    for producer in producers { producer.cancel() }
    var emitted = 0
    for producer in producers { emitted += await producer.value }

    #expect(open != nil, "a busy session must yield to another socket's upgrade")
    #expect(connected != nil, "another socket must authenticate while producers run")
    #expect(closed, "another socket must close while producers run")
    #expect(finishedBeforeClose < producers.count, "producer traffic must still be active through the close")
    #expect(emitted > 0)
}

@Test func realtimeStateQueuedFramesRetainOrderBeforeMembershipRemoval() async throws {
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
    _ = try #require(await client.waitForText { $0 == "42[\"rooms:joined\"]" })

    for index in 0..<193 {
        server.hub.emit(room: "channel:c1", event: "ordered", payloadJSON: "{\"index\":\(index)}")
    }
    server.hub.removeServerMembership(serverId: "s1", userId: "user-1")
    #expect(await client.waitForClose())
    let expected = (0..<193).map { "42[\"ordered\",{\"index\":\($0)}]" }
    #expect(client.textFrames.filter { $0.hasPrefix("42[\"ordered\",") } == expected)
    #expect(client.textFrames.last == "42[\"server:membership-removed\",{\"serverId\":\"s1\"}]")
}

}
private struct LedgerBackedSocketAuth: RealtimeAuthorizing {
    let core: AuthCoreService
    let membership: SocketMembershipService

    func userId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
    func maxMessageSeq(serverId: String) -> Int? { membership.maxMessageSeq(serverId: serverId) }
}

/// Real in-memory message rows over the production `SocketMembershipService`,
/// so the published heartbeat sequence is the same retained fact that
/// `sync:resume` would replay instead of a transport fixture answer.
private struct ApplicationHeartbeatLedger: Sendable {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let serverId: String
    let otherServerId: String
    let channelId: String
    let otherChannelId: String
    let token: String

    init() {
        let accounts = EmailLoginDirectory()
        let ownerId = UUID().uuidString.lowercased()
        let serverId = UUID().uuidString.lowercased()
        let otherServerId = UUID().uuidString.lowercased()
        accounts.addAccount(id: ownerId, email: "heartbeat-\(ownerId)@slock.test", password: "heartbeat-password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "heartbeat-\(serverId.prefix(8))", name: "Heartbeat", ownerId: ownerId)
        accounts.oauth.addOwnedServer(id: otherServerId, slug: "heartbeat-other-\(otherServerId.prefix(8))", name: "Other", ownerId: ownerId)
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: "general", creatorUserId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "general")
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        let otherChannelId = accounts.oauth.createChannel(serverId: otherServerId, name: "general", creatorUserId: ownerId)
        accounts.addPostableChannel(serverId: otherServerId, channelId: otherChannelId, memberId: ownerId, name: "general")
        accounts.oauth.addChannelHuman(channelId: otherChannelId, userId: ownerId)
        self.accounts = accounts
        self.ownerId = ownerId
        self.serverId = serverId
        self.otherServerId = otherServerId
        self.channelId = channelId
        self.otherChannelId = otherChannelId
        self.token = accounts.mintAccessTokenForTesting(userId: ownerId)
    }

    var auth: LedgerBackedSocketAuth {
        LedgerBackedSocketAuth(core: accounts.authCore, membership: accounts.socketMembership)
    }

    func addChannel(serverId: String, name: String) -> String {
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: name)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        return channelId
    }

    func appendMessage(channelId: String, content: String) {
        accounts.insertHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: ownerId,
            content: content
        )
    }
}

private func applicationHeartbeatPayload(_ frame: String) -> [String: Any]? {
    guard frame.hasPrefix("42[\"heartbeat\","),
          let data = String(frame.dropFirst(2)).data(using: .utf8),
          let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
          array.count == 2,
          let payload = array[1] as? [String: Any]
    else { return nil }
    return payload
}

private func applicationHeartbeatSeq(_ frame: String) -> Int? {
    (applicationHeartbeatPayload(frame)?["seq"] as? NSNumber)?.intValue
}

private func applicationHeartbeatTimestamp(_ frame: String) -> Int? {
    (applicationHeartbeatPayload(frame)?["ts"] as? NSNumber)?.intValue
}

private final class MaxSeqProbe: Sendable {
    private let state: Mutex<(seq: Int, reads: Int)>

    init(seq: Int) {
        self.state = Mutex((seq, 0))
    }

    var readCount: Int { state.withLock { $0.reads } }

    func next() -> Int {
        state.withLock { current in
            current.reads += 1
            return current.seq
        }
    }
}

private struct StubAuth: RealtimeAuthorizing {
    var tokens: [String: String]
    var roles: [String: String]
    var channels: [String: [String]]
    var families: [String: String] = [:]
    var maxSeq: MaxSeqProbe? = nil

    func userId(forAccessToken token: String) -> String? { tokens[token] }
    func sessionFamilyId(forAccessToken token: String) -> String? { families[token] }
    func serverRole(serverId: String, userId: String) -> String? { roles["\(serverId)\n\(userId)"] }
    func visibleChannelIds(serverId: String, userId: String) -> [String] { channels["\(serverId)\n\(userId)"] ?? [] }
    func maxMessageSeq(serverId: String) -> Int? { maxSeq?.next() }
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
    var isClosed: Bool { collector.closed }

    func pingCount() -> Int { collector.textFrames.filter { $0 == "2" }.count }

    func waitForPingCount(_ count: Int, timeout: TimeInterval = 3) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let seen = pingCount()
            if seen >= count { return seen }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return pingCount()
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
