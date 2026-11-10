import Crypto
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Logging
import PostgresNIO
@testable import RaftHTTP
import RaftPersistence
import Testing

/// Real-PostgreSQL acceptance for the 2026-11-10 production outage.
///
/// A browser reload aborts its in-flight fetches. The pinned HTTP server
/// cancels the request task on that disconnect, so the request task no longer
/// owns the fenced commit. Before the fix, that cancellation propagated into
/// the writer transaction, the driver closed the writer connection with the
/// transaction open (PostgreSQL logs `unexpected EOF on client connection with
/// an open transaction`) and the runtime failed admission closed permanently.
///
/// Run this filter alone in a fresh test process: the shared transaction domain
/// is a one-way production policy for the lifetime of that process.
///
/// Required environment:
///   RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE=1
///   RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL=<fresh PostgreSQL 17>
///   RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_REDIS_URL=<throwaway Redis>
///   RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_SERVER_BIN=<built RaftServer>
private let businessPGFailClosedEnabled =
    ProcessInfo.processInfo.environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE"] == "1"

@Suite(.serialized) struct BusinessPersistenceFailClosedPostgresTests {
    @Test(.enabled(if: businessPGFailClosedEnabled))
    func cancellingARequestDuringTheFencedCommitDoesNotFailClosedAdmission() async throws {
        let environment = ProcessInfo.processInfo.environment
        let databaseURL = try #require(environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL"])
        let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        let logger = Logger(label: "raft.business-pg-acceptance")

        let accounts = EmailLoginDirectory()
        let bindings = try accounts.makeDurableBindings()
        let runtime = try await BusinessPersistenceRuntime.start(
            configuration: configuration, bindings: bindings
        )
        try await runtime.activate()

        let directConfiguration = try postgresConfiguration(from: databaseURL)
        let control = try await PostgresConnection.connect(
            configuration: directConfiguration, id: 0, logger: logger
        )
        do {
            // Hold the first advisory lock that a fenced CAS takes, so the next
            // command blocks inside its real SQL transaction. Browser aborts
            // happen exactly while such a transaction is in flight.
            let lockID = try firstFencedLockID(bindings)
            try await execute(control, "SELECT pg_advisory_lock(1380001364, \(lockID))", logger: logger)
            let revisionBefore = try await scalarInt(
                control, "SELECT max(revision) FROM raft_persistence.durable_domain_rows", logger: logger
            )
            let writerBefore = try await scalarInt(
                control, "SELECT backend_pid::bigint FROM raft_persistence.writer_control", logger: logger
            )

            let task = Task {
                try await runtime.execute {
                    appendEvent(accounts, type: "blocked-commit")
                }
            }
            let waiting = try await waitForBlockedWriter(control, logger: logger)
            #expect(waiting, "the fenced transaction never reached the advisory lock")

            // A client disconnect cancels the request task while its commit waits.
            task.cancel()
            try await Task.sleep(for: .milliseconds(300))
            #expect(runtime.readinessSnapshot.isReady,
                    "request cancellation must not fail business admission closed")
            #expect(runtime.readinessSnapshot.phase == .active)

            _ = try await scalar(control, "SELECT pg_advisory_unlock(1380001364, \(lockID))", logger: logger)
            let outcome = await task.result
            if case .failure(let error) = outcome {
                Issue.record("cancelled request lost its fenced commit: \(String(describing: error))")
            }

            // The commit that was in flight at cancellation really committed,
            // and the dedicated writer session is still the same live backend.
            let revisionAfter = try await scalarInt(
                control, "SELECT max(revision) FROM raft_persistence.durable_domain_rows", logger: logger
            )
            #expect(revisionAfter > revisionBefore,
                    "the shielded transaction did not commit after the client abort")
            let writerAfter = try await scalarInt(
                control, "SELECT backend_pid::bigint FROM raft_persistence.writer_control", logger: logger
            )
            #expect(writerAfter == writerBefore)
            let writerSessions = try await scalarInt(
                control,
                "SELECT count(*) FROM pg_stat_activity WHERE pid = \(writerBefore)",
                logger: logger
            )
            #expect(writerSessions == 1, "cancellation closed the writer session")

            // Admission is still open for the next real command.
            try await runtime.execute { appendEvent(accounts, type: "after-cancellation") }
            #expect(runtime.readinessSnapshot.isReady)
            let revisionFinal = try await scalarInt(
                control, "SELECT max(revision) FROM raft_persistence.durable_domain_rows", logger: logger
            )
            #expect(revisionFinal > revisionAfter)
        } catch {
            _ = try? await scalar(control, "SELECT pg_advisory_unlock_all()", logger: logger)
            await runtime.close()
            try? await control.close()
            throw error
        }
        await runtime.close()
        try await control.close()
    }

    /// The production composition must not stay alive as a 503-only zombie.
    /// A lost writer lease logs the redacted cause and exits non-zero so the
    /// systemd unit (`Restart=on-failure`) starts a fresh process that claims a
    /// new epoch and reloads every owner from PostgreSQL.
    @Test(.enabled(if: businessPGFailClosedEnabled))
    func writerLeaseLossLogsTheRedactedCauseAndExitsForSupervisorRestart() async throws {
        let environment = ProcessInfo.processInfo.environment
        let databaseURL = try #require(environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL"])
        let redisURL = try #require(environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_REDIS_URL"])
        let serverBinary = try #require(environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_SERVER_BIN"])
        try #require(FileManager.default.isExecutableFile(atPath: serverBinary))
        let logger = Logger(label: "raft.business-pg-supervisor")

        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raft-business-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let logURL = runDirectory.appendingPathComponent("server.log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw BusinessPersistenceFailClosedError.invalidResponse
        }
        let log = try FileHandle(forWritingTo: logURL)

        let ports = try (0..<3).map { _ in try freeLocalPort() }
        let serverEnvironment = try supervisorProductionEnvironment(
            databaseURL: databaseURL, redisURL: redisURL,
            httpPort: ports[0], socketPort: ports[1], daemonPort: ports[2], root: runDirectory
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in serverEnvironment { merged[key] = value }
        process.environment = merged
        process.currentDirectoryURL = runDirectory
        process.standardOutput = log
        process.standardError = log
        try process.run()

        var control: PostgresConnection?
        do {
            try await waitForSupervisorReady(process: process, logURL: logURL)
            let connection = try await PostgresConnection.connect(
                configuration: try postgresConfiguration(from: databaseURL), id: 1, logger: logger
            )
            control = connection
            let writer = try await scalarInt(
                connection,
                "SELECT backend_pid::bigint FROM raft_persistence.writer_control", logger: logger
            )
            _ = try await scalar(
                connection, "SELECT pg_terminate_backend(\(writer))", logger: logger
            )
            let exited = await waitForSupervisorExit(process: process, seconds: 10)
            #expect(exited, "the process stayed alive serving 503 after admission failed closed")
            #expect(process.terminationStatus == 70,
                    "expected exit 70 for the supervisor, got \(process.terminationStatus)")
            let journal = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            #expect(journal.contains("business persistence failed closed"))
            #expect(journal.contains("writer lease"),
                    "the journal must name the lost writer lease without leaking driver details")
            #expect(journal.contains("writerEpoch="))
            if let password = URLComponents(string: databaseURL)?.password, !password.isEmpty {
                #expect(!journal.contains(password), "the journal must not contain the database password")
            }
            #expect(!journal.contains(databaseURL), "the journal must not contain the database URL")
            try await connection.close()
            control = nil
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? await control?.close()
            try? log.close()
            throw error
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? log.close()
    }
}

// MARK: - Published owner mutation

private func appendEvent(_ accounts: EmailLoginDirectory, type: String) {
    accounts.productEventStore.append(RecordedProductEvent(
        subjectType: "user", subjectId: "business-pg-acceptance",
        eventType: type, actorType: "user", actorId: "business-pg-acceptance",
        source: "acceptance", idempotencyKey: nil, metadataJSON: "{}"
    ))
}

// MARK: - Direct PostgreSQL control session

/// Mirrors `PostgresPersistence.lockID`: SHA-256 over `domain + NUL + aggregate`,
/// first four bytes big-endian as a signed 32-bit advisory-lock identity. The
/// transactional lock namespace is asserted by the production CAS itself.
private func firstFencedLockID(_ bindings: [DurableSnapshotBinding]) throws -> Int32 {
    let locks = try bindings.map { binding -> Int32 in
        let ordering = binding.key.domain.rawValue + "\u{0}" + binding.key.aggregateID
        let hash = SHA256.hash(data: Data(ordering.utf8))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int32(bitPattern: value)
    }
    guard let lock = locks.min() else { throw BusinessPersistenceFailClosedError.invalidResponse }
    return lock
}

private func postgresConfiguration(from databaseURL: String) throws -> PostgresConnection.Configuration {
    guard let url = URLComponents(string: databaseURL), let host = url.host,
          let encodedUser = url.percentEncodedUser,
          let username = encodedUser.removingPercentEncoding,
          let encodedPath = url.percentEncodedPath.removingPercentEncoding,
          encodedPath.hasPrefix("/"), encodedPath.count > 1 else {
        throw BusinessPersistenceFailClosedError.invalidDatabaseURL
    }
    let password = url.percentEncodedPassword?.removingPercentEncoding
    let database = String(encodedPath.dropFirst())
    return PostgresConnection.Configuration(
        host: host, port: url.port ?? 5432, username: username, password: password,
        database: database, tls: .disable
    )
}

private func scalar(
    _ connection: PostgresConnection, _ sql: String, logger: Logger
) async throws -> Bool {
    var result = false
    for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {
        result = try row.decode(Bool.self)
    }
    return result
}

private func scalarInt(
    _ connection: PostgresConnection, _ sql: String, logger: Logger
) async throws -> Int64 {
    var result: Int64?
    for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {
        result = try row.decode(Int64.self)
    }
    guard let result else { throw BusinessPersistenceFailClosedError.invalidResponse }
    return result
}

/// Waits until a backend other than this control session is blocked on the
/// fenced advisory lock, i.e. the runtime is inside its real SQL transaction.
private func waitForBlockedWriter(
    _ connection: PostgresConnection, logger: Logger
) async throws -> Bool {
    for _ in 0..<100 {
        if try await scalar(connection, """
            SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE datname = current_database() AND pid <> pg_backend_pid()
                  AND wait_event_type = 'Lock'
                  AND query LIKE '%pg_advisory_xact_lock%'
            )
            """, logger: logger) {
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func execute(
    _ connection: PostgresConnection, _ sql: String, logger: Logger
) async throws {
    for try await _ in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {}
}

// MARK: - Production supervisor process fixture

private func supervisorProductionEnvironment(
    databaseURL: String, redisURL: String, httpPort: Int, socketPort: Int,
    daemonPort: Int, root: URL
) throws -> [String: String] {
    let tmp = root.appendingPathComponent("tmp", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let key = Data(repeating: 0x41, count: 32).base64EncodedString()
    return [
        "NODE_ENV": "production",
        "DATABASE_URL": databaseURL,
        "REDIS_URL": redisURL,
        "JWT_SECRET": "business-pg-supervisor-jwt-secret-0123456789abcdef",
        "CREDENTIAL_ENCRYPTION_KEY": key,
        "RAFT_EMAIL_PROVIDER": "resend",
        "FROM_EMAIL": "raft@slock.test",
        "APP_URL": "https://app.slock.test",
        "RESEND_API_KEY": "re_business_supervisor_throwaway",
        "ATTACHMENT_STORAGE_PROVIDER": "s3",
        "S3_BUCKET": "business-supervisor-attachments",
        "S3_ACCESS_KEY_ID": "businesssupervisoraccess",
        "S3_SECRET_ACCESS_KEY": "businesssupervisorsecret",
        "ATTACHMENT_ENCRYPTION_KEY": key,
        "S3_ENDPOINT": "https://s3.slock.test",
        "SERVER_URL": "https://server.slock.test",
        "HTTP_HOST": "127.0.0.1",
        "SOCKET_HOST": "127.0.0.1",
        "DAEMON_CONNECT_HOST": "127.0.0.1",
        "PORT": String(httpPort),
        "SOCKET_PORT": String(socketPort),
        "DAEMON_CONNECT_PORT": String(daemonPort),
        "TRACE_UPLOAD_DISABLED": "1",
        "TMPDIR": tmp.path,
        "XDG_CACHE_HOME": cache.path,
    ]
}

private func freeLocalPort() throws -> Int {
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard descriptor >= 0 else { throw BusinessPersistenceFailClosedError.invalidResponse }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw BusinessPersistenceFailClosedError.invalidResponse }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard named == 0 else { throw BusinessPersistenceFailClosedError.invalidResponse }
    return Int(UInt16(bigEndian: address.sin_port))
}

private func waitForSupervisorReady(process: Process, logURL: URL) async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if text.contains("raft-server ready") { return }
        if !process.isRunning {
            throw BusinessPersistenceFailClosedError.serverExited(text)
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    throw BusinessPersistenceFailClosedError.serverNotReady(text)
}

private func waitForSupervisorExit(process: Process, seconds: Int) async -> Bool {
    for _ in 0..<(seconds * 20) {
        if !process.isRunning { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return !process.isRunning
}

private enum BusinessPersistenceFailClosedError: Error {
    case invalidDatabaseURL
    case invalidResponse
    case serverNotReady(String)
    case serverExited(String)
}
