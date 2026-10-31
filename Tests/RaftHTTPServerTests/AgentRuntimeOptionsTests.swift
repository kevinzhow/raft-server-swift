import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func memberCanReadRuntimeOptionsButNotBootstrapTokens() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111586"
    let memberId = "11111111-1111-4111-8111-111111111587"
    let serverId = "33333333-3333-4333-8333-333333333642"
    accounts.addAccount(id: ownerId, email: "runtime-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "runtime-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-options", name: "Runtime Options", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "runtime-options-agent", creatorUserId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let memberToken = try await login("runtime-member@slock.test")
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/agents/\(agent)/runtime-options").status == .ok)
            let bootstrap = try await client.send(.post, headers: headers(memberToken), to: "/api/agents/\(agent)/bootstrap-tokens") { request in
                request.body = .init(string: "{}")
            }
            #expect(bootstrap.status == .forbidden)
            let body = try JSONSerialization.jsonObject(with: Data((bootstrap.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "insufficient_role")
            #expect((body?["error"] as? String ?? "").contains("issueAgentCredentials"))
        }
    }
}
