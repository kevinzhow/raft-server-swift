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
    private let controlPlane: ManagedMCPControlPlaneService
    private let identities: AuthIdentitiesService
    private let apps: IntegrationsAndAppAccessService
    private let cardPrepare: ActionCardPrepareService
    private let agentsLifecycle: AgentsLifecycleService
    private let providerConnections: ManagedMCPProviderConnectionsService
    private let actionCards: ActionCardService

    public init(
        controlPlane: ManagedMCPControlPlaneService,
        identities: AuthIdentitiesService,
        apps: IntegrationsAndAppAccessService,
        cardPrepare: ActionCardPrepareService,
        agentsLifecycle: AgentsLifecycleService,
        providerConnections: ManagedMCPProviderConnectionsService,
        actionCards: ActionCardService
    ) {
        self.controlPlane = controlPlane
        self.identities = identities
        self.apps = apps
        self.cardPrepare = cardPrepare
        self.agentsLifecycle = agentsLifecycle
        self.providerConnections = providerConnections
        self.actionCards = actionCards
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
                try self.controlPlane.listServers(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        mcp.post("servers") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPServerCreateRequest.self, request)
            return try await respond(status: 201) {
                try self.controlPlane.createServer(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        mcp.post("servers", "test-configuration") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPTestConfigurationRequest.self, request)
            return try await respond {
                try self.controlPlane.testConfiguration(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        mcp.patch("servers", ":id") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPServerPatchRequest.self, request)
            return try await respond {
                try self.controlPlane.patchServer(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    serverIdPath: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }

        mcp.delete("servers", ":id") { request async throws -> Response in
            try await respond {
                try self.controlPlane.deleteServer(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    serverIdPath: request.parameters.get("id") ?? ""
                )
            }
        }

        mcp.get("oauth", "callback") { _ async throws -> Response in
            try await respond(status: { _ in ManagedMCPOAuthCallbackPage.status }, headers: { $0.headers }) {
                self.controlPlane.oauthCallbackPage()
            }
        }

        mcp.get("oauth", "client-metadata") { _ async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                self.controlPlane.oauthClientMetadata()
            }
        }

        mcp.get("agents", ":agentId") { request async throws -> Response in
            try await respond {
                try self.controlPlane.agentCatalog(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        mcp.put("agents", ":agentId", "assignments") { request async throws -> Response in
            let body = await jsonRequestBody(ManagedMCPAssignmentsRequest.self, request)
            return try await respond {
                try self.controlPlane.setAssignments(
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
                try self.controlPlane.setSingleAssignment(
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
                try self.identities.integrationSettingsClients(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        integrations.post("requests", ":requestId", "approve") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond {
                try self.apps.approveAgentAccessRequest(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? "",
                    body: body
                )
            }
        }

        integrations.post("agents", ":agentId", "grants") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond(status: { $0.status }, headers: { _ in .standard() }) {
                try self.apps.createAgentGrant(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    body: body
                )
            }
        }

        integrations.get("agents", ":agentId", "grants") { request async throws -> Response in
            try await respond {
                try self.apps.agentGrantList(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        integrations.get("agents", ":agentId", "grantable-apps") { request async throws -> Response in
            try await respond {
                try self.apps.agentGrantableApps(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        integrations.get("agents", ":agentId", "events") { request async throws -> Response in
            try await respond {
                try self.apps.agentAppEvents(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    limit: desktopQuery(request.url.query, "limit"),
                    before: desktopQuery(request.url.query, "before")
                )
            }
        }

        integrations.get("agents", ":agentId", "events", ":eventId") { request async throws -> Response in
            try await respond {
                try self.apps.agentAppEventDetail(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    eventId: request.parameters.get("eventId") ?? ""
                )
            }
        }

        integrations.post("grants", ":grantId", "revoke") { request async throws -> Response in
            try await respond {
                try self.apps.revokeAgentGrant(
                    authorization: request.headers[.authorization],
                    grantId: request.parameters.get("grantId") ?? ""
                )
            }
        }

        integrations.get("clients", ":clientId", "setup") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try self.apps.integrationClientSetup(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.patch("clients", ":clientId") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond {
                try self.apps.updateIntegrationClientSetup(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    body: body
                )
            }
        }

        integrations.post("marketplace", ":clientId", "install") { request async throws -> Response in
            try await respond {
                try self.apps.installMarketplaceClient(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.delete("marketplace", ":clientId", "install") { request async throws -> Response in
            try await respond {
                try self.apps.uninstallMarketplaceClient(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.get("marketplace") { request async throws -> Response in
            try await respond {
                try self.cardPrepare.integrationMarketplace(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        integrations.post("clients", ":clientId", "app-notifications", "permissions", "review") { request async throws -> Response in
            // A body that does not decode stays `nil`: the service authorizes
            // first and only then answers the legacy 400, so the status order is
            // unchanged.
            let body = await jsonRequestBody(
                ReviewAppNotificationPermissionsRequest.self,
                request
            )
            return try await respond {
                try self.cardPrepare.reviewAppNotificationPermissions(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    body: body
                )
            }
        }

        integrations.get("agents", ":agentId") { request async throws -> Response in
            try await respond {
                try IntegrationRoutes.integrationAgent(agentId: request.parameters.get("agentId") ?? "")
            }
        }

        integrations.get("clients", ":clientId", "agent-jwt") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try self.cardPrepare.legacyAppAgentJWTSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientRecordId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.put("clients", ":clientId", "agent-jwt") { _ async throws -> Response in
            try await respond {
                try self.cardPrepare.refuseLegacyAppAgentJWTWrite()
            }
        }

        integrations.get("clients", ":clientId", "app-notifications") { request async throws -> Response in
            try await respond {
                try IntegrationRoutes.appNotifications(clientId: request.parameters.get("clientId") ?? "")
            }
        }

        integrations.get("clients", ":clientId", "share-link") { request async throws -> Response in
            try await respond {
                try IntegrationRoutes.shareLink(clientId: request.parameters.get("clientId") ?? "")
            }
        }

        integrations.get("marketplace", ":clientId", "install", "app-notifications") { request async throws -> Response in
            try await respond {
                try IntegrationRoutes.marketplaceAppNotifications(clientId: request.parameters.get("clientId") ?? "")
            }
        }

        runtimeProviders.get(":kind") { request async throws -> Response in
            try await respond {
                try self.agentsLifecycle.agentRuntimeProviderProbe(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    kind: request.parameters.get("kind") ?? ""
                )
            }
        }

        providerConnections.get() { request async throws -> Response in
            try await respond {
                try self.providerConnections.listProviderConnections(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        providerConnections.post(":id", "test") { request async throws -> Response in
            try await respond {
                try self.providerConnections.retiredProviderProbe(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        providerConnections.get(":id", "models") { request async throws -> Response in
            try await respond {
                try self.providerConnections.retiredProviderProbe(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        providerConnections.get(":id", "agents") { request async throws -> Response in
            try await respond {
                try self.providerConnections.listAssignedProviderAgents(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? ""
                )
            }
        }

        providerConnections.delete(":id", "agents", ":agentId") { request async throws -> Response in
            try await respond {
                try self.actionCards.detachProviderAgent(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? "",
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }

        providerConnections.delete(":id") { request async throws -> Response in
            try await respond {
                try self.actionCards.deleteProviderConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? ""
                )
            }
        }

        providerConnections.patch(":id") { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond {
                try self.providerConnections.patchProviderConnection(
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
                try self.providerConnections.rotateProviderConnectionCredential(
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
                try self.providerConnections.createProviderConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        InstallationCredentialRoutes(apps: self.apps).registerReads(routes: appInstallation)
    }
}
