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
    private let appManagement: IntegrationAppManagementService
    private let cardPrepare: ActionCardPrepareService
    private let agentsLifecycle: AgentsLifecycleService
    private let providerConnections: ManagedMCPProviderConnectionsService
    private let actionCards: ActionCardService

    public init(
        controlPlane: ManagedMCPControlPlaneService,
        identities: AuthIdentitiesService,
        apps: IntegrationsAndAppAccessService,
        appManagement: IntegrationAppManagementService,
        cardPrepare: ActionCardPrepareService,
        agentsLifecycle: AgentsLifecycleService,
        providerConnections: ManagedMCPProviderConnectionsService,
        actionCards: ActionCardService
    ) {
        self.controlPlane = controlPlane
        self.identities = identities
        self.apps = apps
        self.appManagement = appManagement
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
        let integrationInvites = app.grouped("api", "integration-invites")

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

        mcp.post("servers", ":id", "oauth", "start") { request async throws -> Response in
            try await respond {
                try self.controlPlane.startServerOAuth(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    serverIdPath: request.parameters.get("id") ?? ""
                )
            }
        }

        mcp.delete("servers", ":id", "oauth") { request async throws -> Response in
            try await respond {
                try self.controlPlane.disconnectServerOAuth(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    serverIdPath: request.parameters.get("id") ?? ""
                )
            }
        }

        mcp.post("servers", ":id", "test") { request async throws -> Response in
            try await respond {
                try self.controlPlane.testServer(
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
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
            return try await respond {
                try self.apps.approveAgentAccessRequest(
                    authorization: request.headers[.authorization],
                    requestId: request.parameters.get("requestId") ?? "",
                    body: body
                )
            }
        }

        integrations.post("agents", ":agentId", "grants") { request async throws -> Response in
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
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
            let body = await jsonRequestBody(IntegrationRequestBody.self, request)
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
                try self.appManagement.getShareLink(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        // MARK: - Developer-platform App management

        integrations.get("overview") { request async throws -> Response in
            try await respond {
                try self.appManagement.overview(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        integrations.post("clients") { request async throws -> Response in
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
            return try await respond {
                try self.appManagement.createClient(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }

        integrations.delete("clients", ":clientId") { request async throws -> Response in
            try await respond {
                try self.appManagement.deleteClient(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.post("clients", ":clientId", "regenerate-secret") { request async throws -> Response in
            try await respond {
                try self.appManagement.regenerateSecret(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.post("clients", ":clientId", "request-publish") { request async throws -> Response in
            try await respond {
                try self.appManagement.requestPublish(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.post("clients", ":clientId", "request-unpublish") { request async throws -> Response in
            try await respond {
                try self.appManagement.requestUnpublish(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.post("clients", ":clientId", "share-link") { request async throws -> Response in
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
            return try await respond {
                try self.appManagement.createShareLink(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    body: body
                )
            }
        }

        integrations.delete("clients", ":clientId", "share-link") { request async throws -> Response in
            try await respond {
                try self.appManagement.revokeShareLink(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.post("clients", ":clientId", "logo") { request async throws -> Response in
            let upload = await logoMultipart(request)
            return try await respond {
                try self.appManagement.uploadLogo(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    upload: upload
                )
            }
        }

        integrations.delete("clients", ":clientId", "logo") { request async throws -> Response in
            try await respond {
                try self.appManagement.clearLogo(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.put("clients", ":clientId", "app-notifications", "permissions") { request async throws -> Response in
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
            return try await respond {
                try self.appManagement.updatePermissions(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    body: body
                )
            }
        }

        integrations.put("clients", ":clientId", "app-notifications", "webhook") { request async throws -> Response in
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try self.appManagement.configureWebhook(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    body: body
                )
            }
        }

        integrations.post("clients", ":clientId", "app-notifications", "webhook", "rotate-secret") { request async throws -> Response in
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try self.appManagement.rotateWebhookSecret(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? "",
                    body: body
                )
            }
        }

        integrations.delete("clients", ":clientId", "app-notifications", "webhook") { request async throws -> Response in
            try await respond {
                try self.appManagement.disableWebhook(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.put("marketplace", ":clientId", "install", "app-notifications", "grant") { request async throws -> Response in
            try await respond {
                try self.appManagement.updateInstallationGrant(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    clientId: request.parameters.get("clientId") ?? ""
                )
            }
        }

        integrations.post("requests", ":requestId", "deny") { request async throws -> Response in
            try await respond {
                try self.appManagement.denyRequest(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    requestId: request.parameters.get("requestId") ?? ""
                )
            }
        }

        integrationInvites.get(":token") { request async throws -> Response in
            try await respond {
                try self.appManagement.getInvite(
                    authorization: request.headers[.authorization],
                    token: request.parameters.get("token") ?? ""
                )
            }
        }

        integrationInvites.post(":token", "install") { request async throws -> Response in
            let body = (await jsonRequestBody(IntegrationRequestBody.self, request)) ?? IntegrationRequestBody()
            return try await respond {
                try self.appManagement.installInvite(
                    authorization: request.headers[.authorization],
                    token: request.parameters.get("token") ?? "",
                    body: body
                )
            }
        }

        integrations.get("marketplace", ":clientId", "install", "app-notifications") { request async throws -> Response in
            try await respond {
                try IntegrationRoutes.marketplaceAppNotifications(clientId: request.parameters.get("clientId") ?? "")
            }
        }

        runtimeProviders.get(":kind", "models") { request async throws -> Response in
            try await respond {
                try self.agentsLifecycle.agentRuntimeProviderModels(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    kind: request.parameters.get("kind") ?? ""
                )
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

        providerConnections.get(":id", "probes") { request async throws -> Response in
            try await respond {
                try self.providerConnections.listProviderProbes(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? ""
                )
            }
        }

        providerConnections.post(":id", "probes") { request async throws -> Response in
            try await respond {
                try self.providerConnections.createProviderProbe(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    connectionId: request.parameters.get("id") ?? ""
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


// MARK: - Logo multipart

private struct LogoMultipartPart {
    var name: String?
    var contentType: String?
    var data: Data
}

private func logoMultipartParts(data: Data, boundary: String) -> [LogoMultipartPart] {
    let separator = Data("\r\n--\(boundary)".utf8)
    var chunks: [Data] = []
    var splitCursor = data.startIndex
    while let range = data.range(of: separator, in: splitCursor..<data.endIndex) {
        chunks.append(data[splitCursor..<range.lowerBound])
        splitCursor = range.upperBound
    }
    chunks.append(data[splitCursor..<data.endIndex])
    let firstPrefix = Data("--\(boundary)\r\n".utf8)
    if var first = chunks.first, first.starts(with: firstPrefix) {
        first = first.dropFirst(firstPrefix.count)
        chunks[0] = first
    }
    var parts: [LogoMultipartPart] = []
    for chunk in chunks {
        var part = chunk
        if part.starts(with: Data("\r\n".utf8)) { part = part.dropFirst(2) }
        if part.starts(with: Data("--".utf8)) { continue }
        guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let headerData = part[part.startIndex..<headerEnd.lowerBound]
        let body = part[headerEnd.upperBound..<part.endIndex]
        let headers = String(decoding: headerData, as: UTF8.self)
        var name: String?
        var contentType: String? = "application/octet-stream"
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") {
                for component in line.components(separatedBy: ";") {
                    let trimmed = component.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name=") {
                        name = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
            } else if lower.hasPrefix("content-type:") {
                contentType = line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        parts.append(LogoMultipartPart(name: name, contentType: contentType, data: Data(body)))
    }
    return parts
}

private func logoMultipart(_ request: Request) async -> MultipartUpload {
    guard let contentType = request.headers[.contentType],
          contentType.lowercased().hasPrefix("multipart/form-data"),
          let boundary = contentType.components(separatedBy: ";")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix("boundary=") })
            .map({ String($0.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }),
          let bytes = try? await request.body.collect()
    else {
        return MultipartUpload()
    }
    guard let part = logoMultipartParts(data: bytes, boundary: boundary).first(where: { $0.name == "logo" }) else {
        return MultipartUpload()
    }
    return MultipartUpload(file: MultipartUpload.File(
        contentType: part.contentType ?? "application/octet-stream", bytes: part.data
    ))
}
