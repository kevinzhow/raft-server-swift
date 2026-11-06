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

    /// Decodes one typed JSON body even when the client omitted a JSON
    /// `Content-Type`. The published handlers accepted a raw JSON body before
    /// the typed migration, so the fallback keeps that behavior without a
    /// second raw parser in the service.
    private func typedJSONBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
        if let decoded = try? await request.content.decode(type) { return decoded }
        guard let data = try await request.body.collect() else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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
        servers.get("unread-summary") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try services.emailAccounts.serverProfileAndOrder.serversUnreadSummary(
                    authorization: request.headers[.authorization]
                )
            }
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
        servers.get() { request async throws -> Response in
            if let ordered = services.emailAccounts.serverProfileAndOrder.orderedServerList(authorization: request.headers[.authorization]) {
                return try await respond { ordered }
            }
            guard let directory = services.publicVisits else {
                return routeResponse(PublicVisits.authRequired(authorization: request.headers[.authorization]))
            }
            return routeResponse(directory.serverList(authorization: request.headers[.authorization]))
        }
        servers.get("order") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverProfileAndOrder.serverOrder(authorization: request.headers[.authorization])
            }
        }
        servers.patch("order") { request async throws -> Response in
            // `serverOrder` is the only field. A body that does not decode
            // reaches the service as nil and keeps the `Invalid server order` 400.
            let body = await jsonRequestBody(ServerOrderPatchDTO.self, request)
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.patchServerOrder(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        servers.post(":id", "machines", ":machineId", "agents", ":agentId", "feedback", ":reportId", "transcript") { request async throws -> Response in
            // A typed body is the common case; a body without a JSON
            // Content-Type keeps the raw parser, which is the authority for the
            // published `Invalid transcript request` and timestamp errors.
            if let body = try? await request.content.decode(TranscriptFeedbackRequestDTO.self) {
                return try await respond(status: 202) {
                    try services.emailAccounts.runtimeUsageAttestations.submitTranscriptFeedback(
                        authorization: request.headers[.authorization],
                        serverId: request.parameters.get("id") ?? "",
                        agentId: request.parameters.get("agentId") ?? "",
                        reportId: request.parameters.get("reportId") ?? "",
                        body: body.encodedBody()
                    )
                }
            }
            let raw = try await request.bodyText()
            return try await respond(status: 202) {
                try services.emailAccounts.runtimeUsageAttestations.submitTranscriptFeedback(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    agentId: request.parameters.get("agentId") ?? "",
                    reportId: request.parameters.get("reportId") ?? "",
                    body: raw
                )
            }
        }
        servers.post(":id", "machines", ":machineId", "computer-lifecycle-operations") { request async throws -> Response in
            let body = await jsonRequestBody(ComputerLifecycleRequest.self, request) ?? ComputerLifecycleRequest()
            return try await respond(status: 201) {
                try services.emailAccounts.computersFleet.computerLifecycleOperation(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    request: body
                )
            }
        }
        servers.get(":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId") { request async throws -> Response in
            try await respond(status: 404) {
                try services.emailAccounts.runtimeUsageAttestations.mentionDeliveryDiagnostic(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    agentId: request.parameters.get("agentId") ?? "",
                    messageId: request.parameters.get("messageId") ?? ""
                )
            }
        }
        servers.get(":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "session-transcript") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeUsageAttestations.agentSessionTranscript(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        servers.post(":id", "machines", ":machineId", "agents", ":agentId", "diagnostic", "mention-delivery", ":messageId", "redrive") { request async throws -> Response in
            // Same split as transcript feedback: a decodable typed body keeps
            // the route on `content.decode`, and every other spelling (boolean
            // or zero-fraction numbers included) stays on the legacy parser.
            if let typed = try? await request.content.decode(MentionRedriveRequestDTO.self) {
                return try await respond(status: 404) {
                    try services.emailAccounts.runtimeUsageAttestations.redriveMentionDelivery(
                        authorization: request.headers[.authorization],
                        serverId: request.parameters.get("id") ?? "",
                        machineId: request.parameters.get("machineId") ?? "",
                        agentId: request.parameters.get("agentId") ?? "",
                        messageId: request.parameters.get("messageId") ?? "",
                        body: typed.encodedBody()
                    )
                }
            }
            let raw = try await request.bodyText()
            return try await respond(status: 404) {
                try services.emailAccounts.runtimeUsageAttestations.redriveMentionDelivery(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    agentId: request.parameters.get("agentId") ?? "",
                    messageId: request.parameters.get("messageId") ?? "",
                    body: raw
                )
            }
        }
        servers.post(":id", "scope-attestation") { request async throws -> Response in
            let body = await jsonRequestBody(ServerScopeAttestationRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.serverScopeAttestation(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.get(":id", "translation-settings") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverProfileAndOrder.serverTranslationSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.patch(":id", "translation-settings") { request async throws -> Response in
            let body = await jsonRequestBody(ServerTranslationSettingsPatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.patchServerTranslationSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.get(":id", "labs") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverMembersAndSidebar.getServerLabs(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        servers.patch(":id", "labs", "access") { request async throws -> Response in
            let body = await jsonRequestBody(ServerLabsToggleRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverMembersAndSidebar.patchServerLabsAccess(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }
        servers.put(":id", "labs", ":labKey") { request async throws -> Response in
            let body = await jsonRequestBody(ServerLabsToggleRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverMembersAndSidebar.putServerLabEnrollment(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    headerServerId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    labKey: request.parameters.get("labKey") ?? "",
                    body: body
                )
            }
        }
        servers.get(":id", "agreement") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverProfileAndOrder.getServerAgreement(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.put(":id", "agreement") { request async throws -> Response in
            let body = await jsonRequestBody(ServerAgreementPutRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.putServerAgreement(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.post(":id", "avatar") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverProfileAndOrder.uploadServerAvatar(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.post(":id", "join-links") { request async throws -> Response in
            // `expiresAt` and `maxUses` are the only fields. The typed decoder
            // keeps the raw parser's tolerance: a wrong-typed field reads as
            // absent and an invalid cap still answers the published 400.
            let body = (try await typedJSONBody(CreateJoinLinkRequest.self, request)) ?? CreateJoinLinkRequest()
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.createJoinLink(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.get(":id", "join-links") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.listJoinLinks(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.delete(":id", "join-links", ":linkId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.revokeJoinLink(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    linkId: request.parameters.get("linkId") ?? ""
                )
            }
        }
        servers.get(":id", "invites") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.listServerInvites(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.post(":id", "invites") { request async throws -> Response in
            // `email` is required and `role` defaults to `member`. A body that
            // is not a JSON object falls back to the empty request, which is
            // the published invite error for a missing address.
            let body = try await typedJSONBody(CreateServerInviteRequest.self, request)
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.createServerInvite(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.post(":id", "setup-reset") { request async throws -> Response in
            // The reset selects its target by path and reads no body fields.
            // Decoding states that empty contract; a malformed body still
            // resolves through the same path-only authorization.
            _ = try? await request.content.decode(ServerSetupResetDTO.self)
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.serverSetupReset(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.post(":id", "setup-handoff") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.serverSetupHandoff(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.delete(":id", "invites", ":inviteId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.revokeServerInvite(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    inviteId: request.parameters.get("inviteId") ?? ""
                )
            }
        }
        servers.post(":id", "leave") { request async throws -> Response in
            let serverId = request.parameters.get("id") ?? ""
            let authorization = request.headers[.authorization]
            let userId = services.emailAccounts.sessionUserId(authorization: authorization)
            return try await respond {
                let result = try services.emailAccounts.joinLinksAndInvites.leaveServer(
                    authorization: authorization,
                    serverId: serverId
                )
                if let userId {
                    services.emailAccounts.socketMembership.revokeServerMembershipResources(
                        serverId: serverId,
                        userId: userId
                    )
                    services.realtime?.removeServerMembership(serverId: serverId, userId: userId)
                }
                return result
            }
        }
        servers.get(":id", "setup-projection") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.serverSetupProjection(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.post(":id", "setup-transition") { request async throws -> Response in
            let body = try await typedJSONBody(ServerSetupTransitionRequest.self, request)
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.serverSetupTransition(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.patch(":id", "members", ":memberId") { request async throws -> Response in
            // A body that does not decode keeps the service's published
            // `Invalid member role` 400; an absent one does too.
            let body = await jsonRequestBody(ServerMemberRolePatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverMembersAndSidebar.patchServerMemberRole(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    memberId: request.parameters.get("memberId") ?? "",
                    body: body
                )
            }
        }
        servers.delete(":id", "members", ":memberId") { request async throws -> Response in
            let serverId = request.parameters.get("id") ?? ""
            let memberId = request.parameters.get("memberId") ?? ""
            return try await respond {
                let result = try services.emailAccounts.serverMembersAndSidebar.removeServerMember(
                    authorization: request.headers[.authorization],
                    serverId: serverId,
                    memberId: memberId
                )
                services.emailAccounts.socketMembership.revokeServerMembershipResources(
                    serverId: serverId,
                    userId: memberId
                )
                services.realtime?.removeServerMembership(serverId: serverId, userId: memberId)
                return result
            }
        }
        servers.delete(":id") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverMembersAndSidebar.deleteServer(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.patch(":id", "sidebar-order") { request async throws -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            var body = await jsonRequestBody(SidebarOrderPatchRequest.self, request)
            if body == nil {
                // The retired handler defaulted an absent body to `{}` and
                // answered malformed bytes with `Invalid sidebar order`.
                let raw = (try? await request.bodyText(default: "")) ?? ""
                if raw.isEmpty { body = SidebarOrderPatchRequest() }
            }
            return try await respond {
                try services.emailAccounts.serverMembersAndSidebar.patchSidebarOrder(
                    authorization: request.headers[.authorization],
                    serverId: id,
                    body: body
                )
            }
        }
        servers.get(":id", "sidebar-order") { request async throws -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            return try await respond {
                try services.emailAccounts.serverMembersAndSidebar.sidebarOrder(
                    authorization: request.headers[.authorization],
                    serverId: id
                )
            }
        }
        servers.get(":id", "model-label-catalog") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.modelLabelCatalog(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
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
        servers.get(":id", "settings") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.serverSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.get(":id", "notification-settings") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.memberNotificationSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.patch(":id", "notification-settings") { request async throws -> Response in
            let body = try await typedJSONBody(ServerNotificationPatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.patchServerNotificationSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.get(":id", "onboarding-settings") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.serverOnboardingSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.patch(":id", "onboarding-settings") { request async throws -> Response in
            let body = try await typedJSONBody(ServerOnboardingPatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.patchServerOnboardingSettings(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.post(":id", "machines", ":machineId", "computer", ":action") { request async throws -> Response in
            let body = await jsonRequestBody(ComputerActionRequest.self, request) ?? ComputerActionRequest()
            return try await respond {
                try services.emailAccounts.computersFleet.computerAction(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    action: request.parameters.get("action") ?? "",
                    request: body
                )
            }
        }
        registerServerMachineDelete(on: servers)
        servers.get(":id", "usage") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeUsageAttestations.serverUsage(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.get(":id", "machines", ":machineId", "workspaces") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.machineWorkspaces(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? ""
                )
            }
        }
        servers.post(":id", "machines", ":machineId", "runtimes", "rescan") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.machineRuntimeRescan(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? ""
                )
            }
        }
        servers.get(":id", "machines", ":machineId", "runtime-options") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.machineRuntimeOptions(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    includeRuntimeFormV2: request.headers[HTTPField.Name("X-Raft-Runtime-Form-V2")!] == "1"
                )
            }
        }
        servers.get(":id", "machines", ":machineId", "runtime-models", ":runtime") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.machineRuntimeModels(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    runtime: request.parameters.get("runtime") ?? ""
                )
            }
        }
        servers.get(":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.runtimeFormDefinition(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    runtimeId: request.parameters.get("runtimeId") ?? "",
                    protocolVersion: 1,
                    schemaVersion: desktopQuery(request.url.query, "schemaVersion"),
                    language: request.headers[HTTPField.Name("Accept-Language")!]
                )
            }
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        servers.get(":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.runtimeFormDefinition(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    runtimeId: request.parameters.get("runtimeId") ?? "",
                    protocolVersion: 2,
                    schemaVersion: nil,
                    language: request.headers[HTTPField.Name("Accept-Language")!]
                )
            }
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        servers.get(":id", "machines", ":machineId", "runtime-form-definitions", ":runtimeId", "option-sources", ":sourceId") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.runtimeFormOptionSource(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    runtimeId: request.parameters.get("runtimeId") ?? "",
                    sourceId: request.parameters.get("sourceId") ?? "",
                    protocolVersion: 1,
                    schemaVersion: desktopQuery(request.url.query, "schemaVersion"),
                    language: request.headers[HTTPField.Name("Accept-Language")!]
                )
            }
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        servers.get(":id", "machines", ":machineId", "runtime-forms", "v2", ":runtimeId", "option-sources", ":sourceId") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.runtimeFormOptionSource(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    runtimeId: request.parameters.get("runtimeId") ?? "",
                    sourceId: request.parameters.get("sourceId") ?? "",
                    protocolVersion: 2,
                    schemaVersion: nil,
                    language: request.headers[HTTPField.Name("Accept-Language")!],
                    refresh: desktopQuery(request.url.query, "refresh") == "1"
                )
            }
            applyRuntimeFormLanguage(&response, language: request.headers[HTTPField.Name("Accept-Language")!])
            return response
        }
        servers.get(":id", "machines", ":machineId", "runtime-account-usage", ":provider") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.machineRuntimeAccountUsage(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    provider: request.parameters.get("provider") ?? ""
                )
            }
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        servers.post(":id", "machines", ":machineId", "runtime-account-usage", ":provider", "refresh") { request async throws -> Response in
            let body = try await typedJSONBody(RuntimeAccountUsageRefreshRequest.self, request)
            return try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.refreshMachineRuntimeAccountUsage(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    provider: request.parameters.get("provider") ?? "",
                    body: body
                )
            }
        }
        servers.delete(":id", "machines", ":machineId", "workspaces", ":directoryName") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.deleteMachineWorkspace(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    directoryName: request.parameters.get("directoryName") ?? ""
                )
            }
        }
        servers.get(":id", "system-notifications") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeUsageAttestations.serverSystemNotifications(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        servers.get(":id", "system-notifications-v2") { request async throws -> Response in
            var response = try await respond {
                try services.emailAccounts.runtimeUsageAttestations.listSystemAttention(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
            response.headers[HTTPField.Name("Cache-Control")!] = "private, no-store"
            return response
        }
        servers.post(":id", "system-notifications-v2", ":incidentId", "seen") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeUsageAttestations.markSystemAttentionSeen(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    incidentId: request.parameters.get("incidentId") ?? ""
                )
            }
        }
        servers.post(":id", "system-notifications-v2", ":incidentId", "dismiss") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.runtimeUsageAttestations.dismissSystemAttention(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    incidentId: request.parameters.get("incidentId") ?? ""
                )
            }
        }
        servers.post(":id", "machines") { request async throws -> Response in
            let body = try await typedJSONBody(ServerMachineRegistrationRequest.self, request)
            return try await respond {
                try services.emailAccounts.runtimeFormsAndProbes.registerServerMachine(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.get(":id", "machines") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.listServerMachines(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.post(":id", "machines", ":machineId", "rotate-key") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.rotateServerMachineKey(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? ""
                )
            }
        }
        registerServerMachineDelete(on: servers)
        servers.patch(":id", "machines", ":machineId") { request async throws -> Response in
            let body = await jsonRequestBody(MachineDescriptionRequest.self, request) ?? MachineDescriptionRequest()
            return try await respond {
                try services.emailAccounts.computersFleet.patchServerMachine(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? "",
                    request: body
                )
            }
        }
        servers.patch(":id") { request async throws -> Response in
            let body = await jsonRequestBody(ServerProfilePatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.patchServerProfile(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    body: body
                )
            }
        }
        servers.get(":id") { request -> Response in
            routeResponse(services.emailAccounts.serverDetails(
                authorization: request.headers[.authorization],
                serverId: request.parameters.get("id") ?? ""
            ))
        }
        servers.get(":id", "members", ":memberId", "profile") { request async throws -> Response in
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
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.memberProfile(
                    authorization: request.headers[.authorization],
                    serverId: id,
                    memberId: memberId
                )
            }
        }
        servers.get(":id", "apps") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverProfileAndOrder.serverApps(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? ""
                )
            }
        }
        servers.get(":id", "member-graph") { request async throws -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.serverMemberGraph(
                    authorization: request.headers[.authorization],
                    serverId: id
                )
            }
        }
        servers.get(":id", "members") { request async throws -> Response in
            let id = request.parameters.get("id") ?? ""
            if let reply = ServerScope.membersGuard(
                serverId: id,
                headerServerId: request.headers[HTTPField.Name("X-Server-Id")!]
            ) {
                return routeResponse(reply)
            }
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.serverMembersList(
                    authorization: request.headers[.authorization],
                    serverId: id
                )
            }
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
        servers.delete(":id", "machines", ":machineId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.deleteServerMachine(
                    authorization: request.headers[.authorization],
                    serverId: request.parameters.get("id") ?? "",
                    machineId: request.parameters.get("machineId") ?? ""
                )
            }
        }
    }
}

// MARK: - Helpers lifted from FallbackApplication.swift

private func applyRuntimeFormLanguage(_ response: inout Response, language: String?) {
    let zh = language?.lowercased().hasPrefix("zh") == true
    response.headers[HTTPField.Name("Content-Language")!] = zh ? "zh-CN" : "en"
    response.headers[HTTPField.Name("Vary")!] = "Accept-Language"
}
