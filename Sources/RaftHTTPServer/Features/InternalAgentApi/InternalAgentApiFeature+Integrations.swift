import Foundation
import RaftHTTP
import Vapor

/// Agent-credential integration-app management routes.
///
/// Kept in its own file so `InternalAgentApiFeature.swift` stays inside the
/// Features file ceiling. The mount order and middleware shape are the pinned
/// `registerAgentApiRoute(routeKey)`: credential capability `read`, no per-route
/// grant (these routes are authorization-checked inside the service by app
/// ownership or server admin), then the request contract, then the handler.
extension InternalAgentApiFeature {
    func registerIntegrationAppRoutes(routes: any RoutesBuilder) {
        let agentApi = routes.grouped("internal", "agent-api")

        agentApi.post("integrations", "app", "logo") { request async throws -> Response in
            let (_, denial) = agentApiGate(request, capability: "read", grant: nil)
            if let denial { return denial }
            let parsed = try await AttachmentMultipartDecoder.decode(request)
            let clientKey = parsed.fields["clientKey"] ?? ""
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppLogo(
                    authorization: request.headers[.authorization],
                    clientKey: clientKey,
                    file: parsed.files.first
                )
            }
        }
        agentApi.post("integrations", "app", "manage") { request async throws -> Response in
            let (_, denial) = agentApiGate(request, capability: "read", grant: nil)
            if let denial { return denial }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request)
            let validated = AgentApiRequestContract.integrationManageBody(body)
            guard let fields = validated.value else {
                return try await invalidAgentApiRequest(
                    routeKey: "integrationAppManage", part: "body", issues: validated.issues
                )
            }
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppManage(
                    authorization: request.headers[.authorization],
                    clientKey: fields.clientKey,
                    action: fields.action,
                    expiresInDays: fields.expiresInDays
                )
            }
        }
        agentApi.post("integrations", "app", "rotate-secret") { request async throws -> Response in
            let (_, denial) = agentApiGate(request, capability: "read", grant: nil)
            if let denial { return denial }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request)
            let validated = AgentApiRequestContract.integrationClientKeyBody(body)
            guard let clientKey = validated.value else {
                return try await invalidAgentApiRequest(
                    routeKey: "integrationAppRotateSecret", part: "body", issues: validated.issues
                )
            }
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppRotateSecret(
                    authorization: request.headers[.authorization],
                    clientKey: clientKey
                )
            }
        }
        agentApi.post("integrations", "app", "transfer-owner") { request async throws -> Response in
            let (_, denial) = agentApiGate(request, capability: "read", grant: nil)
            if let denial { return denial }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request)
            let validated = AgentApiRequestContract.integrationTransferBody(body)
            guard let fields = validated.value else {
                return try await invalidAgentApiRequest(
                    routeKey: "integrationAppTransferOwner", part: "body", issues: validated.issues
                )
            }
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppTransferOwner(
                    authorization: request.headers[.authorization],
                    clientKey: fields.clientKey,
                    targetAgent: fields.targetAgent
                )
            }
        }
    }

    /// The contract-invalid 400 for one request part.
    func invalidAgentApiRequest(
        routeKey: String,
        part: String,
        issues: [AgentApiContractInvalidResponse.Issue]
    ) async throws -> Response {
        try await respond(status: 400) {
            AgentApiContractInvalidResponse(routeKey: routeKey, part: part, issues: issues)
        }
    }
}
