import NIOCore
import NIOPosix

/// A RediStack command client. Each operation uses its own authenticated connection.
/// The caller owns any supplied event-loop group; this client never shuts that group down.
/// Commands are not retried: a timeout or disconnect can follow a committed mutation.
/// Subscriptions, connection-scoped transactions, pooling and Redis Cluster redirects
/// are deliberately unsupported. Use EVAL for one atomic server-side operation.
public struct RedisClient: Sendable {
    public let configuration: RedisConfiguration
    private let group: any EventLoopGroup

    public init(
        configuration: RedisConfiguration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.configuration = configuration
        self.group = eventLoopGroup
    }

    public func execute(_ arguments: [String]) async throws -> RedisReply {
        try await execute(bytes: arguments.map { Array($0.utf8) })
    }

    /// RediStack encodes every argument as a binary bulk string.
    public func execute(bytes arguments: [[UInt8]]) async throws -> RedisReply {
        try Self.validate(arguments)
        try Task.checkCancellation()
        return try await RedisSDKExchange(configuration: configuration, eventLoop: group.next())
            .execute(arguments)
    }

    private static func validate(_ arguments: [[UInt8]]) throws {
        guard let first = arguments.first, !first.isEmpty, first.count <= 64,
              arguments.count <= 16_384,
              first.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) })
        else { throw RedisError.invalidCommand }
        let command = String(decoding: first, as: UTF8.self).uppercased()
        let connectionModes: Set<String> = [
            "AUTH", "SELECT", "HELLO", "CLIENT", "RESET", "MONITOR",
            "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE",
            "MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH", "READONLY", "READWRITE", "ASKING",
        ]
        guard !connectionModes.contains(command) else { throw RedisError.unsupportedConnectionMode }
    }
}
