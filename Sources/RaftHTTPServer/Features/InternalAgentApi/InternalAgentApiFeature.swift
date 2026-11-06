import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Internal agent-principal route surface extracted from
/// `FallbackApplication.configure`.
///
/// Every registration below is copied verbatim from the inline `configure`
/// block: same method, path, async/throws signature, request projection,
/// helper call and `routeResponse` handling. All 75 registrations are the
/// static `app.<verb>("internal", "agent-api", ...)` pairs; the five-method
/// `app.on(method, "internal", "agent-api", "**")` policy catch-all stays in
/// `configure` because it is registered in a shared loop with the
/// `internal/agent/**` prefix and mounts the fail-closed surface handler.
///
/// The reminder/multipart/query helpers were file-private in
/// `FallbackApplication.swift`; they are kept file-private here so the feature
/// is self-contained, matching the `PublicFeature` pattern. The collection is
/// not mounted from `configure` yet; the integration slice decides when it
/// replaces the inline registrations.
public struct InternalAgentApiFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    /// Decodes one typed JSON body even when the client omitted a JSON
    /// `Content-Type`; the published handler accepted a raw JSON body before
    /// the typed migration.
    private func typedJSONBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
        if let decoded = try? await request.content.decode(type) { return decoded }
        guard let data = try await request.body.collect() else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let app = routes
        let agentApi = app.grouped("internal", "agent-api")

        agentApi.delete("reminders", ":reminderId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderCancel(
                    authorization: request.headers[.authorization],
                    reminderId: request.parameters.get("reminderId") ?? ""
                )
            }
        }
        agentApi.post("reminders", ":reminderId", "snooze") { request async throws -> Response in
            let body = await jsonRequestBody(ReminderSnoozeRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderSnooze(
                    authorization: request.headers[.authorization],
                    reminderId: request.parameters.get("reminderId") ?? "",
                    body: body
                )
            }
        }
        agentApi.patch("reminders", ":reminderId") { request async throws -> Response in
            let body = await jsonRequestBody(ReminderUpdateRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderUpdate(
                    authorization: request.headers[.authorization],
                    reminderId: request.parameters.get("reminderId") ?? "",
                    body: body
                )
            }
        }
        agentApi.get("reminders", ":reminderId", "log") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderLog(
                    authorization: request.headers[.authorization],
                    reminderId: request.parameters.get("reminderId") ?? ""
                )
            }
        }
        agentApi.get("reminders") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderList(
                    authorization: request.headers[.authorization],
                    status: desktopQuery(request.url.query, "status")
                )
            }
        }
        agentApi.post("reminders") { request async throws -> Response in
            let body = await jsonRequestBody(ReminderCreateRequest.self, request, emptyDefault: "{}")
            return try await respond {
                let created = try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderCreate(
                    authorization: request.headers[.authorization],
                    body: body
                )
                publishReminderEvent(
                    event: "reminder:scheduled", reminderId: created.reminder.id,
                    agentId: created.ownerAgentId, services: services
                )
                return created
            }
        }
        agentApi.get("users", "info") { request async throws -> Response in
            var name = ""
            var limit: String?
            var offset: String?
            if let components = URLComponents(string: "http://internal/?\(request.url.query ?? "")") {
                name = components.queryItems?.first { $0.name == "name" || $0.name == "user" }?.value ?? ""
                limit = components.queryItems?.first { $0.name == "limit" }?.value
                offset = components.queryItems?.first { $0.name == "offset" }?.value
            }
            return try await respond(headers: { $0.headers }) {
                try services.emailAccounts.managedMCPOAuth.agentUserInfo(
                    authorization: request.headers[.authorization],
                    name: name,
                    limit: limit,
                    offset: offset
                )
            }
        }
        agentApi.get("users", ":name", "channels") { request async throws -> Response in
            let name = request.parameters.get("name") ?? ""
            var limit: String?
            var offset: String?
            if let components = URLComponents(string: "http://internal/?\(request.url.query ?? "")") {
                limit = components.queryItems?.first { $0.name == "limit" }?.value
                offset = components.queryItems?.first { $0.name == "offset" }?.value
            }
            return try await respond {
                try services.emailAccounts.managedMCPOAuth.agentUserChannels(
                    authorization: request.headers[.authorization],
                    name: name,
                    limit: limit,
                    offset: offset
                )
            }
        }
        agentApi.get() { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.agentApiIdentity(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.get("profile") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.joinLinksAndInvites.agentProfileShow(
                    authorization: request.headers[.authorization],
                    target: desktopQuery(request.url.query, "target")
                )
            }
        }
        agentApi.post("profile") { request async throws -> Response in
            let body = try await typedJSONBody(AgentProfileUpdateRequest.self, request)
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.updateAgentProfile(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("channels", ":channelId", "leave") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.channelAssignments().agentLeaveChannel(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }
        agentApi.patch("server") { request async throws -> Response in
            let body = await jsonRequestBody(AgentServerUpdateRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.updateServer(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.patch("channels", ":channelId") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelUpdateRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.updateChannel(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }
        agentApi.post("channels", "archive") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelArchiveRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.managedMCPToolExecution.agentChannelArchive(
                    authorization: request.headers[.authorization],
                    body: body,
                    archive: true
                )
            }
        }
        agentApi.post("channels", "unarchive") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelArchiveRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.managedMCPToolExecution.agentChannelArchive(
                    authorization: request.headers[.authorization],
                    body: body,
                    archive: false
                )
            }
        }
        agentApi.post("channels", ":channelId", "mute") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPToolExecution.agentSetChannelMute(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    muted: true
                )
            }
        }
        agentApi.post("channels", ":channelId", "unmute") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPToolExecution.agentSetChannelMute(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    muted: false
                )
            }
        }
        agentApi.post("channels", ":channelId", "members") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelMemberRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.writeChannelMember(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body,
                    remove: false
                )
            }
        }
        agentApi.delete("channels", ":channelId", "members") { request async throws -> Response in
            let body = await jsonRequestBody(AgentChannelMemberRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.writeChannelMember(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body,
                    remove: true
                )
            }
        }
        agentApi.get("channel-members") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentChannels.channelMembers(
                    authorization: request.headers[.authorization],
                    agentId: nil,
                    channelRef: desktopQuery(request.url.query, "channel")
                )
            }
        }
        agentApi.get("server") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentChannels.serverInfo(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.post("resolve-channel") { request async throws -> Response in
            let body = await jsonRequestBody(AgentResolveChannelRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.resolveChannel(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("channels") { request async throws -> Response in
            let body = await jsonRequestBody(AgentCreateChannelRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.createChannel(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("attachment-upload-capabilities") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.agentAttachmentUploadCapabilities(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.get("history") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentHistory.history(
                    authorization: request.headers[.authorization],
                    channelRef: desktopQuery(request.url.query, "channel"),
                    before: desktopQuery(request.url.query, "before"),
                    after: desktopQuery(request.url.query, "after"),
                    around: desktopQuery(request.url.query, "around"),
                    limit: desktopQuery(request.url.query, "limit"),
                    consume: desktopQuery(request.url.query, "consume"),
                    unread: desktopQuery(request.url.query, "unread") == "true"
                )
            }
        }
        agentApi.get("assistant", "owner-inbox") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.agentAssistantOwnerInbox(
                    authorization: request.headers[.authorization],
                    rawQuery: request.url.query
                )
            }
        }
        agentApi.get("assistant", "owner-messages") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.agentAssistantOwnerMessages(
                    authorization: request.headers[.authorization],
                    channelId: desktopQuery(request.url.query, "channelId") ?? ""
                )
            }
        }
        agentApi.get("inbox", "conversations") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCardMarketplace.inboxConversations(
                    authorization: request.headers[.authorization],
                    limit: desktopQuery(request.url.query, "limit"),
                    beforeSeq: desktopQuery(request.url.query, "before_seq"),
                    view: desktopQuery(request.url.query, "view")
                )
            }
        }
        agentApi.get("attachments", ":attachmentId", "comments") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.attachmentComments.agentAttachmentCommentsList(
                    authorization: request.headers[.authorization],
                    attachmentId: request.parameters.get("attachmentId") ?? ""
                )
            }
        }
        agentApi.post("attachments", ":attachmentId", "comments") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.attachmentComments.agentAttachmentCommentCreate(
                    authorization: request.headers[.authorization],
                    attachmentId: request.parameters.get("attachmentId") ?? ""
                )
            }
        }
        agentApi.get("attachments", ":attachmentId") { request async throws -> Response in
            // The refusal projects through `respond`. The byte reply is the one
            // shape `respond` cannot express: `Content-Length` is the stored
            // byte count while the body is the lossily decoded text, and the
            // `Content-Type` is the attachment's own.
            var stored: AgentAttachmentDownload?
            let refusal = try await respond { () throws -> OkResponse in
                stored = try services.emailAccounts.agentAttachments.download(
                    authorization: request.headers[.authorization],
                    attachmentId: request.parameters.get("attachmentId") ?? ""
                )
                return OkResponse()
            }
            guard let stored else { return refusal }
            return routeResponse(HTTPReply(
                status: 200,
                headers: [
                    "Content-Type": stored.mimeType,
                    "Content-Length": String(stored.bytes.count),
                    "Cache-Control": "private, no-store",
                    "Content-Disposition": "attachment; filename=\"\(stored.filename)\"; filename*=UTF-8''\(stored.encodedFilename)",
                ],
                body: String(decoding: stored.bytes, as: UTF8.self)
            ))
        }
        agentApi.get("attachments", ":attachmentId", "url") { request async throws -> Response in
            try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
                try services.emailAccounts.agentAttachments.downloadURL(
                    authorization: request.headers[.authorization],
                    attachmentId: request.parameters.get("attachmentId") ?? ""
                )
            }
        }
        agentApi.get("integrations") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSendDelivery.agentIntegrationList(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.get("integrations", "app") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppList(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.post("integrations", "app", "prepare") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationAppPrepareRequest.self, request)
            return try await respond(status: 201) {
                try services.emailAccounts.actionCardIntegrationRegister.agentIntegrationAppPrepare(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("integrations", "app", "update") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppUpdate(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("integrations", "app", "status") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppStatus(
                    authorization: request.headers[.authorization],
                    client: desktopQuery(request.url.query, "client"),
                    card: desktopQuery(request.url.query, "card")
                )
            }
        }
        agentApi.get("integrations", "marketplace") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationMarketplace(
                    authorization: request.headers[.authorization],
                    query: desktopQuery(request.url.query, "query"),
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        agentApi.post("integrations", "login") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationLogin(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("integrations", "token") { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond(headers: .standard(extra: ["Cache-Control": "no-store"])) {
                try services.emailAccounts.agentIntegrationTokens.issue(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("context") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCardPrepare.agentContext(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.get("apps", ":appId", "config") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCardPrepare.agentAppConfig(
                    authorization: request.headers[.authorization],
                    appId: request.parameters.get("appId") ?? ""
                )
            }
        }
        agentApi.patch("apps", ":appId", "config") { request async throws -> Response in
            // A body that does not decode stays `nil`: the service authorizes
            // before answering the legacy `Invalid config request` 400.
            let body = try await typedJSONBody(AgentAppConfigPatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardPrepare.patchAgentAppConfig(
                    authorization: request.headers[.authorization],
                    appId: request.parameters.get("appId") ?? "",
                    body: body
                )
            }
        }
        agentApi.post("send") { request async throws -> Response in
            // A body that does not decode stays `nil`: the service authorizes
            // before answering the legacy `Invalid send request` 400.
            let body = await jsonRequestBody(AgentSendMessageRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentSendMessage(
                    authorization: request.headers[.authorization],
                    body: body,
                    v2: false
                )
            }
        }
        agentApi.post("v2", "send") { request async throws -> Response in
            let body = await jsonRequestBody(AgentSendMessageRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentSendMessage(
                    authorization: request.headers[.authorization],
                    body: body,
                    v2: true
                )
            }
        }
        agentApi.get("tasks") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCardExecute.agentTasksList(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    channelRef: desktopQuery(request.url.query, "channel")
                )
            }
        }
        agentApi.post("tasks") { request async throws -> Response in
            // The published handler accepted a raw JSON body, so the typed
            // decode falls back to the collected bytes. The raw text is also
            // what the idempotency fingerprint covers.
            let rawBody = try await request.bodyText()
            let body = (try? await request.content.decode(AgentTaskCreateRequest.self))
                ?? (try? JSONDecoder().decode(AgentTaskCreateRequest.self, from: Data(rawBody.utf8)))
            return try await respond(headers: { $0.headers }) {
                try services.emailAccounts.actionCardMarketplace.createTasks(
                    authorization: request.headers[.authorization],
                    body: body,
                    rawBody: rawBody
                )
            }
        }
        agentApi.post("tasks", "resource-receipt") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskResourceReceiptRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.resourceReceipt(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("tasks", "assign") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskAssignRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.assignTask(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("tasks", "amend") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskAmendRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.tasksAndLabs.amendTask(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    body: body
                )
            }
        }
        agentApi.post("tasks", "claim") { request async throws -> Response in
            // `channel`, `task_numbers`, `message_ids` and `seenUpToSeq` are the
            // only body fields; the request type keeps the legacy per-field
            // leniency. A missing or non-object body stays `nil`, so the
            // service authorizes first and then publishes the legacy 400.
            let body = await jsonRequestBody(AgentTaskClaimRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentTaskClaim(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    body: body
                )
            }
        }
        agentApi.post("tasks", "update-status") { request async throws -> Response in
            // `channel`, `task_number`, `status` and `seenUpToSeq` are the only
            // body fields; the service owns the status allow-list and the
            // legacy 400 when no status arrives.
            let body = await jsonRequestBody(AgentTaskStatusUpdateRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentTaskUpdateStatus(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    body: body
                )
            }
        }
        agentApi.post("tasks", "delete") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskDeleteRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.deleteTask(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("tasks", "convert") { request async throws -> Response in
            let body = await jsonRequestBody(AgentTaskConvertRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.convertTask(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("channels", ":channelId", "join") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.channelMembership.agentJoinChannel(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }
        agentApi.post("messages", ":messageId", "reactions") { request async throws -> Response in
            let body = await jsonRequestBody(ProfileReactionRequestDTO.self, request)
            return try await respond {
                try services.emailAccounts.profileAndChannelFiles.mutateAgentApiMessageReaction(
                    messageId: request.parameters.get("messageId") ?? "",
                    emoji: body?.emoji,
                    authorization: request.headers[.authorization],
                    remove: false
                )
            }
        }
        agentApi.delete("messages", ":messageId", "reactions") { request async throws -> Response in
            let body = await jsonRequestBody(ProfileReactionRequestDTO.self, request)
            return try await respond {
                try services.emailAccounts.profileAndChannelFiles.mutateAgentApiMessageReaction(
                    messageId: request.parameters.get("messageId") ?? "",
                    emoji: body?.emoji,
                    authorization: request.headers[.authorization],
                    remove: true
                )
            }
        }
        agentApi.post("activity") { request async throws -> Response in
            let body = await jsonRequestBody(AgentActivityIngestRequest.self, request)
            return try await respond {
                try services.emailAccounts.agentSendDelivery.agentActivityIngest(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("threads") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSendDelivery.agentThreadList(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.post("threads", "unfollow") { request async throws -> Response in
            let body = await jsonRequestBody(AgentThreadUnfollowRequest.self, request)
            return try await respond {
                try services.emailAccounts.agentSendDelivery.agentThreadUnfollow(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("messages", ":messageId", "mention-deliveries") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMessageLookup.agentMentionDeliveries(
                    authorization: request.headers[.authorization],
                    messageRef: request.parameters.get("messageId") ?? ""
                )
            }
        }
        agentApi.get("messages", ":messageId", "resolve") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentMessageLookup.agentMessageResolve(
                    authorization: request.headers[.authorization],
                    messageRef: request.parameters.get("messageId") ?? ""
                )
            }
        }
        agentApi.get("search") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.searchMentions.agentApiSearch(
                    authorization: request.headers[.authorization],
                    query: desktopQuery(request.url.query, "q"),
                    channelRef: desktopQuery(request.url.query, "channel"),
                    senderRef: desktopQuery(request.url.query, "sender"),
                    sort: desktopQuery(request.url.query, "sort"),
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        agentApi.get("mentions") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.reactionsRealtime.agentMentionInbox(
                    authorization: request.headers[.authorization],
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        agentApi.post("prepare-action") { request async throws -> Response in
            let body = await jsonRequestBody(ActionCardPrepareRequest.self, request)
            return try await respond(
                status: 201,
                headers: { result in
                    result.isIdempotentReplay
                        ? .exact([
                            "Content-Type": AppFallback.jsonContentType,
                            "Cache-Control": "no-store",
                        ])
                        : .standard()
                }
            ) {
                try services.emailAccounts.actionCardIntegrationRegister.prepareActionCard(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("mcp", "tools") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.actionCards.managedMCPToolSnapshot(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.post("mcp", "call") { request async throws -> Response in
            let body = (try? await request.content.decode(ManagedMCPToolCallRequest.self))
                ?? ManagedMCPToolCallRequest()
            return try await respond {
                try services.emailAccounts.actionCards.callManagedMCPTool(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("feedback-locators") { request async throws -> Response in
            let body = await feedbackLocatorEnvelope(request)
            return try await respond {
                try services.emailAccounts.feedbackLocators.ingest(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("feedback-locators") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.feedbackLocators.list(
                    authorization: request.headers[.authorization],
                    reportId: desktopQuery(request.url.query, "report_id"),
                    runtime: desktopQuery(request.url.query, "runtime"),
                    nativeStatus: desktopQuery(request.url.query, "native_status"),
                    nativeLookupMethod: desktopQuery(request.url.query, "native_lookup_method"),
                    servedExactSha256: desktopQuery(request.url.query, "served_exact_sha256"),
                    routeBasis: desktopQuery(request.url.query, "route_basis"),
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        agentApi.get("wake-hints") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.reactionsRealtime.agentWakeHints(
                    authorization: request.headers[.authorization],
                    since: desktopQuery(request.url.query, "since"),
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        agentApi.get("wake-hints", "stream") { request async throws -> Response in
            // The refusal projects through `respond`; the open stream is the one
            // reply `respond` cannot express (a chunked SSE body).
            var started: AgentWakeStreamStart?
            let refusal = try await respond { () throws -> OkResponse in
                started = try services.emailAccounts.agentSurface.beginAgentWakeHintsStream(
                    authorization: request.headers[.authorization],
                    since: request.headers[HTTPField.Name("Last-Event-ID")!] ?? desktopQuery(request.url.query, "since")
                )
                return OkResponse()
            }
            guard let started else { return refusal }
            let token = started.token
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-cache, no-transform"
            headers[HTTPField.Name("X-Accel-Buffering")!] = "no"
            let pollMs = services.nodeEnv == "test" ? 50 : 1_000
            // Tests bound the loop so a streaming task cannot outlive the suite.
            let boundedTicks = services.nodeEnv == "test" ? 200 : Int.max
            var response = Response(status: .ok, headers: headers)
            response.body = Response.Body { writer in
                try await writer.write(started.firstFrame)
                var cursor = started.cursorSeq
                var ticks = 0
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
                    services.emailAccounts.agentSurface.recordAgentCredentialUse(token: token)
                    guard let batch = services.emailAccounts.agentSurface.agentWakeStreamBatch(token: token, after: cursor) else { return }
                    if batch.frames.isEmpty {
                        try await writer.write(": heartbeat\n\n")
                    } else {
                        try await writer.write(batch.frames)
                        cursor = batch.cursorSeq
                    }
                    ticks += 1
                    if ticks >= boundedTicks { return }
                }
            }
            return response
        }
        agentApi.get("mention-actions", "pending") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.humanMessageCreate.agentMentionActionsPending(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.post("mention-actions", "execute") { request async throws -> Response in
            let body = await jsonRequestBody(MentionActionsRequest.self, request)
            return try await respond {
                try services.emailAccounts.humanMessageCreate.agentMentionActionsExecute(
                    authorization: request.headers[.authorization],
                    body
                )
            }
        }
        agentApi.get("events") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.reactionsRealtime.agentThirdPartyEvents(
                    authorization: request.headers[.authorization]
                )
            }
        }
        agentApi.post("third-party-events", "delivered") { request async throws -> Response in
            let body = await jsonRequestBody(ThirdPartyEventDeliveryRequestDTO.self, request)
            return try await respond {
                try services.emailAccounts.profileAndChannelFiles.reportThirdPartyEventsDelivered(
                    authorization: request.headers[.authorization],
                    eventIds: body?.eventIds
                )
            }
        }
        agentApi.put("push-webhook") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentSurface.putAgentPushWebhook(
                    authorization: request.headers[.authorization],
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            }
        }
        agentApi.post("upload") { request async throws -> Response in
            guard let contentType = request.headers[.contentType],
                  let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                  !boundary.isEmpty
            else {
                return respond(status: 400, headers: .exact([:]), rawJSON: "{\"error\":\"Invalid multipart upload\"}")
            }
            let buffer = try await request.body.collect(max: .specified(ByteCount(value: 300 * 1024 * 1024)))
            guard let buffer,
                  let parsed = parseAttachmentMultipart(data: buffer, boundary: boundary),
                  let file = parsed.files.first
            else {
                return respond(status: 400, headers: .exact([:]), rawJSON: "{\"error\":\"Invalid multipart upload\"}")
            }
            return try await respond {
                try services.emailAccounts.agentsLifecycle.uploadAgentAttachmentIdless(
                    authorization: request.headers[.authorization],
                    channelId: parsed.channelId,
                    filename: file.filename,
                    mimeType: file.mimeType,
                    sizeBytes: file.sizeBytes,
                    bytes: file.data
                )
            }
        }
    }
}

// MARK: - File-private helpers copied verbatim from `FallbackApplication.swift`

private struct MultipartPart {
    var name: String?
    var filename: String?
    var mimeType: String?
    var data: Data
}

private func multipartParts(data: Data, boundary: String) -> [MultipartPart] {
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
    var parts: [MultipartPart] = []
    for chunk in chunks {
        var part = chunk
        if part.starts(with: Data("\r\n".utf8)) { part = part.dropFirst(2) }
        if part.starts(with: Data("--".utf8)) { continue }
        guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let headerData = part[part.startIndex..<headerEnd.lowerBound]
        let body = part[headerEnd.upperBound..<part.endIndex]
        let headers = String(decoding: headerData, as: UTF8.self)
        var name: String?
        var filename: String?
        var mimeType: String?
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") {
                for component in line.components(separatedBy: ";") {
                    let trimmed = component.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name=") {
                        name = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    } else if trimmed.hasPrefix("filename=") {
                        filename = trimmed.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
            } else if lower.hasPrefix("content-type:") {
                mimeType = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        parts.append(MultipartPart(name: name, filename: filename, mimeType: mimeType, data: Data(body)))
    }
    return parts
}

private func parseAttachmentMultipart(data: Data, boundary: String) -> (channelId: String, files: [(filename: String, mimeType: String?, sizeBytes: Int, data: Data)])? {
    var channelId: String?
    var files: [(filename: String, mimeType: String?, sizeBytes: Int, data: Data)] = []
    for part in multipartParts(data: data, boundary: boundary) {
        if part.name == "channelId" {
            channelId = String(decoding: part.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let filename = part.filename, !filename.isEmpty {
            files.append((filename: filename, mimeType: part.mimeType, sizeBytes: part.data.count, data: part.data))
        }
    }
    guard let channelId, !channelId.isEmpty else { return nil }
    return (channelId, files)
}

private func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(text.dropFirst().dropLast())
}

private func publishReminderEvent(
    event: String, reminderId: String, agentId: String, services: FallbackServices
) {
    guard let hub = services.realtime,
          let agent = services.emailAccounts.oauth.agentRuntimeInfo(id: agentId)
    else { return }
    var recipients: Set<String> = []
    if let creator = agent.creatorUserId { recipients.insert(creator) }
    for member in services.emailAccounts.oauth.memberRoles(serverId: agent.serverId)
    where member.role == "owner" || member.role == "admin" {
        recipients.insert(member.userId)
    }
    guard !recipients.isEmpty else { return }
    let payload = "{\"reminderId\":\(jsonString(reminderId)),\"ownerAgentId\":\(jsonString(agentId))}"
    for userId in recipients {
        hub.emit(room: "user:\(userId)", event: event, payloadJSON: payload)
    }
}

/// Decodes one typed JSON body even when the client omitted a JSON
/// `Content-Type`. The published handler accepted a raw JSON body before the
/// typed migration, so the fallback keeps that behavior.
private func typedJSONBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
    if let decoded = try? await request.content.decode(type) { return decoded }
    guard let data = try? await request.body.collect() else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

/// `POST /internal/agent-api/feedback-locators` accepted a JSON body with or
/// without a `Content-Type` header, so the typed decode runs first and a
/// header-less body falls back to the raw bytes. A body that is not a JSON
/// object stays `nil`, which the service answers with the published
/// `invalid_payload`.
private func feedbackLocatorEnvelope(_ request: Request) async -> FeedbackLocatorIngestRequest? {
    if let typed = try? await request.content.decode(FeedbackLocatorIngestRequest.self) {
        return typed
    }
    guard let raw = try? await request.bodyText() else { return nil }
    return try? JSONDecoder().decode(FeedbackLocatorIngestRequest.self, from: Data(raw.utf8))
}
