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


    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let app = routes
        let agentApi = app.grouped("internal", "agent-api")

        agentApi.delete("reminders", ":reminderId") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.reminderCancel, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderCancel(
                    authorization: request.headers[.authorization],
                    reminderId: request.parameters.get("reminderId") ?? ""
                )
            }
        }
        agentApi.post("reminders", ":reminderId", "snooze") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.reminderSnooze, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.reminderUpdate, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.reminderLog, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderLog(
                    authorization: request.headers[.authorization],
                    reminderId: request.parameters.get("reminderId") ?? ""
                )
            }
        }
        agentApi.get("reminders") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.reminderList, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderList(
                    authorization: request.headers[.authorization],
                    status: desktopQuery(request.url.query, "status")
                )
            }
        }
        agentApi.post("reminders") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.reminderCreate, request, services: services) { return refusal }
            let body = await jsonRequestBody(ReminderCreateRequest.self, request, emptyDefault: "{}")
            let hub = services.realtime
            return try await respond {
                let completion = try services.emailAccounts.managedMCPAgentCatalog.agentApiReminderCreate(
                    authorization: request.headers[.authorization],
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
            if let refusal = try await agentApiContractRefusal(.userChannels, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.profileShow, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.agentProfileShow(
                    authorization: request.headers[.authorization],
                    target: desktopQuery(request.url.query, "target")
                )
            }
        }
        agentApi.post("profile") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.profileUpdate, request, services: services) { return refusal }
            let body = try await decodeJSONRequestBody(AgentProfileUpdateRequest.self, request)
            return try await respond {
                try services.emailAccounts.joinLinksAndInvites.updateAgentProfile(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("channels", ":channelId", "leave") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.channelLeave, request, services: services) { return refusal }
            return try await respond {
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
            if let refusal = try await agentApiContractRefusal(.channelUpdate, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.channelArchive, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.channelUnarchive, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.channelMute, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.managedMCPToolExecution.agentSetChannelMute(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    muted: true
                )
            }
        }
        agentApi.post("channels", ":channelId", "unmute") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.channelUnmute, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.managedMCPToolExecution.agentSetChannelMute(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? "",
                    muted: false
                )
            }
        }
        agentApi.post("channels", ":channelId", "members") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.channelMemberAdd, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.channelMemberRemove, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.channelMembers, request, services: services) { return refusal }
            return try await respond {
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
            if let refusal = try await agentApiContractRefusal(.resolveChannel, request, services: services) { return refusal }
            let body = await jsonRequestBody(AgentResolveChannelRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentChannels.resolveChannel(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("channels") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.channelCreate, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.historyRead, request, services: services) { return refusal }
            return try await respond {
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
            if let refusal = try await agentApiContractRefusal(.assistantOwnerInbox, request, services: services) { return refusal }
            return try await respond {
                try services.agentSurface.agentAssistantOwnerInbox(
                    authorization: request.headers[.authorization],
                    rawQuery: request.url.query
                )
            }
        }
        agentApi.get("assistant", "owner-messages") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.assistantOwnerMessages, request, services: services) { return refusal }
            return try await respond {
                try services.agentSurface.agentAssistantOwnerMessages(
                    authorization: request.headers[.authorization],
                    channelId: desktopQuery(request.url.query, "channelId") ?? ""
                )
            }
        }
        agentApi.get("inbox", "conversations") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.inboxList, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.inboxConversations(
                    authorization: request.headers[.authorization],
                    limit: desktopQuery(request.url.query, "limit"),
                    beforeSeq: desktopQuery(request.url.query, "before_seq"),
                    view: desktopQuery(request.url.query, "view")
                )
            }
        }
        agentApi.get("attachments", ":attachmentId", "comments") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.attachmentCommentsList, request, services: services) { return refusal }
            return try await respond {
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
            if let refusal = try await agentApiContractRefusal(.attachmentDownload, request, services: services) { return refusal }
            return try await respond {
                let stored = try await services.emailAccounts.agentAttachments.download(
                    authorization: request.headers[.authorization],
                    attachmentId: request.parameters.get("attachmentId") ?? ""
                )
                return BinaryBodyResponse(bytes: stored.bytes, headers: .exact([
                    "Content-Type": stored.mimeType,
                    "Cache-Control": "private, no-store",
                    "Content-Disposition": "attachment; filename=\"\(stored.filename)\"; filename*=UTF-8''\(stored.encodedFilename)",
                ]))
            }
        }
        agentApi.get("attachments", ":attachmentId", "url") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.attachmentDownloadUrl, request, services: services) { return refusal }
            return try await respond(headers: .standard(extra: ["Cache-Control": "private, no-store"])) {
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
            if let refusal = try await agentApiContractRefusal(.integrationAppPrepare, request, services: services) { return refusal }
            let body = await jsonRequestBody(IntegrationAppPrepareRequest.self, request)
            return try await respond(status: 201) {
                try services.emailAccounts.actionCardIntegrationRegister.agentIntegrationAppPrepare(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("integrations", "app", "update") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.integrationAppUpdate, request, services: services) { return refusal }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppUpdate(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("integrations", "app", "status") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.integrationAppStatus, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationAppStatus(
                    authorization: request.headers[.authorization],
                    client: desktopQuery(request.url.query, "client"),
                    card: desktopQuery(request.url.query, "card")
                )
            }
        }
        agentApi.get("integrations", "marketplace") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.integrationMarketplaceSearch, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationMarketplace(
                    authorization: request.headers[.authorization],
                    query: desktopQuery(request.url.query, "query"),
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        agentApi.post("integrations", "login") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.integrationLogin, request, services: services) { return refusal }
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.agentIntegrationApps.agentIntegrationLogin(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("integrations", "token") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.integrationToken, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.appConfigGet, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.actionCardPrepare.agentAppConfig(
                    authorization: request.headers[.authorization],
                    appId: request.parameters.get("appId") ?? ""
                )
            }
        }
        agentApi.patch("apps", ":appId", "config") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.appConfigPatch, request, services: services) { return refusal }
            // A body that does not decode stays `nil`: the service authorizes
            // before answering the legacy `Invalid config request` 400.
            let body = try await decodeJSONRequestBody(AgentAppConfigPatchRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardPrepare.patchAgentAppConfig(
                    authorization: request.headers[.authorization],
                    appId: request.parameters.get("appId") ?? "",
                    body: body
                )
            }
        }
        agentApi.post("send") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.messageSend, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.messageSendV2, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.taskList, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentTasksList(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    channelRef: desktopQuery(request.url.query, "channel")
                )
            }
        }
        agentApi.post("tasks") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskCreate, request, services: services) { return refusal }
            // The published handler accepted a raw JSON body, so the typed
            // decode falls back to the collected bytes. The raw text is also
            // what the idempotency fingerprint covers.
            let rawBody = try await request.bodyText()
            let body = try await decodeJSONRequestBody(AgentTaskCreateRequest.self, request, rawFallback: rawBody)
            return try await respond(headers: { $0.headers }) {
                try services.emailAccounts.actionCardMarketplace.createTasks(
                    authorization: request.headers[.authorization],
                    body: body,
                    rawBody: rawBody
                )
            }
        }
        agentApi.post("tasks", "resource-receipt") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskResourceReceipt, request, services: services) { return refusal }
            let body = await jsonRequestBody(AgentTaskResourceReceiptRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.resourceReceipt(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("tasks", "assign") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskAssign, request, services: services) { return refusal }
            let body = await jsonRequestBody(AgentTaskAssignRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.assignTask(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("tasks", "amend") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskAmend, request, services: services) { return refusal }
            let body = await jsonRequestBody(AgentTaskAmendRequest.self, request, emptyDefault: "{}")
            return try await respond {
                try services.tasksAndLabs.amendTask(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    body: body
                )
            }
        }
        agentApi.post("tasks", "claim") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskClaim, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.taskUpdateStatus, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.taskDelete, request, services: services) { return refusal }
            let body = await jsonRequestBody(AgentTaskDeleteRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.deleteTask(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("tasks", "convert") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskConvert, request, services: services) { return refusal }
            let body = await jsonRequestBody(AgentTaskConvertRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardMarketplace.convertTask(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("channels", ":channelId", "join") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.channelJoin, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.channelMembership.agentJoinChannel(
                    authorization: request.headers[.authorization],
                    channelId: request.parameters.get("channelId") ?? ""
                )
            }
        }
        agentApi.post("messages", ":messageId", "reactions") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.messageReactionAdd, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.messageReactionRemove, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.threadUnfollow, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.messageResolve, request, services: services) { return refusal }
            return try await respond {
                try services.emailAccounts.agentMessageLookup.agentMessageResolve(
                    authorization: request.headers[.authorization],
                    messageRef: request.parameters.get("messageId") ?? ""
                )
            }
        }
        agentApi.get("search") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.messageSearch, request, services: services) { return refusal }
            return try await respond {
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
            if let refusal = try await agentApiContractRefusal(.actionPrepare, request, services: services) { return refusal }
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
            if let refusal = try await agentApiContractRefusal(.managedMcpCall, request, services: services) { return refusal }
            let body = (try? await decodeJSONRequestBody(ManagedMCPToolCallRequest.self, request, decoding: .contentOnly))
                ?? ManagedMCPToolCallRequest()
            return try await respond {
                try services.emailAccounts.actionCards.callManagedMCPTool(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.post("feedback-locators") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.feedbackLocatorIngest, request, services: services) { return refusal }
            let body = await jsonRequestBody(FeedbackLocatorIngestRequest.self, request, emptyDefault: "")
            return try await respond {
                try services.emailAccounts.feedbackLocators.ingest(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        agentApi.get("feedback-locators") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.feedbackLocatorList, request, services: services) { return refusal }
            return try await respond {
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
                started = try services.agentSurface.beginAgentWakeHintsStream(
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
                    services.agentSurface.recordAgentCredentialUse(token: token)
                    guard let batch = services.agentSurface.agentWakeStreamBatch(token: token, after: cursor) else { return }
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
            if let refusal = try await agentApiContractRefusal(.mentionActionsPending, request, services: services) { return refusal }
            return try await respond {
                try services.humanMessageCreate.agentMentionActionsPending(
                    authorization: request.headers[.authorization],
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        agentApi.post("mention-actions", "execute") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.mentionActionsExecute, request, services: services) { return refusal }
            let body = await jsonRequestBody(MentionActionsRequest.self, request)
            return try await respond {
                try services.humanMessageCreate.agentMentionActionsExecute(
                    authorization: request.headers[.authorization],
                    body
                )
            }
        }
        agentApi.get("events") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.events, request, services: services) { return refusal }
            return try await respond {
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
                try services.agentSurface.putAgentPushWebhook(
                    authorization: request.headers[.authorization],
                    body: await jsonRequestBody(LegacyJSONObjectBody.self, request)
                )
            }
        }
        agentApi.post("upload") { request async throws -> Response in
            try await respond {
                let lifecycle = services.emailAccounts.agentsLifecycle
                _ = try lifecycle.agentApiIdentity(authorization: request.headers[.authorization])
                let parsed = try await AttachmentMultipartDecoder.decode(request)
                guard let file = parsed.files.first else { throw AttachmentContentError.noFiles }
                return try await lifecycle.uploadAgentAttachmentContent(
                    authorization: request.headers[.authorization], channelId: parsed.channelId, file: file
                )
            }
        }

        // MARK: - Direct attachment upload sessions

        // The pinned server installs `attachmentUploadSessionService` only when
        // the deployment offers presigned object uploads. This port's
        // attachment pipeline is app-side encrypted and has no presigned PUT, so
        // the capability route already publishes `directUploadEnabled: false`
        // and every session verb is the contract's service-unavailable 404. The
        // credential capability, the `attachment:upload` grant and the request
        // validator still run first, exactly as they do upstream.
        agentApi.post("attachment-upload-sessions") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.attachmentUploadSessionCreate, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "send", grant: nil)
            if let denial { return denial }
            return try await respond(status: 404) { AttachmentUploadSessionDisabledResponse() }
        }
        agentApi.get("attachment-upload-sessions", ":uploadId") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.attachmentUploadSessionStatus, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "send", grant: nil)
            if let denial { return denial }
            return try await respond(status: 404) { AttachmentUploadSessionDisabledResponse() }
        }
        agentApi.delete("attachment-upload-sessions", ":uploadId") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.attachmentUploadSessionCancel, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "send", grant: nil)
            if let denial { return denial }
            return try await respond(status: 404) { AttachmentUploadSessionDisabledResponse() }
        }
        agentApi.post("attachment-upload-sessions", ":uploadId", "complete") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.attachmentUploadSessionComplete, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "send", grant: nil)
            if let denial { return denial }
            return try await respond(status: 404) { AttachmentUploadSessionDisabledResponse() }
        }

        // MARK: - Task history and unclaim

        agentApi.get("tasks", "history") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskHistory, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "tasks", grant: nil)
            if let denial { return denial }
            // The pinned query middleware replaces `req.query` with the parsed
            // schema output, so the lookup consumes the trimmed channel and the
            // coerced task number; `Int(raw)` would turn `0b101`/`0o17`/`1e1`
            // into task 0.
            let parsedQuery = AgentApiContractValidator.taskHistoryQuery(
                contractQueryValue(request.url.query)
            )
            let channelRef = parsedQuery?.channel ?? desktopQuery(request.url.query, "channel") ?? ""
            let taskNumber = parsedQuery?.taskNumber ?? 0
            return try await respond {
                try services.emailAccounts.tasksAndLabs.agentTaskHistory(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    channelRef: channelRef,
                    taskNumber: taskNumber
                )
            }
        }
        agentApi.post("tasks", "unclaim") { request async throws -> Response in
            if let refusal = try await agentApiContractRefusal(.taskUnclaim, request, services: services) { return refusal }
            let (_, denial) = agentApiGate(request, capability: "tasks", grant: nil)
            if let denial { return denial }
            let body = await jsonRequestBody(LegacyJSONObjectBody.self, request)
            let taskNumber: Int
            switch body?["task_number"] {
            case .integer(let value)?: taskNumber = Int(exactly: value) ?? 0
            case .number(let value)?: taskNumber = Int(exactly: value) ?? 0
            default: taskNumber = 0
            }
            return try await respond {
                try services.emailAccounts.actionCardExecute.agentTaskUnclaim(
                    authorization: request.headers[.authorization],
                    legacyAgentId: nil,
                    channel: body?.string("channel") ?? "",
                    taskNumber: taskNumber
                )
            }
        }

        // MARK: - Profile and server avatars

        agentApi.post("profile", "avatar") { request async throws -> Response in
            let (_, denial) = agentApiGate(request, capability: "send", grant: nil)
            if let denial { return denial }
            return try await respond {
                let file = try await singleAvatarUploadFile(request)
                _ = try services.agentSurface.uploadAgentProfileAvatar(
                    authorization: request.headers[.authorization], byteCount: file.bytes.count
                )
                return try services.emailAccounts.joinLinksAndInvites.agentProfileShow(
                    authorization: request.headers[.authorization], target: nil
                )
            }
        }
        agentApi.post("server", "avatar") { request async throws -> Response in
            let (_, denial) = agentApiGate(request, capability: "server", grant: "server:update")
            if let denial { return denial }
            return try await respond {
                let file = try await singleAvatarUploadFile(request)
                return try services.emailAccounts.agentChannels.uploadServerAvatar(
                    authorization: request.headers[.authorization], byteCount: file.bytes.count
                )
            }
        }

        registerIntegrationAppRoutes(routes: app)
    }

    // MARK: - Agent API gates

    /// `requireAgentCapability` + `requireAgentGrant`: a credential denial is
    /// projected before the handler, as the published middleware chain does.
    /// Returns the identity on success, or the exact refusal reply.
    func agentApiGate(
        _ request: Request,
        capability: String,
        grant: String?
    ) -> (AgentApiIdentityDTO?, Response?) {
        let identity: AgentApiIdentityDTO
        do {
            identity = try services.emailAccounts.agentsLifecycle.resolveAgentApiIdentity(
                authorization: request.headers[.authorization]
            )
        } catch let error as any DomainError {
            return (nil, domainErrorResponse(error))
        } catch {
            return (nil, domainErrorResponse(AgentsLifecycleError.invalidOrExpiredToken))
        }
        guard identity.scopes.contains(capability) else {
            return (nil, domainErrorResponse(
                FeedbackLocatorError.capabilityNotAuthorized(capability: capability)
            ))
        }
        if let grant {
            switch services.emailAccounts.feedbackLocators.grantDecision(agentId: identity.agentId, scope: grant) {
            case .allowed:
                break
            case .missingScope(let scope):
                return (nil, domainErrorResponse(FeedbackLocatorError.missingScope(scope: scope)))
            }
        }
        return (identity, nil)
    }

}
