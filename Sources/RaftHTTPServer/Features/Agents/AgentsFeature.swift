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

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let agentGroup = routes.grouped("api", "agent")
        let agents = routes.grouped("api", "agents")

        agentGroup.post("login") { request -> Response in
            routeResponse(services.emailAccounts.agentLogin(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        agents.get { request -> Response in
            routeResponse(services.emailAccounts.listServerAgents(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.post { request -> Response in
            routeResponse(services.emailAccounts.createAgentRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        agents.delete(":id") { request -> Response in
            routeResponse(services.emailAccounts.deleteAgentRoute(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.get(":id") { request -> Response in
            routeResponse(services.emailAccounts.getAgentRoute(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.patch(":id") { request -> Response in
            routeResponse(services.emailAccounts.patchAgent(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.get(":id", "activity") { request -> Response in
            routeResponse(services.emailAccounts.agentPrivateSurface(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                surface: "activity"
            ))
        }
        agents.get(":id", "activity-log") { request -> Response in
            routeResponse(services.emailAccounts.agentPrivateSurface(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                surface: "activity-log",
                query: request.url.query
            ))
        }
        agents.get(":id", "activity-summaries") { request -> Response in
            routeResponse(services.emailAccounts.agentPrivateSurface(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                surface: "activity-summaries",
                query: request.url.query
            ))
        }
        agents.get(":id", "agent-dms") { request -> Response in
            routeResponse(services.emailAccounts.agentDirectMessages(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        agents.get(":id", "archive") { request -> Response in
            routeResponse(services.emailAccounts.agentArchiveView(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.post(":id", "archive", "workspace") { request -> Response in
            routeResponse(services.emailAccounts.agentArchiveWorkspaceAction(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        agents.post(":id", "assign-machine") { request -> Response in
            routeResponse(services.emailAccounts.assignAgentMachine(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
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
        agents.post(":id", "avatar") { request -> Response in
            routeResponse(services.emailAccounts.uploadAgentAvatar(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                byteCount: request.body.string?.utf8.count ?? 0
            ))
        }
        agents.post(":id", "bootstrap-tokens") { request -> Response in
            routeResponse(services.emailAccounts.createAgentBootstrapToken(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        agents.get(":id", "channels") { request -> Response in
            routeResponse(services.emailAccounts.agentChannels(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
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
        agents.post(":id", "connections", ":provider") { request -> Response in
            connectionResponse(services.emailAccounts.startAgentConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? ""
            ))
        }
        agents.put(":id", "connections", ":provider") { request -> Response in
            connectionResponse(services.emailAccounts.assignAgentConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? ""
            ))
        }
        agents.post(":id", "connections", ":provider", "confirm") { request -> Response in
            connectionResponse(services.emailAccounts.confirmAgentConnection(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? ""
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
        agents.patch(":id", "creator") { request -> Response in
            routeResponse(services.emailAccounts.patchAgentCreator(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        agents.get(":id", "credentials") { request -> Response in
            var response = routeResponse(services.emailAccounts.listAgentCredentials(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.post(":id", "credentials") { request -> Response in
            var response = routeResponse(services.emailAccounts.issueAgentCredential(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.delete(":id", "credentials", ":credentialId") { request -> Response in
            routeResponse(services.emailAccounts.revokeAgentCredential(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                credentialId: request.parameters.get("credentialId") ?? ""
            ))
        }
        agents.get(":id", "external-diagnostics") { request -> Response in
            routeResponse(services.emailAccounts.externalAgentDiagnostics(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
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
        agents.put(":id", "hosted-runtime", "model") { request -> Response in
            var response = routeResponse(services.emailAccounts.setAgentHostedModel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "no-store"
            return response
        }
        agents.post(":id", "hosted-runtime", "retry") { request -> Response in
            routeResponse(services.emailAccounts.retryAgentProvisioning(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
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
        agents.post(":id", "migrate") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "migrate",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.get(":id", "migration") { request -> Response in
            routeResponse(services.emailAccounts.agentMigrationStatus(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? ""
            ))
        }
        agents.post(":id", "migration", "cancel") { request -> Response in
            routeResponse(services.emailAccounts.agentMigrationCancel(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        agents.post(":id", "migration", "confirm-hosted") { request -> Response in
            routeResponse(services.emailAccounts.confirmHostedMigration(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
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
        agents.post(":id", "reset") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "reset",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.get(":id", "runtime-form") { request -> Response in
            var response = routeResponse(services.emailAccounts.agentRuntimeForm(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                language: request.headers[HTTPField.Name("Accept-Language")!]
            ))
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
        agents.get(":id", "scopes") { request -> Response in
            routeResponse(services.emailAccounts.agentScopesRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                method: "GET",
                body: ""
            ))
        }
        agents.put(":id", "scopes") { request -> Response in
            routeResponse(services.emailAccounts.agentScopesRoute(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                method: "PUT",
                body: request.body.string ?? ""
            ))
        }
        agents.get(":id", "skills") { request -> Response in
            let hasReplayHeaders = request.headers[HTTPField.Name("X-Raft-Replica-Replay")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Machine")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Timestamp")!] != nil
                || request.headers[HTTPField.Name("X-Raft-Replica-Replay-Signature")!] != nil
            return routeResponse(services.emailAccounts.agentPrivateSurface(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                surface: "skills",
                hasReplayHeaders: hasReplayHeaders
            ))
        }
        agents.post(":id", "start") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "start",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.post(":id", "stop") { request -> Response in
            routeResponse(services.emailAccounts.agentRuntimeAction(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("id") ?? "",
                action: "stop",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        agents.get(":id", "workspace-files") { request -> Response in
            routeResponse(services.emailAccounts.agentWorkspaceFiles(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                query: request.url.query
            ))
        }
        agents.get(":id", "workspace-files", "read") { request -> Response in
            routeResponse(services.emailAccounts.agentWorkspaceRead(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                agentId: request.parameters.get("id") ?? "",
                query: request.url.query
            ))
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
