import Foundation
#if canImport(Crypto)
import Crypto
#endif

/// The Kimi Code client's credential, lock and OAuth locations, resolved the
/// way the upstream oar kimi runtime resolves them. Ported from the daemon
/// runtime-account-usage helper.
public struct KimiCodeAuth: Sendable, Equatable {
    public var baseUrl: String
    public var oauthHost: String
    public var storage: String
    public var storageName: String
    public var home: String
    public var credentialPath: String
    public var lockTarget: String

    public init(
        baseUrl: String, oauthHost: String, storage: String, storageName: String,
        home: String, credentialPath: String, lockTarget: String
    ) {
        self.baseUrl = baseUrl
        self.oauthHost = oauthHost
        self.storage = storage
        self.storageName = storageName
        self.home = home
        self.credentialPath = credentialPath
        self.lockTarget = lockTarget
    }
}

public enum KimiCodeAuthResolver {
    public static let managedProvider = "managed:kimi-code"
    public static let defaultBaseUrl = "https://api.kimi.com/coding/v1"
    public static let defaultOAuthHost = "https://auth.kimi.com"
    public static let defaultOAuthKey = "oauth/kimi-code"
    public static let oauthClientId = "17e5f671-d194-4dfb-9706-5516cb48c098"

    static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedEndpoint(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Default host pair keeps the client's default key; any other pair gets the
    /// oar digest suffix.
    public static func oauthKey(oauthHost: String, baseUrl: String) -> String {
        let host = normalizedEndpoint(oauthHost)
        let base = normalizedEndpoint(baseUrl)
        if host == defaultOAuthHost, base == defaultBaseUrl { return defaultOAuthKey }
        let encoded = #"{"oauthHost":"\#(host)","baseUrl":"\#(base)"}"#
        return "oauth/kimi-code-env-" + String(sha256Hex(encoded).prefix(16))
    }

    public static func storageName(forKey key: String) throws -> String {
        let candidate = key.hasPrefix("oauth/") ? String(key.dropFirst("oauth/".count)) : key
        if candidate.isEmpty || candidate.hasPrefix(".") || candidate.contains("/") {
            throw KimiAuthError.invalidCredentialKey
        }
        return candidate
    }

    public enum KimiAuthError: Error, Equatable {
        case invalidCredentialKey
    }

    static func homeDirectory() -> String {
        NSHomeDirectory()
    }

    /// Pure projection of the client's `provider list --json` plus the env.
    public static func authFromProviderList(
        _ providerListJSON: Any?,
        env: [String: String]
    ) -> KimiCodeAuth? {
        guard let root = providerListJSON as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let provider = providers[managedProvider] as? [String: Any],
              provider["type"] as? String == "kimi"
        else { return nil }
        let configuredOAuth = provider["oauth"] as? [String: Any]
        let envBaseUrl = text(env["KIMI_CODE_BASE_URL"])
        let envOAuthHost = text(env["KIMI_CODE_OAUTH_HOST"] ?? env["KIMI_OAUTH_HOST"])
        let hasEnvironmentOverride = envBaseUrl != nil || envOAuthHost != nil
        let baseUrl = normalizedEndpoint(envBaseUrl ?? text(provider["baseUrl"]) ?? defaultBaseUrl)
        let oauthHost = normalizedEndpoint(envOAuthHost ?? text(configuredOAuth?["oauthHost"]) ?? defaultOAuthHost)
        let expectedKey = oauthKey(oauthHost: oauthHost, baseUrl: baseUrl)
        let configuredKey = text(configuredOAuth?["key"])
        let selectedKey = !hasEnvironmentOverride && configuredKey == expectedKey ? configuredKey! : expectedKey
        let configuredStorage = text(configuredOAuth?["storage"])
        let storage = !hasEnvironmentOverride && configuredKey == expectedKey
            && configuredStorage != nil && configuredStorage != "file"
            ? "other" : "file"
        let home = text(env["KIMI_CODE_HOME"]) ?? homeDirectory() + "/.kimi-code"
        guard let storageName = try? storageName(forKey: selectedKey) else { return nil }
        return KimiCodeAuth(
            baseUrl: baseUrl, oauthHost: oauthHost, storage: storage, storageName: storageName,
            home: home,
            credentialPath: home + "/credentials/\(storageName).json",
            lockTarget: home + "/oauth/\(storageName)"
        )
    }

    public struct ProbeResult: Sendable {
        public var stdout: String

        public init(stdout: String) {
            self.stdout = stdout
        }
    }

    /// Runs `<kimi> provider list --json` as a bounded probe child and projects
    /// it; nil when the output is not JSON or names no managed provider.
    public static func resolve(
        command: String,
        env: [String: String],
        runProbeChild: @Sendable (String, [String], [String: String]) async throws -> ProbeResult
    ) async throws -> KimiCodeAuth? {
        let output = try await runProbeChild(command, ["provider", "list", "--json"], env)
        guard let data = output.stdout.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return authFromProviderList(parsed, env: env)
    }

    /// The device headers the client sends; the platform names this daemon.
    public static func deviceHeaders(
        home: String,
        options: (platform: String, version: String),
        deviceName: String = ProcessInfo.processInfo.hostName,
        deviceModel: String = "linux x86_64",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> [String: String] {
        func ascii(_ value: String, fallback: String = "unknown") -> String {
            let cleaned = String(value.unicodeScalars.filter { (32...126).contains($0.value) })
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? fallback : cleaned
        }
        return [
            "X-Msh-Platform": ascii(options.platform),
            "X-Msh-Version": ascii(options.version),
            "X-Msh-Device-Name": ascii(deviceName),
            "X-Msh-Device-Model": ascii(deviceModel),
            "X-Msh-Os-Version": ascii(osVersion),
            "X-Msh-Device-Id": readOrCreateDeviceId(home: home),
        ]
    }

    /// The client's `<home>/device_id`, created the way the client creates it.
    public static func readOrCreateDeviceId(home: String) -> String {
        let file = home + "/device_id"
        if let data = FileManager.default.contents(atPath: file),
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        let id = UUID().uuidString.lowercased()
        let manager = FileManager.default
        try? manager.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? id.write(toFile: file, atomically: true, encoding: .utf8)
        return id
    }
}
