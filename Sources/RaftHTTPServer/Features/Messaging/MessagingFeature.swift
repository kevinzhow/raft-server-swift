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
        let app = routes
        app.post("api", "read-mutations") { request -> Response in
            routeResponse(services.emailAccounts.postReadMutation(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.get("api", "read-mutations", "frontier") { request -> Response in
            routeResponse(services.emailAccounts.readMutationFrontier(
                authorization: request.headers[.authorization],
                scopeIds: desktopQuery(request.url.query, "scopeIds")
            ))
        }
        app.post("api", "messages", "mention-actions", "execute") { request -> Response in
            routeResponse(services.emailAccounts.executeMentionActions(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.post("api", "messages") { request -> Response in
            // requireAuth runs before the body check. An invalid body writes nothing.
            routeResponse(services.emailAccounts.createHumanMessage(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.get("api", "messages", "forward", "targets", "search") { request -> Response in
            routeResponse(services.emailAccounts.searchForwardTargets(
                query: desktopQuery(request.url.query, "q"),
                limit: desktopQuery(request.url.query, "limit"),
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.get("api", "messages", "forward", "enabled") { request -> Response in
            routeResponse(services.emailAccounts.messageForwardEnabled(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.get("api", "attachments", ":id", "url") { request -> Response in
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
        app.post("api", "messages", "forward") { request -> Response in
            routeResponse(services.emailAccounts.forwardHumanMessage(
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.get("api", "messages", ":messageId", "mention-deliveries") { request -> Response in
            routeResponse(services.emailAccounts.mentionDeliveries(
                messageId: request.parameters.get("messageId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.get("api", "messages", ":messageId", "reactions", "actors") { request -> Response in
            routeResponse(services.emailAccounts.listReactionActors(
                messageId: request.parameters.get("messageId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                emoji: desktopQuery(request.url.query, "emoji"),
                limit: desktopQuery(request.url.query, "limit"),
                cursor: desktopQuery(request.url.query, "cursor")
            ))
        }
        app.get("api", "messages", ":messageId", "reactions", "viewer") { request -> Response in
            routeResponse(services.emailAccounts.reactionViewer(
                messageId: request.parameters.get("messageId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.post("api", "messages", ":messageId", "reactions") { request -> Response in
            routeResponse(services.emailAccounts.addMessageReaction(
                messageId: request.parameters.get("messageId") ?? "",
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.delete("api", "messages", ":messageId", "reactions") { request -> Response in
            routeResponse(services.emailAccounts.removeMessageReaction(
                messageId: request.parameters.get("messageId") ?? "",
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.get("api", "messages", "channel", ":channelId") { request -> Response in
            routeResponse(services.emailAccounts.listChannelMessages(
                channelId: request.parameters.get("channelId") ?? "",
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                limit: desktopQuery(request.url.query, "limit"),
                before: desktopQuery(request.url.query, "before"),
                after: desktopQuery(request.url.query, "after")
            ))
        }
        app.get("api", "attachments", "comments", "counts") { request -> Response in
            routeResponse(services.emailAccounts.attachmentCommentCounts(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? desktopQuery(request.url.query, "server_id") ?? "",
                ids: desktopQuery(request.url.query, "ids")
            ))
        }
        app.get("api", "attachments", ":id", "comments") { request -> Response in
            routeResponse(services.emailAccounts.attachmentCommentsList(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                attachmentId: request.parameters.get("id") ?? ""
            ))
        }
        app.post("api", "attachments", ":id", "comments") { request -> Response in
            routeResponse(services.emailAccounts.createAttachmentComment(
                authorization: request.headers[.authorization],
                attachmentId: request.parameters.get("id") ?? "",
                body: request.body.string ?? "{}",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!]
            ))
        }
        app.post("api", "actions", "migration-export") { _ -> Response in
            routeResponse(HTTPReply(
                status: 410,
                headers: ["Content-Type": "application/json", "Content-Length": "76"],
                body: "{\"error\":\"Migration action cards are no longer supported\",\"code\":\"migration_action_card_not_supported\"}"
            ))
        }
        app.post("api", "actions", ":messageId", "execute") { request -> Response in
            routeResponse(services.emailAccounts.executeActionCard(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                messageId: request.parameters.get("messageId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.post("api", "actions", ":messageId", "mark-executed") { request -> Response in
            routeResponse(services.emailAccounts.markActionCardExecuted(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                messageId: request.parameters.get("messageId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.get("api", "messages", "sync") { request -> Response in
            routeResponse(services.emailAccounts.syncChannelMessages(
                channelId: desktopQuery(request.url.query, "channel_id"),
                sinceSeq: desktopQuery(request.url.query, "since_seq"),
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                limit: desktopQuery(request.url.query, "limit")
            ))
        }
        app.get("api", "messages", "search") { request -> Response in
            routeResponse(services.emailAccounts.searchHumanMessages(
                query: desktopQuery(request.url.query, "q"),
                sort: desktopQuery(request.url.query, "sort"),
                limit: desktopQuery(request.url.query, "limit"),
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!],
                channelId: desktopQuery(request.url.query, "channelId"),
                senderId: desktopQuery(request.url.query, "senderId"),
                senderType: desktopQuery(request.url.query, "senderType"),
                mentionTarget: desktopQuery(request.url.query, "mentionTarget")
            ))
        }
        app.get("api", "messages", "context", ":messageId") { request -> Response in
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
               let stored = services.emailAccounts.humanMessageContext(
                   messageId: messageId,
                   channelId: channelId,
                   authorization: authorization,
                   serverId: serverId,
                   before: desktopQuery(request.url.query, "before"),
                   after: desktopQuery(request.url.query, "after")
               ) {
                return routeResponse(stored)
            }
            return routeResponse(reply)
        }
        app.post("api", "attachments", "upload") { request async throws -> Response in
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
        app.post("api", "attachments", "upload-sessions") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionCreate(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.get("api", "attachments", "upload-sessions", ":uploadId") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
                authorization: request.headers[.authorization],
                uploadId: request.parameters.get("uploadId") ?? ""
            ))
        }
        app.delete("api", "attachments", "upload-sessions", ":uploadId") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
                authorization: request.headers[.authorization],
                uploadId: request.parameters.get("uploadId") ?? ""
            ))
        }
        app.post("api", "attachments", "upload-sessions", ":uploadId", "complete") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadSessionMissing(
                authorization: request.headers[.authorization],
                uploadId: request.parameters.get("uploadId") ?? ""
            ))
        }
        app.get("api", "attachments", "upload-capabilities") { request -> Response in
            routeResponse(services.emailAccounts.attachmentUploadCapabilities(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
            ))
        }
        app.get("api", "attachments", ":id") { request -> Response in
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
        app.get("api", "attachments", ":id", "html-preview") { request -> Response in
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
        app.get("api", "attachments", ":id", "html-preview-url") { request -> Response in
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
        app.get("api", "tasks", "server", "snapshot-metrics") { request -> Response in
            routeResponse(services.emailAccounts.taskSnapshotMetrics(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                rawQuery: request.url.query
            ))
        }
        app.get("api", "tasks", "server", "period-metrics") { request -> Response in
            routeResponse(services.emailAccounts.taskPeriodMetrics(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                rawQuery: request.url.query
            ))
        }
        app.get("api", "tasks", "channel", ":channelId") { request -> Response in
            routeResponse(services.emailAccounts.listChannelTasks(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                rawQuery: request.url.query
            ))
        }
        app.get("api", "tasks", "channel", ":channelId", "number", ":taskNumber") { request -> Response in
            routeResponse(services.emailAccounts.getChannelTaskByNumber(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                taskNumber: Int(request.parameters.get("taskNumber") ?? "") ?? 0
            ))
        }
        app.post("api", "tasks", "channel", ":channelId") { request -> Response in
            let channelId = request.parameters.get("channelId") ?? ""
            let body = request.body.string ?? ""
            let reply = services.emailAccounts.createChannelTasks(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                channelId: channelId,
                body: body
            )
            publishTaskCreated(reply, channelId: channelId, body: body, services: services)
            return routeResponse(reply)
        }
        app.delete("api", "tasks", ":taskId") { request -> Response in
            routeResponse(services.emailAccounts.deleteTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? ""
            ))
        }
        app.patch("api", "tasks", ":taskId", "assignee") { request -> Response in
            routeResponse(services.emailAccounts.assignTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.patch("api", "tasks", ":taskId", "unclaim") { request -> Response in
            routeResponse(services.emailAccounts.unclaimTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? ""
            ))
        }
        app.patch("api", "tasks", ":taskId", "claim") { request -> Response in
            let reply = services.emailAccounts.claimTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? ""
            )
            publishTaskUpdated(reply, services: services)
            return routeResponse(reply)
        }
        app.patch("api", "tasks", ":taskId", "status") { request -> Response in
            routeResponse(services.emailAccounts.updateTaskStatus(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                taskId: request.parameters.get("taskId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.post("api", "tasks", "convert-message") { request -> Response in
            routeResponse(services.emailAccounts.convertMessageToTask(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.get("api", "tasks", "server") { request -> Response in
            routeResponse(services.emailAccounts.listServerTasks(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                rawQuery: request.url.query
            ))
        }
}

}
// MARK: - File-private helpers copied verbatim from `FallbackApplication.swift`

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

private func publishTaskUpdated(_ reply: HTTPReply, services: FallbackServices) {
    guard reply.status == 200,
          let emit = services.emailAccounts.realtimeEmitter,
          let task = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any],
          let channelId = task["channelId"] as? String
    else { return }
    let taskJSON = String(decoding: reply.body.utf8, as: UTF8.self)
    emit("channel:\(channelId)", "task:updated", "{\"channelId\":\(jsonChannelString(channelId)),\"task\":\(taskJSON)}")
}

private func publishTaskCreated(
    _ reply: HTTPReply,
    channelId: String,
    body: String,
    services: FallbackServices
) {
    guard reply.status == 200,
          let emit = services.emailAccounts.realtimeEmitter,
          let response = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any],
          let ids = response["taskIds"] as? [String],
          let request = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
          let requested = request["tasks"] as? [[String: Any]]
    else { return }
    let titles = requested.compactMap { $0["title"] as? String }
    let tasks = zip(ids, titles).map { id, title in
        "{\"id\":\(jsonChannelString(id)),\"channelId\":\(jsonChannelString(channelId)),\"title\":\(jsonChannelString(title)),\"status\":\"todo\"}"
    }.joined(separator: ",")
    emit("channel:\(channelId)", "task:created", "{\"channelId\":\(jsonChannelString(channelId)),\"tasks\":[\(tasks)]}")
}

private func jsonChannelString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
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

private func httpStatus(_ code: Int) -> HTTPResponse.Status {
    switch code {
    case 200: .ok
    case 201: .created
    case 400: .badRequest
    case 401: .unauthorized
    case 403: .forbidden
    case 204: .noContent
    case 302: .found
    case 304: .notModified
    case 404: .notFound
    case 405: .methodNotAllowed
    case 409: .conflict
    case 410: .gone
    case 422: .unprocessableContent
    case 429: .tooManyRequests
    case 500: .internalServerError
    case 502: .badGateway
    case 503: .serviceUnavailable
    default: HTTPResponse.Status(code: code, reasonPhrase: "")
    }
}
