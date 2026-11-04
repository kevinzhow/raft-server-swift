import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import RaftDaemonClient

private let nowMs = 1_800_000_000_000
private let nowSeconds = nowMs / 1_000
private let fastLock = KimiRefreshLock.Options(retries: 2, minTimeoutMs: 50, maxTimeoutMs: 100)

private func tempHome() -> String {
    let home = NSTemporaryDirectory() + "kimi-refresh-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    return home
}

private func fixtureAuth(_ home: String) -> KimiCodeAuth {
    KimiCodeAuth(
        baseUrl: "https://api.kimi.test/coding/v1", oauthHost: "https://auth.kimi.test",
        storage: "file", storageName: "kimi-code", home: home,
        credentialPath: home + "/credentials/kimi-code.json",
        lockTarget: home + "/oauth/kimi-code"
    )
}

private func token(access: String = "at-old", refresh: String = "rt-old", expiresAt: Int? = nil, expiresIn: Int = 900) -> KimiStoredToken {
    KimiStoredToken(
        accessToken: access, refreshToken: refresh,
        expiresAt: expiresAt ?? nowSeconds - 60, expiresIn: expiresIn, scope: "", tokenType: "Bearer"
    )
}

private final class FetchBox: @unchecked Sendable {
    var calls: [(url: String, body: String, headers: [String: String])] = []
    var respond: (Int) -> (status: Int, body: Data) = { _ in (200, okBody()) }
    var transportError: (@Sendable () -> Error)?

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let headers = request.allHTTPHeaderFields ?? [:]
        calls.append((request.url?.absoluteString ?? "", body, headers))
        if let transportError { throw transportError() }
        return respond(calls.count - 1)
    }
}

private func okBody(refresh: String = "rt-new") -> Data {
    let object: [String: Any] = [
        "access_token": "at-new", "refresh_token": refresh, "expires_in": 900,
        "scope": "", "token_type": "Bearer",
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func errorBody(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func deps(_ box: FetchBox, extra: (inout KimiRefreshDeps) -> Void = { _ in }) -> KimiRefreshDeps {
    var value = KimiRefreshDeps(
        now: { nowMs },
        send: { request in try await box.send(request) },
        sleep: { _ in },
        lockOptions: fastLock,
        platform: "linux",
        env: [:],
        identity: (platform: "raft_computer", version: "1.0.0"),
        beforeWrite: nil,
        maxRetries: 3,
        backoffMs: { _ in 0 }
    )
    extra(&value)
    return value
}

private func contents(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

private func waitForLock(_ target: String, timeoutMs: Int = 1_000) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while !FileManager.default.fileExists(atPath: target + ".lock") && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Test func tokenOutsideThresholdIsFresh() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token(expiresAt: nowSeconds + 800))
    let box = FetchBox()
    let before = contents(auth.credentialPath)
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
    #expect(result == .fresh(expiresAt: nowSeconds + 800))
    #expect(box.calls.isEmpty)
    #expect(contents(auth.credentialPath) == before)
}

@Test func expiredTokenIsRefreshedWithTheClientRequestShape() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let box = FetchBox()
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
    #expect(result == .refreshed(expiresAt: nowSeconds + 900))
    #expect(box.calls.count == 1)
    #expect(box.calls[0].url == "https://auth.kimi.test/api/oauth/token")
    #expect(box.calls[0].body == "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=rt-old")
    #expect(box.calls[0].headers["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(box.calls[0].headers["X-Msh-Platform"] == "raft_computer")
    #expect((box.calls[0].headers["X-Msh-Device-Id"] ?? "").isEmpty == false)
    guard case .ok(let stored) = KimiTokenRefresh.readStoredToken(auth.credentialPath) else {
        Issue.record("expected stored token")
        return
    }
    #expect(stored == KimiStoredToken(accessToken: "at-new", refreshToken: "rt-new", expiresAt: nowSeconds + 900, expiresIn: 900, scope: "", tokenType: "Bearer"))
    let attributes = try FileManager.default.attributesOfItem(atPath: auth.credentialPath)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(contents(auth.credentialPath).hasSuffix("}\n"))
    #expect(!FileManager.default.fileExists(atPath: auth.lockTarget + ".lock"))
}

@Test func rejectedRefreshLeavesTheFileUntouched() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let before = contents(auth.credentialPath)
    let responses: [(Int, Data)] = [(401, errorBody([:])), (403, errorBody([:])), (400, errorBody(["error": "invalid_grant"]))]
    for (status, body) in responses {
        let box = FetchBox()
        box.respond = { _ in (status, body) }
        let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
        #expect(result == .rejected(reason: "refresh_rejected"))
        #expect(box.calls.count == 1)
        #expect(contents(auth.credentialPath) == before)
    }
}

@Test func rejectionWhoseRereadFindsARotationAdoptsIt() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let box = FetchBox()
    box.respond = { _ in
        try? KimiTokenRefresh.writeStoredToken(auth.credentialPath, token(access: "at-theirs", refresh: "rt-theirs", expiresAt: nowSeconds + 900))
        return (401, errorBody([:]))
    }
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
    #expect(result == .adopted(expiresAt: nowSeconds + 900))
    if case .ok(let stored) = KimiTokenRefresh.readStoredToken(auth.credentialPath) {
        #expect(stored.refreshToken == "rt-theirs")
    } else {
        Issue.record("expected stored token")
    }
}

@Test func networkAndServerFailuresRetryThenReportTransient() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let before = contents(auth.credentialPath)

    let offline = FetchBox()
    offline.transportError = { URLError(.networkConnectionLost) }
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(offline)) == .transient(reason: "network", expired: true))
    #expect(offline.calls.count == 3)
    #expect(contents(auth.credentialPath) == before)

    let server = FetchBox()
    server.respond = { _ in (503, Data()) }
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(server)) == .transient(reason: "server", expired: true))
    #expect(server.calls.count == 3)

    let noRotation = FetchBox()
    noRotation.respond = { _ in (200, errorBody(["access_token": "at-new", "expires_in": 900])) }
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(noRotation)) == .transient(reason: "rotation_missing", expired: true))
    #expect(contents(auth.credentialPath) == before)
}

@Test func stillValidTokenInsideThresholdReportsNotExpired() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token(expiresAt: nowSeconds + 100))
    let box = FetchBox()
    box.transportError = { URLError(.cannotConnectToHost) }
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(box)) == .transient(reason: "network", expired: false))
}

@Test func loserWaitsForTheWinnerAndAdoptsWithoutSendingTheOldToken() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let winnerPath = home + "/winner.json"
    try KimiTokenRefresh.writeStoredToken(winnerPath, token(access: "at-winner", refresh: "rt-winner", expiresAt: nowSeconds + 900))
    let box = FetchBox()
    let child = Task {
        await runShell("mkdir -p '\(home)/oauth'; mkdir '\(auth.lockTarget).lock'; sleep 0.3; cp '\(winnerPath)' '\(auth.credentialPath)'; rmdir '\(auth.lockTarget).lock'")
    }
    await waitForLock(auth.lockTarget)
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box) { $0.lockOptions = KimiRefreshLock.Options(retries: 20, minTimeoutMs: 50, maxTimeoutMs: 100) })
    #expect(result == .adopted(expiresAt: nowSeconds + 900), "got \(result)")
    #expect(box.calls.isEmpty, "calls=\(box.calls.map(\.body))")
    if case .ok(let stored) = KimiTokenRefresh.readStoredToken(auth.credentialPath) {
        #expect(stored.refreshToken == "rt-winner")
    } else {
        Issue.record("expected stored token")
    }
    await child.value
}

@Test func clientHeldLockIsABoundedFailure() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let before = contents(auth.credentialPath)
    let box = FetchBox()
    let child = Task {
        await runShell("mkdir -p '\(home)/oauth'; mkdir '\(auth.lockTarget).lock'; sleep 1.5; rmdir '\(auth.lockTarget).lock'")
    }
    await waitForLock(auth.lockTarget)
    let startedAt = Date()
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
    #expect(result == .transient(reason: "lock_unavailable", expired: true))
    #expect(Date().timeIntervalSince(startedAt) < 1.4)
    #expect(box.calls.isEmpty)
    #expect(contents(auth.credentialPath) == before)
    await child.value
}

@Test func compromisedLockStopsTheWrite() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let before = contents(auth.credentialPath)
    let box = FetchBox()
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box) { d in
        d.lockOptions = KimiRefreshLock.Options(retries: 2, minTimeoutMs: 50, maxTimeoutMs: 100, staleMs: 2_000)
        d.beforeWrite = {
            let manager = FileManager.default
            try? manager.removeItem(atPath: auth.lockTarget + ".lock")
            try? manager.createDirectory(atPath: auth.lockTarget + ".lock", withIntermediateDirectories: false)
            let foreign = Date().addingTimeInterval(-60)
            try? manager.setAttributes([.modificationDate: foreign], ofItemAtPath: auth.lockTarget + ".lock")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
    })
    #expect(result == .transient(reason: "lock_compromised", expired: true))
    #expect(contents(auth.credentialPath) == before, "no write on a compromised lock")
}

@Test func accountSwitchSeenAtTheLastComparisonIsRespected() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let box = FetchBox()
    box.respond = { _ in
        try? KimiTokenRefresh.writeStoredToken(auth.credentialPath, token(access: "at-login", refresh: "rt-login", expiresAt: nowSeconds + 900))
        return (200, okBody(refresh: "rt-ours"))
    }
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
    #expect(result == .adopted(expiresAt: nowSeconds + 900))
    if case .ok(let stored) = KimiTokenRefresh.readStoredToken(auth.credentialPath) {
        #expect(stored.refreshToken == "rt-login")
    } else {
        Issue.record("expected stored token")
    }
}

@Test func platformStorageAndMissingStatesAreReported() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let box = FetchBox()
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(box) { $0.platform = "win32" }) == .platformUnsupported(reason: "win32"))
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(box) { $0.env = ["KIMI_DISABLE_OAUTH_LOCK": "1"] }) == .platformUnsupported(reason: "lock_disabled"))
    var otherStorage = auth
    otherStorage.storage = "other"
    #expect(await KimiTokenRefresh.ensureFresh(otherStorage, deps: deps(box)) == .platformUnsupported(reason: "storage_not_file"))
    #expect(box.calls.isEmpty)

    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token(access: "", refresh: "", expiresAt: 0, expiresIn: 0))
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(box)) == .revoked)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token(refresh: ""))
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(box)) == .missing(reason: "no_refresh_token"))
    try? FileManager.default.removeItem(atPath: auth.credentialPath)
    #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(box)) == .missing(reason: "no_file"))
    #expect(box.calls.isEmpty)
}

@Test func malformedSuccessResponseIsNeverWritten() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let before = contents(auth.credentialPath)
    for accessToken in ["", "42", "null", "missing"] as [String] {
        var object: [String: Any] = ["refresh_token": "rt-new", "expires_in": 900]
        if accessToken == "42" { object["access_token"] = 42 } else if accessToken != "missing" {
            object["access_token"] = accessToken == "null" ? NSNull() : accessToken
        }
        let box = FetchBox()
        box.respond = { _ in (200, errorBody(object)) }
        let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
        #expect(result == .transient(reason: "malformed_response", expired: true), "\(accessToken)")
        #expect(box.calls.count == 1)
        #expect(contents(auth.credentialPath) == before)
        if case .ok(let stored) = KimiTokenRefresh.readStoredToken(auth.credentialPath) {
            #expect(stored.accessToken == "at-old")
        } else {
            Issue.record("expected usable token")
        }
    }
}

@Test func fileTurnedMalformedDuringTheWriteIsLeftAlone() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let box = FetchBox()
    box.respond = { _ in
        try? "{}".write(toFile: auth.credentialPath, atomically: true, encoding: .utf8)
        return (200, okBody())
    }
    let result = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box))
    #expect(result == .missing(reason: "malformed"))
    #expect(contents(auth.credentialPath) == "{}")
}

@Test func malformedReadsAreDistinctFromRevoked() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try? FileManager.default.createDirectory(atPath: (auth.credentialPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let revoked = #"{"access_token":"","refresh_token":"","expires_at":0,"scope":"","token_type":"Bearer","expires_in":0}"#
    try revoked.write(toFile: auth.credentialPath, atomically: true, encoding: .utf8)
    #expect(KimiTokenRefresh.readStoredToken(auth.credentialPath) == .revoked)
    let malformed = [
        "{}", #"{"access_token":""}"#, #"{"access_token":"","refresh_token":"rt-x","expires_at":0}"#,
        #"{"access_token":"","refresh_token":"","expires_at":1}"#, #"{"access_token":12,"refresh_token":"rt-x"}"#,
        #"{"access_token":"at-x","refresh_token":12}"#, #"{"refresh_token":"rt-x","expires_at":0}"#,
        #"{"foo":"bar"}"#,
    ]
    let box = FetchBox()
    for body in malformed {
        try body.write(toFile: auth.credentialPath, atomically: true, encoding: .utf8)
        #expect(KimiTokenRefresh.readStoredToken(auth.credentialPath) == .missing(reason: "malformed"), "\(body)")
        #expect(await KimiTokenRefresh.ensureFresh(auth, deps: deps(box)) == .missing(reason: "malformed"), "\(body)")
    }
    try "[]".write(toFile: auth.credentialPath, atomically: true, encoding: .utf8)
    #expect(KimiTokenRefresh.readStoredToken(auth.credentialPath) == .missing(reason: "unreadable"))
    try "not json".write(toFile: auth.credentialPath, atomically: true, encoding: .utf8)
    #expect(KimiTokenRefresh.readStoredToken(auth.credentialPath) == .missing(reason: "unreadable"))
    #expect(box.calls.isEmpty)
}

@Test func knownGapLoginBetweenComparisonAndRenameIsOverwritten() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let auth = fixtureAuth(home)
    try KimiTokenRefresh.writeStoredToken(auth.credentialPath, token())
    let box = FetchBox()
    box.respond = { _ in (200, okBody(refresh: "rt-ours")) }
    await withKnownIssue("Known gap: a lockless client login landing between the last comparison and the rename is overwritten") {
        _ = await KimiTokenRefresh.ensureFresh(auth, deps: deps(box) { d in
            d.beforeWrite = {
                try? KimiTokenRefresh.writeStoredToken(auth.credentialPath, token(access: "at-login", refresh: "rt-login", expiresAt: nowSeconds + 900))
            }
        })
        if case .ok(let stored) = KimiTokenRefresh.readStoredToken(auth.credentialPath) {
            #expect(stored.refreshToken == "rt-login")
        } else {
            Issue.record("expected stored token")
        }
    }
}

private func runShell(_ script: String) async -> String {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.terminationHandler = { _ in continuation.resume(returning: "") }
        try? process.run()
    }
}
