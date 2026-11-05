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
        app.get("internal", "agent", ":agentId", "reminders") { request -> Response in
            routeResponse(services.emailAccounts.legacyReminderList(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                status: desktopQuery(request.url.query, "status")
            ))
        }
        app.post("internal", "agent", ":agentId", "reminders") { request -> Response in
            let agentId = request.parameters.get("agentId") ?? ""
            let reply = services.emailAccounts.legacyReminderCreate(
                authorization: request.headers[.authorization],
                agentId: agentId,
                body: request.body.string ?? "{}"
            )
            if let reminderId = reminderIdFromReply(reply) {
                publishReminderEvent(reply, event: "reminder:scheduled", reminderId: reminderId, agentId: agentId, services: services)
            }
            return routeResponse(reply)
        }
        app.delete("internal", "agent", ":agentId", "reminders", ":reminderId") { request -> Response in
            routeResponse(services.emailAccounts.legacyReminderCancel(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                reminderId: request.parameters.get("reminderId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "agent", ":agentId", "reminders", ":reminderId", "snooze") { request -> Response in
            routeResponse(services.emailAccounts.legacyReminderSnooze(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                reminderId: request.parameters.get("reminderId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.patch("internal", "agent", ":agentId", "reminders", ":reminderId") { request -> Response in
            routeResponse(services.emailAccounts.legacyReminderUpdate(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                reminderId: request.parameters.get("reminderId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.get("internal", "agent", ":agentId", "reminders", ":reminderId", "log") { request -> Response in
            routeResponse(services.emailAccounts.legacyReminderLog(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                reminderId: request.parameters.get("reminderId") ?? ""
            ))
        }
        app.post("internal", "agent", ":agentId", "send") { request -> Response in
            routeResponse(services.emailAccounts.agentSend(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.post("internal", "agent", ":agentId", "receive-ack") { request -> Response in
            routeResponse(services.emailAccounts.legacyAgentReceiveAck(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "agent", ":agentId", "runtime-profile", "migration-done") { request -> Response in
            routeResponse(services.emailAccounts.runtimeProfileMigrationDone(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.get("internal", "agent", ":agentId", "server") { request -> Response in
            routeResponse(services.emailAccounts.agentServerInfo(
                authorization: request.headers[.authorization],
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.patch("internal", "agent", ":agentId", "server") { request -> Response in
            routeResponse(services.emailAccounts.agentUpdateServer(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.post("internal", "agent", ":agentId", "channels") { request -> Response in
            routeResponse(services.emailAccounts.agentCreateChannel(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.patch("internal", "agent", ":agentId", "channels", ":channelId") { request -> Response in
            routeResponse(services.emailAccounts.agentUpdateChannel(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.post("internal", "agent", ":agentId", "channels", ":channelId", "members") { request -> Response in
            routeResponse(services.emailAccounts.agentChannelMemberWrite(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? "{}",
                remove: false,
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.delete("internal", "agent", ":agentId", "channels", ":channelId", "members") { request -> Response in
            routeResponse(services.emailAccounts.agentChannelMemberWrite(
                authorization: request.headers[.authorization],
                channelId: request.parameters.get("channelId") ?? "",
                body: request.body.string ?? "{}",
                remove: true,
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.post("internal", "agent", ":agentId", "channels", ":channelId", "join") { request -> Response in
            routeResponse(services.emailAccounts.agentChannelMembershipFromMachine(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                join: true
            ))
        }
        app.post("internal", "agent", ":agentId", "channels", ":channelId", "leave") { request -> Response in
            routeResponse(services.emailAccounts.agentChannelMembershipFromMachine(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                channelId: request.parameters.get("channelId") ?? "",
                join: false
            ))
        }
        app.get("internal", "agent", ":agentId", "channel-members") { request -> Response in
            routeResponse(services.emailAccounts.agentChannelMembers(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId"),
                channelRef: desktopQuery(request.url.query, "channel"),
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.get("internal", "agent", ":agentId", "history") { request -> Response in
            routeResponse(services.emailAccounts.agentHistory(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId"),
                channelRef: desktopQuery(request.url.query, "channel"),
                before: desktopQuery(request.url.query, "before"),
                after: desktopQuery(request.url.query, "after"),
                around: desktopQuery(request.url.query, "around"),
                limit: desktopQuery(request.url.query, "limit"),
                consume: desktopQuery(request.url.query, "consume")
            ))
        }
        app.post("internal", "agent", ":agentId", "tasks") { request -> Response in
            routeResponse(services.emailAccounts.agentTasksCreate(
                authorization: request.headers[.authorization],
                legacyAgentId: request.parameters.get("agentId"),
                body: request.body.string ?? ""
            ))
        }
        app.post("internal", "agent", ":agentId", "tasks", "claim") { request -> Response in
            routeResponse(services.emailAccounts.agentTaskClaim(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId")
            ))
        }
        app.post("internal", "agent", ":agentId", "tasks", "update-status") { request -> Response in
            routeResponse(services.emailAccounts.agentTaskUpdateStatus(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId")
            ))
        }
        app.post("internal", "agent", ":agentId", "tasks", "delete") { request -> Response in
            routeResponse(services.emailAccounts.agentTaskDelete(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId")
            ))
        }
        app.post("internal", "agent", ":agentId", "tasks", "convert") { request -> Response in
            routeResponse(services.emailAccounts.agentTaskConvert(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId")
            ))
        }
        app.post("internal", "agent", ":agentId", "messages", ":messageId", "reactions") { request -> Response in
            routeResponse(services.emailAccounts.mutateAgentMessageReaction(
                agentId: request.parameters.get("agentId") ?? "",
                messageId: request.parameters.get("messageId") ?? "",
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                remove: false
            ))
        }
        app.delete("internal", "agent", ":agentId", "messages", ":messageId", "reactions") { request -> Response in
            routeResponse(services.emailAccounts.mutateAgentMessageReaction(
                agentId: request.parameters.get("agentId") ?? "",
                messageId: request.parameters.get("messageId") ?? "",
                body: request.body.string ?? "",
                authorization: request.headers[.authorization],
                remove: true
            ))
        }
        app.post("internal", "agent", ":agentId", "threads", "unfollow") { request -> Response in
            routeResponse(services.emailAccounts.agentThreadUnfollow(
                authorization: request.headers[.authorization],
                body: request.body.string ?? "{}",
                legacyAgentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.get("internal", "agent", ":agentId", "search") { request -> Response in
            routeResponse(services.emailAccounts.searchAgentMessages(
                agentId: request.parameters.get("agentId") ?? "",
                query: desktopQuery(request.url.query, "q"),
                limit: desktopQuery(request.url.query, "limit"),
                authorization: request.headers[.authorization],
                sender: desktopQuery(request.url.query, "sender"),
                after: desktopQuery(request.url.query, "after"),
                before: desktopQuery(request.url.query, "before"),
                sort: desktopQuery(request.url.query, "sort")
            ))
        }
        app.post("internal", "computer", "preflight") { request -> Response in
            routeResponse(services.emailAccounts.computerPreflight(
                authorization: request.headers[.authorization],
                surface: internalSurface.value
            ))
        }
        app.post("internal", "agent", ":agentId", "upload") { request async throws -> Response in
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
            return routeResponse(services.emailAccounts.uploadAgentAttachment(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                channelId: parsed.channelId,
                filename: file.filename,
                mimeType: file.mimeType,
                sizeBytes: file.sizeBytes
            ))
        }
        app.post("internal", "machine", "scope-attestation") { request -> Response in
            routeResponse(services.emailAccounts.machineScopeAttestation(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        app.post("internal", "computer", "attachment", "revoke") { _ -> Response in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .unauthorized, headers: headers, body: .init(string: "{\"error\":\"Authentication policy not registered for this path\",\"code\":\"auth_policy_unregistered_path\"}"))
        }
        app.post("internal", "computer", "runners", ":agentId", "credentials") { request -> Response in
            routeResponse(services.emailAccounts.computerMintRunnerCredential(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                body: request.body.string ?? ""
            ))
        }
        app.delete("internal", "computer", "runners", ":agentId", "credentials", ":credentialId") { request -> Response in
            routeResponse(services.emailAccounts.computerRevokeRunnerCredential(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? "",
                credentialId: request.parameters.get("credentialId") ?? ""
            ))
        }
        app.post("internal", "computer", "runners", ":agentId", "stop") { request -> Response in
            routeResponse(services.emailAccounts.computerStopRunner(
                authorization: request.headers[.authorization],
                agentId: request.parameters.get("agentId") ?? ""
            ))
        }
        app.get("internal", "computer", "runners") { request -> Response in
            routeResponse(services.emailAccounts.computerRunners(
                authorization: request.headers[.authorization],
                scope: desktopQuery(request.url.query, "scope")
            ))
        }
        // The resumable control manifest is the one JSON surface allowed past the
        // 100 KB global parser: 512 KB manifest plus envelope headroom.
        app.on(.post, "internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "control", maxBodySize: "640kb") { request -> Response in
            routeResponse(services.emailAccounts.putMigrationControlManifest(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.get("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "control") { request -> Response in
            routeResponse(services.emailAccounts.getMigrationControlManifest(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? ""
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "chunks", ":chunkIndex", "receipt") { request -> Response in
            routeResponse(services.emailAccounts.putMigrationChunkReceipt(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                chunkIndex: Int(request.parameters.get("chunkIndex") ?? "") ?? -1,
                body: request.body.string ?? "{}"
            ))
        }
        app.get("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "chunks") { request -> Response in
            routeResponse(services.emailAccounts.migrationChunkStatus(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? ""
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "upload-complete") { request -> Response in
            routeResponse(services.emailAccounts.completeMigrationUpload(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? ""
            ))
        }
        app.get("internal", "computer", "agent-migrations", "by-id", ":migrationId") { request -> Response in
            routeResponse(services.emailAccounts.getMigrationTargetView(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? ""
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "start-transfer") { request -> Response in
            routeResponse(services.emailAccounts.startMigrationTransfer(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "flip-machine") { request -> Response in
            routeResponse(services.emailAccounts.flipMigrationMachine(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "arrived") { request async -> Response in
            routeResponse(await services.emailAccounts.completeMigrationArrival(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "transport-lost") { request -> Response in
            routeResponse(services.emailAccounts.markMigrationTransportLostFromComputer(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "cancel-ack") { request -> Response in
            routeResponse(services.emailAccounts.acknowledgeMigrationCancellation(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "source-quiesced") { request -> Response in
            routeResponse(services.emailAccounts.recordMigrationSourceQuiesced(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        app.post("internal", "computer", "agent-migrations", "by-id", ":migrationId", "resumable", "source-progress") { request -> Response in
            routeResponse(services.emailAccounts.recordMigrationSourceProgress(
                authorization: request.headers[.authorization],
                migrationRef: request.parameters.get("migrationId") ?? "",
                body: request.body.string ?? "{}"
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
