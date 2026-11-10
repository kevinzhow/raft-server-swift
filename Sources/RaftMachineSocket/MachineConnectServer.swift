import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RaftConnectAuth
import Synchronization

/// Listens for the raw `/daemon/connect` upgrade.
/// 401 and 500 bytes come from `machineUpgradeFailurePrelude`.
/// An accepted handshake is `101` plus one unmasked `machine:context` text frame.
public final class MachineConnectServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let commandRegistry: MachineCommandRegistry?
    public let port: Int

    fileprivate init(group: MultiThreadedEventLoopGroup, channel: any Channel, port: Int, commandRegistry: MachineCommandRegistry? = nil) {
        self.group = group
        self.channel = channel
        self.port = port
        self.commandRegistry = commandRegistry
    }

    public static func start(
        lookup: any MachineCredentialLooking,
        capabilities: [String] = [serverCapabilityRuntimeDetectionAsyncV1],
        host: String = "127.0.0.1",
        port: Int = 0,
        onStatusChange: (@Sendable (MatchedMachine, Bool) -> Void)? = nil,
        onStatusCommitted: (@Sendable (MatchedMachine, Bool) async throws -> Void)? = nil,
        commandRegistry: MachineCommandRegistry? = nil
    ) async throws -> MachineConnectServer {
        let registry = commandRegistry ?? (onStatusCommitted == nil ? nil : MachineCommandRegistry())
        let capabilities = machineIngressCapabilities(
            capabilities, durable: registry?.durableOutcomeAcknowledgementsEnabled == true
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.preconditionInEventLoop()
                if let registry {
                    let handler = MachineCommandConnectionHandler(
                        lookup: lookup, capabilities: capabilities, registry: registry,
                        status: onStatusCommitted, legacyStatus: onStatusChange
                    )
                    return channel.eventLoop.makeFutureWithTask {
                        try await registry.openTransport(epoch: handler.epoch, channel: channel)
                    }.flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(handler)
                        }
                    }.flatMapError { error in
                        channel.eventLoop.makeFutureWithTask {
                            await registry.finishTransport(epoch: handler.epoch)
                            throw error
                        }
                    }
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes))
                    )
                    try channel.pipeline.syncOperations.addHandler(ConnectHandler(
                        lookup: lookup,
                        capabilities: capabilities,
                        onStatusChange: onStatusChange
                    ))
                }
            }
        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            guard let port = channel.localAddress?.port else {
                try await channel.close()
                try await group.shutdownGracefully()
                throw MachineConnectError.missingPort
            }
            return MachineConnectServer(group: group, channel: channel, port: port, commandRegistry: registry)
        } catch {
            if let registry { await registry.close() }
            try await group.shutdownGracefully()
            throw error
        }
    }

    public func close() async throws {
        // Stop accepts first, then close children and await their offline commits.
        try await channel.close()
        if let commandRegistry { await commandRegistry.close() }
        try await group.shutdownGracefully()
    }
}

public enum MachineConnectError: Error {
    case missingPort
}

/// Shared only across the async credential lookup and the NIO event loop.
/// Mutable connection state is checked Sendable; status callbacks and channel
/// writes still run on the channel's event loop, after releasing the Mutex.
private final class ConnectState: Sendable {
    private struct State: Sendable {
        var responded = false
        var closed = false
        var acceptedMachine: MatchedMachine?
    }

    private let state = Mutex(State())

    func claimResponse() -> Bool {
        state.withLock { state in
            guard !state.responded, !state.closed else { return false }
            state.responded = true
            return true
        }
    }

    func complete(machine: MatchedMachine?) -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            state.acceptedMachine = machine
            return true
        }
    }

    func disconnect() -> MatchedMachine? {
        state.withLock { state in
            state.closed = true
            let machine = state.acceptedMachine
            state.acceptedMachine = nil
            return machine
        }
    }
}

private final class ConnectHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer

    private let lookup: any MachineCredentialLooking
    private let capabilities: [String]
    private let onStatusChange: (@Sendable (MatchedMachine, Bool) -> Void)?
    private let connection = ConnectState()

    init(
        lookup: any MachineCredentialLooking,
        capabilities: [String],
        onStatusChange: (@Sendable (MatchedMachine, Bool) -> Void)?
    ) {
        self.lookup = lookup
        self.capabilities = capabilities
        self.onStatusChange = onStatusChange
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.eventLoop.preconditionInEventLoop()
        guard case .head(let head) = unwrapInboundIn(data), connection.claimResponse() else { return }
        let uri = head.uri
        let authorization = head.headers.first(name: "authorization")
        let host = head.headers.first(name: "host")
        let websocketKey = head.headers.first(name: "sec-websocket-key")
        let lookup = self.lookup
        let capabilities = self.capabilities
        let onStatusChange = self.onStatusChange
        let connection = self.connection
        let loop = context.eventLoop
        let channel = context.channel
        Task {
            let outcome = await Self.responseBytes(
                uri: uri,
                authorization: authorization,
                host: host,
                websocketKey: websocketKey,
                capabilities: capabilities,
                lookup: lookup
            )
            let closeAfter = outcome.bytes.starts(with: Array("HTTP/1.1 101".utf8)) == false
            loop.execute {
                loop.preconditionInEventLoop()
                guard connection.complete(machine: outcome.machine) else { return }
                if let machine = outcome.machine {
                    onStatusChange?(machine, true)
                }
                var buffer = channel.allocator.buffer(capacity: outcome.bytes.count)
                buffer.writeBytes(outcome.bytes)
                let write = channel.writeAndFlush(buffer)
                if closeAfter {
                    write.whenComplete { _ in channel.close(promise: nil) }
                } else if let json = outcome.contextJSON {
                    write.whenComplete { result in
                        guard case .success = result else { channel.close(promise: nil); return }
                        // Legacy handshake channels remain independent, and their
                        // exact HTTP prelude is flushed before the frame encoder.
                        do {
                            try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
                            MachineCommandWebSocket.write(opcode: 1, payload: Array(json.utf8), channel: channel)
                                .whenFailure { _ in channel.close(promise: nil) }
                        } catch { channel.close(promise: nil) }
                    }
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.eventLoop.preconditionInEventLoop()
        if let acceptedMachine = connection.disconnect() {
            onStatusChange?(acceptedMachine, false)
        }
        context.fireChannelInactive()
    }

    private static func responseBytes(
        uri: String,
        authorization: String?,
        host: String?,
        websocketKey: String?,
        capabilities: [String],
        lookup: any MachineCredentialLooking
    ) async -> MachineConnectOutcome {
        let parts = URLComponents(string: uri.hasPrefix("/") ? "http://localhost\(uri)" : uri)
        let path = parts?.path ?? uri
        guard path == "/daemon/connect" else {
            return MachineConnectOutcome(bytes: Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), machine: nil)
        }
        let queryKey = parts?.queryItems?.first { $0.name == "key" }?.value
        let apiKey = presentedApiKey(authorization: authorization, queryKey: queryKey)
        do {
            let decision = try await UpgradeAuth.resolve(apiKey: apiKey, hostHeader: host, lookup: lookup)
            switch decision.result {
            case .rejected:
                return MachineConnectOutcome(bytes: Array((machineUpgradeFailurePrelude(.success(decision.result)) ?? "").utf8), machine: nil)
            case .accepted(_, let machine, _):
                guard let websocketKey else {
                    return MachineConnectOutcome(bytes: Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8), machine: nil)
                }
                let prelude = machineUpgradeSwitchingProtocols(clientKey: websocketKey, capabilities: capabilities)
                let context = machineContextJSON(
                    machineId: machine.id,
                    serverId: machine.serverId,
                    capabilities: capabilities
                )
                return MachineConnectOutcome(bytes: Array(prelude.utf8), machine: machine, contextJSON: context)
            }
        } catch {
            return MachineConnectOutcome(bytes: Array((machineUpgradeFailurePrelude(.failure(error)) ?? "").utf8), machine: nil)
        }
    }
}

private struct MachineConnectOutcome: Sendable {
    var bytes: [UInt8]
    var machine: MatchedMachine?
    var contextJSON: String? = nil
}
