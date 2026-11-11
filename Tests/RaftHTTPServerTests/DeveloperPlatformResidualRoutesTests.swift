import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ResidualScene {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let memberId: String
    let serverId: String
    let ownerToken: String
    let memberToken: String
}

private func makeResidualScene(_ suffix: String) -> ResidualScene {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000003000\(suffix)"
    let memberId = "11111111-1111-4111-8111-000003001\(suffix)"
    let serverId = "33333333-3333-4333-8333-000003000\(suffix)"
    accounts.addAccount(id: ownerId, email: "residual-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "residual-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "residual-\(suffix)", name: "Residual \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    return ResidualScene(
        accounts: accounts, ownerId: ownerId, memberId: memberId, serverId: serverId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId)
    )
}

private func configureResidualScene(_ app: Application, scene: ResidualScene) {
    configure(app, services: FallbackServices(
        nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
        emailAccounts: scene.accounts
    ))
}

private func residualHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func residualJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func runtimeProviderModelsRefusesUnavailableAndUnknownKinds() async throws {
    let f = makeResidualScene("501")
    try await withApp { app in
        configureResidualScene(app, scene: f)
        try await app.testing { client in
            let unauthorized = try await client.get(URI(string: "/api/agent-runtime-providers/antiproton/models"), headers: HTTPFields())
            #expect(unauthorized.status == .unauthorized)

            let member = try await client.get(URI(string: "/api/agent-runtime-providers/antiproton/models"), headers: residualHeaders(f.memberToken, f.serverId))
            #expect(member.status == .forbidden)
            #expect(residualJSON(member)["code"] as? String == "agent_runtime_provider_forbidden")

            let unknown = try await client.get(URI(string: "/api/agent-runtime-providers/nope/models"), headers: residualHeaders(f.ownerToken, f.serverId))
            #expect(unknown.status == .notFound)
            #expect(residualJSON(unknown)["code"] as? String == "agent_runtime_provider_unknown")

            let unavailable = try await client.get(URI(string: "/api/agent-runtime-providers/antiproton/models"), headers: residualHeaders(f.ownerToken, f.serverId))
            #expect(unavailable.status == .notFound)
            #expect(residualJSON(unavailable)["code"] as? String == "agent_runtime_provider_unavailable")
        }
    }
}

@Test func providerProbesStayBehindTheDisabledSurfaceAndRetireWhenEnabled() async throws {
    let f = makeResidualScene("502")
    try await withApp { app in
        configureResidualScene(app, scene: f)
        try await app.testing { client in
            let connectionId = UUID().uuidString.lowercased()
            let disabledGet = try await client.get(URI(string: "/api/provider-connections/\(connectionId)/probes"), headers: residualHeaders(f.ownerToken, f.serverId))
            #expect(disabledGet.status == .notFound)
            #expect(residualJSON(disabledGet)["code"] as? String == "provider_connections_disabled")

            let disabledPost = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/provider-connections/\(connectionId)/probes") { request in
                request.body = .init(string: "{}")
            }
            #expect(disabledPost.status == .notFound)
            #expect(residualJSON(disabledPost)["code"] as? String == "provider_connections_disabled")

            f.accounts.setProviderConnectionsEnabled(serverId: f.serverId, enabled: true)

            let member = try await client.get(URI(string: "/api/provider-connections/\(connectionId)/probes"), headers: residualHeaders(f.memberToken, f.serverId))
            #expect(member.status == .forbidden)

            let retiredGet = try await client.get(URI(string: "/api/provider-connections/\(connectionId)/probes"), headers: residualHeaders(f.ownerToken, f.serverId))
            #expect(retiredGet.status == .gone)
            #expect(residualJSON(retiredGet)["code"] as? String == "provider_connection_retired")

            let retiredPost = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/provider-connections/\(connectionId)/probes") { request in
                request.body = .init(string: "{}")
            }
            #expect(retiredPost.status == .gone)
        }
    }
}

@Test func mcpOAuthAndTestRefuseWithoutTheThirdPartyTransport() async throws {
    let f = makeResidualScene("503")
    try await withApp { app in
        configureResidualScene(app, scene: f)
        try await app.testing { client in
            let plainServerId = f.accounts.addManagedMCPServerForTesting(
                serverId: f.serverId, name: "Plain MCP", authMode: "none"
            )
            let oauthServerId = f.accounts.addManagedMCPServerForTesting(
                serverId: f.serverId, name: "OAuth MCP", provider: "notion", authMode: "oauth",
                oauthStatus: "disconnected", endpointUrl: "https://mcp.notion.com/mcp"
            )

            let required = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/mcp/servers/\(plainServerId)/oauth/start")
            #expect(required.status == .badRequest)
            #expect(residualJSON(required)["code"] as? String == "managed_mcp_oauth_required")

            let unreachable = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/mcp/servers/\(oauthServerId)/oauth/start")
            #expect(unreachable.status == .badGateway)
            #expect(residualJSON(unreachable)["code"] as? String == "managed_mcp_unreachable")

            let tested = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/mcp/servers/\(oauthServerId)/test")
            #expect(tested.status == .badGateway)
            #expect(residualJSON(tested)["code"] as? String == "managed_mcp_unreachable")

            let missing = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/mcp/servers/\(UUID().uuidString.lowercased())/oauth/start")
            #expect(missing.status == .notFound)
            #expect(residualJSON(missing)["code"] as? String == "managed_mcp_server_not_found")

            let disconnected = try await client.send(.delete, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/mcp/servers/\(oauthServerId)/oauth")
            #expect(disconnected.status == .noContent)

            let notOwner = try await client.send(.delete, headers: residualHeaders(f.memberToken, f.serverId), to: "/api/mcp/servers/\(oauthServerId)/oauth")
            #expect(notOwner.status == .forbidden)
        }
    }
}

@Test func actionCardEventsRecordAndReconfirmRefusesWithoutConversion() async throws {
    let f = makeResidualScene("504")
    try await withApp { app in
        configureResidualScene(app, scene: f)
        try await app.testing { client in
            let agentId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "residual-agent")
            let cardId = f.accounts.addActionCardForTesting(
                serverId: f.serverId, agentId: agentId, carrierChannelId: UUID().uuidString.lowercased()
            )

            let badType = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/actions/\(cardId)/event") { request in
                request.body = .init(string: "{\"eventType\":\"action_card.execute_success\"}")
            }
            #expect(badType.status == .badRequest)
            #expect(residualJSON(badType)["error"] as? String == "eventType must be one of action_card.open, action_card.dismiss, action_card.execute_attempt, action_card.execute_fail")

            let recorded = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/actions/\(cardId)/event") { request in
                request.body = .init(string: "{\"eventType\":\"action_card.open\",\"metadata\":{\"dismiss_reason\":\"esc\",\"latency_ms\":12},\"idempotencyKey\":\"evt-1\"}")
            }
            #expect(recorded.status == .noContent)

            let replay = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/actions/\(cardId)/event") { request in
                request.body = .init(string: "{\"eventType\":\"action_card.open\",\"metadata\":{\"dismiss_reason\":\"esc\",\"latency_ms\":12},\"idempotencyKey\":\"evt-1\"}")
            }
            #expect(replay.status == .noContent)

            let unknownCard = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/actions/\(UUID().uuidString.lowercased())/event") { request in
                request.body = .init(string: "{\"eventType\":\"action_card.open\"}")
            }
            #expect(unknownCard.status == .notFound)
            #expect(residualJSON(unknownCard)["error"] as? String == "Card message not found")

            let reconfirm = try await client.send(.post, headers: residualHeaders(f.ownerToken, f.serverId), to: "/api/actions/\(cardId)/reconfirm")
            #expect(reconfirm.status == .conflict)
            #expect(residualJSON(reconfirm)["errorCode"] as? String == "action_card_conversion_frozen")
        }
    }
}
