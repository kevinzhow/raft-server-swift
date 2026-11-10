import Foundation
import RaftHTTP
import RaftPersistence
import RaftRedis

/// Bootstrap diagnostics name configuration fields, never their values.
enum ProductionStartupError: Error, Sendable, CustomStringConvertible {
    case required(String)
    case invalid(String)
    case unavailable
    case agentExecutionNotConnected

    var description: String {
        switch self {
        case .required(let name): "Required production configuration is missing: \(name)"
        case .invalid(let name): "Invalid production configuration: \(name)"
        case .unavailable: "Production business persistence is unavailable"
        case .agentExecutionNotConnected: "Production agent execution is not connected; listeners remain closed"
        }
    }
}

struct ProductionConfiguration: Sendable {
    let postgres: PostgresPersistenceConfiguration
    let redis: RedisClient
    let searchBucket: RedisPublicSearchBucketStore
    let email: TransactionalEmailConfiguration
    let serverURL: String

    init(environment: [String: String]) throws {
        let jwt = try Self.required("JWT_SECRET", in: environment)
        guard jwt.utf8.count >= 32,
              !jwt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              jwt == jwt.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ProductionStartupError.invalid("JWT_SECRET (at least32 bytes)")
        }
        let credential = try Self.required("CREDENTIAL_ENCRYPTION_KEY", in: environment)
        guard let bytes = Data(base64Encoded: credential), bytes.count == 32,
              bytes.base64EncodedString() == credential else {
            throw ProductionStartupError.invalid("CREDENTIAL_ENCRYPTION_KEY (canonical base64 of32 bytes)")
        }
        postgres = try PostgresPersistenceConfiguration(databaseURL: Self.required("DATABASE_URL", in: environment))
        redis = RedisClient(configuration: try RedisConfiguration(
            url: Self.required("REDIS_URL", in: environment),
            connectTimeout: .milliseconds(250), commandTimeout: .milliseconds(250)
        ))
        searchBucket = try RedisPublicSearchBucketStore(environment: environment)
        email = try TransactionalEmailConfiguration.fromEnvironment(environment)
        let rawServerURL = environment["SERVER_URL"] ?? "https://raft.example.com"
        guard let parts = URLComponents(string: rawServerURL), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw ProductionStartupError.invalid("SERVER_URL (HTTPS)")
        }
        serverURL = rawServerURL.hasSuffix("/") ? String(rawServerURL.dropLast()) : rawServerURL
    }

    static func required(_ name: String, in environment: [String: String]) throws -> String {
        guard let value = environment[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProductionStartupError.required(name)
        }
        return value
    }
}

enum ProductionBootstrap {
    /// This branch runs before Vapor sees any CLI argument. Migration needs only
    /// DATABASE_URL, opens no listener, and does not construct mutable owners.
    static func migrateIfRequested(arguments: [String], environment: [String: String]) async throws -> Bool {
        guard arguments.dropFirst().contains("--migrate-only") else { return false }
        let configuration = try PostgresPersistenceConfiguration(
            databaseURL: ProductionConfiguration.required("DATABASE_URL", in: environment)
        )
        try await PostgresPersistence.migrate(configuration: configuration)
        FileHandle.standardOutput.write(Data("raft-server schema migration succeeded\n".utf8))
        return true
    }

    static func ping(runtime: BusinessPersistenceRuntime, redis: RedisClient) async throws {
        guard await runtime.readiness().isReady else { throw ProductionStartupError.unavailable }
        try await redis.ping()
        guard runtime.readinessSnapshot.isReady else { throw ProductionStartupError.unavailable }
    }
}
