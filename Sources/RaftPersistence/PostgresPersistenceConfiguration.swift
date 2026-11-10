import Foundation
import NIOSSL
import PostgresNIO

/// DATABASE_URL is parsed once. This type has a redacted description and does not
/// expose credentials. TLS defaults to certificate and hostname verification.
public struct PostgresPersistenceConfiguration: Sendable, CustomStringConvertible {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String?
    private let database: String
    private let sslMode: String
    private let rootCertificate: String?
    private let connectSeconds: Int64
    private let statementMilliseconds: Int
    private let lockMilliseconds: Int
    public let maximumConnections: Int
    public let operationTimeout: Duration

    public var description: String { "PostgresPersistenceConfiguration(redacted)" }

    public init(databaseURL: String, maximumConnections: Int = 16) throws {
        guard (1...128).contains(maximumConnections),
              Self.hasValidPercentEscapes(databaseURL),
              let url = URLComponents(string: databaseURL),
              ["postgres", "postgresql"].contains(url.scheme ?? ""),
              let rawHost = url.host, !rawHost.isEmpty,
              let encodedUser = url.percentEncodedUser,
              let username = encodedUser.removingPercentEncoding, !username.isEmpty,
              url.fragment == nil else {
            throw PersistenceError.invalidConfiguration("DATABASE_URL")
        }
        let path = url.percentEncodedPath
        guard path.hasPrefix("/"), !path.dropFirst().contains("/"),
              let database = String(path.dropFirst()).removingPercentEncoding,
              !database.isEmpty, !username.utf8.contains(0), !database.utf8.contains(0),
              !rawHost.utf8.contains(0), (1...65535).contains(url.port ?? 5432) else {
            throw PersistenceError.invalidConfiguration("database, username or endpoint")
        }
        let password: String?
        if let encoded = url.percentEncodedPassword {
            guard let decoded = encoded.removingPercentEncoding, !decoded.utf8.contains(0) else {
                throw PersistenceError.invalidConfiguration("password encoding")
            }
            password = decoded
        } else { password = nil }
        let allowed = Set(["sslmode", "sslrootcert", "connect_timeout", "statement_timeout", "lock_timeout"])
        var options: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard allowed.contains(item.name), options[item.name] == nil, let value = item.value else {
                throw PersistenceError.invalidConfiguration("duplicate or unsupported URL option")
            }
            options[item.name] = value
        }
        let sslMode = options["sslmode"] ?? "verify-full"
        guard ["disable", "require", "verify-ca", "verify-full"].contains(sslMode),
              options["sslrootcert"] == nil || sslMode == "verify-ca" || sslMode == "verify-full" else {
            throw PersistenceError.invalidConfiguration("sslmode or sslrootcert")
        }
        func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = Int(options[name] ?? String(fallback)), range.contains(value) else {
                throw PersistenceError.invalidConfiguration(name)
            }
            return value
        }
        let connect = try integer("connect_timeout", default: 5, range: 1...300)
        let statement = try integer("statement_timeout", default: 30_000, range: 1...300_000)
        let lock = try integer("lock_timeout", default: 10_000, range: 1...300_000)
        self.host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast()) : rawHost
        self.port = url.port ?? 5432
        self.username = username
        self.password = password
        self.database = database
        self.sslMode = sslMode
        self.rootCertificate = options["sslrootcert"]
        self.connectSeconds = Int64(connect)
        self.statementMilliseconds = statement
        self.lockMilliseconds = lock
        self.maximumConnections = maximumConnections
        self.operationTimeout = .seconds(Int64(connect + (statement + 999) / 1000 + 5))
    }

    func connectionConfiguration() throws -> PostgresConnection.Configuration {
        let tls: PostgresConnection.Configuration.TLS
        if sslMode == "disable" { tls = .disable }
        else { tls = .require(try NIOSSLContext(configuration: tlsConfiguration())) }
        var result = PostgresConnection.Configuration(
            host: host, port: port, username: username, password: password, database: database, tls: tls
        )
        result.options.connectTimeout = .seconds(connectSeconds)
        result.options.additionalStartupParameters = startupParameters
        return result
    }

    func clientConfiguration() -> PostgresClient.Configuration {
        var result = PostgresClient.Configuration(
            host: host, port: port, username: username, password: password, database: database,
            tls: sslMode == "disable" ? .disable : .require(tlsConfiguration())
        )
        result.options.connectTimeout = .seconds(connectSeconds)
        result.options.minimumConnections = 0
        result.options.maximumConnections = maximumConnections
        result.options.additionalStartupParameters = startupParameters
        return result
    }

    private var startupParameters: [(String, String)] {
        [("application_name", "raft-server"),
         ("statement_timeout", String(statementMilliseconds)),
         ("lock_timeout", String(lockMilliseconds)),
         ("idle_in_transaction_session_timeout", String(statementMilliseconds))]
    }

    private func tlsConfiguration() -> TLSConfiguration {
        var tls = TLSConfiguration.makeClientConfiguration()
        switch sslMode {
        case "require": tls.certificateVerification = .none
        case "verify-ca": tls.certificateVerification = .noHostnameVerification
        default: tls.certificateVerification = .fullVerification
        }
        if let rootCertificate { tls.trustRoots = .file(rootCertificate) }
        return tls
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func hex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
}
