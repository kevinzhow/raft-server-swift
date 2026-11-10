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

public final class RealtimeServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    public let hub: RealtimeHub
    public let desktopAttention: DesktopAttentionRegistry
    public let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, port: Int, hub: RealtimeHub, desktopAttention: DesktopAttentionRegistry) {
        self.group = group
        self.channel = channel
        self.port = port
        self.hub = hub
        self.desktopAttention = desktopAttention
    }

    public static func start(
        auth: any RealtimeAuthorizing,
        host: String = "127.0.0.1",
        port: Int = 0,
        hub: RealtimeHub = RealtimeHub()
    ) async throws -> RealtimeServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let desktopAttention = DesktopAttentionRegistry()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // ServerBootstrap invokes this initializer on the child loop.
                // The SDK bound value checks that ownership across the Sendable
                // submit closure; synchronous installation never transfers the
                // non-Sendable handler to another executor or channel.
                let handler = NIOLoopBound(
                    RealtimeConnectionHandler(auth: auth, hub: hub, serverPort: port, desktopAttention: desktopAttention),
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
            return RealtimeServer(group: group, channel: channel, port: boundPort, hub: hub, desktopAttention: desktopAttention)
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
    }

    public func close() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }
}

public enum RealtimeServerError: Error {
    case missingPort
}

// All mutable parser and handshake state belongs exclusively to the channel
// event loop. Construction/installation above and every pipeline entry below
// check that confinement; this handler is deliberately not Sendable.
private final class RealtimeConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let auth: any RealtimeAuthorizing
    private let hub: RealtimeHub
    private let desktopAttention: DesktopAttentionRegistry
    private var desktopAttentionHandler: DesktopAttentionHandler?
    private var httpBuffer: [UInt8] = []
    private var frameBuffer: [UInt8] = []
    private var upgraded = false
    private var session: SocketIOSession?
    private var closed = false

    init(auth: any RealtimeAuthorizing, hub: RealtimeHub, serverPort: Int, desktopAttention: DesktopAttentionRegistry) {
        self.auth = auth
        self.hub = hub
        self.desktopAttention = desktopAttention
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.eventLoop.preconditionInEventLoop()
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }
        if upgraded {
            frameBuffer.append(contentsOf: bytes)
            drainFrames(context: context)
        } else {
            httpBuffer.append(contentsOf: bytes)
            drainHTTP(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.eventLoop.preconditionInEventLoop()
        closeSession()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.eventLoop.preconditionInEventLoop()
        closeSession()
        context.close(promise: nil)
    }

    private func drainHTTP(context: ChannelHandlerContext) {
        let separator: [UInt8] = [13, 10, 13, 10]
        guard let end = find(separator, in: httpBuffer) else { return }
        let headBytes = Array(httpBuffer[..<end])
        let leftover = Array(httpBuffer[(end + 4)...])
        httpBuffer = []
        guard let head = String(bytes: headBytes, encoding: .utf8) else {
            reject(context: context, status: "400 Bad Request")
            return
        }
        guard let request = SocketIOUpgradeRequest(head: head),
              request.path == "/socket.io/",
              request.query["EIO"] == "4",
              request.query["transport"] == "websocket",
              let key = request.header("sec-websocket-key")
        else {
            reject(context: context, status: "400 Bad Request")
            return
        }
        let accept = secWebSocketAccept(key)
        let prelude = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        var bytes = Array(prelude.utf8)
        bytes.append(contentsOf: websocketTextFrame(engineIOOpenFrame(sid: socketIOGeneratedID())))
        write(context: context, bytes: bytes)
        upgraded = true
        frameBuffer.append(contentsOf: leftover)
        drainFrames(context: context)
    }

    private func drainFrames(context: ChannelHandlerContext) {
        while let frame = readWebSocketFrame(from: &frameBuffer) {
            switch frame.opcode {
            case 0x1:
                handleText(String(decoding: frame.payload, as: UTF8.self), context: context)
            case 0x8:
                closeSession()
                context.close(promise: nil)
                return
            case 0x9:
                write(context: context, bytes: websocketControlFrame(opcode: 0xA, payload: frame.payload))
            case 0xA:
                break
            default:
                break
            }
        }
    }

    private func handleText(_ text: String, context: ChannelHandlerContext) {
        if text == "2" {
            send(text: "3", context: context)
            return
        }
        if text == "41" {
            closeSession()
            context.close(promise: nil)
            return
        }
        if text.hasPrefix("40"), session == nil {
            connect(payload: String(text.dropFirst(2)), context: context)
            return
        }
        guard let session else { return }
        if text.hasPrefix("42") {
            handleEvent(String(text.dropFirst(2)), session: session)
        }
    }

    private func connect(payload: String, context: ChannelHandlerContext) {
        let parsed = parseSocketHandshakeAuth(Data(payload.utf8))
        let handshake: SocketHandshakeAuth
        switch parsed {
        case .success(let value): handshake = value
        case .failure:
            send(text: socketIOErrorFrame("Authentication required"), context: context)
            context.close(promise: nil)
            return
        }
        guard let identity = auth.sessionIdentity(forAccessToken: handshake.token) else {
            send(text: socketIOErrorFrame("Invalid or expired token"), context: context)
            context.close(promise: nil)
            return
        }
        let userId = identity.userId
        // Register before ALL role/visibility reads: revocation before this
        // point is reflected by those reads; after it the hub sees the pending
        // connection just as Node's pendingHandshakes set does.
        let session = SocketIOSession(id: socketIOGeneratedID(), userId: userId,
            serverId: handshake.serverId, clientKind: handshake.clientKind,
            familyId: identity.familyId, channel: context.channel, pending: true)
        self.session = session
        hub.register(session)
        let role: String?
        let channelIds: [String]
        if let serverId = handshake.serverId {
            role = auth.serverRole(serverId: serverId, userId: userId)
            guard role != nil else {
                send(text: socketIOErrorFrame(socketNotServerMemberMessage), context: context)
                context.close(promise: nil)
                return
            }
            channelIds = auth.visibleChannelIds(serverId: serverId, userId: userId)
        } else {
            role = nil
            channelIds = []
        }
        // A profile/family revoke before registration cannot be reinterpreted
        // as a legacy familyless identity. After registration any user/family
        // revoke closes this pending session; no new error/frame is invented.
        guard auth.sessionIdentity(forAccessToken: handshake.token) == identity, session.admit() else {
            session.close()
            return
        }
        desktopAttentionHandler = DesktopAttentionHandler(userId: userId,
            clientKind: handshake.clientKind, recorder: desktopAttention)
        send(text: socketIOConnectFrame(sid: session.id), context: context)
        session.join(["user:\(userId)", socketClientKindRoom(userId: userId, clientKind: handshake.clientKind)])
        if let serverId = handshake.serverId {
            if role == "guest" { session.join([socketServerGuestsRoom(serverId: serverId)]) }
            else { session.join(["server:\(serverId)"]) }
            session.join([socketUserServerRoom(userId: userId, serverId: serverId)])
            session.join(channelIds.map { "channel:\($0)" })
            send(text: socketIOEventFrame("rooms:joined"), context: context)
        }
    }

    private func handleEvent(_ payload: String, session: SocketIOSession) {
        guard let data = payload.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let event = array.first as? String
        else { return }
        if event == DesktopAttentionEvents.eventName {
            desktopAttentionHandler?.handle(array.count > 1 ? array[1] : nil)
            return
        }
        guard let serverId = session.serverId else { return }
        let userId = session.userId
        switch event {
        case "join:channel":
            guard array.count > 1, let channelId = array[1] as? String, !channelId.isEmpty else { return }
            guard auth.visibleChannelIds(serverId: serverId, userId: userId).contains(channelId) else { return }
            session.join(["channel:\(channelId)"])
        case "leave:channel":
            guard array.count > 1, let channelId = array[1] as? String else { return }
            session.leave("channel:\(channelId)")
        case "sync:resume":
            guard let serverId = session.serverId,
                  array.count > 1,
                  let payload = array[1] as? [String: Any],
                  let lastSeq = (payload["lastSeq"] as? NSNumber)?.intValue ?? (payload["lastSeq"] as? Int),
                  lastSeq > 0
            else { return }
            guard let body = auth.syncResumePayload(
                serverId: serverId,
                userId: userId,
                lastSeq: lastSeq,
                limit: socketResumeLimit
            ) else { return }
            session.send(socketIOEventFrame("sync:resume:response", payloadJSON: body))
        default:
            break
        }
    }

    private func send(text: String, context: ChannelHandlerContext) {
        write(context: context, bytes: websocketTextFrame(text))
    }

    private func write(context: ChannelHandlerContext, bytes: [UInt8]) {
        context.eventLoop.preconditionInEventLoop()
        // Protocol replies share the terminal gate with hub events. Since this
        // write is synchronous on the owner loop, a concurrent terminal drain
        // cannot overtake it after the open-state check.
        guard session?.isClosed != true else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    private func reject(context: ChannelHandlerContext, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\r\n"
        write(context: context, bytes: Array(response.utf8))
        context.close(promise: nil)
    }

    private func closeSession() {
        guard !closed else { return }
        closed = true
        if let session {
            hub.unregister(session)
            session.markClosed()
        }
    }

    private func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for index in 0...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle { return index }
        }
        return nil
    }
}

final class SocketIOSession: Sendable {
    let id: String
    let userId: String
    let serverId: String?
    let clientKind: SocketClientKind
    let familyId: String?
    let channel: any Channel

    private enum Write: Sendable {
        case frame(String)
        case close
        case finalFrame(String)
    }

    private struct State: Sendable {
        var rooms: Set<String> = []
        var admitted = true
        var closed = false
        var pending = CircularBuffer<Write>(initialCapacity: 64)
        var draining = false
    }

    private let state = Mutex(State())

    init(
        id: String,
        userId: String,
        serverId: String?,
        clientKind: SocketClientKind,
        familyId: String?,
        channel: any Channel,
        pending: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.serverId = serverId
        self.clientKind = clientKind
        self.familyId = familyId
        self.channel = channel
        if pending { state.withLock { $0.admitted = false } }
    }

    /// Transport phase only; the actual auth and visibility reads already ran.
    func admit() -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            state.admitted = true
            return true
        }
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    func hasRoom(_ room: String) -> Bool { state.withLock { $0.admitted && $0.rooms.contains(room) } }

    func join(_ newRooms: [String]) { state.withLock { $0.rooms.formUnion(newRooms) } }

    func leave(_ room: String) { _ = state.withLock { $0.rooms.remove(room) } }

    func leave(_ leavingRooms: [String]) {
        guard !leavingRooms.isEmpty else { return }
        state.withLock { $0.rooms.subtract(leavingRooms) }
    }

    func markClosed() {
        state.withLock {
            $0.closed = true
            $0.pending.removeAll()
        }
    }

    func send(_ text: String) { enqueue(.frame(text), terminal: false) }

    func close() { enqueue(.close, terminal: true) }

    func sendAndClose(_ text: String) { enqueue(.finalFrame(text), terminal: true) }

    private func enqueue(_ write: Write, terminal: Bool) {
        let shouldDrain = state.withLock { state in
            guard !state.closed else { return false }
            let queued: Write
            switch write {
            case .frame:
                guard state.admitted else { return false }
                queued = write
            case .finalFrame: queued = state.admitted ? write : .close
            case .close: queued = write
            }
            if terminal { state.closed = true }
            state.pending.append(queued)
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        if shouldDrain {
            // No loop scheduling or outbound handler callback runs under the
            // state mutex. One drainer preserves admitted frame/close order.
            channel.eventLoop.execute { self.drainWrites() }
        }
    }

    private func drainWrites() {
        channel.eventLoop.preconditionInEventLoop()
        let writes = state.withLock { state in
            let count = min(state.pending.count, 64)
            var writes: [Write] = []
            writes.reserveCapacity(count)
            for _ in 0..<count { writes.append(state.pending.removeFirst()) }
            return writes
        }
        for write in writes {
            switch write {
            case .frame(let text):
                guard channel.isActive else { continue }
                writeFrame(text, closeAfterFlush: false)
            case .close:
                channel.close(promise: nil)
            case .finalFrame(let text):
                guard channel.isActive else {
                    channel.close(promise: nil)
                    continue
                }
                writeFrame(text, closeAfterFlush: true)
            }
        }
        let shouldContinue = state.withLock { state in
            // Keep ownership while work remains. An enqueue after this empty
            // check either sees draining=true or claims the next drain itself.
            guard state.pending.isEmpty else { return true }
            state.draining = false
            return false
        }
        if shouldContinue {
            // This NIO loop drains immediate tasks until none remain. A future
            // tick, rather than execute(), also yields to selector I/O under a
            // continuous producer, while the single drainer preserves FIFO.
            _ = channel.eventLoop.scheduleTask(in: .milliseconds(1)) { self.drainWrites() }
        }
    }

    private func writeFrame(_ text: String, closeAfterFlush: Bool) {
        channel.eventLoop.preconditionInEventLoop()
        var buffer = channel.allocator.buffer(capacity: text.utf8.count + 4)
        buffer.writeBytes(websocketTextFrame(text))
        if closeAfterFlush {
            channel.writeAndFlush(buffer).whenComplete { [channel] _ in
                channel.close(promise: nil)
            }
        } else {
            channel.writeAndFlush(buffer, promise: nil)
        }
    }
}

private struct SocketIOUpgradeRequest {
    var path: String
    var query: [String: String]
    private var headers: [String: String]

    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = String(split[0])
        var query: [String: String] = [:]
        if split.count == 2 {
            for pair in split[1].split(separator: "&") {
                let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(item[0]).removingPercentEncoding ?? String(item[0])
                let value = item.count == 2 ? (String(item[1]).removingPercentEncoding ?? String(item[1])) : ""
                query[name] = value
            }
        }
        self.query = query
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        self.headers = headers
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
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
