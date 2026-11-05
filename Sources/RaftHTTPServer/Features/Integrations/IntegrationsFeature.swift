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
        app.get("api", "mcp", "servers") { request -> Response in
            routeResponse(services.emailAccounts.listManagedMCPServers(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        app.post("api", "mcp", "servers") { request -> Response in
            routeResponse(services.emailAccounts.createManagedMCPServer(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.post("api", "mcp", "servers", "test-configuration") { request -> Response in
            routeResponse(services.emailAccounts.testManagedMCPConfiguration(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.patch("api", "mcp", "servers", ":id") { request -> Response in
            routeResponse(services.emailAccounts.patchManagedMCPServer(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                serverIdPath: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.delete("api", "mcp", "servers", ":id") { request -> Response in
            routeResponse(services.emailAccounts.deleteManagedMCPServer(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                serverIdPath: request.parameters.get("id") ?? ""
            ))
        }

        app.get("api", "mcp", "oauth", "callback") { _ -> Response in
            routeResponse(services.emailAccounts.managedMCPOAuthCallback())
        }

        app.get("api", "mcp", "oauth", "client-metadata") { _ -> Response in
            routeResponse(services.emailAccounts.managedMCPOAuthClientMetadata())
        }

        app.get("api", "mcp", "agents", ":agentId") { request -> Response in
            routeResponse(services.emailAccounts.managedMCPAgentCatalog(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        app.put("api", "mcp", "agents", ":agentId", "assignments") { request -> Response in
            routeResponse(services.emailAccounts.setManagedMCPAssignments(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.put("api", "mcp", "agents", ":agentId", "assignments", ":mcpServerId") { request -> Response in
            routeResponse(services.emailAccounts.setSingleManagedMCPAssignment(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                mcpServerId: request.parameters.get("mcpServerId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.get("api", "integrations", "clients") { request -> Response in
            routeResponse(services.emailAccounts.integrationSettingsClients(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        app.post("api", "integrations", "requests", ":requestId", "approve") { request -> Response in
            routeResponse(services.emailAccounts.approveAgentAccessRequest(
                authorization: request.headers[.authorization],
                requestId: request.parameters.get("requestId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "integrations", "agents", ":agentId", "grants") { request -> Response in
            routeResponse(services.emailAccounts.createAgentGrant(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.get("api", "integrations", "agents", ":agentId", "grants") { request -> Response in
            routeResponse(services.emailAccounts.agentGrantList(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        app.get("api", "integrations", "agents", ":agentId", "grantable-apps") { request -> Response in
            routeResponse(services.emailAccounts.agentGrantableApps(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        app.get("api", "integrations", "agents", ":agentId", "events") { request -> Response in
            routeResponse(services.emailAccounts.agentAppEvents(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                limit: desktopQuery(request.url.query, "limit"),
                before: desktopQuery(request.url.query, "before")
            ))
        }

        app.get("api", "integrations", "agents", ":agentId", "events", ":eventId") { request -> Response in
            routeResponse(services.emailAccounts.agentAppEventDetail(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                eventId: request.parameters.get("eventId") ?? ""
            ))
        }

        app.post("api", "integrations", "grants", ":grantId", "revoke") { request -> Response in
            routeResponse(services.emailAccounts.revokeAgentGrant(
                authorization: request.headers[.authorization],
                grantId: request.parameters.get("grantId") ?? ""
            ))
        }

        app.get("api", "integrations", "clients", ":clientId", "setup") { request -> Response in
            routeResponse(services.emailAccounts.integrationClientSetup(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? ""
            ))
        }

        app.patch("api", "integrations", "clients", ":clientId") { request -> Response in
            routeResponse(services.emailAccounts.updateIntegrationClientSetup(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }

        app.post("api", "integrations", "marketplace", ":clientId", "install") { request -> Response in
            routeResponse(services.emailAccounts.installMarketplaceClient(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? ""
            ))
        }

        app.delete("api", "integrations", "marketplace", ":clientId", "install") { request -> Response in
            routeResponse(services.emailAccounts.uninstallMarketplaceClient(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? ""
            ))
        }

        app.get("api", "integrations", "marketplace") { request -> Response in
            routeResponse(services.emailAccounts.integrationMarketplace(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        app.post("api", "integrations", "clients", ":clientId", "app-notifications", "permissions", "review") { request -> Response in
            routeResponse(services.emailAccounts.reviewAppNotificationPermissions(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientId: request.parameters.get("clientId") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.get("api", "integrations", "agents", ":agentId") { request -> Response in
            routeResponse(IntegrationRoutes.integrationAgent(agentId: request.parameters.get("agentId") ?? ""))
        }

        app.get("api", "integrations", "clients", ":clientId", "agent-jwt") { request -> Response in
            routeResponse(services.emailAccounts.legacyAppAgentJWTSettings(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientRecordId: request.parameters.get("clientId") ?? ""
            ))
        }

        app.put("api", "integrations", "clients", ":clientId", "agent-jwt") { _ -> Response in
            routeResponse(services.emailAccounts.refuseLegacyAppAgentJWTWrite())
        }

        app.get("api", "integrations", "clients", ":clientId", "app-notifications") { request -> Response in
            routeResponse(IntegrationRoutes.appNotifications(clientId: request.parameters.get("clientId") ?? ""))
        }

        app.get("api", "integrations", "clients", ":clientId", "share-link") { request -> Response in
            routeResponse(IntegrationRoutes.shareLink(clientId: request.parameters.get("clientId") ?? ""))
        }

        app.get("api", "integrations", "marketplace", ":clientId", "install", "app-notifications") { request -> Response in
            routeResponse(IntegrationRoutes.marketplaceAppNotifications(clientId: request.parameters.get("clientId") ?? ""))
        }

        app.get("api", "agent-runtime-providers", ":kind") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeProviderProbe(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                kind: request.parameters.get("kind") ?? ""
            ))
        }

        app.get("api", "provider-connections") { request -> Response in
            routeResponse(services.emailAccounts.listProviderConnections(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        app.post("api", "provider-connections", ":id", "test") { request -> Response in
            routeResponse(services.emailAccounts.retiredProviderProbe(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        app.get("api", "provider-connections", ":id", "models") { request -> Response in
            routeResponse(services.emailAccounts.retiredProviderProbe(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }

        app.get("api", "provider-connections", ":id", "agents") { request -> Response in
            routeResponse(services.emailAccounts.listAssignedProviderAgents(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                connectionId: request.parameters.get("id") ?? ""
            ))
        }

        app.delete("api", "provider-connections", ":id", "agents", ":agentId") { request -> Response in
            routeResponse(services.emailAccounts.detachProviderAgent(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                connectionId: request.parameters.get("id") ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }

        app.delete("api", "provider-connections", ":id") { request -> Response in
            routeResponse(services.emailAccounts.deleteProviderConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                connectionId: request.parameters.get("id") ?? ""
            ))
        }

        app.patch("api", "provider-connections", ":id") { request -> Response in
            routeResponse(services.emailAccounts.patchProviderConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                connectionId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.post("api", "provider-connections", ":id", "credentials", "rotate") { request -> Response in
            routeResponse(services.emailAccounts.rotateProviderConnectionCredential(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                connectionId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.post("api", "provider-connections") { request -> Response in
            routeResponse(services.emailAccounts.createProviderConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }

        app.get("api", "app-installation", "server") { request -> Response in
            routeResponse(services.emailAccounts.oauth.appInstallationServer(authorization: request.headers[.authorization]))
        }

        app.get("api", "app-installation", "channels") { request -> Response in
            routeResponse(services.emailAccounts.oauth.appInstallationChannels(authorization: request.headers[.authorization]))
        }
    }
}

/// File-private copy of the query helper the extracted handlers use. The
/// original stays private to `FallbackApplication.swift`; keeping a copy here is
/// what lets the collection be registered on a bare `Application` without
/// editing the composition root.
private func desktopQuery(_ query: String?, _ name: String) -> String? {
    guard let query, !query.isEmpty else { return nil }
    for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.first == name else { continue }
        let raw = parts.count > 1 ? parts[1] : ""
        return raw.removingPercentEncoding ?? raw
    }
    return nil
}
