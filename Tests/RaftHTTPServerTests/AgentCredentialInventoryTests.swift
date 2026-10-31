import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func externalCredentialInventoryAndRevocation() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111608"
    let memberId = "11111111-1111-4111-8111-111111111609"
    let serverId = "33333333-3333-4333-8333-333333333656"
    accounts.addAccount(id: ownerId, email: "inventory-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "inventory-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inventory", name: "Inventory", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "inventory-agent", creatorUserId: ownerId, runtime: "external")

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
            let ownerToken = try await login("inventory-owner@slock.test")
            let memberToken = try await login("inventory-member@slock.test")
            let mint = try await client.send(.post, headers: headers(ownerToken), to: "/api/agents/\(agent)/credentials") { request in
                request.body = .init(string: "{}")
            }
            #expect(mint.status.code == 201)
            #expect(mint.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let minted = try JSONSerialization.jsonObject(with: Data((mint.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let credentialId = minted["credentialId"] as? String ?? ""
            let apiKey = minted["apiKey"] as? String ?? ""
            #expect(apiKey.hasPrefix("sk_agent_"))
            #expect(minted["agentId"] as? String == agent)
            #expect(minted["serverId"] as? String == serverId)

            let list = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(agent)/credentials")
            let inventory = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let rows = inventory["credentials"] as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            #expect(rows.first?["id"] as? String == credentialId)
            #expect((rows.first?["maskedToken"] as? String ?? "").hasSuffix("***"))
            #expect(!(list.body.string ?? "").contains(apiKey))
            #expect(list.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/agents/\(agent)/credentials").status == .forbidden)

            for _ in 0..<2 {
                #expect(try await client.send(.delete, headers: headers(ownerToken), to: "/api/agents/\(agent)/credentials/\(credentialId)").status.code == 204)
            }
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(apiKey)"
            #expect(try await client.send(.get, headers: agentHeaders, to: "/internal/agent-api/").status == .unauthorized)
            let after = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(agent)/credentials")
            let afterRows = ((try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [String: Any])?["credentials"] as? [[String: Any]]) ?? []
            #expect(afterRows.first?["revokedAt"] != nil)
        }
    }
}
