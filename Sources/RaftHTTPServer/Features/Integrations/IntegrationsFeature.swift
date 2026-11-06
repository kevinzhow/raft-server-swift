import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/api/integrations`, `/api/mcp`, `/api/provider-connections`,
/// `/api/agent-runtime-providers` and `/api/app-installation` routes extracted
/// from `FallbackApplication.configure`.
///
/// The handlers are lifted verbatim so paths, methods, header projections and
/// `routeResponse` mapping stay identical. This collection is not mounted by
/// `FallbackApplication` yet; the composition root decides when it is live.
/// `boot` delegates to the same synchronous `register(routes:)` used by the
/// pinned Vapor async boot path.
public struct IntegrationsFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let app = routes
        let mcp = app.grouped("api", "mcp")
        let integrations = app.grouped("api", "integrations")
        let runtimeProviders = app.grouped("api", "agent-runtime-providers")
        let providerConnections = app.grouped("api", "provider-connections")
        let appInstallation = app.grouped("api", "app-installation")

        mcp.get("servers") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPControlPlane.listServers(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        mcp.post("servers") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPServerCreateRequest.self, request)
            return try await respond(status: 201) {
                try services.emailAccounts.managedMCPControlPlane.createServer(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        mcp.post("servers", "test-configuration") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPTestConfigurationRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPControlPlane.testConfiguration(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        mcp.patch("servers", ":id") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPServerPatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPControlPlane.patchServer(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    serverIdPath: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }

        mcp.delete("servers", ":id") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPControlPlane.deleteServer(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    serverIdPath: request.parameters.get("id") ?? ""
                )
            }
        }

        mcp.get("oauth", "callback") { _ async throws -> Response in
            try await respond(status: { _ in ManagedMCPOAuthCallbackPage.status }, headers: { $0.headers }) {
                services.emailAccounts.managedMCPControlPlane.oauthCallbackPage()
            }
        }

        mcp.get("oauth", "client-metadata") { _ async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                services.emailAccounts.managedMCPControlPlane.oauthClientMetadata()
            }
        }

        mcp.get("agents", ":agentId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPControlPlane.agentCatalog(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        mcp.put("agents", ":agentId", "assignments") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPAssignmentsRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPControlPlane.setAssignments(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("agentId") ?? "",
                    body: body
                )
            }
        }

        mcp.put("agents", ":agentId", "assignments", ":mcpServerId") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPSingleAssignmentRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPControlPlane.setSingleAssignment(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("agentId") ?? "",
                    mcpServerId: request.parameters.get("mcpServerId") ?? "",
                    body: body
                )
            }
        }

        integrations.get("clients") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.authIdentities.integrationSettingsClients(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        integrations.post("requests", ":requestId", "approve") { request async throws -> Response in
            if let body = try? await request.content.decode(AgentAccessRequestApproveDTO.self) {
                return routeResponse(services.emailAccounts.approveAgentAccessRequest(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? "",
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.approveAgentAccessRequest(
                authorization: request.headers[.authorization],
                requestId: request.parameters.get("requestId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        integrations.post("agents", ":agentId", "grants") { request async throws -> Response in
            if let body = try? await request.content.decode(AgentGrantCreateDTO.self) {
                return routeResponse(services.emailAccounts.createAgentGrant(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.createAgentGrant(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        integrations.get("agents", ":agentId", "grants") { request -> Response in
            routeResponse(services.emailAccounts.agentGrantList(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        integrations.get("agents", ":agentId", "grantable-apps") { request -> Response in
            routeResponse(services.emailAccounts.agentGrantableApps(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        integrations.get("agents", ":agentId", "events") { request -> Response in
            routeResponse(services.emailAccounts.agentAppEvents(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                before: desktopQuery(request.url.query, "before")
            ))
        }

        integrations.get("agents", ":agentId", "events", ":eventId") { request -> Response in
            routeResponse(services.emailAccounts.agentAppEventDetail(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                eventId: request.parameters.get("eventId") ?? ""
            ))
        }

        integrations.post("grants", ":grantId", "revoke") { request -> Response in
            routeResponse(services.emailAccounts.revokeAgentGrant(
                authorization: request.headers[.authorization],
                grantId: request.parameters.get("grantId") ?? ""
            ))
        }

        integrations.get("clients", ":clientId", "setup") { request -> Response in
            routeResponse(services.emailAccounts.integrationClientSetup(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? ""
            ))
        }

        integrations.patch("clients", ":clientId") { request async throws -> Response in
            routeResponse(services.emailAccounts.updateIntegrationClientSetup(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }

        integrations.post("marketplace", ":clientId", "install") { request -> Response in
            routeResponse(services.emailAccounts.installMarketplaceClient(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? ""
            ))
        }

        integrations.delete("marketplace", ":clientId", "install") { request -> Response in
            routeResponse(services.emailAccounts.uninstallMarketplaceClient(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? ""
            ))
        }

        integrations.get("marketplace") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCardPrepare.integrationMarketplace(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        integrations.post("clients", ":clientId", "app-notifications", "permissions", "review") { request async throws -> Response in
            // A body that does not decode stays `nil`: the service authorizes
            // first and only then answers the legacy 400, so the status order is
            // unchanged.
            let body = try await typedJSONBody(
                ReviewAppNotificationPermissionsRequest.self,
                request
            )
            return try await respond {
                try services.emailAccounts.actionCardPrepare.reviewAppNotificationPermissions(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    body: body
                )
            }
        }

        integrations.get("agents", ":agentId") { request -> Response in
            routeResponse(IntegrationRoutes.integrationAgent(agentId: request.parameters.get("agentId") ?? ""))
        }

        integrations.get("clients", ":clientId", "agent-jwt") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try services.emailAccounts.actionCardPrepare.legacyAppAgentJWTSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientRecordId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.put("clients", ":clientId", "agent-jwt") { _ async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCardPrepare.refuseLegacyAppAgentJWTWrite()
            }
        }

        integrations.get("clients", ":clientId", "app-notifications") { request -> Response in
            routeResponse(IntegrationRoutes.appNotifications(clientId: request.parameters.get("clientId") ?? ""))
        }

        integrations.get("clients", ":clientId", "share-link") { request -> Response in
            routeResponse(IntegrationRoutes.shareLink(clientId: request.parameters.get("clientId") ?? ""))
        }

        integrations.get("marketplace", ":clientId", "install", "app-notifications") { request -> Response in
            routeResponse(IntegrationRoutes.marketplaceAppNotifications(clientId: request.parameters.get("clientId") ?? ""))
        }

        runtimeProviders.get(":kind") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeProviderProbe(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                kind: request.parameters.get("kind") ?? ""
            ))
        }

        providerConnections.get() { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPProviderConnections.listProviderConnections(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        providerConnections.post(":id", "test") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPProviderConnections.retiredProviderProbe(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        providerConnections.get(":id", "models") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPProviderConnections.retiredProviderProbe(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        providerConnections.get(":id", "agents") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPProviderConnections.listAssignedProviderAgents(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? ""
                )
            }
        }

        providerConnections.delete(":id", "agents", ":agentId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCards.detachProviderAgent(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? "",
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        providerConnections.delete(":id") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCards.deleteProviderConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? ""
                )
            }
        }

        providerConnections.patch(":id") { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPProviderConnections.patchProviderConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }

        providerConnections.post(":id", "credentials", "rotate") { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPProviderConnections.rotateProviderConnectionCredential(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }

        providerConnections.post() { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond(status: 201) {
                try services.emailAccounts.managedMCPProviderConnections.createProviderConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        appInstallation.get("server") { request -> Response in
            routeResponse(services.emailAccounts.oauth.appInstallationServer(authorization: request.headers[.authorization]))
        }

        appInstallation.get("channels") { request -> Response in
            routeResponse(services.emailAccounts.oauth.appInstallationChannels(authorization: request.headers[.authorization]))
        }
    }
}

/// Decodes one typed JSON body even when the client omitted a JSON
/// `Content-Type`. The published handlers accepted a raw JSON body before the
/// typed migration, so the fallback keeps that behavior.
private func typedJSONBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
    if let decoded = try? await request.content.decode(type) { return decoded }
    guard let data = try? await request.body.collect() else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
