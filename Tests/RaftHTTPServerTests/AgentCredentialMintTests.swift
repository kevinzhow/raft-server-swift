import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func managedAgentsCannotMintExternalCredentialsOrBootstrapTokens() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111603"
    let serverId = "33333333-3333-4333-8333-333333333653"
    accounts.addAccount(id: ownerId, email: "mint-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mint", name: "Mint", ownerId: ownerId)
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "managed-mint", creatorUserId: ownerId)
    let external = accounts.oauth.createAgent(serverId: serverId, name: "external-mint", creatorUserId: ownerId, runtime: "external")

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
                request.body = .init(string: "{\"email\":\"mint-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let mk = try await client.send(.post, headers: headers, to: "/api/agents/\(managed)/credentials") { request in
                request.body = .init(string: "{}")
            }
            #expect(mk.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((mk.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "agent_not_external")
            let boots = try await client.send(.post, headers: headers, to: "/api/agents/\(managed)/bootstrap-tokens") { request in
                request.body = .init(string: "{}")
            }
            #expect(boots.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((boots.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "agent_not_external")

            let okCred = try await client.send(.post, headers: headers, to: "/api/agents/\(external)/credentials") { request in
                request.body = .init(string: "{}")
            }
            #expect(okCred.status.code == 201)
            let okBoot = try await client.send(.post, headers: headers, to: "/api/agents/\(external)/bootstrap-tokens") { request in
                request.body = .init(string: "{}")
            }
            #expect(okBoot.status.code == 201)
            #expect((try JSONSerialization.jsonObject(with: Data((okBoot.body.string ?? "").utf8)) as? [String: Any])?["scopes"] as? [String] == ["channels", "knowledge", "mentions", "reactions", "read", "send", "tasks"])
        }
    }
}
