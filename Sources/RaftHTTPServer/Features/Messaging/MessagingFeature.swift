import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Messaging route surface extracted from `FallbackApplication.configure`.
///
/// Every registration below is copied verbatim from the inline `configure`
/// block: same method, path, request projection, helper call and
/// `routeResponse` handling. The five owned families are `/api/messages/*`
/// (14), `/api/attachments/*` (13), `/api/tasks/*` (12), `/api/actions/*` (3)
/// and `/api/read-mutations` (2) — 44 pairs in total. `/api/v2/messages` stays
/// in `configure` because it is not one of the five extracted prefixes.
///
/// The two multipart/task-realtime helpers and the streaming response helper
/// were file-private in `FallbackApplication.swift`; they are kept file-private
/// here so the feature is self-contained, matching the `PublicFeature` pattern.
/// The collection is not mounted from `configure` yet; the integration slice
/// decides when it replaces the inline registrations.
public struct MessagingFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let readMutations = routes.grouped("api", "read-mutations")
        let messages = routes.grouped("api", "messages")
        let attachments = routes.grouped("api", "attachments")
        let actions = routes.grouped("api", "actions")
        let tasks = routes.grouped("api", "tasks")
        let humanMessageCreate = services.humanMessageCreate
        // The claim publishes `task:updated` through the channel-messaging
        // domain; the service hands it the claimed task's published JSON.
        let assignments = services.emailAccounts.channelAssignments(
            publishTaskUpdated: services.channelMessaging.publishCommittedTaskUpdated
        )
        let inbox = services.emailAccounts.inboxAndWake
        readMutations.post { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request, emptyDefault: "{}")
            return try await respond(status: { $0.status }, headers: { _ in .standard() }) {
                try services.emailAccounts.managedMCPLifecycle.postReadMutation(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }
        readMutations.get("frontier") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.managedMCPLifecycle.readMutationFrontier(
                    authorization: request.headers[.authorization],
                    scopeIds: desktopQuery(request.url.query, "scopeIds")
                )
            }
        }
        messages.post("mention-actions", "execute") { request async throws -> Response in
            let body = await jsonRequestBody(MentionActionsRequest.self, request)
            return try await respond {
                try humanMessageCreate.executeMentionActions(
                    body,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.post { request async throws -> Response in
            // requireAuth runs before the body check. An invalid body writes nothing.
            let body = await jsonRequestBody(HumanMessageCreateRequest.self, request)
            return try await respond {
                try humanMessageCreate.createHumanMessage(
                    body,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.get("forward", "targets", "search") { request async throws -> Response in
            try await respond {
                try humanMessageCreate.searchForwardTargets(
                    query: desktopQuery(request.url.query, "q"),
                    limit: desktopQuery(request.url.query, "limit"),
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.get("attachment-preview", "enabled") { request async throws -> Response in
            try await respond {
                try humanMessageCreate.attachmentPreviewAvailability(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.get("forward", "enabled") { request async throws -> Response in
            try await respond {
                try humanMessageCreate.messageForwardEnabled(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        attachments.post("urls") { request async throws -> Response in
            let body = await jsonRequestBody(AttachmentURLBatchRequest.self, request)
            func scalar(_ name: String) -> String? {
                guard let query = request.url.query,
                      let items = URLComponents(string: "http://localhost/?" + query)?.queryItems else { return nil }
                let matches = items.filter { $0.name == name }
                return matches.count == 1 ? matches.first?.value : nil
            }
            let proxy = AttachmentURLProxyContext(
                authorization: request.headers[.authorization], queryToken: scalar("token"),
                configuredServerURL: services.releaseEnvironment["SERVER_URL"],
                deploymentEnvironment: services.releaseEnvironment["DEPLOYMENT_ENV"],
                requestScheme: request.url.scheme ?? "http",
                requestHost: attachmentRequestHost(request),
                forwardedProto: request.headers[HTTPField.Name("X-Forwarded-Proto")!],
                forwardedHost: request.headers[HTTPField.Name("X-Forwarded-Host")!]
            )
            return try await respond {
                try services.emailAccounts.agentsLifecycle.attachmentBatchURLs(admission: try requireAttachmentFlexContext(request), body: body, proxy: proxy)
            }
        }
        attachments.get(":id", "url") { request async throws -> Response in
            return try await respond {
                guard let admission = request.auth.get(AttachmentFlexContext.self)?.admission else {
                    throw AttachmentFlexAdmissionError.authenticationRequired
                }
                return try services.emailAccounts.messageSend.attachmentDownloadURL(
                    attachmentId: request.parameters.get("id") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: admission.serverId,
                    disposition: AttachmentQueryScalars.value(request.url.query, named: "disposition"),
                    download: AttachmentQueryScalars.value(request.url.query, named: "download"),
                    propagateQueryToken: AttachmentQueryScalars.value(request.url.query, named: "token"),
                    admission: admission,
                    proxy: AttachmentURLProxyContext(
                        authorization: request.headers[.authorization],
                        queryToken: AttachmentQueryScalars.value(request.url.query, named: "token"),
                        configuredServerURL: services.releaseEnvironment["SERVER_URL"],
                        deploymentEnvironment: services.releaseEnvironment["DEPLOYMENT_ENV"],
                        requestScheme: request.url.scheme ?? "http",
                        requestHost: attachmentRequestHost(request),
                        forwardedProto: request.headers[HTTPField.Name("X-Forwarded-Proto")!],
                        forwardedHost: request.headers[HTTPField.Name("X-Forwarded-Host")!]
                    )
                )
            }
        }
        messages.post("forward") { request async throws -> Response in
            let body = await jsonRequestBody(HumanMessageForwardRequest.self, request)
            return try await respond(headers: { $0.headers }) {
                try humanMessageCreate.forwardHumanMessage(
                    body,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.get(":messageId", "mention-deliveries") { request async throws -> Response in
            try await respond {
                try inbox.mentionDeliveries(
                    messageId: request.parameters.get("messageId") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.get(":messageId", "reactions", "actors") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.profileAndChannelFiles.listReactionActors(
                    messageId: request.parameters.get("messageId") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    emoji: desktopQuery(request.url.query, "emoji"),
                    limit: desktopQuery(request.url.query, "limit"),
                    cursor: desktopQuery(request.url.query, "cursor")
                )
            }
        }
        messages.get(":messageId", "reactions", "viewer") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.profileAndChannelFiles.reactionViewer(
                    messageId: request.parameters.get("messageId") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.post(":messageId", "reactions") { request async throws -> Response in
            let body = await jsonRequestBody(ProfileReactionRequestDTO.self, request)
            return try await respond {
                try services.emailAccounts.profileAndChannelFiles.addMessageReaction(
                    messageId: request.parameters.get("messageId") ?? "",
                    emoji: body?.emoji,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.delete(":messageId", "reactions") { request async throws -> Response in
            let body = await jsonRequestBody(ProfileReactionRequestDTO.self, request)
            return try await respond {
                try services.emailAccounts.profileAndChannelFiles.removeMessageReaction(
                    messageId: request.parameters.get("messageId") ?? "",
                    emoji: body?.emoji,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        messages.get("channel", ":channelId") { request async throws -> Response in
            try await respond {
                try inbox.listChannelMessages(
                    channelId: request.parameters.get("channelId") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    limit: desktopQuery(request.url.query, "limit"),
                    before: desktopQuery(request.url.query, "before"),
                    after: desktopQuery(request.url.query, "after")
                )
            }
        }
        attachments.get("comments", "counts") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.attachmentComments.attachmentCommentCounts(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? desktopQuery(request.url.query, "server_id") ?? "",
                    ids: desktopQuery(request.url.query, "ids")
                )
            }
        }
        attachments.get(":id", "comments") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.attachmentComments.attachmentCommentsList(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    attachmentId: request.parameters.get("id") ?? ""
                )
            }
        }
        attachments.post(":id", "comments") { request async throws -> Response in
            let body = await jsonRequestBody(IntegrationRequestBody.self, request, emptyDefault: "{}")
            return try await respond {
                try services.emailAccounts.attachmentComments.createAttachmentComment(
                    authorization: request.headers[.authorization],
                    attachmentId: request.parameters.get("id") ?? "",
                    body: body,
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        actions.post("migration-export") { _ -> Response in
            routeResponse(HTTPReply(
                status: 410,
                headers: ["Content-Type": "application/json", "Content-Length": "76"],
                body: OrderedJSON.object([OrderedJSONField("error", "Migration action cards are no longer supported"), OrderedJSONField("code", "migration_action_card_not_supported")]).render()
            ))
        }
        actions.post(":messageId", "execute") { request async throws -> Response in
            let body = await jsonRequestBody(ActionCardExecuteRequest.self, request)
            return try await respond {
                try services.emailAccounts.actionCardIntegrationRegister.executeActionCard(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    messageId: request.parameters.get("messageId") ?? "",
                    body: body
                )
            }
        }
        actions.post(":messageId", "mark-executed") { request async throws -> Response in
            let body = (try? await decodeJSONRequestBody(MarkActionCardExecutedRequest.self, request, decoding: .contentOnly))
                ?? MarkActionCardExecutedRequest()
            return try await respond {
                try services.emailAccounts.actionCards.markActionCardExecuted(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    messageId: request.parameters.get("messageId") ?? "",
                    body: body
                )
            }
        }
        messages.get("sync") { request async throws -> Response in
            try await respond {
                try inbox.syncChannelMessages(
                    channelId: desktopQuery(request.url.query, "channel_id"),
                    sinceSeq: desktopQuery(request.url.query, "since_seq"),
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    limit: desktopQuery(request.url.query, "limit")
                )
            }
        }
        messages.get("search") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.searchMentions.searchHumanMessages(
                    query: desktopQuery(request.url.query, "q"),
                    sort: desktopQuery(request.url.query, "sort"),
                    limit: desktopQuery(request.url.query, "limit"),
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                    channelId: desktopQuery(request.url.query, "channelId"),
                    senderId: desktopQuery(request.url.query, "senderId"),
                    senderType: desktopQuery(request.url.query, "senderType"),
                    mentionTarget: desktopQuery(request.url.query, "mentionTarget")
                )
            }
        }
        messages.get("context", ":messageId") { request async throws -> Response in
            let messageId = request.parameters.get("messageId") ?? ""
            let channelId = desktopQuery(request.url.query, "channelId")
            let authorization = request.headers[.authorization]
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!]
            do {
                try services.emailAccounts.searchMentions.authorizeHumanContextRead(
                    messageId: messageId, channelId: channelId, authorization: authorization,
                    serverId: serverId, catalog: services.messageContext
                )
                let reply = MessageContext.reply(
                    messageId: messageId,
                    channelId: channelId,
                    catalog: services.messageContext,
                    callerId: services.emailAccounts.sessionUserId(authorization: authorization),
                    serverId: serverId
                )
                if reply.status == 404,
                   let stored = services.emailAccounts.searchMentions.humanMessageContext(
                       messageId: messageId,
                       channelId: channelId,
                       authorization: authorization,
                       serverId: serverId,
                       before: desktopQuery(request.url.query, "before"),
                       after: desktopQuery(request.url.query, "after")
                   ) {
                    return try await respond { stored }
                }
                return routeResponse(reply)
            } catch {
                return try await respond { () throws -> StoredMessageContextResponse in throw error }
            }
        }
        attachments.post("upload") { request async throws -> Response in
            try await respond {
                let lifecycle = services.emailAccounts.agentsLifecycle
                let serverId = try lifecycle.authorizeHumanAttachmentUpload(
                    authorization: request.headers[.authorization],
                    headerServerId: request.headers[HTTPField.Name("X-Server-Id")!],
                    flexAdmission: try requireAttachmentFlexContext(request)
                )
                let parsed = try await AttachmentMultipartDecoder.decode(request)
                return try await lifecycle.uploadAttachmentContents(
                    authorization: request.headers[.authorization], serverId: serverId,
                    channelId: parsed.channelId, files: parsed.files
                )
            }
        }
        attachments.get("upload-sessions", ":uploadId", "active") { request async throws -> Response in
            try await respond {
                try humanMessageCreate.absentAttachmentUploadRecovery(
                    channelId: request.parameters.get("uploadId") ?? "",
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!]
                )
            }
        }
        attachments.post("upload-sessions") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.attachmentUploadSessionCreate(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        attachments.get("upload-sessions", ":uploadId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.attachmentUploadSessionMissing(
                    authorization: request.headers[.authorization],
                    uploadId: request.parameters.get("uploadId") ?? ""
                )
            }
        }
        attachments.delete("upload-sessions", ":uploadId") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.attachmentUploadSessionMissing(
                    authorization: request.headers[.authorization],
                    uploadId: request.parameters.get("uploadId") ?? ""
                )
            }
        }
        attachments.post("upload-sessions", ":uploadId", "complete") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.attachmentUploadSessionMissing(
                    authorization: request.headers[.authorization],
                    uploadId: request.parameters.get("uploadId") ?? ""
                )
            }
        }
        attachments.get("upload-capabilities") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.agentsLifecycle.attachmentUploadCapabilities(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }
        attachments.get(":id") { request async throws -> Response in
            let queryToken = desktopQuery(request.url.query, "token")
            let authorization = request.headers[.authorization] ?? queryToken.map { "Bearer \($0)" }
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!] ?? desktopQuery(request.url.query, "serverId")
            do {
                let content = try await services.emailAccounts.agentsLifecycle.attachmentContent(
                    authorization: authorization, serverId: serverId,
                    attachmentId: request.parameters.get("id") ?? "",
                    admission: try requireAttachmentFlexContext(request)
                )
                return AttachmentContentResponse.make(
                    content, request: request,
                    frameAncestors: services.corsOrigins + [services.releaseEnvironment["APP_URL"]].compactMap { $0 }
                )
            } catch let error as any DomainError {
                return respond(status: error.status, headers: error.errorHeaders, rawJSON: error.publishedErrorBody.render())
            }
        }
        attachments.get(":id", "html-preview") { request async throws -> Response in
            do {
                guard let admission = request.auth.get(AttachmentFlexContext.self)?.admission else {
                    throw AttachmentFlexAdmissionError.authenticationRequired
                }
                let content = try await services.emailAccounts.agentsLifecycle.attachmentHTMLPreview(
                    attachmentId: request.parameters.get("id") ?? "",
                    admission: admission,
                    previewToken: AttachmentQueryScalars.value(request.url.query, named: "previewToken"),
                    bearerQuery: AttachmentQueryScalars.value(request.url.query, named: "token")
                )
                return try AttachmentHTMLPreviewResponse.make(content,
                    frameAncestors: services.corsOrigins + [services.releaseEnvironment["APP_URL"]].compactMap { $0 })
            } catch let error as any DomainError {
                return respond(status: error.status, headers: error.errorHeaders, rawJSON: error.publishedErrorBody.render())
            }
        }
        attachments.get(":id", "html-preview-url") { request async throws -> Response in
            return try await respond {
                guard let admission = request.auth.get(AttachmentFlexContext.self)?.admission else {
                    throw AttachmentFlexAdmissionError.authenticationRequired
                }
                return try await services.emailAccounts.agentsLifecycle.attachmentHTMLPreviewURL(
                    attachmentId: request.parameters.get("id") ?? "", admission: admission)
            }
        }
        tasks.get("server", "snapshot-metrics") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverMembersAndSidebar.taskSnapshotMetrics(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    rawQuery: request.url.query
                )
            }
        }
        tasks.get("server", "period-metrics") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.serverMembersAndSidebar.taskPeriodMetrics(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    rawQuery: request.url.query
                )
            }
        }
        tasks.get("channel", ":channelId") { request async throws -> Response in
            try await respond {
                try services.tasksAndLabs.listChannelTasks(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    rawQuery: request.url.query
                )
            }
        }
        tasks.get("channel", ":channelId", "number", ":taskNumber") { request async throws -> Response in
            try await respond {
                try services.tasksAndLabs.getChannelTaskByNumber(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    taskNumber: Int(request.parameters.get("taskNumber") ?? "") ?? 0
                )
            }
        }
        tasks.post("channel", ":channelId") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond {
                try services.channelMessaging.createChannelTasks(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    channelId: request.parameters.get("channelId") ?? "",
                    body: body
                )
            }
        }
        tasks.delete(":taskId") { request async throws -> Response in
            try await respond {
                try assignments.deleteTask(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    taskId: request.parameters.get("taskId") ?? ""
                )
            }
        }
        tasks.patch(":taskId", "assignee") { request async throws -> Response in
            // A body sent without a JSON Content-Type was accepted before; a
            // missing or non-object body stays `nil` (the service's 400).
            let body = await jsonRequestBody(TaskAssigneePatchRequest.self, request)
            return try await respond {
                try services.tasksAndLabs.assignTask(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    taskId: request.parameters.get("taskId") ?? "",
                    body: body
                )
            }
        }
        tasks.patch(":taskId", "unclaim") { request async throws -> Response in
            try await respond {
                try assignments.unclaimTask(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    taskId: request.parameters.get("taskId") ?? ""
                )
            }
        }
        tasks.patch(":taskId", "claim") { request async throws -> Response in
            try await respond {
                try assignments.claimTask(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    taskId: request.parameters.get("taskId") ?? ""
                )
            }
        }
        tasks.patch(":taskId", "status") { request async throws -> Response in
            // `status` is the only key this route reads; an unknown value still
            // answers the published `Invalid task status` 400.
            let body = await jsonRequestBody(TaskStatusRequest.self, request)
            return try await respond {
                try assignments.updateTaskStatus(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    taskId: request.parameters.get("taskId") ?? "",
                    body: body
                )
            }
        }
        tasks.post("convert-message") { request async throws -> Response in
            let body = await jsonRequestBody(TaskConvertRequest.self, request)
            return try await respond {
                try assignments.convertMessageToTask(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    body: body
                )
            }
        }
        tasks.get("server") { request async throws -> Response in
            try await respond(headers: { $0.headers }) {
                try assignments.listServerTasks(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    rawQuery: request.url.query
                )
            }
        }
}

}

/// Vapor's pinned HTTPTypes bridge does not retain HTTP/1 Host as a field.
/// The native listener address supplies its actual origin when no configured
/// server URL or forwarded development origin applies.
private func attachmentRequestHost(_ request: Request) -> String? {
    if let host = request.headers[HTTPField.Name("Host")!], !host.isEmpty { return host }
    guard let address = request.localAddress, let ip = address.host, let port = address.port else { return nil }
    var origin = URLComponents()
    origin.host = ip
    origin.port = port
    guard let authority = origin.string, authority.hasPrefix("//") else { return nil }
    return String(authority.dropFirst(2))
}

/// The prefix gate is the sole producer; missing wiring fails closed.
private func requireAttachmentFlexContext(_ request: Request) throws -> AttachmentFlexAdmission {
    guard let admission = request.auth.get(AttachmentFlexContext.self)?.admission else {
        throw AttachmentFlexAdmissionError.authenticationRequired
    }
    return admission
}
