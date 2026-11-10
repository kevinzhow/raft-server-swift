import Foundation
import NIOCore
import NIOWebSocket
import RaftConnectAuth
import Synchronization

/// The production path keeps raw bytes after the HTTP prelude. Its RFC6455
/// codec validates masking/fragmentation and does not drop post-upgrade data.
final class MachineCommandConnectionHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let epoch = UUID().uuidString.lowercased()
    private let lookup: any MachineCredentialLooking
    private let capabilities: [String]
    private let registry: MachineCommandRegistry
    private let status: (@Sendable (MatchedMachine, Bool) async throws -> Void)?
    private let legacyStatus: (@Sendable (MatchedMachine, Bool) -> Void)?
    private struct State: Sendable {
        var headerBytes: [UInt8] = []
        var authenticating = false
        var upgraded = false
        var closed = false
        var authenticated: MatchedMachine?
        var committed: MatchedMachine?
        var pendingMessages = 0
        var startup: Task<Void, Never>?
        var messages: Task<Void, Never>?
        var heartbeat: Task<Void, Never>?
        var handshakeDeadline: Task<Void, Never>?
        var lastInbound = ProcessInfo.processInfo.systemUptime
        var pendingUpgradeBytes: [UInt8] = []
        var forwardingFrames = false
    }
    private let state = Mutex(State())

    init(lookup: any MachineCredentialLooking, capabilities: [String], registry: MachineCommandRegistry,
         status: (@Sendable (MatchedMachine, Bool) async throws -> Void)?,
         legacyStatus: (@Sendable (MatchedMachine, Bool) -> Void)?) {
        self.lookup = lookup; self.capabilities = capabilities; self.registry = registry
        self.status = status; self.legacyStatus = legacyStatus
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            if !self.state.withLock({ $0.upgraded }) { channel.close(promise: nil) }
        }
        state.withLock { $0.handshakeDeadline = deadline }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.eventLoop.preconditionInEventLoop()
        let bytes = Array(unwrapInboundIn(data).readableBytesView)
        let channel = context.channel
        do {
            let input = try state.withLock { value -> (header: String?, forward: Bool) in
                value.lastInbound = ProcessInfo.processInfo.systemUptime
                guard !value.closed else { return (nil, false) }
                if value.forwardingFrames { return (nil, true) }
                if value.authenticating {
                    value.pendingUpgradeBytes += bytes
                    guard value.pendingUpgradeBytes.count <= MachineCommandWebSocket.maximumMessageBytes * 2 + 28 else {
                        throw MachineCommandError.protocolViolation
                    }
                    return (nil, false)
                }
                value.headerBytes += bytes
                guard let marker = value.headerBytes.indices.first(where: { index in
                    index + 3 < value.headerBytes.count && Array(value.headerBytes[index...index + 3]) == [13, 10, 13, 10]
                }) else {
                    guard value.headerBytes.count <= 32_768 else { throw MachineCommandError.protocolViolation }
                    return (nil, false)
                }
                guard marker + 4 <= 32_768,
                      let header = String(bytes: value.headerBytes.prefix(marker), encoding: .utf8) else {
                    throw MachineCommandError.protocolViolation
                }
                value.pendingUpgradeBytes = Array(value.headerBytes.dropFirst(marker + 4))
                guard value.pendingUpgradeBytes.count <= MachineCommandWebSocket.maximumMessageBytes * 2 + 28 else {
                    throw MachineCommandError.protocolViolation
                }
                value.headerBytes = []; value.authenticating = true
                return (header, false)
            }
            if input.forward { context.fireChannelRead(data) }
            if let header = input.header {
                let startup = Task { await self.accept(header: header, channel: channel) }
                state.withLock { $0.startup = startup }
            }
        } catch { context.close(promise: nil) }
    }

    /// Receives complete messages and control frames after NIO decoding and
    /// the event-loop-confined message policy. Domain processing is unchanged.
    func receiveFrame(_ frame: MachineCommandWebSocket.Frame, channel: any Channel) throws {
        guard !state.withLock({ $0.closed }) else { return }
        switch frame.opcode {
        case 1:
            guard let json = String(bytes: frame.payload, encoding: .utf8) else { throw MachineCommandError.protocolViolation }
            let previous = try state.withLock { value in
                guard value.pendingMessages < 64 else { throw MachineCommandError.protocolViolation }
                value.pendingMessages += 1; return value.messages
            }
            let task = Task {
                // Immediate post-context ready still waits for transport startup.
                let startup = self.state.withLock { $0.startup }
                await startup?.value
                await previous?.value
                defer { self.state.withLock { $0.pendingMessages -= 1 } }
                guard let machine = self.state.withLock({ $0.committed }), !self.state.withLock({ $0.closed }) else { return }
                do {
                    struct TypeField: Decodable { let type: String }
                    let kind = try JSONDecoder().decode(TypeField.self, from: Data(json.utf8)).type
                    if kind == "ping" {
                        struct Pong: Encodable { let type = "pong" }
                        let payload = try JSONEncoder().encode(Pong())
                        try await Self.writeFrame(opcode: 1, payload: Array(payload), channel: channel).get()
                    } else if kind != "pong" {
                        try await self.registry.receive(machineId: machine.id, epoch: self.epoch, json: json)
                    }
                } catch { channel.close(promise: nil) }
            }
            state.withLock { $0.messages = task }
        case 8:
            Self.writeFrame(opcode: 8, payload: frame.payload, channel: channel).whenComplete { _ in channel.close(promise: nil) }
        case 9: Self.writeFrame(opcode: 10, payload: frame.payload, channel: channel).whenFailure { _ in channel.close(promise: nil) }
        case 10: break
        default: throw MachineCommandError.protocolViolation
        }
    }

    private func accept(header: String, channel: any Channel) async {
        do {
            let lines = header.components(separatedBy: "\r\n")
            let request = lines.first?.split(separator: " ") ?? []
            guard request.count == 3, request[0] == "GET" else { throw MachineCommandError.protocolViolation }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw MachineCommandError.protocolViolation }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard headers[name] == nil else { throw MachineCommandError.protocolViolation }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let uri = String(request[1])
            let parts = URLComponents(string: uri.hasPrefix("/") ? "http://localhost\(uri)" : uri)
            guard parts?.path == "/daemon/connect" else {
                try await Self.writeRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", channel: channel)
                channel.close(promise: nil); return
            }
            let key = presentedApiKey(authorization: headers["authorization"], queryKey: parts?.queryItems?.first { $0.name == "key" }?.value)
            let decision = try await UpgradeAuth.resolve(apiKey: key, hostHeader: headers["host"], lookup: lookup)
            guard case .accepted(_, let machine, _) = decision.result else {
                try await Self.writeRaw(machineUpgradeFailurePrelude(.success(decision.result)) ?? "", channel: channel)
                channel.close(promise: nil); return
            }
            guard let websocketKey = headers["sec-websocket-key"], Data(base64Encoded: websocketKey)?.count == 16,
                  headers["sec-websocket-version"] == "13", headers["upgrade"]?.lowercased() == "websocket",
                  headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true
            else { throw MachineCommandError.protocolViolation }
            state.withLock { $0.authenticated = machine }
            try await registry.register(machineId: machine.id, serverId: machine.serverId, epoch: epoch, channel: channel)
            if let status { try await status(machine, true) }
            state.withLock { $0.committed = machine }
            guard !state.withLock({ $0.closed }) else { throw MachineCommandError.disconnected }
            legacyStatus?(machine, true)
            let prelude = machineUpgradeSwitchingProtocols(clientKey: websocketKey, capabilities: capabilities)
            let json = machineContextJSON(machineId: machine.id, serverId: machine.serverId, capabilities: capabilities, connectionEpochId: epoch)
            // Flush HTTP bytes before installing an encoder that accepts frames.
            try await Self.writeRaw(prelude, channel: channel)
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(
                    WebSocketFrameDecoder(maxFrameSize: MachineCommandWebSocket.maximumMessageBytes)
                ))
                try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
                self.state.withLock { $0.upgraded = true }
                try channel.pipeline.syncOperations.addHandler(MachineCommandFrameHandler(connection: self))
            }.get()
            try await Self.write(json: json, channel: channel)
            guard !state.withLock({ $0.closed }) else { throw MachineCommandError.disconnected }
            await registry.ready(machineId: machine.id, epoch: epoch)
            try await channel.eventLoop.submit {
                let buffered = self.state.withLock { value -> [UInt8] in
                    guard !value.closed else { return [] }
                    value.forwardingFrames = true
                    let bytes = value.pendingUpgradeBytes
                    value.pendingUpgradeBytes = []
                    return bytes
                }
                // Re-enter at the head so buffered and subsequent network bytes
                // traverse the same decoder, in their original receive order.
                if !buffered.isEmpty {
                    channel.pipeline.fireChannelRead(NIOAny(channel.allocator.buffer(bytes: buffered)))
                }
            }.get()
            state.withLock { $0.handshakeDeadline?.cancel(); $0.handshakeDeadline = nil }
            let heartbeat = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(20))
                        guard !self.state.withLock({ $0.closed }),
                              ProcessInfo.processInfo.systemUptime - self.state.withLock({ $0.lastInbound }) < 70 else {
                            channel.close(promise: nil); return
                        }
                        try await Self.writeFrame(opcode: 9, payload: [], channel: channel).get()
                    } catch { channel.close(promise: nil); return }
                }
            }
            state.withLock { value in
                if value.closed { heartbeat.cancel() } else { value.heartbeat = heartbeat }
            }
        } catch {
            if !state.withLock({ $0.upgraded }) {
                let failure = machineUpgradeFailurePrelude(.failure(error)) ?? "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
                _ = try? await Self.writeRaw(failure, channel: channel)
            }
            channel.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let startup = state.withLock { value in
            value.closed = true; value.heartbeat?.cancel(); value.heartbeat = nil
            value.handshakeDeadline?.cancel(); value.handshakeDeadline = nil
            return value.startup
        }
        Task {
            await startup?.value
            if let machine = self.state.withLock({ $0.authenticated }) {
                await self.registry.disconnect(machineId: machine.id, epoch: self.epoch)
            }
            // Drain the one admitted commit before offline/new-online ordering.
            // Queued tasks observe closed and skip work; the NIO loop never waits.
            let messages = self.state.withLock { $0.messages }
            await messages?.value
            if let machine = self.state.withLock({ $0.committed }) {
                do { if let status = self.status { try await status(machine, false) } }
                catch { await self.registry.statusCommitFailed(machineId: machine.id) }
                self.legacyStatus?(machine, false)
            }
            await self.registry.finishTransport(epoch: self.epoch)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }

    private static func writeRaw(_ text: String, channel: any Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count); buffer.writeString(text)
        try await channel.writeAndFlush(buffer).get()
    }
    private static func write(json: String, channel: any Channel) async throws {
        try await writeFrame(opcode: 1, payload: Array(json.utf8), channel: channel).get()
    }
    private static func writeFrame(opcode: UInt8, payload: [UInt8], channel: any Channel) -> EventLoopFuture<Void> {
        MachineCommandWebSocket.write(opcode: opcode, payload: payload, channel: channel)
    }
}
