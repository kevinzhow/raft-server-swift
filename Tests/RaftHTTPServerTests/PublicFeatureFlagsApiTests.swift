import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func publicFlagServices(_ flags: [PublicFeatureFlag], accounts: EmailLoginDirectory) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        featureFlags: flags,
        emailAccounts: accounts
    )
}

@Test func publicFeatureFlagsApiAnswersMarkedFlagsFromRulesAndDefaults() async throws {
    let accounts = EmailLoginDirectory()
    let flags: [PublicFeatureFlag] = [
        PublicFeatureFlag(key: "preauth_default_on_v0", defaultEnabled: true, preAuthEvaluable: true),
        PublicFeatureFlag(key: "preauth_unmarked_v0", defaultEnabled: true),
        PublicFeatureFlag(key: "preauth_disabled_v0", enabled: false, defaultEnabled: true, preAuthEvaluable: true),
        PublicFeatureFlag(key: "preauth_killed_v0", killSwitch: true, defaultEnabled: true, preAuthEvaluable: true),
        PublicFeatureFlag(
            key: "preauth_mobile_v0",
            defaultEnabled: false,
            preAuthEvaluable: true,
            rules: [PublicFeatureFlagRule(stage: "platform", decision: "allow", values: ["mobile"])]
        ),
        PublicFeatureFlag(
            key: "preauth_server_rule_v0",
            defaultEnabled: false,
            preAuthEvaluable: true,
            rules: [PublicFeatureFlagRule(stage: "server", decision: "allow", values: ["33333333-3333-4333-8333-333333991001"])]
        ),
    ]
    let keys = "preauth_default_on_v0,preauth_unmarked_v0,preauth_disabled_v0,preauth_killed_v0,preauth_mobile_v0,preauth_server_rule_v0,preauth_missing_v0"

    try await withApp { app in
        configure(app, services: publicFlagServices(flags, accounts: accounts))
        try await app.testing { client in
            let mobile = try await client.get(URI(string: "/api/public/feature-flags?keys=\(keys)&platform=mobile"))
            #expect(mobile.status == .ok)
            #expect(mobile.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=60")
            let mobileBody = try JSONSerialization.jsonObject(with: Data((mobile.body.string ?? "").utf8)) as? [String: Any]
            let mobileFlags = mobileBody?["flags"] as? [String: Bool] ?? [:]
            #expect(mobileFlags == [
                "preauth_default_on_v0": true,
                "preauth_unmarked_v0": false,
                "preauth_disabled_v0": false,
                "preauth_killed_v0": false,
                "preauth_mobile_v0": true,
                "preauth_server_rule_v0": false,
                "preauth_missing_v0": false,
            ])

            let web = try await client.get(URI(string: "/api/public/feature-flags?keys=\(keys)&platform=web"))
            #expect(web.status == .ok)
            let webFlags = ((try JSONSerialization.jsonObject(with: Data((web.body.string ?? "").utf8)) as? [String: Any])?["flags"] as? [String: Bool]) ?? [:]
            #expect(webFlags["preauth_mobile_v0"] == false)

            let noPlatform = try await client.get(URI(string: "/api/public/feature-flags?keys=preauth_mobile_v0,preauth_default_on_v0"))
            #expect(noPlatform.status == .ok)
            let noPlatformBody = try JSONSerialization.jsonObject(with: Data((noPlatform.body.string ?? "").utf8)) as? [String: Any]
            #expect((noPlatformBody?["flags"] as? [String: Bool]) == ["preauth_mobile_v0": false, "preauth_default_on_v0": true])

            // Credentials are ignored so one URL has one cacheable answer.
            var headers = HTTPFields()
            headers[.authorization] = "Bearer some-session"
            let withAuth = try await client.get(URI(string: "/api/public/feature-flags?keys=\(keys)&platform=mobile"), headers: headers)
            #expect(withAuth.status == .ok)
            #expect(withAuth.body.string == mobile.body.string)
        }
    }
}

@Test func publicFeatureFlagsApiRejectsBadKeysAndPlatforms() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: publicFlagServices([], accounts: accounts))
        try await app.testing { client in
            let manyKeys = (0..<51).map { "k\($0)" }.joined(separator: ",")
            for query in ["", "keys=", "keys=Bad_Key", "keys=\(manyKeys)", "keys=ok_v0&platform=android"] {
                let response = try await client.get(URI(string: "/api/public/feature-flags?\(query)"))
                #expect(response.status == .badRequest, "\(query)")
            }
        }
    }
}
