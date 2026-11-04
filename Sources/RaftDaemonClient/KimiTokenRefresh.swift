import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keeps the Kimi Code access token fresh before a usage probe, mirroring the
/// client's OAuth manager: refresh inside the client's own lock, adopt another
/// writer's rotation, never persist the client's revoked tombstone, and report
/// every failure as a freshness verdict instead of throwing. Ported from the
/// upstream daemon helper.
public struct KimiStoredToken: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Int
    public var expiresIn: Int
    public var scope: String
    public var tokenType: String

    // Wire-compatible keys used by the client's file.
    public init(accessToken: String, refreshToken: String, expiresAt: Int, expiresIn: Int, scope: String, tokenType: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
        self.scope = scope
        self.tokenType = tokenType
    }
}

public enum KimiFreshness: Sendable, Equatable {
    case fresh(expiresAt: Int)
    case refreshed(expiresAt: Int)
    case adopted(expiresAt: Int)
    case rejected(reason: String)
    case revoked
    case missing(reason: String)
    case transient(reason: String, expired: Bool)
    case platformUnsupported(reason: String)
}

public enum KimiStoredTokenRead: Sendable, Equatable {
    case ok(KimiStoredToken)
    case missing(reason: String)
    case revoked
}

public struct KimiRefreshDeps: Sendable {
    public var now: @Sendable () -> Int
    public var send: @Sendable (URLRequest) async throws -> (status: Int, body: Data)
    public var sleep: @Sendable (Int) async -> Void
    public var lockOptions: KimiRefreshLock.Options
    public var platform: String
    public var env: [String: String]
    public var identity: (platform: String, version: String)?
    public var beforeWrite: (@Sendable () async -> Void)?
    public var maxRetries: Int
    public var backoffMs: @Sendable (Int) -> Int

    public init(
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        send: @escaping @Sendable (URLRequest) async throws -> (status: Int, body: Data),
        sleep: @escaping @Sendable (Int) async -> Void = { ms in
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
        },
        lockOptions: KimiRefreshLock.Options = .init(),
        platform: String = "linux",
        env: [String: String] = [:],
        identity: (platform: String, version: String)? = nil,
        beforeWrite: (@Sendable () async -> Void)? = nil,
        maxRetries: Int = 3,
        backoffMs: @escaping @Sendable (Int) -> Int = { attempt in Int(pow(2.0, Double(attempt)) * 1_000) }
    ) {
        self.now = now
        self.send = send
        self.sleep = sleep
        self.lockOptions = lockOptions
        self.platform = platform
        self.env = env
        self.identity = identity
        self.beforeWrite = beforeWrite
        self.maxRetries = maxRetries
        self.backoffMs = backoffMs
    }
}

public enum KimiTokenRefresh {
    public static let minRefreshThresholdSeconds = 300
    public static let refreshThresholdRatio = 0.5
    static let retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]

    public static func refreshThresholdSeconds(expiresIn: Int) -> Int {
        expiresIn > 0 ? max(minRefreshThresholdSeconds, Int(Double(expiresIn) * refreshThresholdRatio)) : minRefreshThresholdSeconds
    }

    static func needsRefresh(_ token: KimiStoredToken, nowSeconds: Int) -> Bool {
        guard token.expiresAt != 0 else { return false }
        return token.expiresAt - nowSeconds < refreshThresholdSeconds(expiresIn: token.expiresIn)
    }

    static func isRevokedTombstone(_ object: [String: Any]) -> Bool {
        (object["access_token"] as? String) == "" && (object["refresh_token"] as? String) == ""
            && (object["expires_at"] as? NSNumber)?.doubleValue == 0
    }

    public static func readStoredToken(_ path: String) -> KimiStoredTokenRead {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return .missing(reason: "no_file") }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let object = parsed as? [String: Any]
        else {
            return .missing(reason: "unreadable")
        }
        if isRevokedTombstone(object) { return .revoked }
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            return .missing(reason: "malformed")
        }
        if let refresh = object["refresh_token"], !(refresh is String) { return .missing(reason: "malformed") }
        return .ok(KimiStoredToken(
            accessToken: access,
            refreshToken: (object["refresh_token"] as? String) ?? "",
            expiresAt: (object["expires_at"] as? NSNumber)?.intValue ?? 0,
            expiresIn: (object["expires_in"] as? NSNumber)?.intValue ?? 0,
            scope: (object["scope"] as? String) ?? "",
            tokenType: (object["token_type"] as? String) ?? "Bearer"
        ))
    }

    static func tokenObject(_ token: KimiStoredToken) -> [String: Any] {
        [
            "access_token": token.accessToken,
            "refresh_token": token.refreshToken,
            "expires_at": token.expiresAt,
            "expires_in": token.expiresIn,
            "scope": token.scope,
            "token_type": token.tokenType,
        ]
    }

    /// The client's FileTokenStorage.save shape: 2-space JSON with a trailing
    /// newline, written atomically and chmod 0600.
    public static func writeStoredToken(_ path: String, _ token: KimiStoredToken) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The client's JSON.stringify(token, null, 2) shape.
        let json = prettyJSON(object: tokenObject(token))
        let payload = Data((json + "\n").utf8)
        try payload.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func prettyJSON(object: [String: Any]) -> String {
        let serialized = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: serialized, as: UTF8.self)
    }

    enum RefreshOutcome {
        case ok(KimiStoredToken)
        case unauthorized
        case network
        case server
        case rotationMissing
        case malformedResponse
    }

    static func parseRefreshResponse(_ object: [String: Any], nowSeconds: Int) -> RefreshOutcome {
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            return .malformedResponse
        }
        guard let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
              let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue,
              expiresIn.isFinite, expiresIn > 0
        else { return .rotationMissing }
        return .ok(KimiStoredToken(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: nowSeconds + Int(expiresIn),
            expiresIn: Int(expiresIn),
            scope: (object["scope"] as? String) ?? "",
            tokenType: (object["token_type"] as? String) ?? "Bearer"
        ))
    }

    static func requestRefresh(
        auth: KimiCodeAuth,
        refreshToken: String,
        deps: KimiRefreshDeps
    ) async -> RefreshOutcome {
        var urlString = auth.oauthHost
        while urlString.hasSuffix("/") { urlString.removeLast() }
        urlString += "/api/oauth/token"
        let identity = deps.identity ?? (platform: "raft_computer", version: "unknown")
        let headers = KimiCodeAuthResolver.deviceHeaders(
            home: auth.home,
            options: (platform: identity.platform, version: identity.version)
        )
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let form = "client_id=\(KimiCodeAuthResolver.oauthClientId)&grant_type=refresh_token&refresh_token=\(formEncode(refreshToken))"
        request.httpBody = Data(form.utf8)

        var last: RefreshOutcome = .network
        for attempt in 0..<deps.maxRetries {
            var status = 0
            var object: [String: Any] = [:]
            do {
                let response = try await deps.send(request)
                status = response.status
                if let parsed = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] {
                    object = parsed
                }
            } catch {
                last = .network
                if attempt < deps.maxRetries - 1 {
                    await deps.sleep(deps.backoffMs(attempt))
                    continue
                }
                return last
            }
            if status == 200 { return parseRefreshResponse(object, nowSeconds: deps.now() / 1_000) }
            let code = object["error"] as? String ?? ""
            if status == 401 || status == 403 || code == "invalid_grant" { return .unauthorized }
            if retryableStatuses.contains(status) {
                last = .server
                if attempt < deps.maxRetries - 1 {
                    await deps.sleep(deps.backoffMs(attempt))
                    continue
                }
                return last
            }
            return .server
        }
        return last
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Ensures the stored access token is fresh enough for a probe. Never
    /// throws; every outcome is a freshness verdict.
    public static func ensureFresh(_ auth: KimiCodeAuth, deps: KimiRefreshDeps) async -> KimiFreshness {
        if auth.storage != "file" { return .platformUnsupported(reason: "storage_not_file") }
        if deps.platform == "win32" { return .platformUnsupported(reason: "win32") }
        if deps.env["KIMI_DISABLE_OAUTH_LOCK"] == "1" { return .platformUnsupported(reason: "lock_disabled") }
        let initial = readStoredToken(auth.credentialPath)
        switch initial {
        case .missing(let reason): return .missing(reason: reason)
        case .revoked: return .revoked
        case .ok(let token):
            if !needsRefresh(token, nowSeconds: deps.now() / 1_000) { return .fresh(expiresAt: token.expiresAt) }
            if token.refreshToken.isEmpty { return .missing(reason: "no_refresh_token") }
        }
        let expiredBefore: Bool = {
            if case .ok(let token) = initial { return token.expiresAt <= deps.now() / 1_000 }
            return false
        }()

        let locked = await KimiRefreshLock.withLock(target: auth.lockTarget, options: deps.lockOptions) { handle -> KimiFreshness in
            let afterLock = readStoredToken(auth.credentialPath)
            switch afterLock {
            case .revoked: return .revoked
            case .missing(let reason): return .missing(reason: reason)
            case .ok(let active):
                if !needsRefresh(active, nowSeconds: deps.now() / 1_000) { return .adopted(expiresAt: active.expiresAt) }
                if active.refreshToken.isEmpty { return .missing(reason: "no_refresh_token") }
                let outcome = await requestRefresh(auth: auth, refreshToken: active.refreshToken, deps: deps)
                switch outcome {
                case .ok(let refreshed):
                    let beforeWrite = readStoredToken(auth.credentialPath)
                    switch beforeWrite {
                    case .ok(let current) where current.refreshToken != active.refreshToken:
                        return .adopted(expiresAt: current.expiresAt)
                    case .revoked: return .revoked
                    case .missing(let reason): return .missing(reason: reason)
                    case .ok: break
                    }
                    await deps.beforeWrite?()
                    if handle.isCompromised {
                        return .transient(reason: "lock_compromised", expired: expiredBefore)
                    }
                    do {
                        try writeStoredToken(auth.credentialPath, refreshed)
                    } catch {
                        return .transient(reason: "write_failed", expired: expiredBefore)
                    }
                    return .refreshed(expiresAt: refreshed.expiresAt)
                case .unauthorized:
                    await deps.sleep(100)
                    if case .ok(let recovery) = readStoredToken(auth.credentialPath),
                       recovery.refreshToken != active.refreshToken {
                        return .adopted(expiresAt: recovery.expiresAt)
                    }
                    return .rejected(reason: "refresh_rejected")
                case .network:
                    return .transient(reason: "network", expired: expiredBefore)
                case .server:
                    return .transient(reason: "server", expired: expiredBefore)
                case .rotationMissing:
                    return .transient(reason: "rotation_missing", expired: expiredBefore)
                case .malformedResponse:
                    return .transient(reason: "malformed_response", expired: expiredBefore)
                }
            }
        }
        switch locked {
        case .unavailable:
            return .transient(reason: "lock_unavailable", expired: expiredBefore)
        case .held(let freshness):
            return freshness
        }
    }
}
