import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif
import Logging
import PostgresNIO
import RaftHTTP
@testable import RaftPersistence
import Testing

/// Process-level acceptance for SIGTERM during transactional-email delivery.
///
/// The queue smoke/unit suites cannot see this failure mode: it is a
/// swift-corelibs-foundation process abort while a used `URLSession` is torn
/// down, not a wrong HTTP response. This test therefore runs the real
/// production executable against a real PostgreSQL and Redis, lets the durable
/// outbox dispatch a verification email to the real provider endpoint with a
/// throwaway key, sends SIGTERM as soon as the dispatch claim becomes visible,
/// and requires a clean exit plus an undelivered, retryable outbox row.
///
/// The provider endpoint is fixed by `TransactionalEmailConfiguration`; the
/// preflight requires HTTPS reachability to `api.resend.com` because an
/// established TLS connection is what makes the Foundation teardown abort
/// reproducible. The key is invalid, so no mail is sent.
private let emailShutdownAcceptanceEnabled =
    ProcessInfo.processInfo.environment["RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE"] == "1"

@Suite(.serialized) struct EmailShutdownAcceptanceTests {
    @Test(.enabled(if: emailShutdownAcceptanceEnabled))
    func sigtermDuringInFlightEmailExitsCleanlyAndLeavesTheOutboxRetryable() async throws {
        let environment = ProcessInfo.processInfo.environment
        let databaseURL = try #require(environment["RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE_DATABASE_URL"])
        let redisURL = try #require(environment["RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE_REDIS_URL"])
        let serverBinary = try #require(environment["RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE_SERVER_BIN"])
        try #require(FileManager.default.isExecutableFile(atPath: serverBinary))
        let runs = Int(environment["RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE_RUNS"] ?? "") ?? 12
        try #require(runs > 0)

        try requireProviderReachability()

        var observer: PostgresPersistence?
        var failures: [String] = []
        for run in 0..<runs {
            do {
                let outcome = try await runOneIteration(
                    run: run, databaseURL: databaseURL, redisURL: redisURL,
                    serverBinary: serverBinary, observer: &observer
                )
                if !outcome.isEmpty { failures.append("run \(run): \(outcome)") }
            } catch {
                failures.append("run \(run): \(error)")
            }
        }
        if let observer { await observer.close() }
        #expect(failures.isEmpty, "email shutdown acceptance failures: \(failures)")
    }
}

// MARK: - One real process

private func runOneIteration(
    run: Int, databaseURL: String, redisURL: String, serverBinary: String,
    observer: inout PostgresPersistence?
) async throws -> String {
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("raft-email-shutdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    let (httpPort, socketPort, daemonPort) = try shutdownAcceptanceDistinctFreePorts()
    let logURL = workDirectory.appendingPathComponent("server.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let logHandle = try FileHandle(forWritingTo: logURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: serverBinary)
    var childEnvironment = ProcessInfo.processInfo.environment
    let encryptionKey = Data(repeating: 0x41, count: 32).base64EncodedString()
    childEnvironment.merge([
        "NODE_ENV": "production",
        "DATABASE_URL": databaseURL,
        "REDIS_URL": redisURL,
        "JWT_SECRET": "email-shutdown-acceptance-jwt-\(UUID().uuidString)",
        "CREDENTIAL_ENCRYPTION_KEY": encryptionKey,
        "RAFT_EMAIL_PROVIDER": "resend",
        "FROM_EMAIL": "raft@example.invalid",
        "APP_URL": "https://app.example.invalid",
        "RESEND_API_KEY": "re_email_shutdown_acceptance_throwaway",
        "ATTACHMENT_STORAGE_PROVIDER": "s3",
        "S3_BUCKET": "raft-email-shutdown-attachments",
        "S3_ACCESS_KEY_ID": "raftshutdownacceptance",
        "S3_SECRET_ACCESS_KEY": "raftshutdownacceptancesecret",
        "ATTACHMENT_ENCRYPTION_KEY": encryptionKey,
        "S3_ENDPOINT": "https://s3.example.invalid",
        "SERVER_URL": "https://server.example.invalid",
        "HTTP_HOST": "127.0.0.1",
        "SOCKET_HOST": "127.0.0.1",
        "DAEMON_CONNECT_HOST": "127.0.0.1",
        "PORT": String(httpPort),
        "SOCKET_PORT": String(socketPort),
        "DAEMON_CONNECT_PORT": String(daemonPort),
        "TRACE_UPLOAD_DISABLED": "1",
        "TMPDIR": workDirectory.appendingPathComponent("tmp").path,
        "XDG_CACHE_HOME": workDirectory.appendingPathComponent("cache").path,
    ]) { current, replacement in replacement }
    try FileManager.default.createDirectory(
        at: workDirectory.appendingPathComponent("tmp"), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: workDirectory.appendingPathComponent("cache"), withIntermediateDirectories: true
    )
    process.environment = childEnvironment
    process.currentDirectoryURL = workDirectory
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()

    func logText() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }
    func stopIfRunning() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
    defer {
        stopIfRunning()
        try? logHandle.close()
    }

    do {
        try await waitForText("raft-server ready", in: logURL, running: process, timeout: 20)
        try await waitForLocalHealth(port: httpPort, process: process)
    } catch {
        return "server did not become ready: \(error); log: \(logTail(logText()))"
    }

    if observer == nil {
        let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        observer = try await PostgresPersistence.start(configuration: configuration, migrate: false)
    }
    guard let observer else { return "observer unavailable" }

    // A previous iteration can leave rejected rows whose retry backoff makes
    // them older-but-not-due candidates ahead of this run's row. The runner
    // supplies a dedicated database; clear only the outbox so the one new row
    // is the next dispatch candidate and SIGTERM lands in the send window.
    try await truncateOutbox(databaseURL: databaseURL)

    let email = "email-shutdown-\(UUID().uuidString.lowercased())@example.invalid"
    let registration = "{\"email\":\"\(email)\",\"password\":\"password123\",\"name\":\"shutdown-probe\","
        + "\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}"
    let registered = try await shutdownAcceptanceHTTP(
        port: httpPort, method: "POST", path: "/api/auth/register", body: registration
    )
    guard registered.status == 200 else {
        return "register returned \(registered.status); log: \(logTail(logText()))"
    }

    let effectID: UUID
    do {
        effectID = try await waitForPendingVerification(observer: observer, email: email)
    } catch {
        return "outbox row for \(email) was never observable as pending: \(error)"
    }

    do {
        try await waitForClaim(observer: observer, effectID: effectID)
    } catch {
        return "outbox row was never claimed: \(error)"
    }

    // Let the claim become a real HTTPS attempt: either the provider already
    // answered (a completed TLS exchange leaves the keep-alive connection whose
    // teardown aborts pre-fix Foundation) or the request is still in flight.
    // SIGTERM lands inside that window.
    let settleDeadline = Date().addingTimeInterval(1)
    while Date() < settleDeadline {
        if let entry = try await observer.outboxEffect(effectID: effectID),
           entry.lastFailure != nil || entry.deliveredAt != nil {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    process.terminate()

    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    let exited = !process.isRunning
    if !exited { stopIfRunning() }
    let status = process.terminationStatus
    let reason = process.terminationReason
    let log = logText()
    var problems: [String] = []
    if reason != .exit || status != 0 {
        problems.append("exit reason=\(reason) status=\(status)")
    }
    if log.contains("non-zero retain count") {
        problems.append("Foundation multi-handle abort printed")
    }

    let stored = try await observer.outboxEffect(effectID: effectID)
    guard let stored else {
        problems.append("outbox row disappeared")
        return problems.joined(separator: "; ")
    }
    if stored.attempts < 1 { problems.append("outbox row was not claimed") }
    if stored.deliveredAt != nil { problems.append("outbox row was marked delivered without provider acceptance") }
    if stored.exhaustedAt != nil { problems.append("outbox row became terminal") }
    if problems.isEmpty, !exited { problems.append("process did not exit within 10s") }
    return problems.joined(separator: "; ")
}

// MARK: - Durable outbox observation

private func truncateOutbox(databaseURL: String) async throws {
    let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
    let logger = Logger(label: "raft.email-shutdown-acceptance")
    let connection = try await PostgresConnection.connect(
        configuration: configuration.connectionConfiguration(), id: 1, logger: logger
    )
    do {
        _ = try await connection.query(
            "TRUNCATE raft_persistence.durable_outbox", logger: logger
        )
        try await connection.close()
    } catch {
        try? await connection.close()
        throw error
    }
}

private func waitForPendingVerification(
    observer: PostgresPersistence, email: String, timeout: TimeInterval = 5
) async throws -> UUID {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let pending = try await observer.pendingOutbox(limit: 64)
        for entry in pending where entry.effect.kind.rawValue == TransactionalEmailIntent.Kind.verifyEmail.rawValue {
            guard let intent = try? TransactionalEmailIntent.decodeOutboxPayload(
                kind: entry.effect.kind.rawValue,
                codec: TransactionalEmailIntent.payloadCodec,
                payload: entry.effect.payload
            ) else { continue }
            if intent.recipientEmail == email { return entry.effect.effectID }
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ShutdownAcceptanceError.timedOut("pending verification intent")
}

private func waitForClaim(
    observer: PostgresPersistence, effectID: UUID, timeout: TimeInterval = 5
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let entry = try await observer.outboxEffect(effectID: effectID), entry.attempts >= 1 {
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw ShutdownAcceptanceError.timedOut("outbox claim")
}

// MARK: - Published-path helpers

private struct ShutdownAcceptanceReply: Sendable {
    let status: Int
    let body: Data
}

/// A process-wide session. It is intentionally never deinitialized: the same
/// Foundation teardown hazard this test covers applies to test-process sessions.
private let shutdownAcceptanceSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    return URLSession(configuration: configuration)
}()

/// Raw TCP reachability only: the test process must not create a second used
/// URLSession just to probe the network, because the same Foundation teardown
/// hazard would then apply to the test process itself.
private func requireProviderReachability() throws {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    hints.ai_protocol = Int32(IPPROTO_TCP)
    var resolved: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo("api.resend.com", "443", &hints, &resolved) == 0, let first = resolved else {
        throw ShutdownAcceptanceError.providerUnreachable("DNS resolution failed")
    }
    defer { freeaddrinfo(resolved) }
    var info: UnsafeMutablePointer<addrinfo>? = first
    while let current = info {
        let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
        if fd >= 0 {
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            if connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                close(fd)
                return
            }
            if errno == EINPROGRESS {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 5000) > 0 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    if error == 0 {
                        close(fd)
                        return
                    }
                }
            }
            close(fd)
        }
        info = current.pointee.ai_next
    }
    throw ShutdownAcceptanceError.providerUnreachable("TCP connect to api.resend.com:443 failed")
}

private func shutdownAcceptanceHTTP(
    port: Int, method: String, path: String, body: String
) async throws -> ShutdownAcceptanceReply {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(body.utf8)
    let (data, response) = try await shutdownAcceptanceSession.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw ShutdownAcceptanceError.invalidResponse
    }
    return ShutdownAcceptanceReply(status: http.statusCode, body: data)
}

private func waitForLocalHealth(port: Int, process: Process, timeout: TimeInterval = 20) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard process.isRunning else { throw ShutdownAcceptanceError.serverExited }
        if let reply = try? await shutdownAcceptanceHTTP(port: port, method: "GET", path: "/health", body: ""),
           reply.status == 200 {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw ShutdownAcceptanceError.timedOut("/health 200")
}

private func waitForText(
    _ needle: String, in logURL: URL, running process: Process, timeout: TimeInterval
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOf: logURL, encoding: .utf8), text.contains(needle) { return }
        guard process.isRunning else { throw ShutdownAcceptanceError.serverExited }
        try await Task.sleep(for: .milliseconds(30))
    }
    throw ShutdownAcceptanceError.timedOut(needle)
}

private func logTail(_ text: String, lines: Int = 8) -> String {
    text.split(separator: "\n").suffix(lines).joined(separator: "\n")
}

/// Three distinct ports; each probe closes before the next, so the kernel can
/// otherwise hand back the same ephemeral port twice and make startup fail.
private func shutdownAcceptanceDistinctFreePorts() throws -> (Int, Int, Int) {
    var ports: Set<Int> = []
    while ports.count < 3 { ports.insert(try shutdownAcceptanceFreePort()) }
    let ordered = ports.sorted()
    return (ordered[0], ordered[1], ordered[2])
}

private func shutdownAcceptanceFreePort() throws -> Int {
    let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard socketFD >= 0 else { throw ShutdownAcceptanceError.invalidResponse }
    defer { close(socketFD) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw ShutdownAcceptanceError.invalidResponse }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketFD, $0, &length)
        }
    }
    guard named == 0 else { throw ShutdownAcceptanceError.invalidResponse }
    return Int(UInt16(bigEndian: address.sin_port))
}

private enum ShutdownAcceptanceError: Error, CustomStringConvertible {
    case invalidResponse
    case serverExited
    case timedOut(String)
    case providerUnreachable(String)

    var description: String {
        switch self {
        case .invalidResponse: "invalid published HTTP response"
        case .serverExited: "server exited before it became ready"
        case .timedOut(let operation): "timed out waiting for \(operation)"
        case .providerUnreachable(let detail):
            "HTTPS egress to api.resend.com is required for this acceptance: \(detail)"
        }
    }
}
