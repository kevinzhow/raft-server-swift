import Configuration
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif
import NIOCore
import NIOPosix
import RaftHTTP
import RaftHTTPServer
import RaftPersistence
import RaftShared
import TestSupport
import Testing
import Vapor

/// Real-PostgreSQL acceptance for the connected first-server onboarding batch.
///
/// Run this filter alone in a fresh test process: phase one activates
/// `TransactionDomain.shared`, which is a one-way production policy for the
/// lifetime of that process.
///
/// The runner supplies a dedicated, empty database and a throwaway Redis. Phase
/// one starts the same Fallback composition used by the production executable
/// in-process (the only way the test seam can hand back the verification token
/// that a real mailbox would deliver). Phase two starts the actual
/// `RaftServer` executable in production mode on the same database, and phase
/// three restarts that executable. Every assertion is made through published
/// HTTP; the database is never seeded by hand.
///
/// Completion and handoff are intentionally not asserted: `canComplete` needs
/// the official Cindy agent, an online Computer and a matching runtime
/// inventory, which a published-path test without a controlled daemon peer
/// cannot establish. The test records the published 409 refusal instead of
/// fabricating an agent.
private let onboardingPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_ONBOARDING_PG_ACCEPTANCE"] == "1"

@Suite(.serialized) struct OnboardingPostgresAcceptanceTests {
    @Test(.enabled(if: onboardingPGEnabled))
    func connectedOnboardingFactsSurviveRuntimeAndProcessRestartsOnRealPostgres() async throws {
        let environment = ProcessInfo.processInfo.environment
        let databaseURL = try #require(environment["RAFT_ONBOARDING_PG_ACCEPTANCE_DATABASE_URL"])
        let redisURL = try #require(environment["RAFT_ONBOARDING_PG_ACCEPTANCE_REDIS_URL"])
        let serverBinary = try #require(environment["RAFT_ONBOARDING_PG_ACCEPTANCE_SERVER_BIN"])
        try #require(FileManager.default.isExecutableFile(atPath: serverBinary))

        let email = "onboarding-pg-\(UUID().uuidString.lowercased())@slock.test"
        let password = "onboarding-pg-password-123456"
        let slug = "onboarding-pg-\(UUID().uuidString.lowercased().prefix(10))"

        var runtime: OnboardingPGRuntime?
        var process: OnboardingServerProcess?
        defer {
            process?.stop()
            if let runtime { Task { await runtime.close() } }
        }

        // A single fresh-database check happens before the first writer exists.
        // A nonempty database is a runner error, never reset or truncated here.
        let runtimeServer = try await OnboardingPGRuntime.start(databaseURL: databaseURL)
        runtime = runtimeServer
        let baseURL = runtimeServer.baseURL

        // 1. Register and verify through the published routes. The raw token is
        // the same fixture seam an in-process mailbox test uses; it is redeemed
        // by the real POST /api/auth/verify-email handler.
        let registration = try await onboardingPGHTTP(baseURL, "POST", "/api/auth/register", body: .init([
            "email": .string(email), "password": .string(password), "name": .string("onboarding-pg-owner"),
            "acceptTerms": .bool(true), "termsVersion": .string("2026-05-12"),
            "privacyVersion": .string("2026-05-12"),
        ]))
        try #require(registration.status == 200, "register status \(registration.status)")
        let registered = try registration.object()
        let registeredUser = try #require(registered.object("user"))
        let userId = try registeredUser.requireString("id")
        #expect(registeredUser.bool("emailVerified") == false)
        let accessToken = try registered.requireString("accessToken")
        _ = try registered.requireString("refreshToken")
        let verificationToken = try #require(
            runtimeServer.accounts.latestEmailVerificationTokenForTesting(userId: userId)
        )
        let verified = try await onboardingPGHTTP(baseURL, "POST", "/api/auth/verify-email", body: .init([
            "token": .string(verificationToken),
        ]))
        try #require(verified.status == 200, "verify status \(verified.status)")
        #expect(try verified.object().bool("ok") == true)

        // The public first-server path completes the profile before business
        // admission, exactly like the smoke and real-process gates.
        let profileGate = try await onboardingPGHTTP(baseURL, "GET", "/api/servers", token: accessToken)
        #expect(profileGate.status == 403)
        #expect(try profileGate.object().string("code") == "PROFILE_SETUP_REQUIRED")
        let profileName = "onboarding-pg-owner-\(UUID().uuidString.lowercased().prefix(8))"
        let completedProfile = try await onboardingPGHTTP(baseURL, "POST", "/api/auth/me/complete-profile",
            token: accessToken, body: .init([
                "name": .string(profileName), "displayName": .string("Onboarding PG Owner"),
            ]))
        try #require(completedProfile.status == 200, "complete-profile status \(completedProfile.status)")
        #expect(try completedProfile.object().bool("emailVerified") == true)
        #expect(try completedProfile.object().string("profileSetupCompletedAt") != nil)

        // 2. The normal public login, empty canonical collection after login
        // and after refresh, before any server membership exists.
        let login = try await onboardingPGHTTP(baseURL, "POST", "/api/auth/login", body: .init([
            "email": .string(email), "password": .string(password),
        ]))
        try #require(login.status == 200, "login status \(login.status)")
        let loginBody = try login.object()
        let loginToken = try loginBody.requireString("accessToken")
        let emptyServers = try await onboardingPGHTTP(baseURL, "GET", "/api/servers", token: loginToken)
        try #require(emptyServers.status == 200, "empty list status \(emptyServers.status)")
        #expect(emptyServers.body == Data("[]".utf8))
        let refreshed = try await onboardingPGHTTP(baseURL, "POST", "/api/auth/refresh", body: .init([
            "refreshToken": .string(try loginBody.requireString("refreshToken")),
        ]))
        try #require(refreshed.status == 200, "refresh status \(refreshed.status)")
        let refreshedToken = try refreshed.object().requireString("accessToken")
        let emptyAfterRefresh = try await onboardingPGHTTP(baseURL, "GET", "/api/servers", token: refreshedToken)
        try #require(emptyAfterRefresh.status == 200)
        #expect(emptyAfterRefresh.body == Data("[]".utf8))

        // 3. Answer the signup survey, then create the first server through the
        // user-scoped collection route. No X-Server-Id is sent for either.
        let survey = try await onboardingPGHTTP(baseURL, "PATCH", "/api/auth/me", token: refreshedToken, body: .init([
            "signupRole": .string("founder"),
        ]))
        try #require(survey.status == 200, "survey status \(survey.status)")
        let surveyed = try survey.object()
        #expect(surveyed.string("signupRole") == "founder")
        let surveyCompletedAt = try #require(surveyed.string("signupSurveyCompletedAt"))
        let meBefore = try await onboardingPGHTTP(baseURL, "GET", "/api/auth/me", token: refreshedToken)
        try #require(meBefore.status == 200, "me status \(meBefore.status)")
        #expect(try meBefore.object().string("signupRole") == "founder")
        #expect(try meBefore.object().string("signupSurveyCompletedAt") == surveyCompletedAt)

        let createdServer = try await onboardingPGHTTP(baseURL, "POST", "/api/servers", token: refreshedToken, body: .init([
            "name": .string("Onboarding PG Server"), "slug": .string(slug),
        ]))
        try #require(createdServer.status == 200, "create server status \(createdServer.status)")
        let serverId = try createdServer.object().requireString("id")
        let serversBefore = try await onboardingPGHTTP(baseURL, "GET", "/api/servers", token: refreshedToken)
        try #require(serversBefore.status == 200)
        let listedServers = try serversBefore.objectArray()
        #expect(listedServers.contains { $0.string("id") == serverId && $0.string("slug") == slug })

        let projectionPath = "/api/servers/\(serverId)/setup-projection"
        let projectionBefore = try await onboardingPGHTTP(baseURL, "GET", projectionPath,
            token: refreshedToken, serverId: serverId)
        try #require(projectionBefore.status == 200, "projection status \(projectionBefore.status)")
        let projected = try projectionBefore.object()
        let postSetup = try #require(projected.object("postSetup"))
        // A fresh server is not complete, so neither post-setup screen is owed.
        #expect(postSetup.bool("surveyPending") == false)
        #expect(postSetup.bool("handoffPending") == false)

        // Completion is not reachable without the official online onboarding
        // agent, and this acceptance does not inject a daemon peer. This is the
        // published refusal that keeps us from fabricating completion/handoff.
        let completion = try await onboardingPGHTTP(baseURL, "POST",
            "/api/servers/\(serverId)/setup-transition", token: refreshedToken, serverId: serverId,
            body: .init(["action": .string("complete")]))
        #expect(completion.status == 409)
        #expect(try completion.object().string("error") == "OFFICIAL_ONBOARDING_AGENT_NOT_USABLE")

        let meBytes = meBefore.body
        let serversBytes = serversBefore.body
        let projectionBytes = projectionBefore.body
        #expect(meBytes == (try await onboardingPGHTTP(baseURL, "GET", "/api/auth/me", token: refreshedToken)).body)
        #expect(projectionBytes == (try await onboardingPGHTTP(baseURL, "GET", projectionPath,
            token: refreshedToken, serverId: serverId)).body)

        // 4. A real process-level restart. The in-process runtime is closed and
        // the actual production executable restores the same database.
        await runtimeServer.close()
        runtime = nil

        func launchProcess() throws -> OnboardingServerProcess {
            let httpPort = try onboardingPGBlockingPort()
            let socketPort = try onboardingPGBlockingPort()
            let daemonPort = try onboardingPGBlockingPort()
            let child = try OnboardingServerProcess(
                executable: serverBinary, workDirectory: onboardingPGTemporaryDirectory(),
                environment: onboardingPGProductionEnvironment(
                    databaseURL: databaseURL, redisURL: redisURL,
                    httpPort: httpPort, socketPort: socketPort, daemonPort: daemonPort
                )
            )
            try child.start()
            return child
        }

        process = try launchProcess()
        try await process!.waitForReady()
        try await onboardingPGWaitForHealth(process!.baseURL)

        // The pre-restart access token remains a valid restored session. A
        // fresh login with the old password also works.
        let restoredMe = try await onboardingPGHTTP(process!.baseURL, "GET", "/api/auth/me", token: refreshedToken)
        try #require(restoredMe.status == 200, "restored session status \(restoredMe.status)")
        #expect(restoredMe.body == meBytes)
        let restoredLogin = try await onboardingPGHTTP(process!.baseURL, "POST", "/api/auth/login", body: .init([
            "email": .string(email), "password": .string(password),
        ]))
        try #require(restoredLogin.status == 200, "restart login status \(restoredLogin.status)")
        let restoredToken = try restoredLogin.object().requireString("accessToken")
        let restoredMeLogin = try await onboardingPGHTTP(process!.baseURL, "GET", "/api/auth/me", token: restoredToken)
        try #require(restoredMeLogin.status == 200)
        #expect(restoredMeLogin.body == meBytes)
        #expect(try restoredMeLogin.object().string("signupRole") == "founder")
        #expect(try restoredMeLogin.object().string("signupSurveyCompletedAt") == surveyCompletedAt)

        let restoredServers = try await onboardingPGHTTP(process!.baseURL, "GET", "/api/servers", token: restoredToken)
        try #require(restoredServers.status == 200)
        #expect(restoredServers.body == serversBytes)
        #expect(try restoredServers.objectArray().contains { $0.string("id") == serverId && $0.string("slug") == slug })

        let restoredProjection = try await onboardingPGHTTP(process!.baseURL, "GET", projectionPath,
            token: restoredToken, serverId: serverId)
        try #require(restoredProjection.status == 200)
        #expect(restoredProjection.body == projectionBytes)

        // 5. Restart the same executable once more and require the identical
        // retained facts, not a first-read migration artifact.
        process!.stop()
        process = try launchProcess()
        try await process!.waitForReady()
        try await onboardingPGWaitForHealth(process!.baseURL)
        let secondLogin = try await onboardingPGHTTP(process!.baseURL, "POST", "/api/auth/login", body: .init([
            "email": .string(email), "password": .string(password),
        ]))
        try #require(secondLogin.status == 200)
        let secondToken = try secondLogin.object().requireString("accessToken")
        let secondMe = try await onboardingPGHTTP(process!.baseURL, "GET", "/api/auth/me", token: secondToken)
        try #require(secondMe.status == 200)
        #expect(secondMe.body == meBytes)
        let secondServers = try await onboardingPGHTTP(process!.baseURL, "GET", "/api/servers", token: secondToken)
        try #require(secondServers.status == 200)
        #expect(secondServers.body == serversBytes)
        let secondProjection = try await onboardingPGHTTP(process!.baseURL, "GET", projectionPath,
            token: secondToken, serverId: serverId)
        try #require(secondProjection.status == 200)
        #expect(secondProjection.body == projectionBytes)

        process!.stop()
        process = nil
    }
}

// MARK: - In-process production composition

/// Owns one real PostgreSQL writer and one published HTTP listener. Only the
/// PG-backed business composition is started here; no daemon listen socket or
/// provider adapters are fabricated.
private final class OnboardingPGRuntime: Sendable {
    let accounts: EmailLoginDirectory
    let baseURL: URL
    private let app: Application
    private let runtime: BusinessPersistenceRuntime
    private let observer: PostgresPersistence
    private let httpTask: Task<Void, any Error>
    private let session: URLSession

    private init(accounts: EmailLoginDirectory, baseURL: URL, app: Application,
                 runtime: BusinessPersistenceRuntime, observer: PostgresPersistence,
                 httpTask: Task<Void, any Error>) {
        self.accounts = accounts
        self.baseURL = baseURL
        self.app = app
        self.runtime = runtime
        self.observer = observer
        self.httpTask = httpTask
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    static func start(databaseURL: String) async throws -> OnboardingPGRuntime {
        let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        let accounts = EmailLoginDirectory()
        let bindings = try accounts.makeDurableBindings()
        let keys = bindings.map(\.key)
        let observer = try await PostgresPersistence.start(configuration: configuration)
        var writer: BusinessPersistenceRuntime?
        var application: Application?
        var serving: Task<Void, any Error>?
        do {
            // The runner's database is dedicated and must be untouched. The
            // fixture never truncates or drops anything.
            guard try await observer.readSnapshot(keys).isEmpty,
                  try await observer.pendingOutbox(limit: 1).isEmpty else {
                throw OnboardingPGAcceptanceError.databaseNotEmpty
            }
            let runtime = try await BusinessPersistenceRuntime.start(configuration: configuration, bindings: bindings)
            writer = runtime
            let app = try Application(.testing,
                configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                configReader: .init(providers: [EnvironmentVariablesProvider()]))
            application = app
            let probe: @Sendable () async throws -> Void = { _ = try await observer.readSnapshot(keys) }
            // The durable email port is required once the runtime has activated
            // the read-only production policy, exactly like the executable's
            // production binding. It never sends here: this fixture has no mail
            // worker, and the raw token is redeemed through the real HTTP route.
            let emailConfiguration = try TransactionalEmailConfiguration.localMailbox(
                apiKey: "onboarding-pg-local-mailbox", from: "raft@slock.test",
                webURL: URL(string: "https://app.slock.test")!,
                endpoint: URL(string: "http://127.0.0.1:1")!
            )
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: probe), pingDatabase: probe,
                emailAccounts: accounts, persistence: runtime,
                transactionalEmail: .durable(configuration: emailConfiguration),
                serverBaseURL: "https://server.slock.test"
            ))
            try await app.boot()
            try await runtime.activate()
            let task = Task { try await app.run() }
            serving = task
            let address = try await onboardingPGDeadline(onTimeout: { task.cancel() }) {
                try await app.server.listeningAddress
            }
            guard let port = address.port, let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
                throw OnboardingPGAcceptanceError.invalidResponse
            }
            return .init(accounts: accounts, baseURL: baseURL, app: app, runtime: runtime,
                         observer: observer, httpTask: task)
        } catch {
            serving?.cancel()
            if let serving { _ = await serving.result }
            try? await application?.shutdown()
            await writer?.close()
            await observer.close()
            throw error
        }
    }

    func close() async {
        httpTask.cancel()
        _ = await httpTask.result
        try? await app.shutdown()
        await runtime.close()
        await observer.close()
        session.invalidateAndCancel()
    }
}

// MARK: - Real executable lifecycle

private final class OnboardingServerProcess: @unchecked Sendable {
    private let process = Process()
    private let executable: String
    private let workDirectory: URL
    private let environment: [String: String]
    let baseURL: URL
    private let logURL: URL
    private var logHandle: FileHandle?

    init(executable: String, workDirectory: URL, environment: [String: String]) throws {
        self.executable = executable
        self.workDirectory = workDirectory
        self.environment = environment
        self.baseURL = URL(string: "http://127.0.0.1:\(environment["PORT"]!)")!
        self.logURL = workDirectory.appendingPathComponent("server.log")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: logURL)
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: executable)
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        process.currentDirectoryURL = workDirectory
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
    }

    func waitForReady() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (try? String(contentsOf: logURL, encoding: .utf8))?.contains("raft-server ready") == true { return }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw OnboardingPGAcceptanceError.serverNotReady(logTail())
    }

    func logTail(_ lines: Int = 20) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "<no log>" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? logHandle?.close()
        logHandle = nil
    }
}

// MARK: - HTTP and environment helpers

private struct OnboardingPGHTTPResponse: Sendable {
    let status: Int
    let body: Data
    func object() throws -> ProtocolPGObject { try .init(data: body) }
    func objectArray() throws -> [ProtocolPGObject] {
        guard case .array(let values) = try JSONDecoder().decode(JSONValue.self, from: body) else {
            throw OnboardingPGAcceptanceError.invalidResponse
        }
        return try values.map { value in
            guard case .object(let fields) = value else { throw OnboardingPGAcceptanceError.invalidResponse }
            return ProtocolPGObject(fields)
        }
    }
}

private let onboardingPGHTTPSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    return URLSession(configuration: configuration)
}()

private func onboardingPGHTTP(_ baseURL: URL, _ method: String, _ path: String,
                              token: String? = nil, serverId: String? = nil,
                              body: ProtocolPGObject? = nil) async throws -> OnboardingPGHTTPResponse {
    guard path.hasPrefix("/"), let url = URL(string: path, relativeTo: baseURL) else {
        throw OnboardingPGAcceptanceError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let body {
        request.httpBody = try body.data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let serverId { request.setValue(serverId, forHTTPHeaderField: "X-Server-Id") }
    let (data, response) = try await onboardingPGHTTPSession.data(for: request)
    guard let response = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else {
        throw OnboardingPGAcceptanceError.invalidResponse
    }
    return .init(status: response.statusCode, body: data)
}

private func onboardingPGWaitForHealth(_ baseURL: URL) async throws {
    for _ in 0..<400 {
        if let health = try? await onboardingPGHTTP(baseURL, "GET", "/health"), health.status == 200 { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw OnboardingPGAcceptanceError.httpNotReady
}

private func onboardingPGDeadline<Value: Sendable>(
    onTimeout: @escaping @Sendable () -> Void,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(15))
            onTimeout()
            throw OnboardingPGAcceptanceError.timeout
        }
        guard let first = try await group.next() else { throw OnboardingPGAcceptanceError.timeout }
        group.cancelAll()
        return first
    }
}

private func onboardingPGProductionEnvironment(
    databaseURL: String, redisURL: String, httpPort: Int, socketPort: Int, daemonPort: Int
) throws -> [String: String] {
    let root = onboardingPGTemporaryDirectory()
    let tmp = root.appendingPathComponent("tmp")
    let cache = root.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let key = Data(repeating: 0x41, count: 32).base64EncodedString()
    return [
        "NODE_ENV": "production",
        "DATABASE_URL": databaseURL,
        "REDIS_URL": redisURL,
        "JWT_SECRET": "onboarding-pg-acceptance-jwt-secret-0123456789abcdef",
        "CREDENTIAL_ENCRYPTION_KEY": key,
        "RAFT_EMAIL_PROVIDER": "resend",
        "FROM_EMAIL": "raft@slock.test",
        "APP_URL": "https://app.slock.test",
        "RESEND_API_KEY": "re_onboarding_pg_throwaway",
        "ATTACHMENT_STORAGE_PROVIDER": "s3",
        "S3_BUCKET": "onboarding-pg-attachments",
        "S3_ACCESS_KEY_ID": "onboardingpgtaccess",
        "S3_SECRET_ACCESS_KEY": "onboardingpgtsecret",
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

private func onboardingPGTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("raft-onboarding-pg-\(UUID().uuidString)")
}

private func onboardingPGBlockingPort() throws -> Int {
    let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard socketFD >= 0 else { throw OnboardingPGAcceptanceError.invalidResponse }
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
    guard bound == 0 else { throw OnboardingPGAcceptanceError.invalidResponse }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketFD, $0, &length)
        }
    }
    guard named == 0 else { throw OnboardingPGAcceptanceError.invalidResponse }
    return Int(UInt16(bigEndian: address.sin_port))
}

private enum OnboardingPGAcceptanceError: Error, CustomStringConvertible {
    case databaseNotEmpty, invalidResponse, httpNotReady, timeout
    case serverNotReady(String)

    var description: String {
        switch self {
        case .databaseNotEmpty: "the acceptance database is not empty"
        case .invalidResponse: "invalid published HTTP response"
        case .httpNotReady: "the restarted server never became healthy"
        case .timeout: "the runtime did not become ready"
        case .serverNotReady(let tail): "the real server did not become ready:\n\(tail)"
        }
    }
}
