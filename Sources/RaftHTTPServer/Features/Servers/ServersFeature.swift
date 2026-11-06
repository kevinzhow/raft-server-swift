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
        let servers = routes.grouped("api", "servers")

        servers.post("join-community") { request async throws -> Response in
            guard let directory = services.publicVisits else {
                return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
            }
            let rawBody = (try? await request.bodyText()) ?? ""
            let slug = (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: Any]
            guard let userId = services.emailAccounts.authenticatedUserId(authorization: request.headers[.authorization]) else {
                return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
            }
            return routeResponse(directory.joinCommunity(
                userId: userId,
                slug: slug?["slug"] as? String
            ))
        }
        servers.get("unread-summary") { request -> Response in
            routeResponse(services.emailAccounts.serversUnreadSummary(
                authorization: request.headers[.authorization]
            ))
        }
        servers.post() { request async throws -> Response in
            // `name` and `slug` are the only body fields. A body that does not
            // carry both strings keeps the directory's raw parser so the
            // published `Invalid server request` 400 is unchanged.
            if let body = try? await request.content.decode(ServerCreateRequestDTO.self) {
                return routeResponse(services.emailAccounts.createServer(
                    authorization: request.headers[.authorization],
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.createServer(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        servers.get() { request -> Response in
            if let ordered = services.emailAccounts.orderedServerList(authorization: request.headers[.authorization]) {
                return routeResponse(ordered)
            }
            guard let directory = services.publicVisits else {
                return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
            }
            return routeResponse(directory.serverList(authorization: request.headers[.authorization]))
        }
        servers.get("order") { request -> Response in
            routeResponse(services.emailAccounts.serverOrder(authorization: request.headers[.authorization]))
        }
        servers.patch("order") { request async throws -> Response in
            // `serverOrder` is the only field. A body that does not decode
            // keeps the directory's raw parser, which owns the sanitizing and
            // the `Invalid server order` 400.
            if let body = try? await request.content.decode(ServerOrderPatchDTO.self) {
                return routeResponse(services.emailAccounts.patchServerOrder(
                    authorization: request.headers[.authorization],
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.patchServerOrder(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        servers.post(":id", "machines", ":machineId", "agents", ":agentId", "feedback", ":reportId", "transcript") { request async throws -> Response in
            routeResponse(services.emailAccounts.submitTranscriptFeedback(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                reportId: request.parameters.get("reportId") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.post(":id", "machines", ":machineId", "computer-lifecycle-operations") { request async throws -> Response in
            routeResponse(services.emailAccounts.computerLifecycleOperation(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId") { request -> Response in
            routeResponse(services.emailAccounts.mentionDeliveryDiagnostic(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                messageId: request.parameters.get("messageId") ?? ""
            ))
        }
        servers.get(":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "session-transcript") { request -> Response in
            routeResponse(services.emailAccounts.agentSessionTranscript(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }
        servers.post(":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId", "redrive") { request async throws -> Response in
            routeResponse(services.emailAccounts.redriveMentionDelivery(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                agentId: request.parameters.get("agentId") ?? "",
                messageId: request.parameters.get("messageId") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.post(":id", "scope-attestation") { request async throws -> Response in
            routeResponse(services.emailAccounts.serverScopeAttestation(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "translation-settings") { request -> Response in
            routeResponse(services.emailAccounts.serverTranslationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.patch(":id", "translation-settings") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchServerTranslationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "labs") { request -> Response in
            routeResponse(services.emailAccounts.getServerLabs(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        servers.patch(":id", "labs", "access") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchServerLabsAccess(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.put(":id", "labs", ":labKey") { request async throws -> Response in
            routeResponse(services.emailAccounts.putServerLabEnrollment(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                labKey: request.parameters.get("labKey") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "agreement") { request -> Response in
            routeResponse(services.emailAccounts.getServerAgreement(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.put(":id", "agreement") { request async throws -> Response in
            routeResponse(services.emailAccounts.putServerAgreement(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.post(":id", "avatar") { request -> Response in
            routeResponse(services.emailAccounts.uploadServerAvatar(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.post(":id", "join-links") { request async throws -> Response in
            // `expiresAt` and `maxUses` are the only fields. A fractional or
            // string `maxUses` does not decode, so that request keeps the raw
            // parser and its `maxUses must be a positive integer` 400.
            if let body = try? await request.content.decode(JoinLinkCreateDTO.self) {
                return routeResponse(services.emailAccounts.createJoinLink(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.createJoinLink(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "join-links") { request -> Response in
            routeResponse(services.emailAccounts.listJoinLinks(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.delete(":id", "join-links", ":linkId") { request -> Response in
            routeResponse(services.emailAccounts.revokeJoinLink(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                linkId: request.parameters.get("linkId") ?? ""
            ))
        }
        servers.get(":id", "invites") { request -> Response in
            routeResponse(services.emailAccounts.listServerInvites(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.post(":id", "invites") { request async throws -> Response in
            // `email` is required and `role` defaults to `member` in both
            // paths. A body that does not decode keeps the raw parser so the
            // published invite errors are unchanged.
            if let body = try? await request.content.decode(ServerInviteCreateDTO.self) {
                return routeResponse(services.emailAccounts.createServerInvite(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.createServerInvite(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.post(":id", "setup-reset") { request async throws -> Response in
            // The reset selects its target by path and reads no body fields.
            // Decoding states that empty contract; a malformed body still
            // resolves through the same path-only authorization.
            _ = try? await request.content.decode(ServerSetupResetDTO.self)
            return routeResponse(services.emailAccounts.serverSetupReset(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.post(":id", "setup-handoff") { request -> Response in
            routeResponse(services.emailAccounts.serverSetupHandoff(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.delete(":id", "invites", ":inviteId") { request -> Response in
            routeResponse(services.emailAccounts.revokeServerInvite(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                inviteId: request.parameters.get("inviteId") ?? ""
            ))
        }
        servers.post(":id", "leave") { request -> Response in
            let serverId = request.parameters.get("id") ?? ""
            let authorization = request.headers[.authorization]
            let userId = services.emailAccounts.sessionUserId(authorization: authorization)
            let reply = services.emailAccounts.leaveServer(
                authorization: authorization,
                serverId: serverId
            )
            if reply.status == 200, let userId {
                services.emailAccounts.socketMembership.revokeServerMembershipResources(serverId: serverId, userId: userId)
                services.realtime?.removeServerMembership(serverId: serverId, userId: userId)
            }
            return routeResponse(reply)
        }
        servers.get(":id", "setup-projection") { request -> Response in
            routeResponse(services.emailAccounts.serverSetupProjection(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.post(":id", "setup-transition") { request async throws -> Response in
            routeResponse(services.emailAccounts.serverSetupTransition(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.patch(":id", "members", ":memberId") { request async throws -> Response in
            // `role` is the only field; the directory owns the membership and
            // self-demotion rules. A body that does not decode keeps the raw
            // parser so `Invalid member role` stays the same.
            if let body = try? await request.content.decode(ServerMemberRolePatchDTO.self) {
                return routeResponse(services.emailAccounts.patchServerMemberRole(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    memberId: request.parameters.get("memberId") ?? "",
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.patchServerMemberRole(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                memberId: request.parameters.get("memberId") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.delete(":id", "members", ":memberId") { request -> Response in
            let serverId = request.parameters.get("id") ?? ""
            let memberId = request.parameters.get("memberId") ?? ""
            let reply = services.emailAccounts.removeServerMember(
                authorization: request.headers[.authorization],
                serverId: serverId,
                memberId: memberId
            )
            if reply.status == 200 {
                services.emailAccounts.socketMembership.revokeServerMembershipResources(serverId: serverId, userId: memberId)
                services.realtime?.removeServerMembership(serverId: serverId, userId: memberId)
            }
            return routeResponse(reply)
        }
        servers.delete(":id") { request -> Response in
            routeResponse(services.emailAccounts.deleteServerRoute(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.patch(":id", "sidebar-order") { request async throws -> Response in
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
                body: try await request.bodyText(default: "{}")
            ))
        }
        servers.get(":id", "sidebar-order") { request -> Response in
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
        servers.get(":id", "model-label-catalog") { request -> Response in
            routeResponse(services.emailAccounts.modelLabelCatalog(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.get(":id", "product-analytics-settings") { request -> Response in
            routeResponse(services.emailAccounts.serverProductAnalyticsSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.patch(":id", "product-analytics-settings") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchServerProductAnalyticsSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "settings") { request -> Response in
            routeResponse(services.emailAccounts.serverSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.get(":id", "notification-settings") { request -> Response in
            routeResponse(services.emailAccounts.memberNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.patch(":id", "notification-settings") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchServerNotificationSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "onboarding-settings") { request -> Response in
            routeResponse(services.emailAccounts.serverOnboardingSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.patch(":id", "onboarding-settings") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchServerOnboardingSettings(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.post(":id", "machines", ":machineId", "computer", ":action") { request async throws -> Response in
            routeResponse(services.emailAccounts.computerAction(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                action: request.parameters.get("action") ?? "",
                body: try await request.bodyText()
            ))
        }
        registerServerMachineDelete(on: servers)
        servers.get(":id", "usage") { request -> Response in
            routeResponse(services.emailAccounts.serverUsage(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.get(":id", "machines", ":machineId", "workspaces") { request -> Response in
            routeResponse(services.emailAccounts.machineWorkspaces(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        servers.post(":id", "machines", ":machineId", "runtimes", "rescan") { request -> Response in
            routeResponse(services.emailAccounts.machineRuntimeRescan(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        servers.get(":id", "machines", ":machineId", "runtime-options") { request -> Response in        routeResponse(services.emailAccounts.machineRuntimeOptions(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                includeRuntimeFormV2: request.headers[HTTPField.Name("X-Raft-Runtime-Form-V2")!] == "1"
            ))
        }
        servers.get(":id", "machines", ":machineId", "runtime-models", ":runtime") { request -> Response in
            routeResponse(services.emailAccounts.machineRuntimeModels(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                runtime: request.parameters.get("runtime") ?? ""
            ))
        }
        servers.get(":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId") { request -> Response in
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
        servers.get(":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId") { request -> Response in
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
        servers.get(":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId", "option-sources", ":sourceId") { request -> Response in
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
        servers.get(":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId", "option-sources", ":sourceId") { request -> Response in
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
        servers.get(":id", "machines", ":machineId", "runtime-account-usage", ":provider") { request -> Response in
            var response = routeResponse(services.emailAccounts.machineRuntimeAccountUsage(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                provider: request.parameters.get("provider") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        servers.post(":id", "machines", ":machineId", "runtime-account-usage", ":provider", "refresh") { request async throws -> Response in
            routeResponse(services.emailAccounts.refreshMachineRuntimeAccountUsage(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                provider: request.parameters.get("provider") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.delete(":id", "machines", ":machineId", "workspaces", ":directoryName") { request -> Response in
            routeResponse(services.emailAccounts.deleteMachineWorkspace(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                directoryName: request.parameters.get("directoryName") ?? ""
            ))
        }
        servers.get(":id", "system-notifications") { request -> Response in
            var response = routeResponse(services.emailAccounts.serverSystemNotifications(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        servers.get(":id", "system-notifications-v2") { request -> Response in
            var response = routeResponse(services.emailAccounts.listSystemAttention(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        servers.post(":id", "system-notifications-v2", ":incidentId", "seen") { request -> Response in
            routeResponse(services.emailAccounts.markSystemAttentionSeen(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                incidentId: request.parameters.get("incidentId") ?? ""
            ))
        }
        servers.post(":id", "system-notifications-v2", ":incidentId", "dismiss") { request -> Response in
            routeResponse(services.emailAccounts.dismissSystemAttention(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                incidentId: request.parameters.get("incidentId") ?? ""
            ))
        }
        servers.post(":id", "machines") { request async throws -> Response in
            routeResponse(services.emailAccounts.registerServerMachine(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id", "machines") { request -> Response in
            routeResponse(services.emailAccounts.listServerMachines(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.post(":id", "machines", ":machineId", "rotate-key") { request -> Response in
            routeResponse(services.emailAccounts.rotateServerMachineKey(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
        registerServerMachineDelete(on: servers)
        servers.patch(":id", "machines", ":machineId") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchServerMachine(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.patch(":id") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchServerProfile(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                body: try await request.bodyText()
            ))
        }
        servers.get(":id") { request -> Response in
            routeResponse(services.emailAccounts.serverDetails(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.get(":id", "members", ":memberId", "profile") { request -> Response in
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
        servers.get(":id", "apps") { request -> Response in
            routeResponse(services.emailAccounts.serverApps(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.get(":id", "member-graph") { request -> Response in
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
        servers.get(":id", "members") { request -> Response in
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
        servers.get(":id", "public-visibility") { request -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.readVisibility(serverId: id, authorization: request.headers[.authorization]))
        }
        servers.patch(":id", "public-guest-join") { request async throws -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.patchGuestJoin(
                serverId: id,
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        servers.patch(":id", "public-visibility") { request async throws -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.patchVisibility(
                serverId: id,
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        servers.patch(":id", "public-search") { request async throws -> Response in
            guard let directory = services.publicServerDirectory, let id = request.parameters.get("id") else {
                return routeResponse(HTTPReply(status: 404, headers: [:], body: "{\"error\":\"Not found\"}"))
            }
            return routeResponse(directory.patchSearch(
                serverId: id,
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
    }

    /// Registers `DELETE /api/servers/:id/machines/:machineId`.
    ///
    /// Upstream registers this route twice (its servers route module mounts the
    /// same handler on both surfaces) and `FeatureServersRoutesTests` locks the
    /// registered multiset, so both call sites stay. RoutingKit logs an
    /// override warning and keeps the second leaf; this helper only makes the
    /// intentional duplicate explicit instead of copy-pasting the handler.
    private func registerServerMachineDelete(on servers: any RoutesBuilder) {
        servers.delete(":id", "machines", ":machineId") { request -> Response in
            routeResponse(services.emailAccounts.deleteServerMachine(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? "",
                machineId: request.parameters.get("machineId") ?? ""
            ))
        }
    }
}

// MARK: - Helpers lifted from FallbackApplication.swift

private func applyRuntimeFormLanguage(_ response: inout Response, language: String?) {
    let zh = language?.lowercased().hasPrefix("zh") == true
    response.headers[HTTPField.Name("Content-Language")!] = zh ? "zh-CN" : "en"
    response.headers[HTTPField.Name("Vary")!] = "Accept-Language"
}
