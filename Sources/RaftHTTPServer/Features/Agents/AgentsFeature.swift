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
            try await respond {
                try services.emailAccounts.agentSurface.agentLogin(body: await jsonRequestBody(LegacyJSONObjectBody.self, request))
            }
        }
        agents.get { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.listServerAgents(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        agents.post { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.createAgent(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            }
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
        agents.get(":id") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.getAgent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        agents.patch(":id") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.patchAgent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request),
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
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
        agents.delete(":id", "assistant-owner") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.agentAssistantOwner(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    remove: true
                )
            }
        }
        agents.put(":id", "assistant-owner") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.agentAssistantOwner(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    remove: false
                )
            }
        }
        agents.post(":id", "avatar") { request async throws -> Response in
            let byteCount = (try await request.bodyText()).utf8.count
            return try await respond {
                try services.emailAccounts.agentSurface.uploadAgentAvatar(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? "",
                    byteCount: byteCount
                )
            }
        }
        agents.post(":id", "bootstrap-tokens") { request async throws -> Response in
            try await respond(status: 201) {
                try services.emailAccounts.agentSurface.createAgentBootstrapToken(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
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
        agents.delete(":id", "connections", ":provider") { request async throws -> Response in
            noStoreOnSuccess(try await respond(status: 204, headers: .standard()) {
                try services.emailAccounts.machinesAndHostedRuntime.disconnectAgentConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    provider: request.parameters.get("provider") ?? ""
                )
            })
        }
        agents.get(":id", "connections", ":provider") { request async throws -> Response in
            noStoreOnSuccess(try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.agentConnectionStatus(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    provider: request.parameters.get("provider") ?? ""
                )
            })
        }
        agents.post(":id", "connections", ":provider") { request async throws -> Response in
            noStoreOnSuccess(try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.startAgentConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    provider: request.parameters.get("provider") ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            })
        }
        agents.put(":id", "connections", ":provider") { request async throws -> Response in
            noStoreOnSuccess(try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.assignAgentConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    provider: request.parameters.get("provider") ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            })
        }
        agents.post(":id", "connections", ":provider", "confirm") { request async throws -> Response in
            noStoreOnSuccess(try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.confirmAgentConnection(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    provider: request.parameters.get("provider") ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            })
        }
        agents.delete(":id", "connections", ":provider", "connectors", ":connectorId") { request async throws -> Response in
            noStoreOnSuccess(try await respond(status: 204, headers: .standard()) {
                try services.emailAccounts.machinesAndHostedRuntime.disconnectAgentConnector(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    provider: request.parameters.get("provider") ?? "",
                    connectorId: request.parameters.get("connectorId") ?? ""
                )
            })
        }
        agents.patch(":id", "creator") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.patchAgentCreator(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            }
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
        agents.get(":id", "external-status") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.externalAgentStatus(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.get(":id", "hosted-runtime") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.agentHostedRuntime(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.get(":id", "hosted-runtime", "model") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.agentHostedModel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.put(":id", "hosted-runtime", "model") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.setAgentHostedModel(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            }
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.post(":id", "hosted-runtime", "retry") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.retryAgentProvisioning(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            }
        }
        agents.get(":id", "hosted-runtime", "usage") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.agentHostedUsage(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? "",
                    query: request.url.query
                )
            }
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
        agents.get(":id", "onboarding-identity-adoption") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.onboardingIdentityAdoption(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
        }
        agents.post(":id", "onboarding-identity-adoption") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.machinesAndHostedRuntime.adoptOnboardingIdentity(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
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
        agents.get(":id", "runtime-options") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.agentRuntimeOptions(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    agentId: request.parameters.get("id") ?? ""
                )
            }
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
        agents.get("archived") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.listArchivedAgents(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        agents.get("manageable") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.manageableAgentList(authorization: request.headers[.authorization])
            }
        }
    }
}

/// Connection endpoints answer 200 with `Cache-Control: no-store`, every other
/// status is passed through untouched.
private func noStoreOnSuccess(_ response: Response) -> Response {
    var response = response
    if response.status == .ok {
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
