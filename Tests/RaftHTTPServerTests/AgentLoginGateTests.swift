import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentLoginBootstrapRouteIsGatedByItsEnvironmentFlag() async throws {
    unsetenv("SLOCK_SELF_HOSTED_RUNNER_BOOTSTRAP_ENABLED")
    defer { unsetenv("SLOCK_SELF_HOSTED_RUNNER_BOOTSTRAP_ENABLED") }
    let accounts = EmailLoginDirectory()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/api/agent/login") { request in
                    request.body = .init(string: body)
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            let disabled = try await login("{\"bootstrapToken\":\"abtk_test\"}")
            #expect(disabled.status == .notFound)
            #expect(payload(disabled)["code"] as? String == "self_hosted_runner_bootstrap_disabled")
            #expect(try await login("{}").status == .notFound)

            setenv("SLOCK_SELF_HOSTED_RUNNER_BOOTSTRAP_ENABLED", "true", 1)
            let missing = try await login("{}")
            #expect(missing.status == .badRequest)
            #expect(payload(missing)["code"] as? String == "missing_bootstrap_token")
            let blank = try await login("{\"bootstrapToken\":\"   \"}")
            #expect(blank.status == .badRequest)
            #expect(payload(blank)["code"] as? String == "missing_bootstrap_token")

            let unknown = try await login("{\"bootstrapToken\":\"abtk_test\"}")
            #expect(unknown.status == .unauthorized)
            #expect(payload(unknown)["code"] as? String == "token_invalid")
        }
    }
}
