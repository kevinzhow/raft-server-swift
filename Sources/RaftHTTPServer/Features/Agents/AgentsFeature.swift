import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// The `api/agent/login` and every `api/agents/**` route, split out of
/// `NotificationsFeature` to match upstream `routes/agents.ts` (53 routes).
///
/// Handlers, header projections, path parameters and `routeResponse` mapping
/// are unchanged from the pre-split collection. The routes are grouped under
/// `api/agent` and `api/agents`; the literal `archived` and `manageable`
/// children stay registered after `:id` exactly as before, and RoutingKit's
/// constant-child precedence keeps them reachable.
public struct AgentsFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    /// Decodes one typed JSON body even when the client omitted a JSON
    /// `Content-Type`. The retired raw parser accepted the body regardless of
    /// the header, so the fallback keeps that behavior for the typed route.
    private func jsonBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
        if let decoded = try? await request.content.decode(type) { return decoded }
        guard let data = try await request.body.collect() else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let agentGroup = routes.grouped("api", "agent")
        let agents = routes.grouped("api", "agents")

        agentGroup.post("login") { request async throws -> Response in
            if let body = try? await request.content.decode(AgentLoginRequestDTO.self) {
                return routeResponse(services.emailAccounts.agentLogin(
                    authorization: request.headers[.authorization],
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.agentLogin(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        agents.get { request -> Response in
            routeResponse(services.emailAccounts.listServerAgents(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.post { request async throws -> Response in
            routeResponse(services.emailAccounts.createAgentRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText()
            ))
        }
        agents.delete(":id") { request async throws -> Response in
            let body = (try await jsonBody(AgentDeleteRequest.self, request)) ?? AgentDeleteRequest()
            return try await respond {
                try services.emailAccounts.agentMachineMigrationControl.deleteAgent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    request: body
                )
            }
        }
        agents.get(":id") { request -> Response in
            routeResponse(services.emailAccounts.getAgentRoute(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.patch(":id") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchAgent(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: try await request.bodyText(),
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.get(":id", "activity") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentActivity(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.get(":id", "activity-log") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentActivityLog(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    query: request.url.query
                )
            }
        }
        agents.get(":id", "activity-summaries") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentActivitySummaries(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    query: request.url.query
                )
            }
        }
        agents.get(":id", "agent-dms") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentDirectMessages(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.get(":id", "archive") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentArchiveView(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        agents.post(":id", "archive", "workspace") { request async throws -> Response in
            let body = (try await jsonBody(AgentArchiveWorkspaceRequest.self, request)) ?? AgentArchiveWorkspaceRequest()
            return try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentArchiveWorkspaceAction(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    request: body
                )
            }
        }
        agents.post(":id", "assign-machine") { request async throws -> Response in
            let body = (try await jsonBody(AgentAssignMachineRequest.self, request)) ?? AgentAssignMachineRequest()
            return try await respond {
                try services.emailAccounts.agentHostedMigration.assignAgentMachine(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    request: body
                )
            }
        }
        agents.delete(":id", "assistant-owner") { request -> Response in
            routeResponse(services.emailAccounts.agentAssistantOwner(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                method: "DELETE"
            ))
        }
        agents.put(":id", "assistant-owner") { request -> Response in
            routeResponse(services.emailAccounts.agentAssistantOwner(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                method: "PUT"
            ))
        }
        agents.post(":id", "avatar") { request async throws -> Response in
            routeResponse(services.emailAccounts.uploadAgentAvatar(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                byteCount: (try await request.bodyText()).utf8.count
            ))
        }
        agents.post(":id", "bootstrap-tokens") { request async throws -> Response in
            routeResponse(services.emailAccounts.createAgentBootstrapToken(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        agents.get(":id", "channels") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentChannels(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.delete(":id", "connections", ":provider") { request -> Response in
            connectionResponse(services.emailAccounts.disconnectAgentConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? ""
            ))
        }
        agents.get(":id", "connections", ":provider") { request -> Response in
            connectionResponse(services.emailAccounts.agentConnectionStatus(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? ""
            ))
        }
        agents.post(":id", "connections", ":provider") { request async throws -> Response in
            connectionResponse(services.emailAccounts.startAgentConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText()
            ))
        }
        agents.put(":id", "connections", ":provider") { request async throws -> Response in
            connectionResponse(services.emailAccounts.assignAgentConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText()
            ))
        }
        agents.post(":id", "connections", ":provider", "confirm") { request async throws -> Response in
            connectionResponse(services.emailAccounts.confirmAgentConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText()
            ))
        }
        agents.delete(":id", "connections", ":provider", "connectors", ":connectorId") { request -> Response in
            connectionResponse(services.emailAccounts.disconnectAgentConnector(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                connectorId: request.parameters.get("connectorId") ?? ""
            ))
        }
        agents.patch(":id", "creator") { request async throws -> Response in
            if let body = try? await request.content.decode(AgentCreatorPatchDTO.self) {
                return routeResponse(services.emailAccounts.patchAgentCreator(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.patchAgentCreator(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        agents.get(":id", "credentials") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try services.emailAccounts.agentHostedMigration.listAgentCredentials(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.post(":id", "credentials") { request async throws -> Response in
            let body = (try await jsonBody(AgentCredentialIssueRequest.self, request)) ?? AgentCredentialIssueRequest()
            return try await respond(status: 201, headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try services.emailAccounts.agentHostedMigration.issueAgentCredential(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    request: body
                )
            }
        }
        agents.delete(":id", "credentials", ":credentialId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHostedMigration.revokeAgentCredential(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    credentialId: request.parameters.get("credentialId") ?? ""
                )
            }
        }
        agents.get(":id", "external-diagnostics") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMigrationStatus.externalDiagnostics(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.get(":id", "external-status") { request -> Response in
            routeResponse(services.emailAccounts.externalAgentStatus(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        agents.get(":id", "hosted-runtime") { request -> Response in
            var response = routeResponse(services.emailAccounts.agentHostedRuntime(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.get(":id", "hosted-runtime", "model") { request -> Response in
            var response = routeResponse(services.emailAccounts.agentHostedModel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.put(":id", "hosted-runtime", "model") { request async throws -> Response in
            var response: Response
            if let body = try? await request.content.decode(AgentHostedModelDTO.self) {
                response = routeResponse(services.emailAccounts.setAgentHostedModel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    body: body.encodedBody()
                ))
            } else {
                response = routeResponse(services.emailAccounts.setAgentHostedModel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    body: try await request.bodyText()
                ))
            }
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.post(":id", "hosted-runtime", "retry") { request async throws -> Response in
            routeResponse(services.emailAccounts.retryAgentProvisioning(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        agents.get(":id", "hosted-runtime", "usage") { request -> Response in
            var response = routeResponse(services.emailAccounts.agentHostedUsage(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                query: request.url.query
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.post(":id", "migrate") { request async throws -> Response in
            let body = (try await jsonBody(AgentMigrateRequest.self, request)) ?? AgentMigrateRequest()
            return try await respond(status: { $0.status }, headers: { _ in .standard() }) {
                try services.emailAccounts.agentMachineMigrationControl.migrateAgent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    request: body
                )
            }
        }
        agents.get(":id", "migration") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMigrationStatus.migrationStatus(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.post(":id", "migration", "cancel") { request async throws -> Response in
            // The retired handler read the JSON object regardless of
            // `Content-Type`, so a body without a JSON header still decodes
            // here instead of falling back to an empty request.
            let body = (try await jsonBody(AgentMigrationCancelRequest.self, request))
                ?? AgentMigrationCancelRequest()
            return try await respond {
                try services.emailAccounts.agentMigrationStatus.cancelMigration(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    request: body
                )
            }
        }
        agents.post(":id", "migration", "confirm-hosted") { request async throws -> Response in
            let body = (try await jsonBody(AgentMigrationCancelRequest.self, request)) ?? AgentMigrationCancelRequest()
            return try await respond {
                try services.emailAccounts.agentMachineMigrationControl.confirmHostedMigration(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    request: body
                )
            }
        }
        agents.get(":id", "onboarding-identity-adoption") { request -> Response in
            routeResponse(services.emailAccounts.onboardingIdentityAdoption(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        agents.post(":id", "onboarding-identity-adoption") { request -> Response in
            routeResponse(services.emailAccounts.adoptOnboardingIdentity(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        agents.post(":id", "reset") { request async throws -> Response in
            let body = (try await jsonBody(AgentResetRequest.self, request)) ?? AgentResetRequest()
            return try await respond(status: 202) {
                try services.emailAccounts.agentMachineMigrationControl.resetAgent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    request: body
                )
            }
        }
        agents.get(":id", "runtime-form") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.agentRuntimeForm(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    language: request.headers[HTTPField.Name("Accept-Language")!]
                )
            }
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        agents.get(":id", "runtime-options") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeOptions(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        agents.get(":id", "scopes") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.getAgentScopes(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.put(":id", "scopes") { request async throws -> Response in
            let body = (try await jsonBody(AgentScopesUpdateRequest.self, request)) ?? AgentScopesUpdateRequest()
            return try await respond {
                try services.emailAccounts.agentMachineMigrationControl.putAgentScopes(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    request: body
                )
            }
        }
        agents.get(":id", "skills") { request async throws -> Response in
            let hasReplayHeaders = request.headers[HTTPField.Name("X-Raft-Replica-Replay")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Machine")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Timestamp")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Signature")!] != nil
            return try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentSkills(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    hasReplayHeaders: hasReplayHeaders
                )
            }
        }
        agents.post(":id", "start") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.startAgent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        agents.post(":id", "stop") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.stopAgent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        agents.get(":id", "workspace-files") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentWorkspaceFiles(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    query: request.url.query
                )
            }
        }
        agents.get(":id", "workspace-files", "read") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMachineMigrationControl.agentWorkspaceRead(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    query: request.url.query
                )
            }
        }
        agents.get("archived") { request -> Response in
            routeResponse(services.emailAccounts.listArchivedAgents(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.get("manageable") { request -> Response in
            routeResponse(services.emailAccounts.manageableAgentList(
                authorization: request.headers[.authorization]
            ))
        }
    }
}

/// Connection endpoints answer 200 with `Cache-Control: no-store`, every other
/// status is passed through untouched.
private func connectionResponse(_ reply: HTTPReply) -> Response {
    var response = routeResponse(reply)
    if reply.status == 200 {
        response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
    }
    return response
}

/// `runtime-form` advertises the language it rendered, so the header tracks the
/// request rather than the body.
private func applyRuntimeFormLanguage(_ response: inout Response, language: String?) {
    let zh = language?.lowercased().hasPrefix("zh") == true
    response.headers[HTTPField.Name("Content-Language")!] = zh ? "zh-CN" : "en"
    response.headers[HTTPField.Name("Vary")!] = "Accept-Language"
}
