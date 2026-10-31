import Foundation
import NIOCore
import NIOPosix
import RaftConnectAuth

public protocol RealtimeAuthorizing: Sendable {
    func userId(forAccessToken token: String) -> String?
    func sessionFamilyId(forAccessToken token: String) -> String?
    func serverRole(serverId: String, userId: String) -> String?
    func visibleChannelIds(serverId: String, userId: String) -> [String]
}

public final class RealtimeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: SocketIOSession] = [:]

    public init() {}

    public var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    public func emit(room: String, event: String, payloadJSON: String? = nil) {
        lock.lock()
        let targets = sessions.values.filter { $0.hasRoom(room) }
        lock.unlock()
        let frame = socketIOEventFrame(event, payloadJSON: payloadJSON)
        for session in targets {
            session.send(frame)
        }
    }

    func register(_ session: SocketIOSession) {
        lock.lock()
        sessions[ObjectIdentifier(session)] = session
        lock.unlock()
    }

    func unregister(_ session: SocketIOSession) {
        lock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    /// Close every socket that belongs to one user session family.
    public func revokeFamily(userId: String, familyId: String) {
        lock.lock()
        let targets = sessions.values.filter { session in
            session.userId == userId && (session.familyId == nil || session.familyId == familyId)
        }
        lock.unlock()
        for session in targets {
            session.close()
        }
    }

    /// `server:membership-removed` is the last packet before the close, and
    /// only connections attached to that server are affected.
    public func removeServerMembership(serverId: String, userId: String) {
        lock.lock()
        let targets = sessions.values.filter { $0.serverId == serverId && $0.userId == userId }
        lock.unlock()
        let payload = "{\"serverId\":\(quotedJSON(serverId))}"
        let frame = socketIOEventFrame("server:membership-removed", payloadJSON: payload)
        for session in targets {
            session.sendAndClose(frame)
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
    public let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, port: Int, hub: RealtimeHub) {
        self.group = group
        self.channel = channel
        self.port = port
        self.hub = hub
    }

    public static func start(
        auth: any RealtimeAuthorizing,
        host: String = "127.0.0.1",
        port: Int = 0
    ) async throws -> RealtimeServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hub = RealtimeHub()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    RealtimeConnectionHandler(auth: auth, hub: hub, serverPort: port)
                )
            }
        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            guard let boundPort = channel.localAddress?.port else {
                try await channel.close()
                try await group.shutdownGracefully()
                throw RealtimeServerError.missingPort
            }
            return RealtimeServer(group: group, channel: channel, port: boundPort, hub: hub)
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

private final class RealtimeConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let auth: any RealtimeAuthorizing
    private let hub: RealtimeHub
    private var httpBuffer: [UInt8] = []
    private var frameBuffer: [UInt8] = []
    private var upgraded = false
    private var session: SocketIOSession?
    private var closed = false

    init(auth: any RealtimeAuthorizing, hub: RealtimeHub, serverPort: Int) {
        self.auth = auth
        self.hub = hub
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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
        closeSession()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
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
        case .success(let value):
            handshake = value
        case .failure:
            send(text: socketIOErrorFrame("Authentication required"), context: context)
            context.close(promise: nil)
            return
        }
        guard let userId = auth.userId(forAccessToken: handshake.token) else {
            send(text: socketIOErrorFrame("Invalid or expired token"), context: context)
            context.close(promise: nil)
            return
        }
        let role: String?
        if let serverId = handshake.serverId {
            role = auth.serverRole(serverId: serverId, userId: userId)
            guard role != nil else {
                send(text: socketIOErrorFrame(socketNotServerMemberMessage), context: context)
                context.close(promise: nil)
                return
            }
        } else {
            role = nil
        }
        let session = SocketIOSession(
            id: socketIOGeneratedID(),
            userId: userId,
            serverId: handshake.serverId,
            clientKind: handshake.clientKind,
            familyId: auth.sessionFamilyId(forAccessToken: handshake.token),
            channel: context.channel
        )
        self.session = session
        hub.register(session)
        send(text: socketIOConnectFrame(sid: session.id), context: context)
        session.join(["user:\(userId)", socketClientKindRoom(userId: userId, clientKind: handshake.clientKind)])
        if let serverId = handshake.serverId {
            if role == "guest" {
                session.join([socketServerGuestsRoom(serverId: serverId)])
            } else {
                session.join(["server:\(serverId)"])
            }
            session.join([socketUserServerRoom(userId: userId, serverId: serverId)])
            let channelIds = auth.visibleChannelIds(serverId: serverId, userId: userId)
            session.join(channelIds.map { "channel:\($0)" })
            send(text: socketIOEventFrame("rooms:joined"), context: context)
        }
    }

    private func handleEvent(_ payload: String, session: SocketIOSession) {
        guard let data = payload.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let event = array.first as? String
        else { return }
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
        default:
            break
        }
    }

    private func send(text: String, context: ChannelHandlerContext) {
        write(context: context, bytes: websocketTextFrame(text))
    }

    private func write(context: ChannelHandlerContext, bytes: [UInt8]) {
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

final class SocketIOSession: @unchecked Sendable {
    let id: String
    let userId: String
    let serverId: String?
    let clientKind: SocketClientKind
    let familyId: String?
    let channel: any Channel
    private let lock = NSLock()
    private var rooms: Set<String> = []
    private var closed = false

    init(
        id: String,
        userId: String,
        serverId: String?,
        clientKind: SocketClientKind,
        familyId: String?,
        channel: any Channel
    ) {
        self.id = id
        self.userId = userId
        self.serverId = serverId
        self.clientKind = clientKind
        self.familyId = familyId
        self.channel = channel
    }

    func hasRoom(_ room: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rooms.contains(room)
    }

    func join(_ newRooms: [String]) {
        lock.lock()
        rooms.formUnion(newRooms)
        lock.unlock()
    }

    func leave(_ room: String) {
        lock.lock()
        rooms.remove(room)
        lock.unlock()
    }

    func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func send(_ text: String) {
        lock.lock()
        let closed = self.closed
        lock.unlock()
        guard !closed else { return }
        channel.eventLoop.execute { [channel] in
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: text.utf8.count + 4)
            buffer.writeBytes(websocketTextFrame(text))
            channel.writeAndFlush(NIOAny(buffer), promise: nil)
        }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        channel.eventLoop.execute { [channel] in
            channel.close(promise: nil)
        }
    }

    func sendAndClose(_ text: String) {        lock.lock()
        if closed {
            lock.unlock()
            channel.close(promise: nil)
            return
        }
        closed = true
        lock.unlock()
        channel.eventLoop.execute { [channel] in
            guard channel.isActive else {
                channel.close(promise: nil)
                return
            }
            var buffer = channel.allocator.buffer(capacity: text.utf8.count + 4)
            buffer.writeBytes(websocketTextFrame(text))
            channel.writeAndFlush(NIOAny(buffer)).whenComplete { _ in
                channel.close(promise: nil)
            }
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
