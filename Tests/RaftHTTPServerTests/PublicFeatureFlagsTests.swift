import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let keys = [
    "preauth_default_on_v0",
    "preauth_unmarked_v0",
    "preauth_disabled_v0",
    "preauth_killed_v0",
    "preauth_mobile_v0",
    "preauth_server_rule_v0",
    "preauth_missing_v0",
].joined(separator: ",")

private let catalog: [PublicFeatureFlag] = [
    PublicFeatureFlag(key: "preauth_default_on_v0", defaultEnabled: true, preAuthEvaluable: true),
    PublicFeatureFlag(key: "preauth_unmarked_v0", defaultEnabled: true),
    PublicFeatureFlag(key: "preauth_disabled_v0", enabled: false, defaultEnabled: true, preAuthEvaluable: true),
    PublicFeatureFlag(key: "preauth_killed_v0", killSwitch: true, defaultEnabled: true, preAuthEvaluable: true),
    PublicFeatureFlag(
        key: "preauth_mobile_v0",
        preAuthEvaluable: true,
        rules: [PublicFeatureFlagRule(stage: "platform", decision: "allow", values: ["mobile"])]
    ),
    PublicFeatureFlag(
        key: "preauth_server_rule_v0",
        preAuthEvaluable: true,
        rules: [PublicFeatureFlagRule(stage: "server", decision: "allow", values: ["server-1"])]
    ),
]

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func flags(_ response: ClientResponse) throws -> [String: Bool] {
    let object = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
    let flags = object?["flags"] as? [String: Bool] ?? [:]
    return flags
}

private func app() -> FallbackServices {
    FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, featureFlags: catalog)
}

@Test func publicFeatureFlagsAnswerBeforeLoginFromMarkedFlagsOnly() async throws {
    let mobileBody = """
    {"flags":{"preauth_default_on_v0":true,"preauth_unmarked_v0":false,"preauth_disabled_v0":false,"preauth_killed_v0":false,"preauth_mobile_v0":true,"preauth_server_rule_v0":false,"preauth_missing_v0":false}}
    """
    try await withApp { application in
        configure(application, services: app())
        try await application.testing { client in
            let mobile = try await client.get("/api/public/feature-flags?keys=\(keys)&platform=mobile")
            #expect(mobile.status == .ok)
            #expect(mobile.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=60")
            #expect(mobile.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(bodyText(mobile) == mobileBody)

            let web = try await client.get("/api/public/feature-flags?keys=\(keys)&platform=web")
            #expect(web.status == .ok)
            #expect(try flags(web)["preauth_mobile_v0"] == false)

            let noPlatform = try await client.get("/api/public/feature-flags?keys=preauth_mobile_v0,preauth_default_on_v0")
            #expect(noPlatform.status == .ok)
            #expect(bodyText(noPlatform) == "{\"flags\":{\"preauth_mobile_v0\":false,\"preauth_default_on_v0\":true}}")

            let withAuth = try await client.get(
                "/api/public/feature-flags?keys=\(keys)&platform=mobile",
                headers: [HTTPField.Name("Authorization")!: "Bearer owner-token"]
            )
            #expect(withAuth.status == .ok)
            #expect(bodyText(withAuth) == bodyText(mobile))
        }
    }
}

@Test func publicFeatureFlagsRejectBadKeysAndPlatforms() async throws {
    let tooMany = (0..<51).map { "k\($0)" }.joined(separator: ",")
    let queries = [
        "",
        "keys=",
        "keys=Bad_Key",
        "keys=\(tooMany)",
        "keys=ok_v0&platform=android",
    ]
    try await withApp { application in
        configure(application, services: app())
        try await application.testing { client in
            for query in queries {
                let path = query.isEmpty ? "/api/public/feature-flags" : "/api/public/feature-flags?\(query)"
                let response = try await client.get(URI(string: path))
                #expect(response.status == .badRequest)
            }
            let badKey = try await client.get("/api/public/feature-flags?keys=Bad_Key")
            #expect(bodyText(badKey) == "{\"error\":\"keys must contain 1-50 valid feature flag keys\"}")
            let badPlatform = try await client.get("/api/public/feature-flags?keys=ok_v0&platform=android")
            #expect(bodyText(badPlatform) == "{\"error\":\"platform must be web or mobile\"}")
        }
    }
}
