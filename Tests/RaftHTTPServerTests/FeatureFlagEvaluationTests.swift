import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct FeatureFlagFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let outsiderEmail: String
}

private func makeFeatureFlagFixture(suffix: String) -> FeatureFlagFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 900_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 100_000 + number)
    let outsiderId = String(format: "11111111-1111-4111-8111-%012d", 200_000 + number)
    let ownerEmail = "feature-owner-\(suffix)@slock.test"
    let outsiderEmail = "feature-outsider-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: outsiderId, email: outsiderEmail, password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "feature-\(suffix)", name: "Feature \(suffix)", ownerId: ownerId)
    return FeatureFlagFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        outsiderEmail: outsiderEmail
    )
}

private func featureLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func featureEvaluate(_ client: any Client, token: String, body: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: "/api/feature-flags/evaluate") { request in
        request.body = .init(string: body)
    }
}

private func featureEvaluation(_ response: ClientResponse) -> [String: Any] {
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
    return ((body?["evaluations"] as? [[String: Any]])?.first) ?? [:]
}

@Test func featureFlagEvaluationIsMemberScopedAndHonoursRules() async throws {
    let fixture = makeFeatureFlagFixture(suffix: "101")
    let accounts = fixture.accounts

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await featureLogin(client, email: fixture.ownerEmail)
            let outsider = try await featureLogin(client, email: fixture.outsiderEmail)

            let productEval = try await featureEvaluate(client, token: owner, body: "{\"serverId\":\"\(fixture.serverId)\",\"keys\":[\"attachment_comments_v0\"]}")
            #expect(productEval.status == .ok)
            #expect(featureEvaluation(productEval)["key"] as? String == "attachment_comments_v0")
            #expect(featureEvaluation(productEval)["enabled"] as? Bool == true)
            #expect(featureEvaluation(productEval)["reason"] as? String == "default")

            let outsiderEval = try await featureEvaluate(client, token: outsider, body: "{\"serverId\":\"\(fixture.serverId)\",\"keys\":[\"attachment_comments_v0\"]}")
            #expect(outsiderEval.status == .forbidden)

            accounts.createFeatureFlagForTesting(key: "api_test_v0", defaultEnabled: false)
            accounts.addFeatureFlagRuleForTesting(key: "api_test_v0", stage: "server", decision: "allow", values: [fixture.serverId])
            accounts.addFeatureFlagRuleForTesting(key: "api_test_v0", stage: "platform", decision: "deny", values: ["mobile"])

            let serverRule = try await featureEvaluate(client, token: owner, body: "{\"serverId\":\"\(fixture.serverId)\",\"keys\":[\"api_test_v0\"]}")
            #expect(serverRule.status == .ok)
            #expect(featureEvaluation(serverRule)["enabled"] as? Bool == true)
            #expect(featureEvaluation(serverRule)["reason"] as? String == "server_rule")

            let webEval = try await featureEvaluate(client, token: owner, body: "{\"serverId\":\"\(fixture.serverId)\",\"platform\":\"web\",\"keys\":[\"api_test_v0\"]}")
            #expect(webEval.status == .ok)
            #expect(featureEvaluation(webEval)["reason"] as? String == "server_rule")
            #expect(featureEvaluation(webEval)["enabled"] as? Bool == true)

            let mobileEval = try await featureEvaluate(client, token: owner, body: "{\"serverId\":\"\(fixture.serverId)\",\"platform\":\"mobile\",\"keys\":[\"api_test_v0\"]}")
            #expect(mobileEval.status == .ok)
            #expect(featureEvaluation(mobileEval)["enabled"] as? Bool == false)
            #expect(featureEvaluation(mobileEval)["reason"] as? String == "platform_rule")

            let invalidPlatform = try await featureEvaluate(client, token: owner, body: "{\"serverId\":\"\(fixture.serverId)\",\"platform\":\"desktop\",\"keys\":[\"api_test_v0\"]}")
            #expect(invalidPlatform.status == .badRequest)

            accounts.setFeatureFlagKillSwitchForTesting(key: "attachment_comments_v0", killSwitch: true)
            let killed = try await featureEvaluate(client, token: owner, body: "{\"serverId\":\"\(fixture.serverId)\",\"keys\":[\"attachment_comments_v0\"]}")
            #expect(killed.status == .ok)
            #expect(featureEvaluation(killed)["enabled"] as? Bool == false)
            #expect(featureEvaluation(killed)["reason"] as? String == "kill_switch")
        }
    }
}

@Test func featureFlagClientFactsDriveClientRulesWithoutFailingTheRequest() async throws {
    let fixture = makeFeatureFlagFixture(suffix: "102")
    let accounts = fixture.accounts
    accounts.createFeatureFlagForTesting(key: "api_client_v0", defaultEnabled: false)
    accounts.addFeatureFlagRuleForTesting(
        key: "api_client_v0",
        stage: "client",
        decision: "allow",
        values: [fixture.serverId],
        clientOs: ["android"],
        minClientBuild: 1120131
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await featureLogin(client, email: fixture.ownerEmail)
            func evaluate(_ extra: String) async throws -> [String: Any] {
                let response = try await featureEvaluate(
                    client,
                    token: owner,
                    body: "{\"serverId\":\"\(fixture.serverId)\",\"platform\":\"mobile\",\"keys\":[\"api_client_v0\"]\(extra)}"
                )
                #expect(response.status == .ok)
                return featureEvaluation(response)
            }

            let matched = try await evaluate(",\"os\":\"android\",\"appVersion\":\"1.12.0\",\"buildNumber\":\"1120131\",\"buildType\":\"alpha\"")
            #expect(matched["enabled"] as? Bool == true)
            #expect(matched["reason"] as? String == "client_rule")
            let old = try await evaluate(",\"os\":\"android\",\"buildNumber\":\"1120130\"")
            #expect(old["enabled"] as? Bool == false)
            #expect(old["reason"] as? String == "default")

            accounts.createFeatureFlagForTesting(key: "api_client_alpha_v0", defaultEnabled: false)
            accounts.addFeatureFlagRuleForTesting(
                key: "api_client_alpha_v0",
                stage: "client",
                decision: "allow",
                values: [fixture.serverId],
                clientBuildTypes: ["alpha"]
            )
            func alpha(_ buildType: String) async throws -> Bool {
                let response = try await featureEvaluate(
                    client,
                    token: owner,
                    body: "{\"serverId\":\"\(fixture.serverId)\",\"platform\":\"mobile\",\"keys\":[\"api_client_alpha_v0\"],\"os\":\"android\",\"buildNumber\":\"1000031\",\"buildType\":\(buildType)}"
                )
                #expect(response.status == .ok)
                return featureEvaluation(response)["enabled"] as? Bool ?? false
            }
            #expect(try await alpha("\"alpha\"") == true)
            #expect(try await alpha("\"release\"") == false)
            #expect(try await alpha("\"ALPHA\"") == false)
            #expect(try await alpha("\"connectedTest\"") == false)
            #expect(try await alpha("null") == false)

            for extra in [
                "",
                ",\"os\":\"desktop\",\"buildNumber\":\"1120200\"",
                ",\"os\":\"android\",\"buildNumber\":\"1.12.0\"",
                ",\"os\":\"android\",\"buildNumber\":null",
                ",\"os\":\"android\",\"buildNumber\":-5",
                ",\"os\":7,\"buildNumber\":1120200",
            ] {
                let evaluation = try await evaluate(extra)
                #expect(evaluation["enabled"] as? Bool == false, "\(extra)")
                #expect(evaluation["reason"] as? String == "default", "\(extra)")
            }
        }
    }
}
