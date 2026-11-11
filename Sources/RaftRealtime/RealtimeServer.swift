import Foundation
import Synchronization
import NIOCore
import NIOPosix
import RaftConnectAuth
import RaftShared

public struct RealtimeSessionIdentity: Sendable, Equatable {
    public let userId: String
    public let familyId: String?
    public init(userId: String, familyId: String?) {
        self.userId = userId
        self.familyId = familyId
    }
}

public protocol RealtimeAuthorizing: Sendable {
    func sessionIdentity(forAccessToken token: String) -> RealtimeSessionIdentity?
    func userId(forAccessToken token: String) -> String?
    func sessionFamilyId(forAccessToken token: String) -> String?
    func serverRole(serverId: String, userId: String) -> String?
    func visibleChannelIds(serverId: String, userId: String) -> [String]
    /// `sync:resume` catch-up body (`{messages,currentSeq,hasMore}`), or nil
    /// when the viewer cannot read the server.
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String?
    /// Upstream `messageService.getMaxSeq(serverId)`: the highest retained
    /// message sequence for the server, published by the application
    /// `heartbeat`. It is a read of the same message rows `sync:resume`
    /// replays, not a second counter. nil keeps the heartbeat quiet when a
    /// provider does not expose that fact.
    func maxMessageSeq(serverId: String) -> Int?
}

public extension RealtimeAuthorizing {
    /// Compatibility for existing transport fixtures. Actual ledger/production
    /// adapters override this requirement with one atomic principal read.
    func sessionIdentity(forAccessToken token: String) -> RealtimeSessionIdentity? {
        guard let userId = userId(forAccessToken: token) else { return nil }
        return RealtimeSessionIdentity(userId: userId, familyId: sessionFamilyId(forAccessToken: token))
    }

    /// Providers that do not implement reconnect replay keep the socket quiet
    /// instead of failing the event handler.
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        nil
    }

    /// Transport fixtures without retained message rows stay quiet rather than
    /// publishing an invented sequence.
    func maxMessageSeq(serverId: String) -> Int? {
        nil
    }
}

public final class RealtimeHub: Sendable {
    private let sessions = Mutex<[ObjectIdentifier: SocketIOSession]>([:])

    public init() {}

    public var connectionCount: Int { sessions.withLock { $0.count } }

    private func snapshot() -> [SocketIOSession] {
        sessions.withLock { Array($0.values) }
    }

    public func emit(room: String, event: String, payloadJSON: String? = nil) {
        DeferredEffects.emit { [self] in
            // Session locks and channel callbacks never run under the hub mutex.
            let targets = snapshot().filter { $0.hasRoom(room) }
            let frame = socketIOEventFrame(event, payloadJSON: payloadJSON)
            for session in targets { session.send(frame) }
        }
    }

    func register(_ session: SocketIOSession) {
        sessions.withLock { $0[ObjectIdentifier(session)] = session }
    }

    func unregister(_ session: SocketIOSession) {
        _ = sessions.withLock { $0.removeValue(forKey: ObjectIdentifier(session)) }
    }

    /// Close every socket that belongs to one user session family.
    public func revokeFamily(userId: String, familyId: String) {
        revokeFamilies(userId: userId, familyIds: [familyId])
    }

    /// Revoke exactly the committed families, including legacy sockets without
    /// a family even when the persisted credential had no family metadata.
    /// A new authenticated family is not in this revocation snapshot.
    public func revokeFamilies(userId: String, familyIds: [String]) {
        let revoked = Set(familyIds)
        DeferredEffects.emit { [self] in
            let targets = snapshot().filter { session in
                guard session.userId == userId else { return false }
                guard let family = session.familyId else { return true }
                return revoked.contains(family)
            }
            for session in targets { session.close() }
        }
    }

    /// Node user-scope eviction: every family and server, including legacy
    /// familyless sessions. Used by account retirement and role writers.
    public func revokeUserAccess(userId: String) {
        DeferredEffects.emit { [self] in
            for session in snapshot() where session.userId == userId { session.close() }
        }
    }

    /// Logout's exact family scope differs from the legacy push-family close
    /// rule above: unrelated families and familyless sockets stay connected.
    public func revokeSessionAccess(userId: String, familyId: String) {
        DeferredEffects.emit { [self] in
            for session in snapshot() where session.userId == userId && session.familyId == familyId { session.close() }
        }
    }

    /// Channel creation and membership grants add the room to every live
    /// session of that user so later channel-room events are delivered.
    public func joinUserSessions(userId: String, room: String) {
        DeferredEffects.emit { [self] in
            let targets = snapshot().filter { $0.userId == userId }
            for session in targets { session.join([room]) }
        }
    }

    /// The server-scoped join used by send-time `socketsJoin`
    /// (`socketUserServerRoom(userId, serverId)`): only sessions attached to
    /// the same server receive the room, never the user's other-server tabs.
    public func joinUserSessions(userId: String, serverId: String, room: String) {
        DeferredEffects.emit { [self] in
            let targets = snapshot().filter { $0.userId == userId && $0.serverId == serverId }
            for session in targets { session.join([room]) }
        }
    }

    /// `server:membership-removed` is the last packet before the close, and
    /// only connections attached to that server are affected.
    public func removeServerMembership(serverId: String, userId: String) {
        DeferredEffects.emit { [self] in
            let targets = snapshot().filter { $0.serverId == serverId && $0.userId == userId }
            let payload = "{\"serverId\":\(quotedJSON(serverId))}"
            let frame = socketIOEventFrame("server:membership-removed", payloadJSON: payload)
            for session in targets { session.sendAndClose(frame) }
        }
    }

    /// Drop one user's subscriptions to the given rooms (a channel plus its
    /// child thread rooms) after a membership change. Only sockets attached to
    /// the same server are touched.
    public func leaveUserRooms(userId: String, serverId: String?, rooms: [String]) {
        guard !rooms.isEmpty else { return }
        DeferredEffects.emit { [self] in
            let targets = snapshot().filter { session in
                session.userId == userId && (serverId == nil || session.serverId == serverId)
            }
            for session in targets { session.leave(rooms) }
        }
    }

    /// One shared `channel:<id>` frame with the agent's new watermark.
    public func emitScopeReadUpdated(serverId: String, scopeId: String, agentId: String, maxReadSeq: Int) {
        let payload = "{\"scopeId\":\(quotedJSON(scopeId)),\"peerKind\":\"agent\",\"peerId\":\(quotedJSON(agentId)),\"maxReadSeq\":\(maxReadSeq)}"
        emit(room: "channel:\(scopeId)", event: "scope_read:updated", payloadJSON: payload)
    }
}

final class EngineIOSessionRegistry: Sendable {
    private let sessions = Mutex<[String: EngineIOSession]>([:])

    func insert(_ session: EngineIOSession) {
        sessions.withLock { $0[session.id] = session }
    }

    func session(id: String) -> EngineIOSession? {
        sessions.withLock { $0[id] }
    }

    func remove(id: String) {
        _ = sessions.withLock { $0.removeValue(forKey: id) }
    }

    func closeAll() {
        let all = sessions.withLock { state -> [EngineIOSession] in
            let all = Array(state.values)
            state.removeAll()
            return all
        }
        for session in all { session.close() }
    }
}

public final class RealtimeServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    public let hub: RealtimeHub
    public let desktopAttention: DesktopAttentionRegistry
    public let port: Int
    private let registry: EngineIOSessionRegistry
    private let cors: EngineIOCORS
    private let heartbeat: RealtimeHeartbeatConfiguration

    private init(
        group: MultiThreadedEventLoopGroup,
        channel: any Channel,
        port: Int,
        hub: RealtimeHub,
        desktopAttention: DesktopAttentionRegistry,
        registry: EngineIOSessionRegistry,
        cors: EngineIOCORS,
        heartbeat: RealtimeHeartbeatConfiguration
    ) {
        self.group = group
        self.channel = channel
        self.port = port
        self.hub = hub
        self.desktopAttention = desktopAttention
        self.registry = registry
        self.cors = cors
        self.heartbeat = heartbeat
    }

    public static func start(
        auth: any RealtimeAuthorizing,
        host: String = "127.0.0.1",
        port: Int = 0,
        hub: RealtimeHub = RealtimeHub(),
        heartbeat: RealtimeHeartbeatConfiguration = .production,
        corsOrigins: [String] = []
    ) async throws -> RealtimeServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let desktopAttention = DesktopAttentionRegistry()
        let registry = EngineIOSessionRegistry()
        let cors = EngineIOCORS(origins: corsOrigins)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // ServerBootstrap invokes this initializer on the child loop.
                // The SDK bound value checks that ownership across the Sendable
                // submit closure; synchronous installation never transfers the
                // non-Sendable handler to another executor or channel.
                let handler = NIOLoopBound(
                    RealtimeConnectionHandler(
                        auth: auth, hub: hub, desktopAttention: desktopAttention,
                        heartbeat: heartbeat, registry: registry, cors: cors
                    ),
                    eventLoop: channel.eventLoop
                )
                return channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(handler.value)
                }
            }
        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            guard let boundPort = channel.localAddress?.port else {
                try await channel.close()
                try await group.shutdownGracefully()
                throw RealtimeServerError.missingPort
            }
            return RealtimeServer(
                group: group, channel: channel, port: boundPort, hub: hub,
                desktopAttention: desktopAttention, registry: registry,
                cors: cors, heartbeat: heartbeat
            )
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
    }

    public func close() async throws {
        try await channel.close()
        registry.closeAll()
        try await group.shutdownGracefully()
    }
}

public enum RealtimeServerError: Error {
    case missingPort
}

/// One TCP connection on the Socket.IO listener. It handles HTTP requests
/// (polling GET/POST and the WebSocket handshake) and, after an upgrade, the
/// WebSocket frame stream. Engine state lives in `EngineIOSession`, not here.
private final class RealtimeConnectionHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Mode {
        case http
        case websocket
    }

    private struct HeldHTTPResponse {
        var bytes: [UInt8]
        var closeAfter: Bool
    }

    private let auth: any RealtimeAuthorizing
    private let hub: RealtimeHub
    private let desktopAttention: DesktopAttentionRegistry
    private let heartbeat: RealtimeHeartbeatConfiguration
    private let registry: EngineIOSessionRegistry
    private let cors: EngineIOCORS
    private let connectionID = UUID()

    private var mode: Mode = .http
    private var httpFramer = EngineIOHTTPFramer(maxPayload: 1_000_000)
    private var websocketBuffer: [UInt8] = []
    private var engine: EngineIOSession?
    private var layer: RealtimeSocketIOSession?
    private var closed = false
    private var engineCloseNotified = false

    /// A polling GET that has not written its response yet owns the next
    /// response position on this connection. Later pipelined responses are
    /// held until the poll response flushes, matching Node's ordered
    /// ServerResponse queue.
    private var awaitingEngineResponse = false
    private var heldResponses: [HeldHTTPResponse] = []
    private var engineResponseFlushPending = false
    private var stopReadingHTTP = false

    init(
        auth: any RealtimeAuthorizing,
        hub: RealtimeHub,
        desktopAttention: DesktopAttentionRegistry,
        heartbeat: RealtimeHeartbeatConfiguration,
        registry: EngineIOSessionRegistry,
        cors: EngineIOCORS
    ) {
        self.auth = auth
        self.hub = hub
        self.desktopAttention = desktopAttention
        self.heartbeat = heartbeat
        self.registry = registry
        self.cors = cors
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.eventLoop.preconditionInEventLoop()
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }
        switch mode {
        case .http:
            httpFramer.append(bytes)
            drainHTTP(context: context)
        case .websocket:
            websocketBuffer.append(contentsOf: bytes)
            drainWebSocket(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.eventLoop.preconditionInEventLoop()
        closed = true
        heldResponses.removeAll()
        notifyEngineOfClose()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.eventLoop.preconditionInEventLoop()
        closed = true
        heldResponses.removeAll()
        notifyEngineOfClose()
        context.close(promise: nil)
    }

    private func notifyEngineOfClose() {
        guard !engineCloseNotified else { return }
        engineCloseNotified = true
        guard let engine else { return }
        if mode == .websocket {
            engine.websocketClosed(connectionID)
        } else {
            engine.pollConnectionClosed(connectionID)
        }
    }

    /// Engine poll writes reach this handler (`channel.writeAndFlush` starts at
    /// the tail) while this handler's own writes use its context and skip the
    /// interception. A flushed engine response releases held pipelined
    /// responses in request order.
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        engineResponseFlushPending = true
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        context.flush()
        guard engineResponseFlushPending else { return }
        engineResponseFlushPending = false
        guard awaitingEngineResponse else { return }
        awaitingEngineResponse = false
        flushHeldResponses(context: context)
    }

    // MARK: - HTTP

    private func drainHTTP(context: ChannelHandlerContext) {
        while mode == .http, !closed, !stopReadingHTTP {
            switch httpFramer.next() {
            case .incomplete:
                return
            case .failure:
                // Node's HTTP parser answers an invalid request head or body
                // framing with 400 and closes that connection before any
                // engine.io routing happens.
                writeMalformed(context: context)
                return
            case .oversized(let request):
                // The unread body cannot be framed again on this connection,
                // so every oversized response closes it regardless of whether
                // the request itself was otherwise routable.
                handle(request, body: [], keepAlive: false, oversized: true, context: context)
                return
            case .upgrade(let request, let residual):
                guard request.path == "/socket.io/" else {
                    writeNotFound(request, context: context)
                    return
                }
                handleWebSocket(
                    request, sid: request.query["sid"], residual: residual,
                    keepAlive: request.keepsConnectionAlive, context: context
                )
                return
            case .request(let request, let body):
                let keepAlive = request.keepsConnectionAlive
                handle(request, body: body, keepAlive: keepAlive, context: context)
                if mode == .websocket || closed || stopReadingHTTP { return }
            }
        }
    }

    private func handle(
        _ request: EngineIOHTTPRequest,
        body: [UInt8],
        keepAlive: Bool,
        oversized: Bool = false,
        context: ChannelHandlerContext
    ) {
        let origin = request.header("origin")
        guard request.path == "/socket.io/" else {
            writeNotFound(request, context: context)
            return
        }
        if request.method == "OPTIONS", cors.isEnabled {
            let bytes = engineIOPreflightResponseBytes(
                cors: cors, origin: origin, requestedHeaders: request.header("access-control-request-headers")
            )
            writeHTTPResponse(bytes, closeAfter: false, context: context)
            return
        }
        guard let transport = request.query["transport"], transport == "polling" || transport == "websocket" else {
            writeEngineError(code: 0, message: "Transport unknown", origin: origin, keepAlive: keepAlive, context: context)
            return
        }
        if request.query["EIO"] != "4" {
            let sid = request.query["sid"]
            if let sid, !sid.isEmpty {
                writeEngineError(code: 3, message: "Bad request", origin: origin, keepAlive: keepAlive, context: context)
            } else {
                writeEngineError(code: 5, message: "Unsupported protocol version", origin: origin, keepAlive: keepAlive, context: context)
            }
            return
        }
        if transport == "websocket" {
            // A WebSocket transport without an Upgrade header is the
            // `TRANSPORT_HANDSHAKE_ERROR` / mismatch arm of engine.io.
            writeEngineError(code: 3, message: "Bad request", origin: origin, keepAlive: keepAlive, context: context)
            return
        }
        let sid = request.query["sid"]
        if let sid, !sid.isEmpty {
            guard let engine = registry.session(id: sid) else {
                writeEngineError(code: 1, message: "Session ID unknown", origin: origin, keepAlive: keepAlive, context: context)
                return
            }
            handlePollingRequest(
                engine, request: request, body: body, origin: origin,
                keepAlive: keepAlive, oversized: oversized, context: context
            )
        } else {
            guard request.method == "GET" else {
                writeEngineError(code: 2, message: "Bad handshake method", origin: origin, keepAlive: keepAlive, context: context)
                return
            }
            let engine = makeEngine(on: context.eventLoop)
            engine.startPolling()
            attachPoll(
                engine, origin: origin, userAgent: request.header("user-agent"),
                keepAlive: keepAlive, context: context
            )
        }
    }

    private func handlePollingRequest(
        _ engine: EngineIOSession,
        request: EngineIOHTTPRequest,
        body: [UInt8],
        origin: String?,
        keepAlive: Bool,
        oversized: Bool,
        context: ChannelHandlerContext
    ) {
        self.engine = engine
        if oversized {
            writeEmptyError(
                status: "413 Payload Too Large", origin: origin,
                context: context, closeAfter: true
            )
            return
        }
        switch request.method {
        case "GET":
            attachPoll(
                engine, origin: origin, userAgent: request.header("user-agent"),
                keepAlive: keepAlive, context: context
            )
        case "POST":
            let contentType = request.header("content-type")?.lowercased() ?? ""
            if contentType == "application/octet-stream" {
                engine.close()
                writeEmptyError(
                    status: "400 Bad Request", origin: origin,
                    context: context, closeAfter: !keepAlive
                )
                return
            }
            let text = String(decoding: body, as: UTF8.self)
            let packets = text.split(separator: "\u{1e}", omittingEmptySubsequences: false).map(String.init)
            switch engine.beginPost(connectionID: connectionID) {
            case .accepted:
                engine.receivePostPackets(packets)
                engine.endPost(connectionID: connectionID)
                let bytes = engineIOPostAckBytes(
                    cors: cors, origin: origin, userAgent: request.header("user-agent"),
                    keepAlive: keepAlive
                )
                writeHTTPResponse(bytes, closeAfter: !keepAlive, context: context)
            case .overlap:
                writeEmptyError(
                    status: "400 Bad Request", origin: origin,
                    context: context, closeAfter: !keepAlive
                )
            case .unknownSid:
                writeEngineError(code: 1, message: "Session ID unknown", origin: origin, keepAlive: keepAlive, context: context)
            case .wrongTransport:
                writeEngineError(code: 3, message: "Bad request", origin: origin, keepAlive: keepAlive, context: context)
            }
        default:
            writeEmptyError(
                status: "500 Internal Server Error", origin: origin,
                context: context, closeAfter: !keepAlive
            )
        }
    }

    private func attachPoll(
        _ engine: EngineIOSession,
        origin: String?,
        userAgent: String?,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        self.engine = engine
        switch engine.attachPoll(
            connectionID: connectionID, channel: context.channel, origin: origin,
            userAgent: userAgent, keepAlive: keepAlive
        ) {
        case .accepted:
            // The poll response is produced on the engine's owner loop. Until
            // it flushes, later pipelined responses stay queued behind it.
            awaitingEngineResponse = true
        case .overlap:
            writeEmptyError(
                status: "400 Bad Request", origin: origin,
                context: context, closeAfter: !keepAlive
            )
        case .unknownSid:
            writeEngineError(code: 1, message: "Session ID unknown", origin: origin, keepAlive: keepAlive, context: context)
        case .wrongTransport:
            writeEngineError(code: 3, message: "Bad request", origin: origin, keepAlive: keepAlive, context: context)
        }
    }

    private func makeEngine(on eventLoop: any EventLoop) -> EngineIOSession {
        let layer = RealtimeSocketIOSession(
            auth: auth, hub: hub, desktopAttention: desktopAttention,
            heartbeat: heartbeat, ownerLoop: eventLoop
        )
        self.layer = layer
        let bound = NIOLoopBound(layer, eventLoop: eventLoop)
        let engineID = socketIOGeneratedID()
        let hub = self.hub
        let engine = EngineIOSession(
            id: engineID,
            heartbeat: heartbeat,
            ownerLoop: eventLoop,
            cors: cors,
            onClose: { [weak registry] socketIO in
                registry?.remove(id: engineID)
                if let socketIO { hub.unregister(socketIO) }
            },
            socketIOHandler: { packet in
                eventLoop.execute { bound.value.receive(packet) }
            }
        )
        layer.engine = engine
        self.engine = engine
        registry.insert(engine)
        return engine
    }

    // MARK: - WebSocket

    private func handleWebSocket(
        _ request: EngineIOHTTPRequest,
        sid: String?,
        residual: [UInt8],
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        guard let key = request.header("sec-websocket-key"), !key.isEmpty else {
            writeUpgradeAbort(engineIOEmptyErrorResponseBytes(
                status: "400 Bad Request", cors: cors, origin: request.header("origin"),
                keepAlive: false
            ), context: context)
            return
        }
        if let sid, !sid.isEmpty {
            guard registry.session(id: sid) != nil else {
                writeUpgradeAbort(engineIOWebSocketAbortBytes(message: "Session ID unknown"), context: context)
                return
            }
            if request.query["EIO"] != "4" {
                writeUpgradeAbort(engineIOWebSocketAbortBytes(message: "Bad request"), context: context)
                return
            }
        } else if request.query["EIO"] != "4" {
            writeUpgradeAbort(engineIOWebSocketAbortBytes(message: "Unsupported protocol version"), context: context)
            return
        }
        let prelude = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(secWebSocketAccept(key))\r\n\r\n"
        writeRawResponse(Array(prelude.utf8), closeAfter: false, context: context)
        mode = .websocket
        websocketBuffer = residual
        // Any HTTP response still queued on the old transport would be written
        // into the WebSocket frame stream; the upgrade request owns this
        // connection from the 101 onward.
        awaitingEngineResponse = false
        heldResponses.removeAll()
        stopReadingHTTP = false
        if let sid, !sid.isEmpty {
            guard let engine = registry.session(id: sid) else {
                context.close(promise: nil)
                closed = true
                return
            }
            self.engine = engine
            engine.startUpgrade(context.channel, connectionID: connectionID)
        } else {
            let engine = makeEngine(on: context.eventLoop)
            engine.startWebSocket(context.channel, connectionID: connectionID)
        }
        drainWebSocket(context: context)
    }

    private func drainWebSocket(context: ChannelHandlerContext) {
        while mode == .websocket, !closed {
            guard let frame = readWebSocketFrame(from: &websocketBuffer) else { return }
            switch frame.opcode {
            case 0x1:
                guard let engine else { return }
                engine.handleWebSocketText(String(decoding: frame.payload, as: UTF8.self), connectionID: connectionID)
            case 0x8:
                if let engine { engine.websocketClosed(connectionID) }
                closed = true
                context.close(promise: nil)
                return
            case 0x9:
                writeRawResponse(
                    websocketControlFrame(opcode: 0xA, payload: frame.payload),
                    closeAfter: false, context: context
                )
            case 0xA:
                break
            default:
                break
            }
        }
    }

    // MARK: - Responses

    private func writeHTTPResponse(_ bytes: [UInt8], closeAfter: Bool, context: ChannelHandlerContext) {
        guard !closed else { return }
        if awaitingEngineResponse {
            heldResponses.append(HeldHTTPResponse(bytes: bytes, closeAfter: closeAfter))
            if closeAfter { stopReadingHTTP = true }
            return
        }
        writeRawResponse(bytes, closeAfter: closeAfter, context: context)
    }

    private func writeRawResponse(_ bytes: [UInt8], closeAfter: Bool, context: ChannelHandlerContext) {
        guard !closed else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        if closeAfter {
            closed = true
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
                channel.close(promise: nil)
            }
        } else {
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }

    private func flushHeldResponses(context: ChannelHandlerContext) {
        let responses = heldResponses
        heldResponses.removeAll()
        for response in responses {
            writeRawResponse(response.bytes, closeAfter: response.closeAfter, context: context)
            if response.closeAfter { return }
        }
    }

    private func writeUpgradeAbort(_ bytes: [UInt8], context: ChannelHandlerContext) {
        // An upgrade abort closes before the 101; it owns the connection and is
        // never queued behind a polling response.
        writeRawResponse(bytes, closeAfter: true, context: context)
    }

    private func writeNotFound(_ request: EngineIOHTTPRequest, context: ChannelHandlerContext) {
        let keepAlive = request.keepsConnectionAlive
        let bytes = engineIOHTTPResponseBytes(
            status: "404 Not Found", headers: [], body: [], keepAlive: keepAlive,
            chunked: false, contentLength: true
        )
        writeHTTPResponse(bytes, closeAfter: !keepAlive, context: context)
    }

    private func writeEngineError(
        code: Int, message: String, origin: String?, keepAlive: Bool, context: ChannelHandlerContext
    ) {
        let bytes = engineIOErrorResponseBytes(
            code: code, message: message, cors: cors, origin: origin, keepAlive: keepAlive
        )
        writeHTTPResponse(bytes, closeAfter: !keepAlive, context: context)
    }

    private func writeEmptyError(
        status: String, origin: String? = nil,
        context: ChannelHandlerContext, closeAfter: Bool
    ) {
        let bytes = engineIOEmptyErrorResponseBytes(
            status: status, cors: cors, origin: origin, keepAlive: !closeAfter
        )
        writeHTTPResponse(bytes, closeAfter: closeAfter, context: context)
    }

    private func writeMalformed(context: ChannelHandlerContext) {
        let bytes = engineIOHTTPResponseBytes(
            status: "400 Bad Request", headers: [], body: [], keepAlive: false,
            chunked: true, contentLength: false
        )
        // A parser error terminates the connection even if an earlier poll is
        // still outstanding, exactly like Node destroying the socket.
        writeRawResponse(bytes, closeAfter: true, context: context)
    }
}

private struct WebSocketFrame {
    var opcode: UInt8
    var payload: [UInt8]
}

private func readWebSocketFrame(from buffer: inout [UInt8]) -> WebSocketFrame? {
    guard buffer.count >= 2 else { return nil }
    let first = buffer[0]
    let second = buffer[1]
    let opcode = first & 0x0f
    let masked = (second & 0x80) != 0
    var length = Int(second & 0x7f)
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
    let maskOffset = offset
    if masked { offset += 4 }
    guard buffer.count >= offset + length else { return nil }
    var payload = Array(buffer[offset..<(offset + length)])
    if masked {
        for index in payload.indices {
            payload[index] ^= buffer[maskOffset + (index % 4)]
        }
    }
    buffer.removeFirst(offset + length)
    return WebSocketFrame(opcode: opcode, payload: payload)
}

private func websocketControlFrame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
    var frame: [UInt8] = [0x80 | opcode]
    if payload.count < 126 {
        frame.append(UInt8(payload.count))
    } else {
        frame.append(126)
        frame.append(UInt8((payload.count >> 8) & 0xff))
        frame.append(UInt8(payload.count & 0xff))
    }
    frame.append(contentsOf: payload)
    return frame
}
