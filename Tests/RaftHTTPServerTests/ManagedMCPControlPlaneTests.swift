import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ManagedMCPFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerEmail: String
    let memberEmail: String
    let agentId: String
}

private func makeManagedMCPFixture(suffix: String) -> ManagedMCPFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 600_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 500_000 + number)
    let memberId = String(format: "11111111-1111-4111-8111-%012d", 510_000 + number)
    let ownerEmail = "mcp-owner-\(suffix)@slock.test"
    let memberEmail = "mcp-member-\(suffix)@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    let slug = "managed-mcp-\(suffix)"
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Managed MCP API", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "managed-mcp-agent-\(suffix)", runtime: "claude")
    return ManagedMCPFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: slug,
        ownerEmail: ownerEmail,
        memberEmail: memberEmail,
        agentId: agent
    )
}

private func managedMCPLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func managedMCPHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func managedMCPObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func managedMCPControlPlaneIsGatedAndNeverReturnsCredentialValues() async throws {
    let fixture = makeManagedMCPFixture(suffix: "891")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await managedMCPLogin(client, email: fixture.ownerEmail)
            let member = try await managedMCPLogin(client, email: fixture.memberEmail)
            let memberHeaders = managedMCPHeaders(member, fixture.serverId)
            let ownerHeaders = managedMCPHeaders(owner, fixture.serverId)

            let memberRead = try await client.get("/api/mcp/agents/\(fixture.agentId)", headers: memberHeaders)
            #expect(memberRead.status == .ok)

            let forbiddenCreate = try await client.send(.post, headers: memberHeaders, to: "/api/mcp/servers") { request in
                request.body = .init(string: "{\"name\":\"Denied\",\"endpointUrl\":\"https://example.com/mcp\"}")
            }
            #expect(forbiddenCreate.status == .forbidden)

            let emptyCatalog = try await client.get("/api/mcp/servers", headers: memberHeaders)
            #expect(emptyCatalog.status == .ok)
            #expect((try managedMCPObject(emptyCatalog)["servers"] as? [[String: Any]] ?? []).isEmpty)

            let create = try await client.send(.post, headers: ownerHeaders, to: "/api/mcp/servers") { request in
                request.body = .init(string: "{\"name\":\"Private MCP\",\"endpointUrl\":\"https://example.com/mcp\",\"headers\":{\"Authorization\":\"Bearer route-secret\"}}")
            }
            #expect(create.status == .created)
            let created = try managedMCPObject(create)
            let createdId = try #require(created["id"] as? String)
            #expect(created["hasCredentials"] as? Bool == true)
            #expect(created["credentialHeaderNames"] as? [String] == ["Authorization"])
            #expect(!(create.body.string ?? "").contains("route-secret"))
            #expect(!(create.body.string ?? "").contains("encryptedHeaders"))

            let queryCreate = try await client.send(.post, headers: ownerHeaders, to: "/api/mcp/servers") { request in
                request.body = .init(string: "{\"name\":\"Query secret rejected\",\"endpointUrl\":\"https://example.com/mcp?token=must-not-persist\"}")
            }
            #expect(queryCreate.status == .badRequest)
            let queryError = try managedMCPObject(queryCreate)
            #expect(queryError["code"] as? String == "managed_mcp_endpoint_invalid")
            #expect(!(queryCreate.body.string ?? "").contains("must-not-persist"))

            fixture.accounts.setManagedMCPServerEndpointForTesting(id: createdId, endpointUrl: "https://example.com/mcp?token=legacy-member-secret")
            let memberCatalog = try await client.get("/api/mcp/servers", headers: memberHeaders)
            #expect(memberCatalog.status == .ok)
            let memberServers = try managedMCPObject(memberCatalog)["servers"] as? [[String: Any]] ?? []
            #expect(memberServers.count == 1)
            #expect(memberServers.first?["id"] as? String == createdId)
            #expect(memberServers.first?["endpointUrl"] as? String == "https://example.com/mcp")
            #expect(!(memberCatalog.body.string ?? "").contains("route-secret"))
            #expect(!(memberCatalog.body.string ?? "").contains("legacy-member-secret"))
            #expect(!(memberCatalog.body.string ?? "").contains("encryptedHeaders"))
            fixture.accounts.setManagedMCPServerEndpointForTesting(id: createdId, endpointUrl: "https://example.com/mcp")

            let forbiddenPatch = try await client.send(.patch, headers: memberHeaders, to: "/api/mcp/servers/\(createdId)") { request in
                request.body = .init(string: "{\"name\":\"Denied edit\"}")
            }
            #expect(forbiddenPatch.status == .forbidden)
            let forbiddenDelete = try await client.send(.delete, headers: memberHeaders, to: "/api/mcp/servers/\(createdId)")
            #expect(forbiddenDelete.status == .forbidden)

            let serverCatalog = try await client.get("/api/mcp/servers", headers: ownerHeaders)
            #expect(serverCatalog.status == .ok)
            let serverBody = try managedMCPObject(serverCatalog)
            let serverRows = serverBody["servers"] as? [[String: Any]] ?? []
            #expect(serverRows.count == 1)
            #expect(serverRows.first?["assignment"] is NSNull)
            let recommendations = serverBody["recommendations"] as? [[String: Any]] ?? []
            #expect(recommendations.compactMap { $0["id"] as? String } == ["notion", "linear"])
            #expect(!(serverCatalog.body.string ?? "").contains("route-secret"))

            let agentCatalog = try await client.get("/api/mcp/agents/\(fixture.agentId)", headers: ownerHeaders)
            #expect(agentCatalog.status == .ok)
            #expect(!(agentCatalog.body.string ?? "").contains("route-secret"))
            #expect(!(agentCatalog.body.string ?? "").contains("encryptedHeaders"))

            let credentialPatch = try await client.send(.patch, headers: ownerHeaders, to: "/api/mcp/servers/\(createdId)") { request in
                request.body = .init(string: "{\"credentialPatch\":{\"upsertHeaders\":{\"X-New\":\"replacement-secret\"},\"removeHeaderNames\":[\"Authorization\"]}}")
            }
            #expect(credentialPatch.status == .ok)
            let patched = try managedMCPObject(credentialPatch)
            #expect(patched["credentialHeaderNames"] as? [String] == ["X-New"])
            #expect(!(credentialPatch.body.string ?? "").contains("replacement-secret"))

            let notion = try await client.send(.post, headers: ownerHeaders, to: "/api/mcp/servers") { request in
                request.body = .init(string: "{\"name\":\"Notion\",\"provider\":\"notion\",\"authMode\":\"oauth\",\"endpointUrl\":\"https://mcp.notion.com/mcp\"}")
            }
            #expect(notion.status == .created)
            let notionBody = try managedMCPObject(notion)
            #expect(notionBody["provider"] as? String == "notion")
            #expect(notionBody["authMode"] as? String == "oauth")
            #expect(notionBody["oauthStatus"] as? String == "disconnected")
            #expect(!(notion.body.string ?? "").contains("encryptedOAuth"))

            let wrongNotion = try await client.send(.post, headers: ownerHeaders, to: "/api/mcp/servers") { request in
                request.body = .init(string: "{\"name\":\"Notion impostor\",\"provider\":\"notion\",\"authMode\":\"oauth\",\"endpointUrl\":\"https://example.com/mcp\"}")
            }
            #expect(wrongNotion.status == .conflict)
            #expect(try managedMCPObject(wrongNotion)["code"] as? String == "managed_mcp_auth_invalid")

            let callback = try await client.get(URI(string: "/api/mcp/oauth/callback?state=invalid&code=invalid"))
            #expect(callback.status == .badRequest)
            #expect(callback.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            #expect((callback.headers[HTTPField.Name("Content-Security-Policy")!] ?? "").contains("default-src 'none'"))
            let callbackBody = callback.body.string ?? ""
            for needle in ["<main>", "RAFT", "MCP was not connected", "Close window", "raft-managed-mcp-oauth-result", "managed-mcp-oauth-result"] {
                #expect(callbackBody.contains(needle))
            }
            #expect(!callbackBody.contains("setTimeout"))
            #expect(!callbackBody.contains("setInterval"))

            let metadata = try await client.get("/api/mcp/oauth/client-metadata")
            #expect(metadata.status == .ok)
            #expect(metadata.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let metadataBody = try managedMCPObject(metadata)
            let clientIdString = try #require(metadataBody["client_id"] as? String)
            let clientId = try #require(URL(string: clientIdString))
            #expect(clientId.path == "/api/mcp/oauth/client-metadata")
            let redirects = metadataBody["redirect_uris"] as? [String] ?? []
            #expect(redirects == [clientId.absoluteString.replacingOccurrences(of: "/api/mcp/oauth/client-metadata", with: "/api/mcp/oauth/callback")])

            let apply = try await client.send(.put, headers: memberHeaders, to: "/api/mcp/agents/\(fixture.agentId)/assignments") { request in
                request.body = .init(string: "{\"assignments\":[{\"mcpServerId\":\"\(createdId)\",\"enabled\":true,\"allowedTools\":null}]}")
            }
            #expect(apply.status == .ok, "\(apply.body.string ?? "")")

            let single = try await client.send(.put, headers: memberHeaders, to: "/api/mcp/agents/\(fixture.agentId)/assignments/\(createdId)") { request in
                request.body = .init(string: "{\"enabled\":false,\"allowedTools\":null}")
            }
            #expect(single.status == .ok)
            let singleBody = try managedMCPObject(single)
            #expect((singleBody["assignment"] as? [String: Any])?["enabled"] as? Bool == false)

            let unsafeDraft = try await client.send(.post, headers: ownerHeaders, to: "/api/mcp/servers/test-configuration") { request in
                request.body = .init(string: "{\"endpointUrl\":\"http://127.0.0.1/mcp\",\"headers\":{}}")
            }
            #expect(unsafeDraft.status == .badRequest)
            #expect(try managedMCPObject(unsafeDraft)["code"] as? String == "managed_mcp_endpoint_invalid")
        }
    }
}
