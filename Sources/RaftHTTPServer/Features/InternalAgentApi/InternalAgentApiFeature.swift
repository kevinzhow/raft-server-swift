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

        agentApi.delete("reminders", ":reminderId") { request -> Response in
            routeResponse(services.emailAccounts.agentApiReminderCancel(
                authorization: request.headers[.authorization],
                reminderId: request.parameters.get("reminderId") ?? ""
            ))
        }
        agentApi.post("reminders", ":reminderId", "snooze") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentApiReminderSnooze(
                authorization: request.headers[.authorization],
                reminderId: request.parameters.get("reminderId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.patch("reminders", ":reminderId") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentApiReminderUpdate(
                authorization: request.headers[.authorization],
                reminderId: request.parameters.get("reminderId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.get("reminders", ":reminderId", "log") { request -> Response in
            routeResponse(services.emailAccounts.agentApiReminderLog(
                authorization: request.headers[.authorization],
                reminderId: request.parameters.get("reminderId") ?? ""
            ))
        }
        agentApi.get("reminders") { request -> Response in
            routeResponse(services.emailAccounts.agentApiReminderList(
                authorization: request.headers[.authorization],
                status: desktopQuery(request.url.query, "status")
            ))
        }
        agentApi.post("reminders") { request async throws -> Response in
            let reply = services.emailAccounts.agentApiReminderCreate(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            )
            if let reminderId = reminderIdFromReply(reply),
               let agentId = services.emailAccounts.agentIdForReminderTesting(reminderId: reminderId) {
                publishReminderEvent(reply, event: "reminder:scheduled", reminderId: reminderId, agentId: agentId, services: services)
            }
            return routeResponse(reply)
        }
        agentApi.get("users", "info") { request -> Response in
            var name = ""
            var limit: String?
            var offset: String?
            if let components = URLComponents(string: "http://internal/?\(request.url.query ?? "")") {
                name = components.queryItems?.first { $0.name == "name" || $0.name == "user" }?.value ?? ""
                limit = components.queryItems?.first { $0.name == "limit" }?.value
                offset = components.queryItems?.first { $0.name == "offset" }?.value
            }
            return routeResponse(services.emailAccounts.agentUserInfo(
                authorization: request.headers[.authorization],
                name: name,
                limit: limit,
                offset: offset
            ))
        }
        agentApi.get("users", ":name", "channels") { request -> Response in
            let name = request.parameters.get("name") ?? ""
            var limit: String?
            var offset: String?
            if let components = URLComponents(string: "http://internal/?\(request.url.query ?? "")") {
                limit = components.queryItems?.first { $0.name == "limit" }?.value
                offset = components.queryItems?.first { $0.name == "offset" }?.value
            }
            return routeResponse(services.emailAccounts.agentUserChannels(
                authorization: request.headers[.authorization],
                name: name,
                limit: limit,
                offset: offset
            ))
        }
        agentApi.get() { request -> Response in
            routeResponse(services.emailAccounts.agentApiIdentity(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.get("profile") { request -> Response in
            routeResponse(services.emailAccounts.agentProfileShow(
                authorization: request.headers[.authorization],
                target: desktopQuery(request.url.query, "target")
            ))
        }
        agentApi.post("profile") { request async throws -> Response in
            routeResponse(services.emailAccounts.updateAgentProfile(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        agentApi.post("channels", ":channelId", "leave") { request -> Response in
            routeResponse(services.emailAccounts.agentLeaveChannel(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }
        agentApi.patch("server") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentUpdateServer(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.patch("channels", ":channelId") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentUpdateChannel(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("channels", "archive") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentChannelArchive(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}"),
                archive: true
            ))
        }
        agentApi.post("channels", "unarchive") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentChannelArchive(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}"),
                archive: false
            ))
        }
        agentApi.post("channels", ":channelId", "mute") { request -> Response in
            routeResponse(services.emailAccounts.agentSetChannelMute(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                muted: true
            ))
        }
        agentApi.post("channels", ":channelId", "unmute") { request -> Response in
            routeResponse(services.emailAccounts.agentSetChannelMute(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                muted: false
            ))
        }
        agentApi.post("channels", ":channelId", "members") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentChannelMemberWrite(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText(default: "{}"),
                remove: false
            ))
        }
        agentApi.delete("channels", ":channelId", "members") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentChannelMemberWrite(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                body: try await request.bodyText(default: "{}"),
                remove: true
            ))
        }
        agentApi.get("channel-members") { request -> Response in
            routeResponse(services.emailAccounts.agentChannelMembers(
                authorization: request.headers[.authorization],
                agentId: nil,
                channelRef: desktopQuery(request.url.query, "channel")
            ))
        }
        agentApi.get("server") { request -> Response in
            routeResponse(services.emailAccounts.agentServerInfo(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.post("resolve-channel") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentResolveChannel(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("channels") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentCreateChannel(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.get("attachment-upload-capabilities") { request -> Response in
            routeResponse(services.emailAccounts.agentAttachmentUploadCapabilities(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.get("history") { request -> Response in
            routeResponse(services.emailAccounts.agentHistory(
                authorization: request.headers[.authorization],
                channelRef: desktopQuery(request.url.query, "channel"),
                before: desktopQuery(request.url.query, "before"),
                after: desktopQuery(request.url.query, "after"),
                around: desktopQuery(request.url.query, "around"),
                limit: desktopQuery(request.url.query, "limit"),
                consume: desktopQuery(request.url.query, "consume"),
                unread: desktopQuery(request.url.query, "unread") == "true"
            ))
        }
        agentApi.get("assistant", "owner-inbox") { request -> Response in
            routeResponse(services.emailAccounts.agentAssistantOwnerInbox(
                authorization: request.headers[.authorization],
                rawQuery: request.url.query
            ))
        }
        agentApi.get("assistant", "owner-messages") { request -> Response in
            routeResponse(services.emailAccounts.agentAssistantOwnerMessages(
                authorization: request.headers[.authorization],
                channelId: desktopQuery(request.url.query, "channelId") ?? ""
            ))
        }
        agentApi.get("inbox", "conversations") { request -> Response in
            routeResponse(services.emailAccounts.agentInboxConversations(
                authorization: request.headers[.authorization],
                limit: desktopQuery(request.url.query, "limit"),
                beforeSeq: desktopQuery(request.url.query, "before_seq"),
                view: desktopQuery(request.url.query, "view")
            ))
        }
        agentApi.get("attachments", ":attachmentId", "comments") { request -> Response in
            routeResponse(services.emailAccounts.agentAttachmentCommentsList(
                authorization: request.headers[.authorization],
                attachmentId: request.parameters.get("attachmentId") ?? ""
            ))
        }
        agentApi.post("attachments", ":attachmentId", "comments") { request -> Response in
            routeResponse(services.emailAccounts.agentAttachmentCommentCreate(
                authorization: request.headers[.authorization],
                attachmentId: request.parameters.get("attachmentId") ?? ""
            ))
        }
        agentApi.get("attachments", ":attachmentId") { request -> Response in
            routeResponse(services.emailAccounts.agentAttachmentDownload(
                authorization: request.headers[.authorization],
                attachmentId: request.parameters.get("attachmentId") ?? ""
            ))
        }
        agentApi.get("attachments", ":attachmentId", "url") { request -> Response in
            routeResponse(services.emailAccounts.agentAttachmentDownloadURL(
                authorization: request.headers[.authorization],
                attachmentId: request.parameters.get("attachmentId") ?? ""
            ))
        }
        agentApi.get("integrations") { request -> Response in
            routeResponse(services.emailAccounts.agentIntegrationList(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.get("integrations", "app") { request -> Response in
            routeResponse(services.emailAccounts.agentIntegrationAppList(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.post("integrations", "app", "prepare") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentIntegrationAppPrepare(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("integrations", "app", "update") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentIntegrationAppUpdate(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.get("integrations", "app", "status") { request -> Response in
            routeResponse(services.emailAccounts.agentIntegrationAppStatus(
                authorization: request.headers[.authorization],
                client: desktopQuery(request.url.query, "client"),
                card: desktopQuery(request.url.query, "card")
            ))
        }
        agentApi.get("integrations", "marketplace") { request -> Response in
            routeResponse(services.emailAccounts.agentIntegrationMarketplace(
                authorization: request.headers[.authorization],
                query: desktopQuery(request.url.query, "query"),
                limit: desktopQuery(request.url.query, "limit")
            ))
        }
        agentApi.post("integrations", "login") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentIntegrationLogin(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("integrations", "token") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentIntegrationToken(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        agentApi.get("context") { request -> Response in
            routeResponse(services.emailAccounts.agentContext(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.get("apps", ":appId", "config") { request -> Response in
            routeResponse(services.emailAccounts.agentAppConfig(
                authorization: request.headers[.authorization],
                appId: request.parameters.get("appId") ?? ""
            ))
        }
        agentApi.patch("apps", ":appId", "config") { request async throws -> Response in
            routeResponse(services.emailAccounts.patchAgentAppConfig(
                authorization: request.headers[.authorization],
                appId: request.parameters.get("appId") ?? "",
                body: try await request.bodyText()
            ))
        }
        agentApi.post("send") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentSendMessage(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(),
                v2: false
            ))
        }
        agentApi.post("v2", "send") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentSendMessage(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(),
                v2: true
            ))
        }
        agentApi.get("tasks") { request -> Response in
            routeResponse(services.emailAccounts.agentTasksList(
                authorization: request.headers[.authorization],
                legacyAgentId: nil,
                channelRef: desktopQuery(request.url.query, "channel")
            ))
        }
        agentApi.post("tasks") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentTasksCreate(
                authorization: request.headers[.authorization],
                legacyAgentId: nil,
                body: try await request.bodyText()
            ))
        }
        agentApi.post("tasks", "resource-receipt") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentTaskResourceReceipt(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("tasks", "assign") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentTaskAssign(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("tasks", "amend") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentTasksAmend(
                authorization: request.headers[.authorization],
                legacyAgentId: nil,
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("tasks", "claim") { request async throws -> Response in
            // `channel`, `task_numbers`, `message_ids` and `seenUpToSeq` are the
            // only body fields. A body that does not decode keeps the
            // directory's raw parser so the published 400 is unchanged.
            if let body = try? await request.content.decode(AgentTaskClaimDTO.self) {
                return routeResponse(services.emailAccounts.agentTaskClaim(
                    authorization: request.headers[.authorization],
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.agentTaskClaim(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("tasks", "update-status") { request async throws -> Response in
            // `channel`, `task_number`, `status` and `seenUpToSeq` are the only
            // body fields; the directory owns the status allow-list and the
            // warning when no status arrives.
            if let body = try? await request.content.decode(AgentStatusUpdateDTO.self) {
                return routeResponse(services.emailAccounts.agentTaskUpdateStatus(
                    authorization: request.headers[.authorization],
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.agentTaskUpdateStatus(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("tasks", "delete") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentTaskDelete(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("tasks", "convert") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentTaskConvert(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.post("channels", ":channelId", "join") { request -> Response in
            routeResponse(services.emailAccounts.agentJoinChannel(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? ""
            ))
        }
        agentApi.post("messages", ":messageId", "reactions") { request async throws -> Response in
            // `emoji` is the only body field on both verbs; the directory owns
            // the trim, the 16-unit cap and the `A valid emoji is required` 400.
            if let body = try? await request.content.decode(AgentMessageReactionDTO.self) {
                return routeResponse(services.emailAccounts.mutateAgentApiMessageReaction(
                    messageId: request.parameters.get("messageId") ?? "",
                    body: body.encodedBody(),
                    authorization: request.headers[.authorization],
                    remove: false
                ))
            }
            return routeResponse(services.emailAccounts.mutateAgentApiMessageReaction(
                messageId: request.parameters.get("messageId") ?? "",
                body: try await request.bodyText(),
                authorization: request.headers[.authorization],
                remove: false
            ))
        }
        agentApi.delete("messages", ":messageId", "reactions") { request async throws -> Response in
            if let body = try? await request.content.decode(AgentMessageReactionDTO.self) {
                return routeResponse(services.emailAccounts.mutateAgentApiMessageReaction(
                    messageId: request.parameters.get("messageId") ?? "",
                    body: body.encodedBody(),
                    authorization: request.headers[.authorization],
                    remove: true
                ))
            }
            return routeResponse(services.emailAccounts.mutateAgentApiMessageReaction(
                messageId: request.parameters.get("messageId") ?? "",
                body: try await request.bodyText(),
                authorization: request.headers[.authorization],
                remove: true
            ))
        }
        agentApi.post("activity") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentActivityIngest(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.get("threads") { request -> Response in
            routeResponse(services.emailAccounts.agentThreadList(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.post("threads", "unfollow") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentThreadUnfollow(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.get("messages", ":messageId", "mention-deliveries") { request -> Response in
            routeResponse(services.emailAccounts.agentMentionDeliveries(
                authorization: request.headers[.authorization],
                messageRef: request.parameters.get("messageId") ?? ""
            ))
        }
        agentApi.get("messages", ":messageId", "resolve") { request -> Response in
            routeResponse(services.emailAccounts.agentMessageResolve(
                authorization: request.headers[.authorization],
                messageRef: request.parameters.get("messageId") ?? ""
            ))
        }
        agentApi.get("search") { request -> Response in
            routeResponse(services.emailAccounts.agentApiSearch(
                authorization: request.headers[.authorization],
                query: desktopQuery(request.url.query, "q"),
                channelRef: desktopQuery(request.url.query, "channel"),
                senderRef: desktopQuery(request.url.query, "sender"),
                sort: desktopQuery(request.url.query, "sort"),
                limit: desktopQuery(request.url.query, "limit")
            ))
        }
        agentApi.get("mentions") { request -> Response in
            routeResponse(services.emailAccounts.agentMentionInbox(
                authorization: request.headers[.authorization],
                limit: desktopQuery(request.url.query, "limit")
            ))
        }
        agentApi.post("prepare-action") { request async throws -> Response in
            routeResponse(services.emailAccounts.prepareActionCard(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
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
        agentApi.get("wake-hints") { request -> Response in
            routeResponse(services.emailAccounts.agentWakeHints(
                authorization: request.headers[.authorization],
                since: desktopQuery(request.url.query, "since"),
                limit: desktopQuery(request.url.query, "limit")
            ))
        }
        agentApi.get("wake-hints", "stream") { request -> Response in
            switch services.emailAccounts.beginAgentWakeHintsStream(
                authorization: request.headers[.authorization],
                since: request.headers[HTTPField.Name("Last-Event-ID")!] ?? desktopQuery(request.url.query, "since")
            ) {
            case .refused(let reply):
                return routeResponse(reply)
            case .start(let token, let cursorSeq, let firstFrame):
                var headers = HTTPFields()
                headers[.contentType] = "text/event-stream"
                headers[.cacheControl] = "no-cache, no-transform"
                headers[HTTPField.Name("X-Accel-Buffering")!] = "no"
                let pollMs = services.nodeEnv == "test" ? 50 : 1_000
                // Tests bound the loop so a streaming task cannot outlive the suite.
                let boundedTicks = services.nodeEnv == "test" ? 200 : Int.max
                var response = Response(status: .ok, headers: headers)
                response.body = Response.Body { writer in
                    try await writer.write(firstFrame)
                    var cursor = cursorSeq
                    var ticks = 0
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
                        services.emailAccounts.refreshAgentWakeStreamCredential(token: token)
                        guard let batch = services.emailAccounts.agentWakeStreamBatch(token: token, after: cursor) else { return }
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
        }
        agentApi.get("mention-actions", "pending") { request -> Response in
            routeResponse(services.emailAccounts.agentMentionActionsPending(
                authorization: request.headers[.authorization]
            ))
        }
        agentApi.post("mention-actions", "execute") { request async throws -> Response in
            routeResponse(services.emailAccounts.agentMentionActionsExecute(
                authorization: request.headers[.authorization],
                body: try await request.bodyText(default: "{}")
            ))
        }
        agentApi.get("events") { request -> Response in
            routeResponse(services.emailAccounts.agentThirdPartyEvents(authorization: request.headers[.authorization]))
        }
        agentApi.post("third-party-events", "delivered") { request async throws -> Response in
            routeResponse(services.emailAccounts.reportThirdPartyEventsDelivered(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        agentApi.put("push-webhook") { request async throws -> Response in
            routeResponse(services.emailAccounts.putAgentPushWebhook(
                authorization: request.headers[.authorization],
                body: try await request.bodyText()
            ))
        }
        agentApi.post("upload") { request async throws -> Response in
            guard let contentType = request.headers[.contentType],
                  let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                  !boundary.isEmpty
            else {
                return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
            }
            let buffer = try await request.body.collect(max: .specified(ByteCount(value: 300 * 1024 * 1024)))
            guard let buffer,
                  let parsed = parseAttachmentMultipart(data: buffer, boundary: boundary),
                  let file = parsed.files.first
            else {
                return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
            }
            return routeResponse(services.emailAccounts.uploadAgentAttachmentIdless(
                authorization: request.headers[.authorization],
                channelId: parsed.channelId,
                filename: file.filename,
                mimeType: file.mimeType,
                sizeBytes: file.sizeBytes,
                bytes: file.data
            ))
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

private func reminderIdFromReply(_ reply: HTTPReply) -> String? {
    guard reply.status == 200, let data = reply.body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let reminder = object["reminder"] as? [String: Any]
    else { return nil }
    return reminder["reminderId"] as? String ?? reminder["id"] as? String
}

private func publishReminderEvent(
    _ reply: HTTPReply, event: String, reminderId: String, agentId: String, services: FallbackServices
) {
    guard reply.status == 200, let hub = services.realtime,
          let agent = services.emailAccounts.oauth.agentRuntimeInfo(id: agentId)
    else { return }
    var recipients: Set<String> = []
    if let creator = agent.creatorUserId { recipients.insert(creator) }
    for member in services.emailAccounts.serverMemberRoles(serverId: agent.serverId)
    where member.role == "owner" || member.role == "admin" {
        recipients.insert(member.userId)
    }
    guard !recipients.isEmpty else { return }
    let payload = "{\"reminderId\":\(jsonString(reminderId)),\"ownerAgentId\":\(jsonString(agentId))}"
    for userId in recipients {
        hub.emit(room: "user:\(userId)", event: event, payloadJSON: payload)
    }
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
