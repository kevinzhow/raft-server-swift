import Foundation
import NIOCore
import NIOPosix
import NIOSSL

public enum PersistentDaemonError: Error, Sendable, Equatable {
    case invalidURL, unsupportedScheme, protocolViolation, disconnected, receiveBufferFull
    case unsupportedExecution, receiptConflict, receiptIndeterminate
}

/// A real duplex session. The message callback must route commands to a real
/// runtime; this transport never manufactures an ACK or a process outcome.
public actor PersistentDaemonSession {
    public typealias Receiver = @Sendable (String, PersistentDaemonSession) async throws -> Void
    public nonisolated let handshake: DaemonHandshake
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let inbound: PersistentDaemonInboundState
    private let closedSignal: AsyncStream<Void>
    private let closedContinuation: AsyncStream<Void>.Continuation
    private var consumer: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var closing = false

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel,
                 inbound: PersistentDaemonInboundState, handshake: DaemonHandshake) {
        self.group = group; self.channel = channel; self.inbound = inbound; self.handshake = handshake
        let signal = AsyncStream<Void>.makeStream()
        closedSignal = signal.stream; closedContinuation = signal.continuation
    }

    public static func connect(
        serverURL: URL, apiKey: String, timeout: Duration = .seconds(30),
        onMessage: @escaping Receiver
    ) async throws -> PersistentDaemonSession {
        guard let components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, ["", "/", "/daemon/connect"].contains(components.path) else {
            throw PersistentDaemonError.invalidURL
        }
        guard ["http", "https", "ws", "wss"].contains(scheme) else { throw PersistentDaemonError.unsupportedScheme }
        let secure = scheme == "https" || scheme == "wss"
        let port = components.port ?? (secure ? 443 : 80)
        guard (1...65_535).contains(port), !apiKey.isEmpty else { throw PersistentDaemonError.invalidURL }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = try daemonUpgradeRequest(host: host, port: port, apiKey: apiKey,
                                              keyPlacement: .authorizationHeader, websocketKey: key)
        // Full certificate and hostname verification; TLS never falls back to TCP.
        let tls: NIOSSLContext?
        if secure { tls = try NIOSSLContext(configuration: .makeClientConfiguration()) }
        else { tls = nil }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bridge = PersistentDaemonInboundState(clientKey: key, loop: group.next())
        var connected: (any Channel)?
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            bridge.fail(DaemonConnectError.timedOut)
        }
        do {
            let parts = timeout.components
            let millis = max(1, parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
            let channel = try await ClientBootstrap(group: group)
                .connectTimeout(.milliseconds(millis))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        if let tls {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: host))
                        }
                        try channel.pipeline.syncOperations.addHandler(PersistentDaemonInboundHandler(state: bridge))
                    }
                }.connect(host: host, port: port).get()
            connected = channel; bridge.attach(channel)
            var buffer = channel.allocator.buffer(capacity: request.utf8.count); buffer.writeString(request)
            try await channel.writeAndFlush(buffer).get()
            let handshake = try await bridge.ready.futureResult.get()
            if let error = bridge.failure { throw error }
            guard channel.isActive else { throw PersistentDaemonError.disconnected }
            timer.cancel()
            let session = PersistentDaemonSession(group: group, channel: channel, inbound: bridge, handshake: handshake)
            await session.start(onMessage: onMessage)
            return session
        } catch {
            timer.cancel(); bridge.fail(error)
            if let connected { _ = try? await connected.close().get() }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func start(onMessage: @escaping Receiver) {
        consumer = Task {
            do {
                for try await json in self.inbound.messages {
                    try Task.checkCancellation()
                    try await onMessage(json, self)
                }
            } catch { self.inbound.fail(error) }
            await self.close()
        }
        heartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(20))
                    guard self.inbound.secondsSinceInbound < 70 else { await self.close(); return }
                    try await self.sendFrame(opcode: 9, payload: [])
                } catch { await self.close(); return }
            }
        }
    }

    /// JSON must already use the upstream MachineToServerMessage schema.
    public func send(json: String) async throws {
        struct MessageType: Decodable { let type: String }
        _ = try JSONDecoder().decode(MessageType.self, from: Data(json.utf8))
        guard json.utf8.count <= PersistentWebSocket.maximumMessageBytes else { throw PersistentDaemonError.protocolViolation }
        try await sendFrame(opcode: 1, payload: Array(json.utf8))
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8]) async throws {
        guard !closing, channel.isActive else { throw PersistentDaemonError.disconnected }
        var buffer = channel.allocator.buffer(capacity: payload.count + 16)
        buffer.writeBytes(PersistentWebSocket.encode(opcode: opcode, payload: payload, masked: true))
        try await channel.writeAndFlush(buffer).get()
    }

    public func terminalError() -> (any Error)? { inbound.failure }

    public func waitUntilClosed() async {
        for await _ in closedSignal { }
    }

    public func close() async {
        guard !closing else { return }
        closing = true
        heartbeat?.cancel(); heartbeat = nil
        consumer?.cancel(); consumer = nil
        if channel.isActive {
            var buffer = channel.allocator.buffer(capacity: 8)
            buffer.writeBytes(PersistentWebSocket.encode(opcode: 8, payload: [3, 232], masked: true))
            _ = try? await channel.writeAndFlush(buffer).get()
            _ = try? await channel.close().get()
        }
        inbound.fail(PersistentDaemonError.disconnected)
        try? await group.shutdownGracefully()
        closedContinuation.finish()
    }
}

/// Reconnect creates a fresh authenticated session, with bounded backoff.
/// Cancellation closes the current connection instead of leaving a listener alive.
public enum PersistentDaemonConnection {
    public static func run(
        serverURL: URL, apiKey: String, timeout: Duration = .seconds(30),
        onConnect: @escaping @Sendable (PersistentDaemonSession) async throws -> Void = { _ in },
        onMessage: @escaping PersistentDaemonSession.Receiver,
        onFailure: @escaping @Sendable (any Error) async -> Void = { _ in }
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let session = try await PersistentDaemonSession.connect(serverURL: serverURL, apiKey: apiKey, timeout: timeout, onMessage: onMessage)
                do { try await onConnect(session) }
                catch { await session.close(); throw error }
                attempt = 0
                await withTaskCancellationHandler {
                    await session.waitUntilClosed()
                } onCancel: { Task { await session.close() } }
                if !Task.isCancelled, let error = await session.terminalError() { await onFailure(error) }
            } catch { await onFailure(error) }
            guard !Task.isCancelled else { return }
            attempt = min(attempt + 1, 6)
            do { try await Task.sleep(for: .milliseconds(min(30_000, 500 * (1 << attempt)))) }
            catch { return }
        }
    }
}
