import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/internal/agent/...`, `/internal/computer/...` and `/internal/machine/...`
/// routes extracted from `FallbackApplication.configure`.
///
/// 48 static `app.<verb>(...)` registrations are copied verbatim from the
/// inline block: 28 agent, 19 computer and 1 machine. Method, path,
/// async/throws signature, request projection, helper call and `routeResponse`
/// handling are unchanged.
///
/// The two policy catch-alls stay in `configure`:
/// - `app.on(method, "internal", "computer", "**")` — five methods;
/// - `app.on(method, "internal", "agent", "**")` — five methods, registered in
///   the same loop as the `internal/agent-api/**` catch-all owned by
///   `InternalAgentApiFeature`, so the shared loop remains in the composition
///   root until the integration slice.
///
/// The collection is not mounted from `configure` yet; the integration slice
/// removes the inline registrations and mounts it. `internalSurface` is shared
/// with the composition root through the internal initializer so
/// `/internal/computer/preflight` keeps reporting the post-registration
/// snapshot.
public struct InternalAdminFeature: RouteCollection, Sendable {
    public let services: FallbackServices
    private let internalSurface: InternalSurfaceBox

    public init(services: FallbackServices) {
        self.init(services: services, internalSurface: InternalSurfaceBox())
    }

    /// Integration hook: `configure` owns the surface box it fills after every
    /// route is registered; passing it keeps preflight identical to the inline
    /// registration.
    init(services: FallbackServices, internalSurface: InternalSurfaceBox) {
        self.services = services
        self.internalSurface = internalSurface
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    /// Synchronous mount for `configure`, whose call sites are not `async`.
    public func register(routes: any RoutesBuilder) {
        let app = routes
        let agent = app.grouped("internal", "agent", ":agentId")
        let computer = app.grouped("internal", "computer")
        let machine = app.grouped("internal", "machine")

        agent.get("reminders") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.legacyReminderList(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    status: desktopQuery(request.url.query, "status")
                )
            }
        }
        agent.post("reminders") { request async throws -> Response in
            let agentId = request.parameters.get("agentId") ?? ""
            let body = await jsonRequestBody(ReminderCreateRequest.self, request, emptyDefault: "{}")
            let hub = services.realtime
            return try await respond {
                let completion = try services.emailAccounts.managedMCPAgentCatalog.legacyReminderCreate(
                    authorization: request.headers[.authorization],
                    agentId: agentId,
                    body: body,
                    delivery: hub == nil ? .omit : .prepare
                )
                if let hub, let delivery = completion.scheduledDelivery {
                    let payload = delivery.payload.jsonBody.render()
                    for userId in delivery.recipientUserIds {
                        hub.emit(room: "user:\(userId)", event: ReminderScheduledDelivery.eventName, payloadJSON: payload)
                    }
                }
                return completion.response
            }
        }
        agent.delete("reminders", ":reminderId") { request async throws -> Response in
            let body = await jsonRequestBody(ReminderCancelRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.legacyReminderCancel(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    reminderId: request.parameters.get("reminderId") ?? "",
                    body: body
                )
            }
        }
        agent.post("reminders", ":reminderId", "snooze") { request async throws -> Response in
            let body = await jsonRequestBody(ReminderSnoozeRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.legacyReminderSnooze(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    reminderId: request.parameters.get("reminderId") ?? "",
                    body: body
                )
            }
        }
        agent.patch("reminders", ":reminderId") { request async throws -> Response in
            let body = await jsonRequestBody(ReminderUpdateRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.legacyReminderUpdate(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    reminderId: request.parameters.get("reminderId") ?? "",
                    body: body
                )
            }
        }
        agent.get("reminders", ":reminderId", "log") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.legacyReminderLog(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    reminderId: request.parameters.get("reminderId") ?? ""
                )
            }
        }
        agent.post("send") { request async throws -> Response in
            let body = await jsonRequestBody(AgentSendRequest.self, request)
            return try await respond {
                try services.emailAccounts.agentSendDelivery.agentSend(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    body: body
                )
            }
        }
        agent.post("receive-ack") { request async throws -> Response in
            let body = await jsonRequestBody(AgentReceiveAckRequest.self, request)
            return try await respond {
                try services.emailAccounts.agentSendDelivery.legacyAgentReceiveAck(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    body: body
                )
            }
        }
        agent.post("runtime-profile", "migration-done") { request async throws -> Response in
            let body = await jsonRequestBody(AgentRuntimeProfileMigrationDTO.self, request)
            return try await respond {
                try services.emailAccounts.agentSendDelivery.runtimeProfileMigrationDone(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    body: body
                )
            }
        }
        agent.get("server") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentChannels.serverInfo(
                    authorization: request.headers[.authorization],
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.patch("server") { request async throws -> Response in
            let body = await jsonRequestBody(AgentServerUpdateRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.updateServer(
                    authorization: request.headers[.authorization],
                    body: body,
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.post("channels") { request async throws -> Response in
            let body = await jsonRequestBody(AgentCreateChannelRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.createChannel(
                    authorization: request.headers[.authorization],
                    body: body,
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.patch("channels", ":channelId") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelUpdateRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.updateChannel(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body,
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.post("channels", ":channelId", "members") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelMemberRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.writeChannelMember(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body,
                    remove: false,
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.delete("channels", ":channelId", "members") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelMemberRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.writeChannelMember(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body,
                    remove: true,
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.post("channels", ":channelId", "join") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHistory.agentChannelMembershipFromMachine(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    join: true
                )
            }
        }
        agent.post("channels", ":channelId", "leave") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHistory.agentChannelMembershipFromMachine(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    join: false
                )
            }
        }
        agent.get("channel-members") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentChannels.channelMembers(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId"),
                    channelRef: desktopQuery(request.url.query, "channel"),
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.get("history") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHistory.history(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId"),
                    channelRef: desktopQuery(request.url.query, "channel"),
                    before: desktopQuery(request.url.query, "before"),
                    after: desktopQuery(request.url.query, "after"),
                    around: desktopQuery(request.url.query, "around"),
                    limit: desktopQuery(request.url.query, "limit"),
                    consume: desktopQuery(request.url.query, "consume")
                )
            }
        }
        agent.post("tasks") { request async throws -> Response in
            // The published handler accepted a raw JSON body, so the typed
            // decode falls back to the collected bytes. The raw text is also
            // what the idempotency fingerprint covers.
            let rawBody = try await request.bodyText()
            let body = try await decodeJSONRequestBody(AgentTaskCreateRequest.self, request, rawFallback: rawBody)
            return try await respond(headers: { $0.headers }) {
                try services.emailAccounts.actionCardMarketplace.createTasks(
                    authorization: request.headers[.authorization],
                    body: body,
                    rawBody: rawBody,
                    legacyAgentId: request.parameters.get("agentId")
                )
            }
        }
        agent.post("tasks", "claim") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskClaimRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentTaskClaim(
                    authorization: request.headers[.authorization],
                    legacyAgentId: request.parameters.get("agentId"),
                    body: body
                )
            }
        }
        agent.post("tasks", "update-status") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskStatusUpdateRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentTaskUpdateStatus(
                    authorization: request.headers[.authorization],
                    legacyAgentId: request.parameters.get("agentId"),
                    body: body
                )
            }
        }
        agent.post("tasks", "delete") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskDeleteRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.deleteTask(
                    authorization: request.headers[.authorization],
                    body: body,
                    legacyAgentId: request.parameters.get("agentId")
                )
            }
        }
        agent.post("tasks", "convert") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskConvertRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.convertTask(
                    authorization: request.headers[.authorization],
                    body: body,
                    legacyAgentId: request.parameters.get("agentId")
                )
            }
        }
        agent.post("messages", ":messageId", "reactions") { request async throws -> Response in
            let body = await jsonRequestBody(ProfileReactionRequestDTO.self, request)
            return try await respond {
                try services.emailAccounts.profileAndChannelFiles.mutateAgentMessageReaction(
                    agentId: request.parameters.get("agentId") ?? "",
                    messageId: request.parameters.get("messageId") ?? "",
                    emoji: body?.emoji,
                    authorization: request.headers[.authorization],
                    remove: false
                )
            }
        }
        agent.delete("messages", ":messageId", "reactions") { request async throws -> Response in
            let body = await jsonRequestBody(ProfileReactionRequestDTO.self, request)
            return try await respond {
                try services.emailAccounts.profileAndChannelFiles.mutateAgentMessageReaction(
                    agentId: request.parameters.get("agentId") ?? "",
                    messageId: request.parameters.get("messageId") ?? "",
                    emoji: body?.emoji,
                    authorization: request.headers[.authorization],
                    remove: true
                )
            }
        }
        agent.post("threads", "unfollow") { request async throws -> Response in
            let body = await jsonRequestBody(AgentThreadUnfollowRequest.self, request)
            return try await respond {
                try services.emailAccounts.agentSendDelivery.agentThreadUnfollow(
                    authorization: request.headers[.authorization],
                    body: body,
                    legacyAgentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        agent.get("search") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.searchMentions.searchAgentMessages(
                    agentId: request.parameters.get("agentId") ?? "",
                    query: desktopQuery(request.url.query, "q"),
                    limit: desktopQuery(request.url.query, "limit"),
                    authorization: request.headers[.authorization],
                    sender: desktopQuery(request.url.query, "sender"),
                    after: desktopQuery(request.url.query, "after"),
                    before: desktopQuery(request.url.query, "before"),
                    sort: desktopQuery(request.url.query, "sort")
                )
            }
        }
        computer.post("preflight") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.computerPreflight(
                    authorization: request.headers[.authorization],
                    surface: internalSurface.value
                )
            }
        }
        agent.post("upload") { request async throws -> Response in
            try await respond {
                let parsed = try await AttachmentMultipartDecoder.decode(request)
                guard let file = parsed.files.first else { throw AttachmentContentError.noFiles }
                return try await services.emailAccounts.agentsLifecycle.uploadMachineAttachmentContent(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    channelId: parsed.channelId, file: file
                )
            }
        }
        machine.post("scope-attestation") { request async throws -> Response in
            let body = await jsonRequestBody(MachineScopeAttestationRequest.self, request)
            return try await respond {
                try services.emailAccounts.serverProfileAndOrder.machineScopeAttestation(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        computer.post("attachment", "revoke") { _ -> Response in
            respond(
                status: 401,
                headers: .exact(["Content-Type": "application/json"]),
                rawJSON: OrderedJSON.object([
                    OrderedJSONField("error", "Authentication policy not registered for this path"),
                    OrderedJSONField("code", "auth_policy_unregistered_path"),
                ]).render()
            )
        }
        computer.post("runners", ":agentId", "credentials") { request async throws -> Response in
            let body = await jsonRequestBody(ComputerRunnerCredentialRequest.self, request)
                ?? ComputerRunnerCredentialRequest()
            return try await respond(status: 201) {
                try services.emailAccounts.computersFleet.computerMintRunnerCredential(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    request: body
                )
            }
        }
        computer.delete("runners", ":agentId", "credentials", ":credentialId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.computerRevokeRunnerCredential(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? "",
                    credentialId: request.parameters.get("credentialId") ?? ""
                )
            }
        }
        computer.post("runners", ":agentId", "stop") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.computerStopRunner(
                    authorization: request.headers[.authorization],
                    agentId: request.parameters.get("agentId") ?? ""
                )
            }
        }
        computer.get("runners") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.computerRunners(
                    authorization: request.headers[.authorization],
                    scope: desktopQuery(request.url.query, "scope")
                )
            }
        }
        // The resumable control manifest is the one JSON surface allowed past the
        // 100 KB global parser: 512 KB manifest plus envelope headroom.
        computer.on(.post, "agent-migrations", "by-id", ":migrationId", "resumable", "control", maxBodySize: "640kb") { request async throws -> Response in
            // The route publishes the manifest text exactly as sent, so the
            // service takes the raw body.
            try await respond {
                try services.emailAccounts.agentHostedMigration.putMigrationControlManifest(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    body: try await request.bodyText(default: "{}")
                )
            }
        }
        computer.get("agent-migrations", "by-id", ":migrationId", "resumable", "control") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHostedMigration.getMigrationControlManifest(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? ""
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "resumable", "chunks", ":chunkIndex", "receipt") { request async throws -> Response in
            let body = try await decodeJSONRequestBody(MigrationChunkReceiptRequest.self, request) ?? MigrationChunkReceiptRequest()
            return try await respond {
                try services.emailAccounts.agentHostedMigration.putMigrationChunkReceipt(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    chunkIndex: Int(request.parameters.get("chunkIndex") ?? "") ?? -1,
                    request: body
                )
            }
        }
        computer.get("agent-migrations", "by-id", ":migrationId", "resumable", "chunks") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHostedMigration.migrationChunkStatus(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? ""
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "resumable", "upload-complete") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHostedMigration.completeMigrationUpload(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? ""
                )
            }
        }
        computer.get("agent-migrations", "by-id", ":migrationId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHostedMigration.getMigrationTargetView(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? ""
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "start-transfer") { request async throws -> Response in
            let body = try await decodeJSONRequestBody(MigrationGenerationRequest.self, request) ?? MigrationGenerationRequest()
            return try await respond {
                try services.emailAccounts.agentHostedMigration.startMigrationTransfer(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    request: body
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "flip-machine") { request async throws -> Response in
            let body = try await decodeJSONRequestBody(MigrationGenerationRequest.self, request) ?? MigrationGenerationRequest()
            return try await respond {
                try services.emailAccounts.agentHostedMigration.flipMigrationMachine(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    request: body
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "arrived") { request async throws -> Response in
            let body = try await decodeJSONRequestBody(MigrationArrivalRequest.self, request) ?? MigrationArrivalRequest()
            return try await respond {
                try await services.emailAccounts.agentHostedMigration.completeMigrationArrival(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    request: body
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "transport-lost") { request async throws -> Response in
            let body = try await decodeJSONRequestBody(MigrationTransportLostRequest.self, request) ?? MigrationTransportLostRequest()
            return try await respond {
                try services.emailAccounts.agentHostedMigration.markMigrationTransportLostFromComputer(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    request: body
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "cancel-ack") { request async throws -> Response in
            let body = try await decodeJSONRequestBody(MigrationCancelAckRequest.self, request) ?? MigrationCancelAckRequest()
            return try await respond {
                try services.emailAccounts.agentHostedMigration.acknowledgeMigrationCancellation(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    request: body
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "resumable", "source-quiesced") { request async throws -> Response in
            let body = try await decodeJSONRequestBody(MigrationSourceQuiescedRequest.self, request) ?? MigrationSourceQuiescedRequest()
            return try await respond {
                try services.emailAccounts.agentHostedMigration.recordMigrationSourceQuiesced(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    request: body
                )
            }
        }
        computer.post("agent-migrations", "by-id", ":migrationId", "resumable", "source-progress") { request async throws -> Response in
            // The progress body is stored as sent, so the service takes the raw text.
            try await respond {
                try services.emailAccounts.agentHostedMigration.recordMigrationSourceProgress(
                    authorization: request.headers[.authorization],
                    migrationRef: request.parameters.get("migrationId") ?? "",
                    body: try await request.bodyText(default: "{}")
                )
            }
        }
    }


}
