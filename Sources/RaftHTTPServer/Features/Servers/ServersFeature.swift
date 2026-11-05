import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Server-scoped route surface: every `api/servers...` registration that used
/// to live inline in `configure(_:services:)`.
///
/// The blocks are lifted verbatim (method, path, headers, body projection and
/// `routeResponse` call). `register(routes:)` is synchronous because the
/// application mount is synchronous; `boot(routes:)` adapts it to the
/// `RouteCollection` requirement. The collection is not registered here; the
/// application mount decides when it is live.
public struct ServersFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        routes.post("api", "servers", "join-community") { request -> Response in
            guard let directory = services.publicVisits else {
                return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
            }
            let slug = (try? JSONSerialization.jsonObject(with: Data((request.body.string ?? "").utf8))) as? [String: Any]
            guard let userId = services.emailAccounts.authenticatedUserId(authorization: request.headers[.authorization]) else {
                return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
            }
            return routeResponse(directory.joinCommunity(
                userId: userId,
                slug: slug?["slug"] as? String
            ))
        }
        routes.get("api", "servers", "unread-summary") { request -> Response in
            routeResponse(services.emailAccounts.serversUnreadSummary(
                authorization: request.headers[.authorization]
            ))
        }
        routes.post("api", "servers") { request -> Response in
            routeResponse(services.emailAccounts.createServer(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers") { request -> Response in
            if let ordered = services.emailAccounts.orderedServerList(authorization: request.headers[.authorization]) {
                return routeResponse(ordered)
            }
            guard let directory = services.publicVisits else {
                return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
            }
            return routeResponse(directory.serverList(authorization: request.headers[.authorization]))
        }
        routes.get("api", "servers", "order") { request -> Response in
            routeResponse(services.emailAccounts.serverOrder(authorization: request.headers[.authorization]))
        }
        routes.patch("api", "servers", "order") { request -> Response in
            routeResponse(services.emailAccounts.patchServerOrder(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "feedback", ":reportId", "transcript") { request -> Response in
            routeResponse(services.emailAccounts.submitTranscriptFeedback(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                reportId: request.parameters.get("reportId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "machines", ":machineId", "computer-lifecycle-operations") { request -> Response in
            routeResponse(services.emailAccounts.computerLifecycleOperation(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId") { request -> Response in
            routeResponse(services.emailAccounts.mentionDeliveryDiagnostic(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                messageId: request.parameters.get("messageId") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "session-transcript") { request -> Response in
            routeResponse(services.emailAccounts.agentSessionTranscript(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId", "redrive") { request -> Response in
            routeResponse(services.emailAccounts.redriveMentionDelivery(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                messageId: request.parameters.get("messageId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "scope-attestation") { request -> Response in
            routeResponse(services.emailAccounts.serverScopeAttestation(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "translation-settings") { request -> Response in
            routeResponse(services.emailAccounts.serverTranslationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "translation-settings") { request -> Response in
            routeResponse(services.emailAccounts.patchServerTranslationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "labs") { request -> Response in
            routeResponse(services.emailAccounts.getServerLabs(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "labs", "access") { request -> Response in
            routeResponse(services.emailAccounts.patchServerLabsAccess(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.put("api", "servers", ":id", "labs", ":labKey") { request -> Response in
            routeResponse(services.emailAccounts.putServerLabEnrollment(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                labKey: request.parameters.get("labKey") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "agreement") { request -> Response in
            routeResponse(services.emailAccounts.getServerAgreement(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.put("api", "servers", ":id", "agreement") { request -> Response in
            routeResponse(services.emailAccounts.putServerAgreement(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "avatar") { request -> Response in
            routeResponse(services.emailAccounts.uploadServerAvatar(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "join-links") { request -> Response in
            routeResponse(services.emailAccounts.createJoinLink(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "join-links") { request -> Response in
            routeResponse(services.emailAccounts.listJoinLinks(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.delete("api", "servers", ":id", "join-links", ":linkId") { request -> Response in
            routeResponse(services.emailAccounts.revokeJoinLink(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                linkId: request.parameters.get("linkId") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "invites") { request -> Response in
            routeResponse(services.emailAccounts.listServerInvites(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "invites") { request -> Response in
            routeResponse(services.emailAccounts.createServerInvite(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "setup-reset") { request -> Response in
            routeResponse(services.emailAccounts.serverSetupReset(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "setup-handoff") { request -> Response in
            routeResponse(services.emailAccounts.serverSetupHandoff(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.delete("api", "servers", ":id", "invites", ":inviteId") { request -> Response in
            routeResponse(services.emailAccounts.revokeServerInvite(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                inviteId: request.parameters.get("inviteId") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "leave") { request -> Response in
            let serverId = request.parameters.get("id") ?? ""
            let authorization = request.headers[.authorization]
            let userId = services.emailAccounts.sessionUserId(authorization: authorization)
            let reply = services.emailAccounts.leaveServer(
                authorization: authorization,
                serverId: serverId
            )
            if reply.status == 200, let userId {
                services.realtime?.removeServerMembership(serverId: serverId, userId: userId)
            }
            return routeResponse(reply)
        }
        routes.get("api", "servers", ":id", "setup-projection") { request -> Response in
            routeResponse(services.emailAccounts.serverSetupProjection(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "setup-transition") { request -> Response in
            routeResponse(services.emailAccounts.serverSetupTransition(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "members", ":memberId") { request -> Response in
            routeResponse(services.emailAccounts.patchServerMemberRole(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                memberId: request.parameters.get("memberId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.delete("api", "servers", ":id", "members", ":memberId") { request -> Response in
            let serverId = request.parameters.get("id") ?? ""
            let memberId = request.parameters.get("memberId") ?? ""
            let reply = services.emailAccounts.removeServerMember(
                authorization: request.headers[.authorization],
                serverId: serverId,
                memberId: memberId
            )
            if reply.status == 200 {
                services.realtime?.removeServerMembership(serverId: serverId, userId: memberId)
            }
            return routeResponse(reply)
        }
        routes.delete("api", "servers", ":id") { request -> Response in
            routeResponse(services.emailAccounts.deleteServerRoute(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "sidebar-order") { request -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            return routeResponse(services.emailAccounts.patchSidebarOrder(
                authorization: request.headers[.authorization],
                serverId: id,
                body: request.body.string ?? "{}"
            ))
        }
        routes.get("api", "servers", ":id", "sidebar-order") { request -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            return routeResponse(services.emailAccounts.sidebarOrder(
                authorization: request.headers[.authorization],
                serverId: id
            ))
        }
        routes.get("api", "servers", ":id", "model-label-catalog") { request -> Response in
            routeResponse(services.emailAccounts.modelLabelCatalog(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "product-analytics-settings") { request -> Response in
            routeResponse(services.emailAccounts.serverProductAnalyticsSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "product-analytics-settings") { request -> Response in
            routeResponse(services.emailAccounts.patchServerProductAnalyticsSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "settings") { request -> Response in
            routeResponse(services.emailAccounts.serverSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "notification-settings") { request -> Response in
            routeResponse(services.emailAccounts.memberNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "notification-settings") { request -> Response in
            routeResponse(services.emailAccounts.patchServerNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "onboarding-settings") { request -> Response in
            routeResponse(services.emailAccounts.serverOnboardingSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "onboarding-settings") { request -> Response in
            routeResponse(services.emailAccounts.patchServerOnboardingSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "machines", ":machineId", "computer", ":action") { request -> Response in
            routeResponse(services.emailAccounts.computerAction(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                action: request.parameters.get("action") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.delete("api", "servers", ":id", "machines", ":machineId") { request -> Response in
            routeResponse(services.emailAccounts.deleteServerMachine(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "usage") { request -> Response in
            routeResponse(services.emailAccounts.serverUsage(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "workspaces") { request -> Response in
            routeResponse(services.emailAccounts.machineWorkspaces(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "machines", ":machineId", "runtimes", "rescan") { request -> Response in
            routeResponse(services.emailAccounts.machineRuntimeRescan(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "runtime-options") { request -> Response in        routeResponse(services.emailAccounts.machineRuntimeOptions(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                includeRuntimeFormV2: request.headers[HTTPField.Name("X-Raft-Runtime-Form-V2")!] == "1"
            ))
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "runtime-models", ":runtime") { request -> Response in
            routeResponse(services.emailAccounts.machineRuntimeModels(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                runtime: request.parameters.get("runtime") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId") { request -> Response in
            var response = routeResponse(services.emailAccounts.runtimeFormDefinition(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                runtimeId: request.parameters.get("runtimeId") ?? "",
                protocolVersion: 1,
                schemaVersion: desktopQuery(request.url.query, "schemaVersion"),
                language: request.headers[HTTPField.Name("Accept-Language")!]
            ))
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId") { request -> Response in
            var response = routeResponse(services.emailAccounts.runtimeFormDefinition(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                runtimeId: request.parameters.get("runtimeId") ?? "",
                protocolVersion: 2,
                schemaVersion: nil,
                language: request.headers[HTTPField.Name("Accept-Language")!]
            ))
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId", "option-sources", ":sourceId") { request -> Response in
            var response = routeResponse(services.emailAccounts.runtimeFormOptionSource(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                runtimeId: request.parameters.get("runtimeId") ?? "",
                sourceId: request.parameters.get("sourceId") ?? "",
                protocolVersion: 1,
                schemaVersion: desktopQuery(request.url.query, "schemaVersion"),
                language: request.headers[HTTPField.Name("Accept-Language")!]
            ))
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId", "option-sources", ":sourceId") { request -> Response in
            var response = routeResponse(services.emailAccounts.runtimeFormOptionSource(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                runtimeId: request.parameters.get("runtimeId") ?? "",
                sourceId: request.parameters.get("sourceId") ?? "",
                protocolVersion: 2,
                schemaVersion: nil,
                language: request.headers[HTTPField.Name("Accept-Language")!],
                refresh: desktopQuery(request.url.query, "refresh") == "1"
            ))
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        routes.get("api", "servers", ":id", "machines", ":machineId", "runtime-account-usage", ":provider") { request -> Response in
            var response = routeResponse(services.emailAccounts.machineRuntimeAccountUsage(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                provider: request.parameters.get("provider") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        routes.post("api", "servers", ":id", "machines", ":machineId", "runtime-account-usage", ":provider", "refresh") { request -> Response in
            routeResponse(services.emailAccounts.refreshMachineRuntimeAccountUsage(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.delete("api", "servers", ":id", "machines", ":machineId", "workspaces", ":directoryName") { request -> Response in
            routeResponse(services.emailAccounts.deleteMachineWorkspace(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                directoryName: request.parameters.get("directoryName") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "system-notifications") { request -> Response in
            var response = routeResponse(services.emailAccounts.serverSystemNotifications(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        routes.get("api", "servers", ":id", "system-notifications-v2") { request -> Response in
            var response = routeResponse(services.emailAccounts.listSystemAttention(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        routes.post("api", "servers", ":id", "system-notifications-v2", ":incidentId", "seen") { request -> Response in
            routeResponse(services.emailAccounts.markSystemAttentionSeen(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                incidentId: request.parameters.get("incidentId") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "system-notifications-v2", ":incidentId", "dismiss") { request -> Response in
            routeResponse(services.emailAccounts.dismissSystemAttention(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                incidentId: request.parameters.get("incidentId") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "machines") { request -> Response in
            routeResponse(services.emailAccounts.registerServerMachine(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "machines") { request -> Response in
            routeResponse(services.emailAccounts.listServerMachines(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.post("api", "servers", ":id", "machines", ":machineId", "rotate-key") { request -> Response in
            routeResponse(services.emailAccounts.rotateServerMachineKey(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        routes.delete("api", "servers", ":id", "machines", ":machineId") { request -> Response in
            routeResponse(services.emailAccounts.deleteServerMachine(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "machines", ":machineId") { request -> Response in
            routeResponse(services.emailAccounts.patchServerMachine(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.patch("api", "servers", ":id") { request -> Response in
            routeResponse(services.emailAccounts.patchServerProfile(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "servers", ":id") { request -> Response in
            routeResponse(services.emailAccounts.serverDetails(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "members", ":memberId", "profile") { request -> Response in
            let id = request.parameters.get("id") ?? ""
            let memberId = request.parameters.get("memberId") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            if !ServerScope.isUUID(memberId) {
                return routeResponse(ServerScope.memberProfile(
                    serverId: id,
                    headerServerId: request.headers[HTTPField.Name("X-Server-Id")!],
                    memberId: memberId
                ))
            }
            return routeResponse(services.emailAccounts.memberProfile(
                authorization: request.headers[.authorization],
                serverId: id,
                memberId: memberId
            ))
        }
        routes.get("api", "servers", ":id", "apps") { request -> Response in
            routeResponse(services.emailAccounts.serverApps(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        routes.get("api", "servers", ":id", "member-graph") { request -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            return routeResponse(services.emailAccounts.serverMemberGraph(
                authorization: request.headers[.authorization],
                serverId: id
            ))
        }
        routes.get("api", "servers", ":id", "members") { request -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            return routeResponse(services.emailAccounts.serverMembersList(
                authorization: request.headers[.authorization],
                serverId: id
            ))
        }
        routes.get("api", "servers", ":id", "public-visibility") { request -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.readVisibility(serverId: id, authorization: request.headers[.authorization]))
        }
        routes.patch("api", "servers", ":id", "public-guest-join") { request -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.patchGuestJoin(
                serverId: id,
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "public-visibility") { request -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.patchVisibility(
                serverId: id,
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        routes.patch("api", "servers", ":id", "public-search") { request -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.patchSearch(
                serverId: id,
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
    }
}

// MARK: - Helpers lifted from FallbackApplication.swift

// File-scoped copies of the two private helpers the runtime-form routes use.
// They cannot be shared across files (`private` is file-scoped there), so the
// bodies are copied unchanged rather than widening the original declarations.

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

private func applyRuntimeFormLanguage(_ response: inout Response, language: String?) {
    let zh = language?.lowercased().hasPrefix("zh") == true
    response.headers[HTTPField.Name("Content-Language")!] = zh ? "zh-CN" : "en"
    response.headers[HTTPField.Name("Vary")!] = "Accept-Language"
}
