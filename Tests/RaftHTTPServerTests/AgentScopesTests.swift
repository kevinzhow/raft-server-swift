import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentScopesRequireTheOwningServerAndExternalAgent() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111568"
    let serverId = "33333333-3333-4333-8333-333333333632"
    let otherServerId = "33333333-3333-4333-8333-333333333633"
    accounts.addAccount(id: ownerId, email: "scopes-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "scopes", name: "Scopes", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "scopes-other", name: "Scopes Other", ownerId: ownerId)
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "managed-agent")
    let external = accounts.oauth.createAgent(serverId: serverId, name: "external-agent", runtime: "external")

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
                request.body = .init(string: "{\"email\":\"scopes-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            func headers(_ server: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = server
                return fields
            }
            let get = try await client.send(.get, headers: headers(serverId), to: "/api/agents/\(managed)/scopes")
            #expect(get.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((get.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["agentId"] as? String == managed)
            #expect(body?["mode"] as? String == "default")
            #expect((body?["scopes"] as? [String] ?? []).contains("message:send"))

            let managedPut = try await client.send(.put, headers: headers(serverId), to: "/api/agents/\(managed)/scopes") { request in
                request.body = .init(string: "{\"mode\":\"default\"}")
            }
            #expect(managedPut.status.code == 422)

            let externalPut = try await client.send(.put, headers: headers(serverId), to: "/api/agents/\(external)/scopes") { request in
                request.body = .init(string: "{\"mode\":\"default\"}")
            }
            #expect(externalPut.status == .ok)

            #expect(try await client.send(.get, headers: headers(otherServerId), to: "/api/agents/\(managed)/scopes").status == .notFound)
        }
    }
}
