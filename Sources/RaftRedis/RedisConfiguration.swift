import Foundation
import NIOCore

/// Connection policy for the RediStack command adapter. Descriptions never contain credentials.
public struct RedisConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let host: String
    public let port: Int
    public let database: Int
    public let connectTimeout: TimeAmount
    public let commandTimeout: TimeAmount
    public let maximumResponseBytes: Int
    public let maximumCommandBytes: Int
    private let username: String?
    private let password: String?

    /// Supports redis://[username:password@]host[:port][/database].
    /// rediss:// and URL query options are rejected; this client never downgrades TLS.
    public init(
        url: String,
        connectTimeout: TimeAmount = .seconds(3),
        commandTimeout: TimeAmount = .seconds(3),
        maximumResponseBytes: Int = 8 * 1024 * 1024,
        maximumCommandBytes: Int = 8 * 1024 * 1024
    ) throws {
        guard let parts = URLComponents(string: url) else { throw RedisError.invalidConfiguration }
        if parts.scheme?.lowercased() == "rediss" { throw RedisError.tlsNotSupported }
        guard parts.scheme?.lowercased() == "redis",
              let rawHost = parts.host, !rawHost.isEmpty,
              parts.query == nil, parts.fragment == nil,
              connectTimeout.nanoseconds > 0, commandTimeout.nanoseconds > 0,
              (64...64 * 1024 * 1024).contains(maximumResponseBytes),
              (64...64 * 1024 * 1024).contains(maximumCommandBytes)
        else { throw RedisError.invalidConfiguration }
        let port = parts.port ?? 6379
        guard (1...65535).contains(port) else { throw RedisError.invalidConfiguration }
        let path = parts.percentEncodedPath
        let databaseText = path.isEmpty || path == "/" ? "0" : String(path.dropFirst())
        guard path.isEmpty || path.hasPrefix("/"),
              !databaseText.isEmpty, databaseText.utf8.allSatisfy({ (48...57).contains($0) }),
              let database = Int(databaseText), database <= Int(Int32.max)
        else { throw RedisError.invalidConfiguration }
        let user = try Self.decode(parts.percentEncodedUser)
        let password = try Self.decode(parts.percentEncodedPassword)
        guard user?.isEmpty != false || password != nil else { throw RedisError.invalidConfiguration }
        self.host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast()) : rawHost
        self.port = port
        self.database = database
        self.username = user?.isEmpty == false ? user : nil
        self.password = password
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumCommandBytes = maximumCommandBytes
    }

    /// REDIS_URL must be present. A production caller must not select a memory fallback.
    public init(environment: [String: String]) throws {
        guard let url = environment["REDIS_URL"], !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RedisError.notConfigured }
        try self.init(url: url)
    }

    public var description: String {
        "RedisConfiguration(host: \(host), port: \(port), database: \(database), credentials: \(password == nil ? "absent" : "redacted"), TLS: disabled)"
    }

    public var debugDescription: String { description }

    var authenticationArguments: [[UInt8]]? {
        guard let password else { return nil }
        return (["AUTH"] + (username.map { [$0] } ?? []) + [password]).map { Array($0.utf8) }
    }

    private static func decode(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let decoded = value.removingPercentEncoding else { throw RedisError.invalidConfiguration }
        return decoded
    }
}

/// Errors intentionally omit the URL, command arguments and authentication material.
public enum RedisError: Error, Equatable, Sendable {
    case notConfigured
    case invalidConfiguration
    case tlsNotSupported
    case invalidCommand
    case unsupportedConnectionMode
    case commandTooLarge
    case responseTooLarge
    case malformedResponse
    case truncatedResponse
    case unexpectedResponse
    case connectionClosed
    case connectionFailed
    case connectionTimedOut
    /// A mutation may already have committed. The client never retries it automatically.
    case commandTimedOut
    /// Only the bounded error code is exposed, not the server's arbitrary response text.
    case serverError(code: String)
}
