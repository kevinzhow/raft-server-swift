import Foundation
import Testing
import RaftDaemonClient

private func defaultList() -> [String: Any] { [
    "providers": [
        "managed:kimi-code": [
            "type": "kimi",
            "baseUrl": "https://api.kimi.com/coding/v1",
            "oauth": ["key": "oauth/kimi-code", "oauthHost": "https://auth.kimi.com", "storage": "file"],
        ]
    ]
] }

@Test func defaultHostPairKeepsTheDefaultKeyAndCustomPairsGetTheDigestSuffix() throws {
    #expect(KimiCodeAuthResolver.oauthKey(oauthHost: "https://auth.kimi.com/", baseUrl: "https://api.kimi.com/coding/v1") == "oauth/kimi-code")
    let custom = KimiCodeAuthResolver.oauthKey(oauthHost: "https://auth.example.test", baseUrl: "https://api.example.test/v1")
    #expect(custom.range(of: #"^oauth/kimi-code-env-[0-9a-f]{16}$"#, options: .regularExpression) != nil)
    #expect(try KimiCodeAuthResolver.storageName(forKey: custom) == String(custom.dropFirst("oauth/".count)))
    #expect(throws: KimiCodeAuthResolver.KimiAuthError.invalidCredentialKey) {
        try KimiCodeAuthResolver.storageName(forKey: "oauth/.hidden")
    }
}

@Test func providerListProjectionFollowsOar() throws {
    let home = "/tmp/kimi-home-fixture"
    let auth = try #require(KimiCodeAuthResolver.authFromProviderList(defaultList(), env: ["KIMI_CODE_HOME": home]))
    #expect(auth.baseUrl == "https://api.kimi.com/coding/v1")
    #expect(auth.oauthHost == "https://auth.kimi.com")
    #expect(auth.storage == "file")
    #expect(auth.storageName == "kimi-code")
    #expect(auth.home == home)
    #expect(auth.credentialPath == home + "/credentials/kimi-code.json")
    #expect(auth.lockTarget == home + "/oauth/kimi-code")

    let overridden = try #require(KimiCodeAuthResolver.authFromProviderList(defaultList(), env: [
        "KIMI_CODE_HOME": home, "KIMI_CODE_OAUTH_HOST": "https://auth.example.test",
    ]))
    #expect(overridden.storageName.hasPrefix("kimi-code-env-"))
    #expect(overridden.oauthHost == "https://auth.example.test")

    let otherList: [String: Any] = [
        "providers": ["managed:kimi-code": ["type": "kimi", "oauth": ["key": "oauth/kimi-code", "storage": "keyring"]]]
    ]
    let other = try #require(KimiCodeAuthResolver.authFromProviderList(otherList, env: ["KIMI_CODE_HOME": home]))
    #expect(other.storage == "other")

    #expect(KimiCodeAuthResolver.authFromProviderList(["providers": [String: Any]()], env: [:]) == nil)
    #expect(KimiCodeAuthResolver.authFromProviderList(
        ["providers": ["managed:kimi-code": ["type": "openai"]]], env: [:]
    ) == nil)
}

@Test func resolveRunsTheProviderListProbeAndProjectsItsOutput() async throws {
    final class Seen: @unchecked Sendable { var command = ""; var args: [String] = []; var env: [String: String] = [:] }
    let seen = Seen()
    let auth = try await KimiCodeAuthResolver.resolve(command: "/tmp/fake-kimi", env: ["KIMI_CODE_HOME": "/tmp/kimi-root"]) { command, args, env in
        seen.command = command
        seen.args = args
        seen.env = env
        let data = try! JSONSerialization.data(withJSONObject: defaultList())
        return KimiCodeAuthResolver.ProbeResult(stdout: String(decoding: data, as: UTF8.self))
    }
    #expect(seen.command == "/tmp/fake-kimi")
    #expect(seen.args == ["provider", "list", "--json"])
    #expect(seen.env["KIMI_CODE_HOME"] == "/tmp/kimi-root")
    #expect(auth?.credentialPath == "/tmp/kimi-root/credentials/kimi-code.json")
    #expect(auth?.lockTarget == "/tmp/kimi-root/oauth/kimi-code")

    let unparseable = try await KimiCodeAuthResolver.resolve(command: "/tmp/fake-kimi", env: [:]) { _, _, _ in
        .init(stdout: "not json")
    }
    #expect(unparseable == nil)
}
