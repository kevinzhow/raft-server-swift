import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func externalAgentStatusFollowsCredentialLifecycle() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111274"
    let serverId = "33333333-3333-4333-8333-333333333461"
    accounts.addAccount(id: ownerId, email: "external-status@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "external-status", name: "External Status Server", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"external-status@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let create = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"external-status-agent\",\"external\":true}")
            }
            #expect(create.status == .ok)
            let created = try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8)) as? [String: Any]
            let agentId = created?["id"] as? String ?? ""

            func status() async throws -> (ClientResponse, [String: Any]) {
                let response = try await client.send(.get, headers: headers, to: "/api/agents/\(agentId)/external-status")
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                return (response, body)
            }

            let waiting = try await status()
            #expect(waiting.0.status == .ok)
            #expect(waiting.1["setupState"] as? String == "waiting_for_login")
            #expect(waiting.1["credentialLastUsedAt"] == nil || waiting.1["credentialLastUsedAt"] is NSNull)
            #expect(waiting.1["lastActivityAt"] == nil || waiting.1["lastActivityAt"] is NSNull)

            _ = accounts.mintAgentCredential(agentId: agentId, scopes: ["send"], name: "status-test")
            let minted = try await status()
            #expect(minted.1["setupState"] as? String == "credential_minted")
            #expect(minted.1["credentialLastUsedAt"] == nil || minted.1["credentialLastUsedAt"] is NSNull)

            accounts.markAgentCredentialUsed(agentId: agentId)
            let connected = try await status()
            #expect(connected.1["setupState"] as? String == "connected")
            #expect(connected.1["credentialLastUsedAt"] is String)
            #expect(connected.1["lastActivityAt"] == nil || connected.1["lastActivityAt"] is NSNull)

            let managedId = accounts.oauth.createAgent(serverId: serverId, name: "managed-status-agent")
            let managed = try await client.send(.get, headers: headers, to: "/api/agents/\(managedId)/external-status")
            #expect(managed.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((managed.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Agent is not external")

            let list = try await client.send(.get, headers: headers, to: "/api/agents")
            let rows = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.first { $0["id"] as? String == managedId }?["serverRole"] as? String == "member")
            let profile = try await client.send(.get, headers: headers, to: "/api/agents/\(managedId)")
            #expect((try JSONSerialization.jsonObject(with: Data((profile.body.string ?? "").utf8)) as? [String: Any])?["serverRole"] as? String == "member")
        }
    }
}
