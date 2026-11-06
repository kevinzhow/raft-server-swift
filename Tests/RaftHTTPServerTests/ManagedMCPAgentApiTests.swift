import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ManagedMCPFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let agentId: String
    let mcpKey: String
    let readKey: String
    let docsId: String
}

private func makeManagedMCPFixture(suffix: String) -> ManagedMCPFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 500_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 960_000 + number)
    accounts.addAccount(id: ownerId, email: "mcp-agent-api-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mcp-agent-api-\(suffix)", name: "MCP Agent API", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "McpAgent\(suffix)")
    let docsId = accounts.addManagedMCPServerForTesting(
        serverId: serverId,
        name: "Docs",
        endpointUrl: "https://example.com/mcp",
        tools: [(name: "search", inputSchemaJSON: "{\"type\":\"object\"}")],
        catalogVersion: 1
    )
    let mcpKey = accounts.mintAgentCredential(agentId: agent, scopes: ["mcp"], name: "mcp-test-\(suffix)")
    let readKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "read-test-\(suffix)")
    return ManagedMCPFixture(
        accounts: accounts,
        serverId: serverId,
        agentId: agent,
        mcpKey: mcpKey,
        readKey: readKey,
        docsId: docsId
    )
}

private func managedMCPObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func managedMCPToolsAreCredentialBoundAndCapabilityGated() async throws {
    let fixture = makeManagedMCPFixture(suffix: "731")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var readHeaders = HTTPFields()
            readHeaders[.authorization] = "Bearer \(fixture.readKey)"
            let denied = try await client.get("/internal/agent-api/mcp/tools", headers: readHeaders)
            #expect(denied.status == .forbidden)
            #expect(try managedMCPObject(denied)["requiredCapability"] as? String == "mcp")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.mcpKey)"
            headers[HTTPField.Name("X-Slock-Agent-Active-Capabilities")!] = "mcp"
            let response = try await client.get("/internal/agent-api/mcp/tools", headers: headers)
            #expect(response.status == .ok)
            let body = try managedMCPObject(response)
            #expect(body["catalogVersion"] as? Int == 1)
            let tools = body["tools"] as? [[String: Any]] ?? []
            #expect(tools.count == 1)
            let tool = tools.first ?? [:]
            #expect(tool["mcpServerId"] as? String == fixture.docsId)
            #expect(tool["serverName"] as? String == "Docs")
            #expect(tool["toolName"] as? String == "search")
            #expect(tool["assignmentVersion"] as? Int == 1)
            #expect(tool["endpointUrl"] == nil)
            #expect(tool["headers"] == nil)
            #expect(body["unavailable"] == nil)

            headers[.contentType] = "application/json"
            let invalidCall = try await client.send(.post, headers: headers, to: "/internal/agent-api/mcp/call") { request in
                request.body = .init(string: "{\"mcpServerId\":\"not-a-uuid\",\"toolName\":\"search\",\"arguments\":{}}")
            }
            #expect(invalidCall.status == .badRequest)
        }
    }
}

@Test func managedMCPListsDisconnectedConnectorsAndRefusesStaleCalls() async throws {
    let fixture = makeManagedMCPFixture(suffix: "732")
    let notionId = fixture.accounts.addManagedMCPServerForTesting(
        serverId: fixture.serverId,
        name: "Notion",
        provider: "notion",
        authMode: "oauth",
        oauthStatus: "error",
        endpointUrl: "https://mcp.notion.com/mcp",
        tools: [(name: "search", inputSchemaJSON: "{\"type\":\"object\"}")],
        catalogVersion: 1
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.mcpKey)"
            headers[HTTPField.Name("X-Slock-Agent-Active-Capabilities")!] = "mcp"
            headers[.contentType] = "application/json"

            let listed = try await client.get("/internal/agent-api/mcp/tools", headers: headers)
            #expect(listed.status == .ok)
            let body = try managedMCPObject(listed)
            let tools = body["tools"] as? [[String: Any]] ?? []
            #expect(tools.map { $0["serverName"] as? String } == ["Docs"])
            let unavailable = body["unavailable"] as? [[String: Any]] ?? []
            #expect(unavailable.count == 1)
            #expect(unavailable.first?["mcpServerId"] as? String == notionId)
            #expect(unavailable.first?["serverName"] as? String == "Notion")
            #expect(unavailable.first?["status"] as? String == "reconnect_required")

            let stale = try await client.send(.post, headers: headers, to: "/internal/agent-api/mcp/call") { request in
                request.body = .init(string: "{\"mcpServerId\":\"\(fixture.docsId)\",\"toolName\":\"search\",\"arguments\":{},\"expectedConfigVersion\":999,\"expectedAssignmentVersion\":1}")
            }
            #expect(stale.status == .conflict)
            let staleText = "\"search\" is no longer offered by \"Docs\"; don't call it again. If you still need it, tell the person who asked."
            #expect(try managedMCPObject(stale) as NSDictionary == [
                "code": "managed_mcp_config_stale",
                "error": staleText,
                "suggestedNextAction": staleText,
            ] as NSDictionary)
        }
    }
}
