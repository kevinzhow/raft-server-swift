import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func removedAppAdminAndOperatorRoutesStayAt404() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111391"
    let serverId = "33333333-3333-4333-8333-333333333528"
    accounts.addAccount(id: ownerId, email: "removed-routes@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "removed-routes", name: "Removed Routes", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"removed-routes@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let appAdmin = try await client.send(.get, headers: headers, to: "/api/app-admin/me")
            #expect(appAdmin.status == .notFound)

            let operatorPathsAndBodies: [(String, String)] = [
                ("/api/oauth/operator/feature-flags/removed_flag/evaluate-preview", "{\"serverId\":\"\(serverId)\",\"userId\":\"\(ownerId)\",\"platform\":\"web\"}"),
                ("/api/oauth/operator/feature-flags/removed_flag/server-allowlist/rules", "{\"serverIds\":[\"\(serverId)\"],\"reason\":\"removed\",\"expectedConfigVersion\":1}"),
                ("/api/oauth/operator/feature-flags/apple_web_login_v0/platform-allowlist/web/rules", "{\"reason\":\"removed\",\"expectedConfigVersion\":1}"),
            ]
            for (path, body) in operatorPathsAndBodies {
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .notFound)
            }
        }
    }
}
