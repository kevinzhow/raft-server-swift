import Foundation
import PostgresNIO

/// The explicit B2 database probe. `DATABASE_URL` is the only switch: with no
/// URL the server keeps the in-memory store and `/health` stays 503. When a URL
/// is present, `/health` runs `SELECT 1` on a short-lived Postgres connection.
public struct DatabaseHealth: Sendable {
    public let databaseURL: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(databaseURL: environment["DATABASE_URL"])
    }

    public init(databaseURL: String?) {
        let trimmed = databaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.databaseURL = trimmed.isEmpty ? nil : trimmed
    }

    public var isConfigured: Bool { databaseURL != nil }

    public func ping() async throws {
        guard let databaseURL else { throw DatabaseHealthError.notConfigured }
        var configuration = try Self.configuration(from: databaseURL)
        configuration.options.connectTimeout = .seconds(3)
        let logger = Logger(label: "raft.health")
        let connection = try await PostgresConnection.connect(
            configuration: configuration,
            id: 1,
            logger: logger
        )
        do {
            for try await _ in try await connection.query("SELECT 1", logger: logger) {}
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }

    static func configuration(from raw: String) throws -> PostgresConnection.Configuration {
        guard let components = URLComponents(string: raw),
              let host = components.host, !host.isEmpty,
              components.scheme == "postgres" || components.scheme == "postgresql"
        else {
            throw DatabaseHealthError.invalidURL
        }
        let query = components.queryItems ?? []
        if query.contains(where: { $0.name == "sslmode" && $0.value != "disable" }) {
            throw DatabaseHealthError.tlsRequiresConfiguration
        }
        let username = components.user?.removingPercentEncoding ?? "postgres"
        let password = components.password?.removingPercentEncoding
        let path = components.path
        let database = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return PostgresConnection.Configuration(
            host: host,
            port: components.port ?? 5432,
            username: username,
            password: password,
            database: database.isEmpty ? nil : database,
            tls: .disable
        )
    }
}

public enum DatabaseHealthError: Error, Equatable, Sendable {
    case notConfigured
    case invalidURL
    case tlsRequiresConfiguration
}
