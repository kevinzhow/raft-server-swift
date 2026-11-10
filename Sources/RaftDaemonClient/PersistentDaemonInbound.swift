import Foundation
import NIOCore
import RaftConnectAuth
import Synchronization

final class PersistentDaemonInboundState: Sendable {
    let ready: EventLoopPromise<DaemonHandshake>
    let messages: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let clientKey: String
    private struct State: Sendable {
        var headerBytes: [UInt8] = []
        var upgraded = false
        var receivedContext = false
        var readyFinished = false
        var failed = false
        var failure: (any Error)?
        var capabilities: [String] = []
        var channel: (any Channel)?
        var lastInbound = ProcessInfo.processInfo.systemUptime
        var codec = PersistentWebSocket()
    }
    private let state = Mutex(State())

    init(clientKey: String, loop: any EventLoop) {
        self.clientKey = clientKey; ready = loop.makePromise(of: DaemonHandshake.self)
        let stream = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        messages = stream.stream; continuation = stream.continuation
    }

    var failure: (any Error)? { state.withLock { $0.failure } }

    var secondsSinceInbound: Double {
        ProcessInfo.processInfo.systemUptime - state.withLock { $0.lastInbound }
    }

    func attach(_ channel: any Channel) {
        let failed = state.withLock { value in value.channel = channel; return value.failed }
        if failed { channel.close(promise: nil) }
    }

    func fail(_ error: any Error) {
        let action = state.withLock { value -> (Bool, (any Channel)?)? in
            guard !value.failed else { return nil }
            value.failed = true; value.failure = error
            let pending = !value.readyFinished
            value.readyFinished = true
            return (pending, value.channel)
        }
        guard let action else { return }
        if action.0 { ready.fail(error) }
        continuation.finish(throwing: error)
        action.1?.close(promise: nil)
    }

    func receive(_ bytes: [UInt8], channel: any Channel) {
        do {
            let frames = try state.withLock { value -> [PersistentWebSocket.Frame] in
                guard !value.failed else { return [] }
                value.lastInbound = ProcessInfo.processInfo.systemUptime
                var incoming = bytes
                if !value.upgraded {
                    value.headerBytes += incoming
                    guard let marker = value.headerBytes.indices.first(where: { index in
                        index + 3 < value.headerBytes.count && Array(value.headerBytes[index...index + 3]) == [13, 10, 13, 10]
                    }) else {
                        guard value.headerBytes.count <= 32_768 else { throw PersistentDaemonError.protocolViolation }
                        return []
                    }
                    guard marker <= 32_768, let text = String(bytes: value.headerBytes.prefix(marker), encoding: .utf8) else {
                        throw PersistentDaemonError.protocolViolation
                    }
                    let lines = text.components(separatedBy: "\r\n")
                    let pieces = lines.first?.split(separator: " ") ?? []
                    guard pieces.count >= 2, pieces[0].hasPrefix("HTTP/"), let code = Int(pieces[1]) else {
                        throw PersistentDaemonError.protocolViolation
                    }
                    var headers: [String: [String]] = [:]
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else { throw PersistentDaemonError.protocolViolation }
                        headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(), default: []]
                            .append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                    }
                    guard code == 101 else {
                        throw DaemonHandshakeRejection(statusCode: code, reason: normalizeHandshakeReason(headers["slock-reason"]?.first))
                    }
                    guard headers["sec-websocket-accept"]?.count == 1,
                          headers["sec-websocket-accept"]?.first == secWebSocketAccept(clientKey),
                          headers["upgrade"]?.first?.lowercased() == "websocket",
                          headers["connection"]?.joined(separator: ",").lowercased().split(separator: ",")
                            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
                          headers["sec-websocket-extensions"] == nil else { throw DaemonConnectError.acceptMismatch }
                    value.capabilities = parseServerCapabilitiesHeader(headers[raftServerCapabilitiesHeader]?.joined(separator: " "))
                    incoming = Array(value.headerBytes.dropFirst(marker + 4)); value.headerBytes = []; value.upgraded = true
                }
                return try value.codec.append(incoming, requireMask: false)
            }
            for frame in frames {
                switch frame.opcode {
                case 1:
                    guard let json = String(bytes: frame.payload, encoding: .utf8) else { throw PersistentDaemonError.protocolViolation }
                    struct Context: Decodable {
                        let type: String
                        var machineId: String?; var serverId: String?; var capabilities: [String]?; var connectionEpochId: String?
                    }
                    let value = try JSONDecoder().decode(Context.self, from: Data(json.utf8))
                    if !state.withLock({ $0.receivedContext }) {
                        guard value.type == "machine:context", let machine = value.machineId, !machine.isEmpty,
                              let server = value.serverId, !server.isEmpty else { throw DaemonConnectError.badContext }
                        let capabilities = state.withLock { current -> [String]? in
                            guard !current.failed, !current.readyFinished else { return nil }
                            current.receivedContext = true; current.readyFinished = true; return current.capabilities
                        }
                        guard let capabilities else { return }
                        ready.succeed(DaemonHandshake(serverCapabilities: capabilities, context: DaemonMachineContext(
                            machineId: machine, serverId: server, capabilities: value.capabilities ?? [], connectionEpochId: value.connectionEpochId
                        )))
                    } else if value.type == "machine:context" { throw PersistentDaemonError.protocolViolation }
                    else if value.type == "ping" {
                        write(opcode: 1, payload: Array("{\"type\":\"pong\"}".utf8), channel: channel)
                    } else if value.type != "pong" {
                        switch continuation.yield(json) {
                        case .enqueued: break
                        case .dropped: throw PersistentDaemonError.receiveBufferFull
                        case .terminated: throw PersistentDaemonError.disconnected
                        @unknown default: throw PersistentDaemonError.protocolViolation
                        }
                    }
                case 8:
                    var output = channel.allocator.buffer(capacity: frame.payload.count + 16)
                    output.writeBytes(PersistentWebSocket.encode(opcode: 8, payload: frame.payload, masked: true))
                    channel.writeAndFlush(output).whenComplete { _ in self.fail(PersistentDaemonError.disconnected) }
                case 9: write(opcode: 10, payload: frame.payload, channel: channel)
                case 10: break
                default: throw PersistentDaemonError.protocolViolation
                }
            }
        } catch { fail(error) }
    }

    private func write(opcode: UInt8, payload: [UInt8], channel: any Channel) {
        var buffer = channel.allocator.buffer(capacity: payload.count + 16)
        buffer.writeBytes(PersistentWebSocket.encode(opcode: opcode, payload: payload, masked: true))
        channel.writeAndFlush(buffer).whenFailure { self.fail($0) }
    }
}

final class PersistentDaemonInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let state: PersistentDaemonInboundState
    init(state: PersistentDaemonInboundState) { self.state = state }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        state.receive(Array(unwrapInboundIn(data).readableBytesView), channel: context.channel)
    }
    func channelInactive(context: ChannelHandlerContext) {
        state.fail(PersistentDaemonError.disconnected); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { state.fail(error) }
}
