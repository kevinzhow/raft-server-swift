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
        let messageSend = MessageSendService(directory: services.emailAccounts)
        let humanMessageCreate = HumanMessageCreateService(directory: services.emailAccounts)
        let inboxRealtime = ReactionsRealtimeService(directory: services.emailAccounts)
        let inbox = services.emailAccounts.inboxAndWake
        readMutations.post { request async throws -> Response in
            // A typed body re-encodes through the DTO so the directory's
            // fingerprinting parser reads the same keys; a body that does not
            // decode keeps the raw path and its published error codes.
            if let body = try? await request.content.decode(ReadMutationAckRequestDTO.self) {
                return routeResponse(inboxRealtime.acknowledgeReadMutation(
                    body,
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                ))
            }
            return routeResponse(services.emailAccounts.postReadMutation(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText(default: "{}")
            ))
        }
        readMutations.get("frontier") { request -> Response in
            routeResponse(services.emailAccounts.readMutationFrontier(
                authorization: request.headers[.authorization],
                scopeIds: desktopQuery(request.url.query, "scopeIds")
            ))
        }
        messages.post("mention-actions", "execute") { request async throws -> Response in
            routeResponse(humanMessageCreate.executeMentionActions(
                body: try await request.bodyText(),
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        messages.post { request async throws -> Response in
            // requireAuth runs before the body check. An invalid body writes nothing.
            routeResponse(humanMessageCreate.createHumanMessage(
                body: try await request.bodyText(),
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        messages.get("forward", "targets", "search") { request -> Response in
            routeResponse(humanMessageCreate.searchForwardTargets(
                query: desktopQuery(request.url.query, "q"),
                limit: desktopQuery(request.url.query, "limit"),
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        messages.get("forward", "enabled") { request -> Response in
            routeResponse(humanMessageCreate.messageForwardEnabled(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        attachments.get(":id", "url") { request -> Response in
            if desktopQuery(request.url.query, "previewToken") != nil {
                return routeResponse(HTTPReply(status: 401, headers: [:], body: "{\"error\":\"Unauthorized\"}"))
            }
            let queryToken = desktopQuery(request.url.query, "token")
            let authorization = request.headers[.authorization] ?? queryToken.map { "Bearer \($0)" }
            return routeResponse(services.emailAccounts.attachmentDownloadURL(
                attachmentId: request.parameters.get("id") ?? "",
                authorization: authorization,
                serverId: desktopQuery(request.url.query, "serverId") ?? request.headers[HTTPField.Name("X-Server-Id")!],
                disposition: desktopQuery(request.url.query, "disposition"),
                download: desktopQuery(request.url.query, "download"),
                propagateQueryToken: queryToken
            ))
        }
        messages.post("forward") { request async throws -> Response in
            routeResponse(humanMessageCreate.forwardHumanMessage(
                body: try await request.bodyText(),
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
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
        messages.get(":messageId", "reactions", "actors") { request -> Response in
            routeResponse(services.emailAccounts.listReactionActors(
                messageId: request.parameters.get("messageId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                emoji: desktopQuery(request.url.query, "emoji"),
                limit: desktopQuery(request.url.query, "limit"),
                cursor: desktopQuery(request.url.query, "cursor")
            ))
        }
        messages.get(":messageId", "reactions", "viewer") { request -> Response in
            routeResponse(services.emailAccounts.reactionViewer(
                messageId: request.parameters.get("messageId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        messages.post(":messageId", "reactions") { request async throws -> Response in
            let messageId = request.parameters.get("messageId") ?? ""
            let authorization = request.headers[.authorization]
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!]
            // `emoji` is the only key this route reads, so a decoded body is
            // re-encoded for the directory's reaction parser. Every other shape
            // keeps the raw body.
            if let body = try? await request.content.decode(ReactionMutationRequestDTO.self) {
                return routeResponse(messageSend.addMessageReaction(
                    messageId: messageId,
                    body: body,
                    authorization: authorization,
                    serverId: serverId
                ))
            }
            return routeResponse(services.emailAccounts.addMessageReaction(
                messageId: messageId,
                body: try await request.bodyText(),
                authorization: authorization,
                serverId: serverId
            ))
        }
        messages.delete(":messageId", "reactions") { request async throws -> Response in
            let messageId = request.parameters.get("messageId") ?? ""
            let authorization = request.headers[.authorization]
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!]
            if let body = try? await request.content.decode(ReactionMutationRequestDTO.self) {
                return routeResponse(messageSend.removeMessageReaction(
                    messageId: messageId,
                    body: body,
                    authorization: authorization,
                    serverId: serverId
                ))
            }
            return routeResponse(services.emailAccounts.removeMessageReaction(
                messageId: messageId,
                body: try await request.bodyText(),
                authorization: authorization,
                serverId: serverId
            ))
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
        attachments.get("comments", "counts") { request -> Response in
            routeResponse(services.emailAccounts.attachmentCommentCounts(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? desktopQuery(request.url.query, "server_id") ?? "",
                ids: desktopQuery(request.url.query, "ids")
            ))
        }
        attachments.get(":id", "comments") { request -> Response in
            routeResponse(services.emailAccounts.attachmentCommentsList(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                attachmentId: request.parameters.get("id") ?? ""
            ))
        }
        attachments.post(":id", "comments") { request async throws -> Response in
            routeResponse(services.emailAccounts.createAttachmentComment(
                authorization: request.headers[.authorization],
                attachmentId: request.parameters.get("id") ?? "",
                body: try await request.bodyText(default: "{}"),
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        actions.post("migration-export") { _ -> Response in
            routeResponse(HTTPReply(
                status: 410,
                headers: ["Content-Type": "application/json", "Content-Length": "76"],
                body: "{\"error\":\"Migration action cards are no longer supported\",\"code\":\"migration_action_card_not_supported\"}"
            ))
        }
        actions.post(":messageId", "execute") { request async throws -> Response in
            routeResponse(services.emailAccounts.executeActionCard(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                messageId: request.parameters.get("messageId") ?? "",
                body: try await request.bodyText()
            ))
        }
        actions.post(":messageId", "mark-executed") { request async throws -> Response in
            let body = (try? await request.content.decode(MarkActionCardExecutedRequest.self))
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
        }
        attachments.post("upload") { request async throws -> Response in
            guard let contentType = request.headers[.contentType],
                  let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                  !boundary.isEmpty
            else {
                return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
            }
            let buffer = try await request.body.collect(max: .specified(ByteCount(value: 300 * 1024 * 1024)))
            guard let buffer, let parsed = parseAttachmentMultipart(data: buffer, boundary: boundary) else {
                return routeResponse(HTTPReply(status: 400, headers: [:], body: "{\"error\":\"Invalid multipart upload\"}"))
            }
            return routeResponse(services.emailAccounts.uploadAttachments(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: parsed.channelId,
                files: parsed.files.map { (filename: $0.filename, mimeType: $0.mimeType, sizeBytes: $0.sizeBytes) }
            ))
        }
        attachments.post("upload-sessions") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionCreate(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        attachments.get("upload-sessions", ":uploadId") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
                authorization: request.headers[.authorization],
                uploadId: request.parameters.get("uploadId") ?? ""
            ))
        }
        attachments.delete("upload-sessions", ":uploadId") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
                authorization: request.headers[.authorization],
                uploadId: request.parameters.get("uploadId") ?? ""
            ))
        }
        attachments.post("upload-sessions", ":uploadId", "complete") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
                authorization: request.headers[.authorization],
                uploadId: request.parameters.get("uploadId") ?? ""
            ))
        }
        attachments.get("upload-capabilities") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadCapabilities(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        attachments.get(":id") { request -> Response in
            if desktopQuery(request.url.query, "previewToken") != nil {
                return routeResponse(HTTPReply(status: 401, headers: [:], body: "{\"error\":\"Unauthorized\"}"))
            }
            if request.headers[.authorization] == nil, desktopQuery(request.url.query, "token") != nil {
                return routeResponse(services.emailAccounts.attachmentQueryTokenStream(
                    attachmentId: request.parameters.get("id") ?? "",
                    token: desktopQuery(request.url.query, "token") ?? "",
                    serverId: desktopQuery(request.url.query, "serverId")
                ))
            }
            return routeResponse(services.emailAccounts.readAttachment(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                attachmentId: request.parameters.get("id") ?? "",
                kind: "metadata"
            ))
        }
        attachments.get(":id", "html-preview") { request -> Response in
            let reply = services.emailAccounts.attachmentHTMLPreview(
                attachmentId: request.parameters.get("id") ?? "",
                serverId: desktopQuery(request.url.query, "serverId") ?? request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                previewToken: desktopQuery(request.url.query, "previewToken"),
                bearerQuery: desktopQuery(request.url.query, "token")
            )
            // The preview streams the stored document plus the appended bridge, so
            // it must not carry the stored Content-Length.
            if reply.status == 200 { return vaporStreamingResponse(reply) }
            return routeResponse(reply)
        }
        attachments.get(":id", "html-preview-url") { request -> Response in
            if desktopQuery(request.url.query, "previewToken") != nil {
                return routeResponse(HTTPReply(status: 401, headers: [:], body: "{\"error\":\"Unauthorized\"}"))
            }
            return routeResponse(services.emailAccounts.readAttachment(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                attachmentId: request.parameters.get("id") ?? "",
                kind: "html-preview-url"
            ))
        }
        tasks.get("server", "snapshot-metrics") { request -> Response in
            routeResponse(services.emailAccounts.taskSnapshotMetrics(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                rawQuery: request.url.query
            ))
        }
        tasks.get("server", "period-metrics") { request -> Response in
            routeResponse(services.emailAccounts.taskPeriodMetrics(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                rawQuery: request.url.query
            ))
        }
        tasks.get("channel", ":channelId") { request -> Response in
            routeResponse(services.emailAccounts.listChannelTasks(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                rawQuery: request.url.query
            ))
        }
        tasks.get("channel", ":channelId", "number", ":taskNumber") { request -> Response in
            routeResponse(services.emailAccounts.getChannelTaskByNumber(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                taskNumber: Int(request.parameters.get("taskNumber") ?? "") ?? 0
            ))
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
        tasks.delete(":taskId") { request -> Response in
            routeResponse(services.emailAccounts.deleteTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? ""
            ))
        }
        tasks.patch(":taskId", "assignee") { request async throws -> Response in
            routeResponse(services.emailAccounts.assignTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? "",
                body: try await request.bodyText()
            ))
        }
        tasks.patch(":taskId", "unclaim") { request -> Response in
            routeResponse(services.emailAccounts.unclaimTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? ""
            ))
        }
        tasks.patch(":taskId", "claim") { request -> Response in
            let reply = services.emailAccounts.claimTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? ""
            )
            services.channelMessaging.publishTaskUpdated(status: reply.status, replyBody: reply.body)
            return routeResponse(reply)
        }
        tasks.patch(":taskId", "status") { request async throws -> Response in
            let taskId = request.parameters.get("taskId") ?? ""
            let authorization = request.headers[.authorization]
            let serverId = request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            // `status` is the only key this route reads; an unknown value still
            // answers the directory's `Invalid task status` 400.
            if let body = try? await request.content.decode(TaskStatusUpdateRequestDTO.self) {
                return routeResponse(services.emailAccounts.updateTaskStatus(
                    authorization: authorization,
                    serverId: serverId,
                    taskId: taskId,
                    body: body.encodedBody()
                ))
            }
            return routeResponse(services.emailAccounts.updateTaskStatus(
                authorization: authorization,
                serverId: serverId,
                taskId: taskId,
                body: try await request.bodyText()
            ))
        }
        tasks.post("convert-message") { request async throws -> Response in
            routeResponse(services.emailAccounts.convertMessageToTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: try await request.bodyText()
            ))
        }
        tasks.get("server") { request -> Response in
            routeResponse(services.emailAccounts.listServerTasks(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                rawQuery: request.url.query
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

private func vaporStreamingResponse(_ reply: HTTPReply) -> Response {
    var headers = HTTPFields()
    for (name, value) in reply.headers {
        guard let field = HTTPField.Name(name) else { continue }
        if field == .contentLength { continue }
        headers[field] = value
    }
    var response = Response(status: httpStatus(reply.status), headers: headers)
    let body = reply.body
    response.body = Response.Body { writer in
        try await writer.write(body)
    }
    return response
}
