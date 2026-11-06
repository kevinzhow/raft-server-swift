import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App integrations and agent app access: setup declarations, marketplace
/// installs, agent grants, attachment comments and the agent integration
/// app surfaces.
///
/// These handlers were lifted from
/// `EmailLogin+IntegrationsAndAccess.swift`.

public struct IntegrationsAndAppAccessService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    /// `GET /api/integrations/clients/:clientId/setup`. Reading or visiting the
    /// setup link never completes setup and never changes grants; only
    /// owner/admin see the destination URL.
    public func integrationClientSetup(authorization: String?, serverId: String, clientId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let recordId = oauth.setupClientRecordId(serverId: serverId, clientKey: clientId),
              let state = oauth.getAppInstallationSetup(clientRecordId: recordId, serverId: serverId)
        else {
            return Self.json(404, "{\"error\":\"Active installation not found\"}")
        }
        let canConfigure = role == "owner" || role == "admin"
        let url = canConfigure ? state.url : nil
        let description = canConfigure ? state.description : nil
        let body = "{\"status\":\(jsonString(state.status.rawValue)),\"url\":\(url.map(jsonString) ?? "null"),\"description\":\(description.map(jsonString) ?? "null"),\"revision\":\(state.revision),\"completedAt\":\(state.completedAt.map(jsonString) ?? "null"),\"canConfigure\":\(canConfigure ? "true" : "false")}"
        return Self.jsonNoStore(200, body)
    }

    /// `PATCH /api/integrations/clients/:clientId`: the owning App's Server
    /// owner/admin edits the setup declaration. A changed setup URL is a new
    /// revision; wording-only changes do not require configuration again.
    public func updateIntegrationClientSetup(authorization: String?, serverId: String, clientId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can change app setup\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid request body\"}")
        }
        guard let recordId = oauth.setupClientRecordId(serverId: serverId, clientKey: clientId) else {
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        do {
            try oauth.updateClientSetupDeclaration(
                clientRecordId: recordId,
                setupUrl: object["setupUrl"] as? String,
                setupDescription: object["setupDescription"] as? String
            )
        } catch let error as AppSetupValidationError {
            return Self.json(400, "{\"error\":\(jsonString(error.message)),\"errorCode\":\"INVALID_APP_METADATA\"}")
        } catch {
            return Self.json(400, "{\"error\":\"Invalid app metadata\",\"errorCode\":\"INVALID_APP_METADATA\"}")
        }
        let declaration = oauth.clientSetupDeclarationForTesting(clientRecordId: recordId)
        let body = "{\"clientId\":\(jsonString(clientId)),\"setupUrl\":\(declaration?.url.map(jsonString) ?? "null"),\"setupDescription\":\(declaration?.description.map(jsonString) ?? "null"),\"setupRevision\":\(declaration?.revision ?? 1)}"
        return Self.json(200, body)
    }

    /// `PUT /api/oauth/installations/:installationId/setup`. Only the owning
    /// App's backend can report; human login is not App authentication.
    public func reportInstallationSetup(authorization: String?, installationId: String, body: String) -> HTTPReply {
        // This surface takes App backend credentials only; a human session is
        // not App authentication.
        if let authorization, !authorization.isEmpty {
            return Self.json(401, "{\"error\":\"Installation setup reports require App credentials\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let clientKey = object["clientId"] as? String,
              let clientSecret = object["clientSecret"] as? String,
              let revision = object["revision"] as? Int,
              let status = object["status"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid setup report\"}")
        }
        guard status == "pending" || status == "complete" else {
            return Self.json(400, "{\"error\":\"status must be pending or complete\"}")
        }
        guard let recordId = oauth.verifyClientSecret(clientKey: clientKey, clientSecret: clientSecret) else {
            return Self.json(401, "{\"error\":\"Invalid client credentials\"}")
        }
        do {
            guard let state = try oauth.updateAppInstallationSetup(
                clientRecordId: recordId, installationId: installationId, revision: revision, status: status
            ) else {
                return Self.json(404, "{\"error\":\"Active installation not found\"}")
            }
            let body = "{\"status\":\(jsonString(state.status.rawValue)),\"url\":\(state.url.map(jsonString) ?? "null"),\"description\":\(state.description.map(jsonString) ?? "null"),\"revision\":\(state.revision),\"completedAt\":\(state.completedAt.map(jsonString) ?? "null")}"
            return Self.jsonNoStore(200, body)
        } catch is OAuthLedger.AppSetupConflictError {
            return Self.json(409, "{\"error\":\"Setup declaration changed; read current setup state before reporting completion\"}")
        } catch {
            return Self.json(400, "{\"error\":\"Invalid setup report\"}")
        }
    }

    /// `POST /api/integrations/marketplace/:clientId/install` for the target Server.
    public func installMarketplaceClient(authorization: String?, serverId: String, clientId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can install apps\"}")
        }
        let recordId: String
        if oauth.marketplaceInstallableClient(recordId: clientId) != nil {
            recordId = clientId
        } else if let direct = oauth.clientRecordIdForServer(serverId: serverId, clientKey: clientId) {
            recordId = direct
        } else {
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        let installationId = oauth.installClient(serverId: serverId, clientRecordId: recordId, installedByUserId: userId, groups: [])
        let state = oauth.getAppInstallationSetup(clientRecordId: recordId, serverId: serverId)
        return Self.json(200, "{\"id\":\(jsonString(installationId)),\"setup\":{\"status\":\(jsonString(state?.status.rawValue ?? "not_required")),\"revision\":\(state?.revision ?? 1)}}")
    }

    /// `DELETE /api/integrations/marketplace/:clientId/install`.
    public func uninstallMarketplaceClient(authorization: String?, serverId: String, clientId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can uninstall apps\"}")
        }
        guard let recordId = oauth.setupClientRecordId(serverId: serverId, clientKey: clientId) else {
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        _ = oauth.uninstallClient(serverId: serverId, clientRecordId: recordId)
        return Self.json(200, "{\"ok\":true}")
    }

    public func approveAgentAccessRequest(authorization: String?, requestId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let reply = oauth.approveAgentAccessRequest(
            userId: userId, requestId: requestId, remember: object["remember"] as? Bool ?? false
        ) else {
            return Self.json(404, "{\"error\":\"Access request not found\"}")
        }
        return reply
    }

    public func createAgentGrant(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let clientRecordId = object["clientId"] as? String
        else {
            return Self.json(400, "{\"error\":\"clientId is required\"}")
        }
        let scopes = (object["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let result = oauth.createAgentGrant(userId: userId, agentId: agentId, clientRecordId: clientRecordId, scopes: scopes) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        switch result.status {
        case 403: return Self.json(403, "{\"error\":\"You cannot manage this agent's app access\"}")
        case 404: return Self.json(404, "{\"error\":\"Integration app not found for this server\"}")
        case 400: return Self.json(400, "{\"error\":\"invalid_scope\"}")
        default:
            return Self.json(result.status, "{\"grantId\":\(jsonString(result.grantId)),\"created\":\(result.created ? "true" : "false")}")
        }
    }

    public func revokeAgentGrant(authorization: String?, grantId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let reply = oauth.revokeAgentGrant(userId: userId, grantId: grantId) else {
            return Self.json(404, "{\"error\":\"Grant not found\"}")
        }
        return reply
    }

    public func agentGrantList(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let rows = oauth.agentGrantListVisible(userId: userId, agentId: agentId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), oauth.agentRole(serverId: agent.serverId, agentId: agentId) != nil else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        if rows.isEmpty, oauth.memberRole(serverId: agent.serverId, userId: userId) == nil,
           agent.creatorUserId != userId {
            return Self.json(403, "{\"error\":\"You cannot manage this agent's app access\"}")
        }
        let body = rows.map { row in
            "{\"id\":\(jsonString(row.id)),\"clientId\":\(jsonString(row.clientRecordId)),\"scopes\":[\(row.scopes.map(jsonString).joined(separator: ","))],\"grantSource\":\(jsonString(row.grantSource))}"
        }.joined(separator: ",")
        return Self.json(200, "[\(body)]")
    }

    public func agentGrantableApps(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let apps = oauth.grantableApps(userId: userId, agentId: agentId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        if apps.isEmpty, let agent = oauth.agentRuntimeInfo(id: agentId),
           oauth.memberRole(serverId: agent.serverId, userId: userId) == nil,
           agent.creatorUserId != userId {
            return Self.json(403, "{\"error\":\"You cannot manage this agent's app access\"}")
        }
        let body = apps.map { app in
            let scopes = app.scopes.map(jsonString).joined(separator: ",")
            return "{\"clientId\":\(jsonString(app.recordId)),\"clientKey\":\(jsonString(app.clientKey)),\"name\":\(jsonString(app.name)),\"scopes\":[\(scopes)]}"
        }.joined(separator: ",")
        return Self.json(200, "{\"apps\":[\(body)]}")
    }

    public func agentAppEvents(authorization: String?, agentId: String, limit: String?, before: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let parsedLimit: Int
        if let limit, !limit.isEmpty {
            guard let value = Int(limit), value > 0 else {
                return Self.json(400, "{\"error\":\"limit must be a positive integer\"}")
            }
            parsedLimit = value
        } else {
            parsedLimit = 50
        }
        switch oauth.agentAppEvents(userId: userId, agentId: agentId, limit: parsedLimit, before: before) {
        case .forbidden:
            return Self.json(403, "{\"error\":\"You cannot manage this agent's app access\"}")
        case .notFound:
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        case .invalidLimit:
            return Self.json(400, "{\"error\":\"limit must be a positive integer\"}")
        case .invalidCursor:
            return Self.json(400, "{\"error\":\"before is not a valid cursor\"}")
        case .events(let rows, let nextCursor):
            let eventsJSON = rows.map(Self.agentAppEventJSON).joined(separator: ",")
            let next = nextCursor.map(jsonString) ?? "null"
            return Self.json(200, "{\"events\":[\(eventsJSON)],\"nextCursor\":\(next)}")
        }
    }

    public func agentAppEventDetail(authorization: String?, agentId: String, eventId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        switch oauth.agentAppEventDetail(userId: userId, agentId: agentId, eventId: eventId) {
        case .forbidden:
            return Self.json(403, "{\"error\":\"You cannot manage this agent's app access\"}")
        case .notFound:
            return Self.json(404, "{\"error\":\"Event not found\"}")
        case .event(let event):
            let summary = Self.agentAppEventJSON(event)
            let payload = event.payloadJSON.isEmpty ? "null" : event.payloadJSON
            let detail = String(summary.dropLast()) + ",\"payload\":\(payload)}"
            return Self.json(200, detail)
        }
    }

    /// Feature flag gate shared by the attachment-comment routes. It answers
    /// before body validation so a disabled server sees one uniform 403.
    public func attachmentCommentsEnabled(serverId: String, userId: String? = nil) -> Bool {
        evaluateFeatureFlagKey(
            key: "attachment_comments_v0",
            userId: userId ?? "",
            serverId: serverId,
            platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        ).enabled
    }

    /// `GET /api/attachments/comments/counts`. Batch chip counts; only
    /// attachments the caller can read are counted.
    public func attachmentCommentCounts(authorization: String?, serverId: String, ids: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard attachmentCommentsEnabled(serverId: serverId, userId: userId) else { return Self.attachmentCommentsDisabledReply }
        let requested = (ids ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !requested.isEmpty, requested.count <= 100 else {
            return Self.json(400, "{\"error\":\"ids must contain 1-100 attachment ids\"}")
        }
        lock.lock()
        let candidates = requested.compactMap { id -> (String, ChannelAttachment)? in
            guard ServerScope.isUUID(id), let attachment = channelAttachments[id] else { return nil }
            return (id, attachment)
        }
        lock.unlock()
        lock.lock()
        var entries: [String] = []
        for (id, attachment) in candidates where visibleAttachmentUnlocked(userId: userId, serverId: serverId, attachment: attachment) {
            entries.append("\(jsonString(id)):\(attachmentCommentRecords[id]?.count ?? 0)")
        }
        lock.unlock()
        return Self.json(200, "{\"counts\":{\(entries.joined(separator: ","))}}")
    }

    /// `GET /api/attachments/:id/comments`: the scoped comment list plus the
    /// viewer write-state so the panel can gate affordances honestly.
    public func attachmentCommentsList(authorization: String?, serverId: String, attachmentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard attachmentCommentsEnabled(serverId: serverId, userId: userId) else { return Self.attachmentCommentsDisabledReply }
        guard ServerScope.isUUID(attachmentId) else {
            return Self.json(400, "{\"error\":\"A valid attachment id is required\",\"code\":\"invalid_attachment_id\"}")
        }
        lock.lock()
        let candidate = channelAttachments[attachmentId]
        lock.unlock()
        guard let attachment = candidate, visibleAttachment(userId: userId, serverId: serverId, attachment: attachment) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        lock.lock()
        let records = attachmentCommentRecords[attachmentId] ?? []
        let channel = postableChannels[attachment.channelId]
        let archived = oauth.channelArchivedAt(id: attachment.channelId) != nil
        let canPost = channel.map { channel in
            channel.kind == "channel"
                ? oauth.memberRole(serverId: serverId, userId: userId) != nil
                : channel.memberIds.contains(userId) || oauth.channelHumanIds(channelId: attachment.channelId).contains(userId)
        } ?? false
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let comments = records.sorted { $0.createdAt < $1.createdAt }.map { record -> String in
            let anchor = record.anchorJSON ?? "null"
            let senderName = accounts.values.first { $0.id == record.senderId }?.name ?? record.senderId
            return "{\"id\":\(jsonString(record.id)),\"attachmentId\":\(jsonString(record.attachmentId)),\"content\":\(jsonString(record.content)),\"anchor\":\(anchor),\"sender\":{\"type\":\(jsonString(record.senderType)),\"id\":\(jsonString(record.senderId)),\"name\":\(jsonString(senderName))},\"createdAt\":\(jsonString(formatter.string(from: record.createdAt))),\"reactions\":[]}"
        }
        lock.unlock()
        let viewer: String
        if archived {
            viewer = "{\"canComment\":false,\"reason\":\"archived\"}"
        } else if attachment.messageId == nil {
            viewer = "{\"canComment\":false,\"reason\":\"unlinked\"}"
        } else if canPost {
            viewer = "{\"canComment\":true,\"reason\":\"ok\"}"
        } else {
            viewer = "{\"canComment\":false,\"reason\":\"not_member\"}"
        }
        return Self.json(200, "{\"comments\":[\(comments.joined(separator: ","))],\"viewer\":\(viewer)}")
    }

    /// Canonical anchor projection for attachment comments: a closed type
    /// vocabulary, a payload cap measured before per-type validation, and a
    /// rebuild from known fields only (extras never reach storage).

    /// Strict structured-mention payload: the comment transport reuses the same
    /// wire shape as messages and rejects a malformed batch before any write.

    /// Scoped commentRef projection. Callers hold the directory lock. The chip
    /// payload carries the host coordinates the client routes with; it is only
    /// emitted to viewers who may see the scoped comment.
    /// Attachment projection with the scoped comment count; a viewer who cannot
    /// use attachment comments always observes zero, never a hint.
    func messageAttachmentsJSONLocked(_ ids: [String], commentsVisible: Bool) -> String {
        ids.map { id -> String in
            let count = commentsVisible ? (attachmentCommentRecords[id]?.count ?? 0) : 0
            return "{\"id\":\(jsonString(id)),\"commentCount\":\(count)}"
        }.joined(separator: ",")
    }

    func commentRefJSONLocked(messageId: String) -> String? {
        for (attachmentId, records) in attachmentCommentRecords {
            guard let record = records.first(where: { $0.id == messageId }),
                  let hostMessageId = record.hostMessageId,
                  let hostChannelId = record.hostChannelId
            else { continue }
            let threadJSON = record.threadChannelId.map(jsonString) ?? "null"
            return "{\"attachmentId\":\(jsonString(attachmentId)),\"hostMessageId\":\(jsonString(hostMessageId)),\"hostSource\":{\"type\":\"channel\",\"routeKind\":\"channel\",\"channelId\":\(jsonString(hostChannelId)),\"rootThreadChannelId\":\(threadJSON)}}"
        }
        return nil
    }

    public func createAttachmentComment(authorization: String?, attachmentId: String, body: String, serverId: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        // The feature gate answers before ANY body validation: a disabled
        // server must see one uniform 403 for every payload.
        if let serverId, !attachmentCommentsEnabled(serverId: serverId, userId: userId) {
            return Self.attachmentCommentsDisabledReply
        }
        guard ServerScope.isUUID(attachmentId) else {
            return Self.json(400, "{\"error\":\"A valid attachment id is required\",\"code\":\"invalid_attachment_id\"}")
        }
        lock.lock()
        guard let attachment = channelAttachments[attachmentId] else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        // An attachment the caller cannot see is the same neutral 404 as one
        // that does not exist, and that cloak runs before body validation.
        if let serverId, !visibleAttachmentUnlocked(userId: userId, serverId: serverId, attachment: attachment) {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        if attachment.messageId == nil {
            lock.unlock()
            return Self.json(422, "{\"error\":\"This attachment is not linked to a message\",\"code\":\"attachment_not_linked\"}")
        }
        if oauth.channelArchivedAt(id: attachment.channelId) != nil {
            lock.unlock()
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let canPost = postableChannels[attachment.channelId].map { channel in
            channel.kind == "channel"
                ? oauth.memberRole(serverId: channel.serverId, userId: userId) != nil
                : channel.memberIds.contains(userId) || oauth.channelHumanIds(channelId: attachment.channelId).contains(userId)
        } ?? false
        if !canPost {
            lock.unlock()
            return Self.json(403, "{\"error\":\"You must join this channel to comment\",\"code\":\"not_a_member\"}")
        }
        lock.unlock()
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let content = object["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.json(400, "{\"error\":\"content is required\"}")
        }
        // A comment is a normal message in the attachment host message's thread;
        // siblings under the same host share that thread. The directory lock is
        // not held across thread creation because those helpers take it.
        lock.lock()
        let hostChannelId = attachment.channelId
        let hostMessageId = attachment.messageId ?? ""
        let hostServerId = postableChannels[hostChannelId]?.serverId ?? ""
        let hostMembers = Array(postableChannels[hostChannelId]?.memberIds ?? [])
        lock.unlock()
        let threadChannelId: String = {
            guard !hostMessageId.isEmpty else { return hostChannelId }
            lock.lock()
            let existing = agentHistoryThread(parentId: hostChannelId, anchorMessageId: hostMessageId)
            lock.unlock()
            if let existing { return existing }
            let created = oauth.createThreadChannel(parentChannelId: hostChannelId, parentMessageId: hostMessageId)
            for member in hostMembers {
                addPostableChannel(
                    serverId: hostServerId,
                    channelId: created,
                    memberId: member,
                    kind: "thread",
                    parentChannelId: hostChannelId,
                    parentMessageId: hostMessageId,
                    name: "thread"
                )
            }
            addPostableChannel(
                serverId: hostServerId,
                channelId: created,
                memberId: userId,
                kind: "thread",
                parentChannelId: hostChannelId,
                parentMessageId: hostMessageId,
                name: "thread"
            )
            oauth.addChannelHuman(channelId: created, userId: userId)
            return created
        }()
        guard let commentMentions = Self.strictCommentMentions(object["mentions"]) else {
            return Self.json(400, "{\"error\":\"Invalid mentions payload\",\"code\":\"mentions_invalid\"}")
        }
        let anchorProjection = Self.canonicalCommentAnchor(object["anchor"])
        if let code = anchorProjection.code {
            return Self.json(400, "{\"error\":\"Invalid anchor\",\"code\":\"\(code)\"}")
        }
        let anchorJSON = anchorProjection.json
        lock.lock()
        let now = Date()
        let id = UUID().uuidString.lowercased()
        attachmentCommentRecords[attachmentId, default: []].append(AttachmentCommentRecord(
            id: id,
            attachmentId: attachmentId,
            content: content,
            anchorJSON: anchorJSON,
            senderId: userId,
            senderType: "user",
            createdAt: now,
            threadChannelId: threadChannelId,
            hostMessageId: hostMessageId,
            hostChannelId: hostChannelId
        ))
        appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: threadChannelId,
            senderId: userId,
            content: content,
            randomId: nil,
            messageType: "comment",
            senderType: "user",
            createdAt: now
        ))
        lock.unlock()
        if !commentMentions.isEmpty {
            recordMemberMentionRows(messageId: id, channelId: threadChannelId, mentions: commentMentions)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let anchorValue = anchorJSON ?? "null"
        return Self.json(200, "{\"message\":{\"id\":\(jsonString(id)),\"channelId\":\(jsonString(threadChannelId)),\"content\":\(jsonString(content)),\"senderType\":\"user\",\"createdAt\":\(jsonString(formatter.string(from: now))),\"anchor\":\(anchorValue),\"commentRef\":{\"attachmentId\":\(jsonString(attachmentId)),\"hostMessageId\":\(jsonString(hostMessageId)),\"hostSource\":{\"type\":\"channel\",\"routeKind\":\"channel\",\"channelId\":\(jsonString(hostChannelId)),\"rootThreadChannelId\":\(jsonString(threadChannelId))}}},\"threadChannelId\":\(jsonString(threadChannelId))}")
    }

    public func agentAttachmentCommentsList(authorization: String?, attachmentId: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
        }
        guard ServerScope.isUUID(attachmentId), let attachment = agentVisibleAttachment(agentId: agent.id, serverId: agent.serverId, attachmentId: attachmentId) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        lock.lock()
        let parentAuthor = attachment.messageId.flatMap { messageId in
            humanMessageRows.first { $0.id == messageId }?.senderId
        }
        let canResolve = parentAuthor == agent.id
        var commentRows: [String] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for comment in attachmentCommentRecords[attachmentId] ?? [] {
            let reaction = messageReactions.first {
                $0.messageId == comment.id && $0.emoji == "✅" && $0.reactorId == parentAuthor
            }
            let resolvedJSON = reaction == nil ? "false" : "true"
            var resolvedBy = "null"
            if let reaction {
                resolvedBy = "{\"reactorId\":\(jsonString(reaction.reactorId)),\"reactorType\":\(jsonString(reaction.reactorType))}"
            }
            var resolvedAt = "null"
            if reaction != nil {
                resolvedAt = jsonString(formatter.string(from: comment.createdAt))
            }
            let anchor = comment.anchorJSON ?? "null"
            commentRows.append("{\"id\":\(jsonString(comment.id)),\"content\":\(jsonString(comment.content)),\"senderType\":\(jsonString(comment.senderType)),\"anchor\":\(anchor),\"resolved\":\(resolvedJSON),\"resolvedBy\":\(resolvedBy),\"resolvedAt\":\(resolvedAt)}")
        }
        let comments = commentRows.joined(separator: ",")
        lock.unlock()
        let resolveAction = canResolve ? ",\"resolveAction\":{\"type\":\"reaction\",\"emoji\":\"✅\"}" : ""
        return Self.json(200, "{\"comments\":[\(comments)],\"viewer\":{\"canComment\":false,\"reason\":\"agent_descoped\",\"canResolve\":\(canResolve ? "true" : "false")\(resolveAction)}}")
    }

    public func agentAttachmentCommentCreate(authorization: String?, attachmentId: String) -> HTTPReply {
        guard agentCredentialAgent(authorization) != nil else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard ServerScope.isUUID(attachmentId) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        return Self.json(403, "{\"error\":\"Agents cannot create attachment comments\",\"code\":\"agent_comment_create_disabled\"}")
    }

    /// `whenToUse` is prompt material: one line, at most 160 code points, and
    /// no bare `@scope/pkg` outside inline code.
    static func normalizedWhenToUse(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.unicodeScalars.count <= 160 else {
            throw WhenToUseError.tooLong
        }
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw WhenToUseError.notSingleLine
        }
        var outsideCode = value
        outsideCode = outsideCode.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " ",
            options: .regularExpression
        )
        outsideCode = outsideCode.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        let bare = try! NSRegularExpression(pattern: "(^|[\\s(])@[a-z0-9][a-z0-9-]*/[a-z0-9._-]+", options: [.caseInsensitive])
        let range = NSRange(location: 0, length: (outsideCode as NSString).length)
        if bare.firstMatch(in: outsideCode, options: [], range: range) != nil {
            throw WhenToUseError.bareScopedPackage
        }
        return value
    }

    public func agentIntegrationAppUpdate(authorization: String?, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let clientKey = (object["clientKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"clientKey is required\",\"errorCode\":\"INVALID_APP_METADATA\"}")
        }
        let admin = oauth.agentRole(serverId: agent.serverId, agentId: agent.id) == "admin"
        guard oauth.ownedIntegrationApp(
            serverId: agent.serverId,
            agentId: agent.id,
            clientKey: clientKey,
            admin: admin
        ) != nil else {
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        guard let recordId = oauth.clientRecordId(serverId: agent.serverId, clientKey: clientKey) else {
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        var updatedFields: [String] = []
        if object.keys.contains("setupUrl") || object.keys.contains("setupDescription") {
            do {
                try oauth.updateClientSetupDeclaration(
                    clientRecordId: recordId,
                    setupUrl: object["setupUrl"] as? String ?? oauth.clientSetupDeclarationForTesting(clientRecordId: recordId)?.url,
                    setupDescription: object["setupDescription"] as? String ?? oauth.clientSetupDeclarationForTesting(clientRecordId: recordId)?.description
                )
                if object.keys.contains("setupUrl") { updatedFields.append("setupUrl") }
                if object.keys.contains("setupDescription") { updatedFields.append("setupDescription") }
            } catch {
                return Self.json(400, "{\"error\":\"Invalid app metadata\",\"errorCode\":\"INVALID_APP_METADATA\"}")
            }
        }
        if object.keys.contains("whenToUse") {
            do {
                let normalized = try Self.normalizedWhenToUse(object["whenToUse"] as? String)
                oauth.setClientWhenToUse(clientRecordId: recordId, whenToUse: normalized)
                updatedFields.append("whenToUse")
            } catch let error as WhenToUseError {
                return Self.json(400, "{\"error\":\(jsonString(error.message)),\"errorCode\":\"INVALID_APP_METADATA\"}")
            } catch {
                return Self.json(400, "{\"error\":\"Invalid app metadata\",\"errorCode\":\"INVALID_APP_METADATA\"}")
            }
        }
        let app = oauth.ownedIntegrationApp(serverId: agent.serverId, agentId: agent.id, clientKey: clientKey, admin: admin)
        let clientName = app?["name"] as? String ?? ""
        let fields = updatedFields.map(jsonString).joined(separator: ",")
        return Self.json(200, "{\"clientId\":\(jsonString(recordId)),\"clientKey\":\(jsonString(clientKey)),\"clientName\":\(jsonString(clientName)),\"updatedFields\":[\(fields)]}")
    }

    public func agentIntegrationAppList(authorization: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        let admin = oauth.agentRole(serverId: agent.serverId, agentId: agent.id) == "admin"
        let rows = oauth.ownedIntegrationApps(serverId: agent.serverId, agentId: agent.id, admin: admin)
        guard let data = try? JSONSerialization.data(withJSONObject: ["apps": rows], options: [.sortedKeys]) else {
            return Self.json(200, "{\"apps\":[]}")
        }
        return Self.json(200, String(decoding: data, as: UTF8.self))
    }

    public func agentIntegrationAppStatus(authorization: String?, client: String?, card: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        let clientKey = (client ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cardRef = (card ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientKey.isEmpty != cardRef.isEmpty else {
            return Self.json(400, "{\"error\":\"Exactly one of card or client is required\"}")
        }
        if !cardRef.isEmpty {
            // Registration cards are the only card-backed app state; until a
            // prepared card exists the reference is simply unknown.
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        let admin = oauth.agentRole(serverId: agent.serverId, agentId: agent.id) == "admin"
        guard let app = oauth.ownedIntegrationApp(
            serverId: agent.serverId,
            agentId: agent.id,
            clientKey: clientKey,
            admin: admin
        ) else {
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["app": app], options: [.sortedKeys]) else {
            return Self.json(404, "{\"error\":\"Integration app not found\"}")
        }
        return Self.json(200, String(decoding: data, as: UTF8.self))
    }

    public func agentIntegrationMarketplace(authorization: String?, query: String?, limit: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        var pageLimit = 20
        if let limit, !limit.isEmpty {
            guard let parsed = Int(limit), parsed >= 1, parsed <= 50 else {
                return Self.json(400, "{\"error\":\"limit must be between 1 and 50\"}")
            }
            pageLimit = parsed
        }
        let trimmedQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = oauth.marketplaceClients(serverId: agent.serverId, query: trimmedQuery).prefix(pageLimit)
        let appsJSON = apps.map { app -> String in
            func text(_ key: String) -> String {
                guard let raw = app[key], !(raw is NSNull) else { return "null" }
                return (raw as? String).map(jsonString) ?? "null"
            }
            let scopes = (app["allowedScopes"] as? [String] ?? []).map(jsonString).joined(separator: ",")
            return "{\"id\":\(text("id")),\"clientId\":\(text("clientId")),\"name\":\(text("name")),\"description\":\(text("description")),\"homepageUrl\":\(text("homepageUrl")),\"allowedScopes\":[\(scopes)],\"installedOnServer\":\((app["installedOnServer"] as? Bool == true) ? "true" : "false")}"
        }.joined(separator: ",")
        let queryJSON = trimmedQuery.isEmpty ? "null" : jsonString(trimmedQuery)
        return Self.json(200, "{\"surface\":\"public_marketplace\",\"metadataTrust\":\"untrusted_app_supplied\",\"query\":\(queryJSON),\"apps\":[\(appsJSON)]}")
    }

    public func agentIntegrationLogin(authorization: String?, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let serviceRef = object["service"] as? String, !serviceRef.isEmpty
        else {
            return Self.json(404, "{\"error\":\"Registered service not found\",\"code\":\"integration_not_found\"}")
        }
        let installedService = oauth.integrationLoginClient(serverId: agent.serverId, clientId: serviceRef)
        let publicService = installedService == nil ? oauth.publicIntegrationClient(clientId: serviceRef) : nil
        guard let service = installedService ?? publicService, let serviceId = service["id"] as? String else {
            return Self.json(404, "{\"error\":\"Registered service not found\",\"code\":\"integration_not_found\"}")
        }
        let defaultScopes: [String] = (service["allowedScopes"] as? [String]) == nil ? ["identity", "openid", "profile"] : ["openid"]
        let requestedScopes = (object["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        if !requestedScopes.isEmpty, !Set(requestedScopes).isSubset(of: Set(defaultScopes)) {
            return Self.json(400, "{\"error\":\"Scope is not allowed for this service\",\"errorCode\":\"INVALID_SCOPE\"}")
        }
        let effectiveScopes = requestedScopes.isEmpty ? defaultScopes : requestedScopes
        if installedService == nil {
            let profile = oauth.serverProfile(id: agent.serverId)
            let serverSlug = profile?.slug ?? ""
            let serverName = profile?.name ?? ""
            let marketplaceUrl = "/marketplace?marketplace_app=\(serviceId)"
            let scopesJSON = effectiveScopes.map(jsonString).joined(separator: ",")
            let requestedTarget = ((object["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var targetJSON = "null"
            var actionCardMessageIdJSON = "null"
            if !requestedTarget.isEmpty {
                guard let resolved = actionCardTarget(serverId: agent.serverId, agentId: agent.id, target: requestedTarget),
                      let messageId = prepareMarketplaceInstallCard(
                          serverId: agent.serverId,
                          agent: agent,
                          client: service,
                          scopes: effectiveScopes,
                          target: resolved
                      )
                else {
                    return Self.json(404, "{\"error\":\"Install target not found or not visible to this agent\"}")
                }
                targetJSON = jsonString(requestedTarget)
                actionCardMessageIdJSON = jsonString(messageId)
            }
            return Self.json(200, "{\"status\":\"install_required\",\"nextAction\":\"install_from_marketplace\",\"service\":\(Self.integrationServiceJSON(service)),\"scopes\":[\(scopesJSON)],\"installation\":{\"serverSlug\":\(jsonString(serverSlug)),\"serverName\":\(jsonString(serverName)),\"marketplaceUrl\":\(jsonString(marketplaceUrl)),\"target\":\(targetJSON),\"actionCardMessageId\":\(actionCardMessageIdJSON)}}")
        }
        let key = "\(agent.serverId)\n\(agent.id)\n\(serviceId)"
        lock.lock()
        let existing = agentIntegrationLogins[key]
        if existing == nil {
            agentIntegrationLogins[key] = AgentIntegrationLoginRecord(
                serverId: agent.serverId,
                agentId: agent.id,
                clientId: serviceId,
                scopes: effectiveScopes,
                loggedInAt: Date()
            )
        }
        lock.unlock()
        let status = existing == nil ? "logged_in" : "already_logged_in"
        let scopesJSON = effectiveScopes.map(jsonString).joined(separator: ",")
        return Self.json(200, "{\"status\":\(jsonString(status)),\"requestId\":\(jsonString(UUID().uuidString.lowercased())),\"service\":\(Self.integrationServiceJSON(service)),\"scopes\":[\(scopesJSON)]}")
    }

    public func agentMentionDeliveries(authorization: String?, messageRef: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        lock.lock()
        guard let message = humanMessageRows.first(where: { $0.id == messageRef }),
              message.senderType == "agent",
              message.senderId == agent.id,
              messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: agent.serverId, viewer: .agent(agent.id))
        else {
            lock.unlock()
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        let deliveries = storedMentions.filter {
            $0.messageId == message.id && $0.targetType == "agent" && $0.notifiableAtSend
        }.map { mention in
            "{\"targetId\":\(jsonString(mention.targetId)),\(Self.mentionDeliveryFields(handle: mention.handle, terminalCode: mention.terminalCode))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"messageId\":\(jsonString(message.id)),\"deliveries\":[\(deliveries)]}")
    }

    func jointLocalChannelIdForAgentLocked(canonicalChannelId: String, serverId: String, agentId: String) -> String? {
        jointProjections.first { link in
            link.canonicalChannelId == canonicalChannelId
                && link.serverId == serverId
                && (postableChannels[link.localChannelId]?.kind == "joint"
                    || postableChannels[link.localChannelId]?.kind == "channel"
                    || postableChannels[link.localChannelId]?.memberIds.contains(agentId) == true
                    || oauth.channelAgentIds(channelId: link.localChannelId).contains(agentId))
        }?.localChannelId
    }

    public func agentMessageResolve(authorization: String?, messageRef: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        lock.lock()
        let candidates = humanMessageRows.filter { message in
            message.id == messageRef || message.id.hasPrefix(messageRef.lowercased())
        }
        var matches: [(message: StoredHumanMessage, storageChannelId: String, localChannelId: String?)] = []
        for message in candidates {
            if messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: agent.serverId, viewer: .agent(agent.id)) {
                matches.append((message, message.channelId, nil))
                continue
            }
            let storageChannelId = message.channelId
            let canonicalId: String?
            if let link = jointProjections.first(where: { $0.localChannelId == storageChannelId }) {
                canonicalId = link.canonicalChannelId
            } else if jointProjections.contains(where: { $0.canonicalChannelId == storageChannelId }) {
                canonicalId = storageChannelId
            } else {
                canonicalId = nil
            }
            if let canonicalId,
               let localId = jointLocalChannelIdForAgentLocked(canonicalChannelId: canonicalId, serverId: agent.serverId, agentId: agent.id),
               messageSearchVisibleLocked(messageChannelId: localId, serverId: agent.serverId, viewer: .agent(agent.id)) {
                matches.append((message, storageChannelId, localId))
            }
        }
        guard !matches.isEmpty else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found: \(messageRef)\",\"errorCode\":\"NOT_FOUND\"}")
        }
        guard matches.count == 1, let matched = matches.first else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Ambiguous message id: \(messageRef)\",\"errorCode\":\"AMBIGUOUS_ID\",\"suggestedNextAction\":\"Retry with the full message UUID.\"}")
        }
        let message = matched.message
        let effectiveChannelId = matched.localChannelId ?? matched.storageChannelId
        let channel = postableChannels[effectiveChannelId]
        let kind = channel?.kind ?? "channel"
        let channelType = kind == "dm" ? "dm" : (kind == "thread" ? "thread" : "channel")
        let channelName: String
        if kind == "dm" {
            let humans = oauth.channelHumanIds(channelId: effectiveChannelId).filter { $0 != agent.id }
            let agents = oauth.channelAgentIds(channelId: effectiveChannelId).filter { $0 != agent.id }
            if let humanId = humans.first, let account = accounts.values.first(where: { $0.id == humanId }) {
                channelName = account.name
            } else if let peerAgentId = agents.first, let peer = oauth.agentRuntimeInfo(id: peerAgentId) {
                channelName = peer.name
            } else {
                channelName = channel?.name ?? ""
            }
        } else if kind == "thread", let parentId = channel?.parentChannelId, let parent = postableChannels[parentId] {
            channelName = parent.name
        } else {
            channelName = channel?.name ?? ""
        }
        let senderType: String
        let senderName: String
        if message.senderType == "system" || message.senderId == "system" {
            senderType = "system"
            senderName = "system"
        } else if message.senderType == "agent" || oauth.agentRuntimeInfo(id: message.senderId) != nil {
            senderType = "agent"
            senderName = oauth.agentRuntimeInfo(id: message.senderId)?.name ?? ""
        } else {
            senderType = "human"
            senderName = accounts.values.first(where: { $0.id == message.senderId })?.name ?? ""
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdAt = formatter.string(from: message.createdAt)
        let senderTimezone = message.senderTimezone.map(jsonString) ?? "null"
        let mentioned = storedMentions.contains { $0.messageId == message.id && $0.targetType == "agent" && $0.targetId == agent.id }
        var json = "{\"message_id\":\(jsonString(message.id)),\"id\":\(jsonString(message.id)),\"channel_id\":\(jsonString(effectiveChannelId)),\"channel_name\":\(jsonString(channelName)),\"channel_type\":\(jsonString(channelType)),\"sender_type\":\(jsonString(senderType)),\"sender_name\":\(jsonString(senderName)),\"content\":\(jsonString(message.content)),\"created_at\":\(jsonString(createdAt)),\"sender_timezone\":\(senderTimezone),\"mentioned\":\(mentioned ? "true" : "false")}"
        if message.senderType == "external_projection" {
            json = String(json.dropLast()) + ",\"external_message\":{\"message_id\":\(message.externalMessageId.map(jsonString) ?? "null"),\"provider\":\(message.externalProvider.map(jsonString) ?? "null"),\"actor_name\":\(message.externalSenderName.map(jsonString) ?? "null")}}"
        }
        lock.unlock()
        return Self.json(200, "{\"message\":\(json)}")
    }

}
