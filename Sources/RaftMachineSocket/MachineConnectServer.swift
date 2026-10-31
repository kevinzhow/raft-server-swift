import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import RaftConnectAuth

/// Listens for the raw `/daemon/connect` upgrade.
/// 401 and 500 bytes come from `machineUpgradeFailurePrelude`.
/// An accepted handshake is `101` plus one unmasked `machine:context` text frame.
public final class MachineConnectServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    public let port: Int

    fileprivate init(group: MultiThreadedEventLoopGroup, channel: any Channel, port: Int) {
        self.group = group
        self.channel = channel
        self.port = port
    }

    public static func start(
        lookup: any MachineCredentialLooking,
        capabilities: [String] = [serverCapabilityRuntimeDetectionAsyncV1],
        host: String = "127.0.0.1",
        port: Int = 0,
        onStatusChange: (@Sendable (MatchedMachine, Bool) -> Void)? = nil
    ) async throws -> MachineConnectServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes))).flatMap {
                    channel.pipeline.addHandler(ConnectHandler(
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
            return MachineConnectServer(group: group, channel: channel, port: port)
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

public enum MachineConnectError: Error {
    case missingPort
}

private final class ConnectHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer

    private let lookup: any MachineCredentialLooking
    private let capabilities: [String]
    private let onStatusChange: (@Sendable (MatchedMachine, Bool) -> Void)?
    private var responded = false
    private var acceptedMachine: MatchedMachine?

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
        guard case .head(let head) = unwrapInboundIn(data), !responded else { return }
        responded = true
        let uri = head.uri
        let authorization = head.headers.first(name: "authorization")
        let host = head.headers.first(name: "host")
        let websocketKey = head.headers.first(name: "sec-websocket-key")
        let lookup = self.lookup
        let capabilities = self.capabilities
        let onStatusChange = self.onStatusChange
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
                if let machine = outcome.machine {
                    self.acceptedMachine = machine
                    onStatusChange?(machine, true)
                }
                var buffer = channel.allocator.buffer(capacity: outcome.bytes.count)
                buffer.writeBytes(outcome.bytes)
                let write = channel.writeAndFlush(buffer)
                if closeAfter {
                    write.whenComplete { _ in channel.close(promise: nil) }
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let acceptedMachine {
            onStatusChange?(acceptedMachine, false)
            self.acceptedMachine = nil
        }
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
                return MachineConnectOutcome(bytes: Array(prelude.utf8) + websocketTextFrame(context), machine: machine)
            }
        } catch {
            return MachineConnectOutcome(bytes: Array((machineUpgradeFailurePrelude(.failure(error)) ?? "").utf8), machine: nil)
        }
    }
}

private struct MachineConnectOutcome {
    var bytes: [UInt8]
    var machine: MatchedMachine?
}
