import Foundation
import RaftHTTP
import Vapor

/// Agent-credential integration-app management routes.
///
/// Kept in its own file so `InternalAgentApiFeature.swift` stays inside the
/// Features file ceiling. The mount order and middleware shape are the pinned
/// `registerAgentApiRoute(routeKey)`: credential capability `read`, no per-route
/// grant (these routes are authorization-checked inside the service by app
/// ownership or server admin), the shared contract validators, then the
/// handler. `agentApiContractRefusal` owns the first two steps for every route
/// in this file.
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
            if let refusal = try await agentApiContractRefusal(.integrationAppManage, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "read", grant: nil)
            if let denial { return denial }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request)
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppManage(
                    authorization: request.headers[.authorization],
                    clientKey: body?.string("clientKey") ?? "",
                    action: body?.string("action") ?? "",
                    expiresInDays: body?.int("expiresInDays")
                )
            }
        }
        agentApi.post("integrations", "app", "rotate-secret") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.integrationAppRotateSecret, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "read", grant: nil)
            if let denial { return denial }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request)
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppRotateSecret(
                    authorization: request.headers[.authorization],
                    clientKey: body?.string("clientKey") ?? ""
                )
            }
        }
        agentApi.post("integrations", "app", "transfer-owner") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.integrationAppTransferOwner, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "read", grant: nil)
            if let denial { return denial }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request)
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppTransferOwner(
                    authorization: request.headers[.authorization],
                    clientKey: body?.string("clientKey") ?? "",
                    targetAgent: body?.string("targetAgent") ?? ""
                )
            }
        }
    }
}
