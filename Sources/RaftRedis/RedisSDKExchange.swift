import Logging
import NIOCore
import NIOPosix
@preconcurrency import RediStack

/// One SDK connection per operation, with no reconnect, pool or mutation replay.
struct RedisSDKExchange: Sendable {
    let configuration: RedisConfiguration
    let eventLoop: any EventLoop

    func execute(_ arguments: [[UInt8]]) async throws -> RedisReply {
        // Use the library encoder for exact command budgets before connecting.
        _ = try RedisRESP.command(arguments, maximumBytes: configuration.maximumCommandBytes)
        if let auth = configuration.authenticationArguments {
            _ = try RedisRESP.command(auth, maximumBytes: configuration.maximumCommandBytes)
        }
        if configuration.database != 0 {
            _ = try RedisRESP.command(selectArguments, maximumBytes: configuration.maximumCommandBytes)
        }
        let lifetime = RedisSDKLifetime(eventLoop: eventLoop, commandTimeout: configuration.commandTimeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            lifetime.begin(connectTimeout: configuration.connectTimeout)
            start(arguments, lifetime: lifetime)
            let result = try await lifetime.promise.futureResult.get()
            try Task.checkCancellation()
            return result
        } onCancel: {
            lifetime.finish(.failure(CancellationError()))
        }
    }

    private var selectArguments: [[UInt8]] {
        [Array("SELECT".utf8), Array(String(configuration.database).utf8)]
    }

    private func start(_ arguments: [[UInt8]], lifetime: RedisSDKLifetime) {
        let bootstrap = ClientBootstrap.makeRedisTCPClient(group: eventLoop)
            .connectTimeout(configuration.connectTimeout)
            .channelInitializer { channel in
                lifetime.register(channel)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RedisSDKByteBudget(
                        maximumBytes: configuration.maximumResponseBytes, lifetime: lifetime
                    ))
                }.flatMap {
                    channel.pipeline.addBaseRedisHandlers()
                }
            }
        // The SDK address initializer resolves synchronously. Keep that work off
        // event loops, under the same cancellable connection deadline.
        NIOThreadPool.singleton.runIfActive(eventLoop: eventLoop) {
            try SocketAddress.makeAddressResolvingHost(configuration.host, port: configuration.port)
        }.flatMap { address -> EventLoopFuture<RedisReply> in
            guard lifetime.isPending else { return eventLoop.makeFailedFuture(CancellationError()) }
            do {
                let logger = Logger(label: "RaftRedis", factory: { _ in SwiftLogNoOpLogHandler() })
                // Authentication is sent through the SDK below so every startup
                // failure has the same explicit connection cleanup as a command.
                let sdkConfiguration = try RedisConnection.Configuration(address: address, defaultLogger: logger)
                return RedisConnection.make(
                    configuration: sdkConfiguration, boundEventLoop: eventLoop, configuredTCPClient: bootstrap
                ).flatMap { connection in
                    exchange(connection, arguments: arguments, lifetime: lifetime)
                }
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }.whenComplete { result in
            lifetime.finish(result.mapError { RedisRESP.failure($0) })
        }
    }

    private func exchange(
        _ connection: RedisConnection, arguments: [[UInt8]], lifetime: RedisSDKLifetime
    ) -> EventLoopFuture<RedisReply> {
        var ready = eventLoop.makeSucceededVoidFuture()
        if let auth = configuration.authenticationArguments {
            ready = ready.flatMap {
                send(connection, arguments: auth, lifetime: lifetime).flatMapThrowing { value in
                    try requireOK(value)
                }
            }
        }
        if configuration.database != 0 {
            ready = ready.flatMap {
                send(connection, arguments: selectArguments, lifetime: lifetime).flatMapThrowing { value in
                    try requireOK(value)
                }
            }
        }
        return ready.flatMap {
            send(connection, arguments: arguments, lifetime: lifetime)
        }.flatMapThrowing { value in
            try RedisRESP.reply(value, maximumBytes: configuration.maximumResponseBytes)
        }.flatMap { reply in
            connection.close().map { reply }
        }.flatMapError { error in
            // On a timeout/cancellation the lifetime already closed the actual
            // channel; normal SDK errors close an otherwise idle connection here.
            connection.close().flatMapThrowing { throw RedisRESP.failure(error) }
        }
    }

    private func send(
        _ connection: RedisConnection, arguments: [[UInt8]], lifetime: RedisSDKLifetime
    ) -> EventLoopFuture<RESPValue> {
        guard lifetime.isPending else { return eventLoop.makeFailedFuture(CancellationError()) }
        do {
            let (command, values) = try RedisRESP.command(arguments, maximumBytes: configuration.maximumCommandBytes)
            return connection.send(command: command, with: values)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }

    private func requireOK(_ value: RESPValue) throws {
        guard try RedisRESP.reply(value, maximumBytes: configuration.maximumResponseBytes) == .simpleString("OK")
        else { throw RedisError.unexpectedResponse }
    }
}
