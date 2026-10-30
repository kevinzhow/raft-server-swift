import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentEnvVarsAreValidatedAtTheBoundary() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111272"
    let serverId = "33333333-3333-4333-8333-333333333459"
    accounts.addAccount(id: ownerId, email: "parse-envvars@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "parse-envvars", name: "Parse EnvVars Server", ownerId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"parse-envvars@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func create(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/agents") { request in
                    request.body = .init(string: body)
                }
            }
            func errorText(_ response: ClientResponse) -> String {
                ((try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any])?["error"] as? String ?? ""
            }

            let rejectionCases: [(String, String, String)] = [
                ("reject-non-object", "\"TEAM_FLAG=1\"", "envVars must be an object"),
                ("reject-array", "[\"TEAM_FLAG\"]", "envVars must be an object"),
                ("reject-non-string-value", "{\"TEAM_FLAG\":1}", "envVars keys and values must be strings"),
                ("reject-bad-key", "{\"1BAD\":\"x\"}", "Invalid env var key \"1BAD\": must match [A-Za-z_][A-Za-z0-9_]*"),
                ("reject-null-byte", "{\"TEAM_FLAG\":\"ab\\u0000cd\"}", "envVars keys and values must not contain null bytes"),
            ]
            for (name, envJSON, reason) in rejectionCases {
                let response = try await create("{\"name\":\"\(name)\",\"runtime\":\"claude\",\"model\":\"sonnet\",\"envVars\":\(envJSON)}")
                #expect(response.status == .badRequest)
                #expect(errorText(response) == reason)
            }

            let valid = try await create("{\"name\":\"parse-valid\",\"runtime\":\"claude\",\"model\":\"sonnet\",\"envVars\":{\"TEAM_FLAG\":\"enabled\"}}")
            #expect(valid.status == .ok)
            let validBody = try JSONSerialization.jsonObject(with: Data((valid.body.string ?? "").utf8)) as? [String: Any]
            let validId = validBody?["id"] as? String ?? ""
            #expect((validBody?["envVars"] as? [String: String])?["TEAM_FLAG"] == "enabled")

            #expect(try await create("{\"name\":\"parse-null-env\",\"runtime\":\"claude\",\"model\":\"sonnet\",\"envVars\":null}").status == .ok)
            #expect(try await create("{\"name\":\"parse-undefined-env\",\"runtime\":\"claude\",\"model\":\"sonnet\"}").status == .ok)

            func patch(_ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers, to: "/api/agents/\(validId)") { request in
                    request.body = .init(string: body)
                }
            }
            func currentEnv() async throws -> [String: String] {
                let response = try await client.send(.get, headers: headers, to: "/api/agents/\(validId)")
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return body?["envVars"] as? [String: String] ?? [:]
            }

            let badPatch = try await patch("{\"envVars\":{\"TEAM_FLAG\":1}}")
            #expect(badPatch.status == .badRequest)
            #expect(errorText(badPatch) == "envVars keys and values must be strings")
            #expect(try await currentEnv()["TEAM_FLAG"] == "enabled")

            #expect(try await patch("{\"displayName\":\"renamed\"}").status == .ok)
            #expect(try await currentEnv()["TEAM_FLAG"] == "enabled")

            #expect(try await patch("{\"envVars\":{\"TEAM_FLAG\":\"changed\"}}").status == .ok)
            #expect(try await currentEnv()["TEAM_FLAG"] == "changed")
        }
    }
}
