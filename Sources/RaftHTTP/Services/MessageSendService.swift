import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The message-mutation boundary: the reaction writes and the migration
/// receipt DM. The create and forward writes live on
/// `HumanMessageCreateService`, which owns that body contract.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures, so every existing caller and test compiles untouched. This type
/// exists so a route can hand over a decoded request DTO instead of a JSON
/// string, and so the domain has a `Service` boundary of its own.
public struct MessageSendService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `POST /api/messages/:messageId/reactions`.
    public func addMessageReaction(
        messageId: String,
        body: ReactionMutationRequestDTO,
        authorization: String?,
        serverId: String?
    ) -> HTTPReply {
        directory.addMessageReaction(
            messageId: messageId,
            body: body.encodedBody(),
            authorization: authorization,
            serverId: serverId
        )
    }

    /// `DELETE /api/messages/:messageId/reactions`.
    public func removeMessageReaction(
        messageId: String,
        body: ReactionMutationRequestDTO,
        authorization: String?,
        serverId: String?
    ) -> HTTPReply {
        directory.removeMessageReaction(
            messageId: messageId,
            body: body.encodedBody(),
            authorization: authorization,
            serverId: serverId
        )
    }

    /// A completed Computer migration writes one receipt into an agent-only DM
    /// named `migration-receipt-<supportRef>`.
    @discardableResult
    public func createMigrationReceiptDm(
        agentId: String,
        serverId: String,
        supportRef: String
    ) -> String? {
        directory.createMigrationReceiptDm(
            agentId: agentId,
            serverId: serverId,
            supportRef: supportRef
        )
    }
}

extension EmailLoginDirectory {


    func forwardContextLocked(source: PendingForwardSource, selectedThreads: Set<String>) -> ForwardSourceContext {
        if source.channelKind == "thread" {
            let parent = source.parentChannelId.flatMap { postableChannels[$0] }
            let publicParent = parent?.kind == "channel"
            return ForwardSourceContext(
                bundleSourceId: source.channelId,
                sourceTargetId: publicParent ? source.channelId : nil,
                sourceThreadId: publicParent ? source.channelId : nil,
                parentChannelId: publicParent ? source.parentChannelId : nil,
                sourceIsThreadParent: false,
                snapshotId: publicParent ? source.parentChannelId : nil,
                snapshotType: "thread",
                snapshotLabel: publicParent ? "#\(parent?.name ?? "")" : "",
                snapshotLabelVisibility: publicParent ? "public" : "restricted"
            )
        }
        if source.channelKind == "channel",
           let threadId = postableChannels.first(where: { $0.value.kind == "thread" && $0.value.parentMessageId == source.messageId })?.key,
           selectedThreads.contains(threadId) {
            return ForwardSourceContext(
                bundleSourceId: threadId,
                sourceTargetId: threadId,
                sourceThreadId: threadId,
                parentChannelId: source.channelId,
                sourceIsThreadParent: true,
                snapshotId: source.channelId,
                snapshotType: "thread",
                snapshotLabel: "#\(source.channelName)",
                snapshotLabelVisibility: "public"
            )
        }
        let publicSource = source.channelKind == "channel"
        return ForwardSourceContext(
            bundleSourceId: source.channelId,
            sourceTargetId: publicSource ? source.channelId : nil,
            sourceThreadId: nil,
            parentChannelId: nil,
            sourceIsThreadParent: false,
            snapshotId: publicSource ? source.channelId : nil,
            snapshotType: publicSource ? "channel" : source.channelKind,
            snapshotLabel: publicSource ? "#\(source.channelName)" : "",
            snapshotLabelVisibility: publicSource ? "public" : "restricted"
        )
    }





    /// A viewer who cannot read the source still sees the forward, with the pointers removed.

    func forwardMetadataJSONLocked(messageId: String, userId: String, serverId: String?) -> String? {
        guard let record = forwardRecords[messageId] else { return nil }
        let rendered = record.items.map { item in
            forwardItemReadableLocked(item, userId: userId, serverId: serverId)
                ? Self.forwardItemJSON(item)
                : Self.scrubbedForwardItemJSON(item)
        }.joined(separator: ",")
        return "{\"kind\":\"forwarded-bundle\",\"forwardedItems\":[\(rendered)]}"
    }

    func forwardItemReadableLocked(_ item: ForwardItemRecord, userId: String, serverId: String?) -> Bool {
        guard let targetId = item.sourceTargetId, let serverId else { return false }
        guard let channel = postableChannels[targetId], channel.serverId == serverId, channel.deletedAt == nil else { return false }
        if channel.kind == "channel" { return true }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = postableChannels[parentId],
                  parent.serverId == serverId,
                  parent.deletedAt == nil
            else { return channel.memberIds.contains(userId) }
            if parent.kind == "channel" { return true }
            return parent.memberIds.contains(userId) || channel.memberIds.contains(userId)
        }
        return channel.memberIds.contains(userId)
    }

    /// A batch keeps one result per distinct destination. A denial or conflict stays inside that result.
    func forwardToMany(object: [String: Any], sourceIds: [String], note: String, authorization: String?, serverId: String) -> HTTPReply {
        guard let destinations = Self.forwardDestinationIds(object["destinationChannelIds"]) else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        guard let rawRequestId = object["requestId"] as? String else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let requestId = rawRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ServerScope.isUUID(requestId) else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let sourcesJSON = sourceIds.map { jsonString($0) }.joined(separator: ",")
        var results: [String] = []
        var successes = 0
        var replays = 0
        for destination in destinations {
            let randomId = "forward:\(requestId):\(destination)"
            let body = "{\"destinationChannelId\":\(jsonString(destination)),\"sourceMessageIds\":[\(sourcesJSON)],\"note\":\(jsonString(note)),\"randomId\":\(jsonString(randomId))}"
            let reply = forwardHumanMessage(body: body, authorization: authorization, serverId: serverId)
            if reply.status == 200 {
                successes += 1
                if reply.value(for: "X-Raft-Forward-Outcome") == "idempotent_replay" {
                    replays += 1
                }
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"success\",\"message\":\(reply.body)}")
            } else if reply.status == 409 {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"request_conflict\",\"error\":\"Forward request conflicts with an earlier request\"}")
            } else if reply.status == 403 || reply.status == 404 {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"destination_unavailable\",\"error\":\"Could not forward to this target\"}")
            } else {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"forward_failed\",\"error\":\"Could not forward to this target\"}")
            }
        }
        let failed = destinations.count - successes
        let outcome: String
        if failed > 0 {
            outcome = successes > 0 ? "partial_failure" : "all_failed"
        } else if replays == destinations.count {
            outcome = "idempotent_replay"
        } else {
            outcome = "success"
        }
        var reply = Self.json(200, "{\"results\":[\(results.joined(separator: ","))]}")
        reply.headers["X-Raft-Forward-Outcome"] = outcome
        return reply
    }



    /// `POST /api/v2/messages`. The message is always nested. A stopped agent DM adds `agent_stopped`.
    func v2HumanSend(_ reply: HTTPReply, channelId: String, mentions: [MentionInput], unresolvedMentionHandles: [String] = []) -> HTTPReply {
        guard reply.status == 200,
              let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = object["id"] as? String
        else { return reply }
        let pending = pendingMentionActionsJSON(channelId: channelId, messageId: messageId, mentions: mentions)
        let warnings = stoppedAgentDeliveryWarningJSON(channelId: channelId, messageId: messageId)
        var body = "{\"message\":\(reply.body)"
        if !pending.isEmpty {
            body += ",\"pendingMentionActions\":[\(pending)]"
        }
        if !warnings.isEmpty {
            body += ",\"deliveryWarnings\":[\(warnings)]"
        }
        if !unresolvedMentionHandles.isEmpty {
            let handles = unresolvedMentionHandles.map { jsonString($0) }.joined(separator: ",")
            body += ",\"unresolvedMentionHandles\":[\(handles)]"
        }
        body += "}"
        return Self.json(200, body)
    }

    /// A DM delivery to a stopped agent is dropped as `wake_suppressed` and reported to the v2 sender as `agent_stopped`.
    func stoppedAgentDeliveryWarningJSON(channelId: String, messageId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId],
              channel.kind == "dm",
              let agentId = channel.agentId,
              serverAgents[agentId]?.status == "stopped"
        else { return "" }
        storedAgentDeliveries.append((agentId: agentId, messageId: messageId, channelType: channel.kind))
        return "{\"targetType\":\"agent\",\"targetId\":\(jsonString(agentId)),\"reason\":\"agent_stopped\"}"
    }

    /// A completed Computer migration writes one receipt into an agent-only DM
    /// named `migration-receipt-<supportRef>`; the agent reads it as
    /// `dm:@migration-receipt-<supportRef>` and cannot reply to it.
    @discardableResult
    public func createMigrationReceiptDm(agentId: String, serverId: String, supportRef: String) -> String? {
        let name = "migration-receipt-\(supportRef)"
        lock.lock()
        let existing = postableChannels.first(where: { _, channel in
            channel.kind == "dm" && channel.name == name && channel.memberIds == [agentId]
        })?.key
        lock.unlock()
        if let existing { return existing }
        let channelId = oauth.createChannel(serverId: serverId, name: name, creatorUserId: agentId, type: "dm")
        addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "dm", name: name)
        oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: "system",
            content: "Migration completed. Your Computer workspace moved successfully (migration \(supportRef)). This is a one-way notice: continue in your owner's DM.",
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        lock.unlock()
        return channelId
    }

    public func createMigrationReceiptDmForTesting(agentId: String, supportRef: String) -> String? {
        guard let serverId = oauth.agentRuntimeInfo(id: agentId)?.serverId else { return nil }
        return createMigrationReceiptDm(agentId: agentId, serverId: serverId, supportRef: supportRef)
    }

    /// Outsider mentions on a new human send are returned beside the message, not inside it.
    func withPendingMentionActions(_ reply: HTTPReply, channelId: String, mentions: [MentionInput]) -> HTTPReply {
        guard reply.status == 200,
              let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = object["id"] as? String
        else { return reply }
        let actions = pendingMentionActionsJSON(channelId: channelId, messageId: messageId, mentions: mentions)
        guard !actions.isEmpty else { return reply }
        return Self.json(200, "{\"message\":\(reply.body),\"pendingMentionActions\":[\(actions)]}")
    }

    func pendingMentionActionsJSON(channelId: String, messageId: String, mentions: [MentionInput]) -> String {
        lock.lock()
        defer { lock.unlock() }
        let channel = postableChannels[channelId]
        let members = channel?.memberIds ?? []
        let serverId = channel?.serverId
        let directMessage = channel?.kind == "dm"
        let expiresAt = Self.pendingMentionExpiry()
        var parts: [String] = []
        for mention in mentions {
            guard mention.type == "user" || mention.type == "agent",
                  ServerScope.isUUID(mention.id),
                  !mention.name.isEmpty
            else { continue }
            let avatar: String?
            if mention.type == "user" {
                guard accounts.values.contains(where: { $0.id == mention.id }), !members.contains(mention.id) else { continue }
                avatar = accounts.values.first { $0.id == mention.id }?.avatarUrl
            } else {
                if oauth.channelAgentIds(channelId: channelId).contains(mention.id) { continue }
                if let agent = serverAgents[mention.id], agent.serverId == serverId {
                    avatar = agent.avatarUrl
                } else if let agent = oauth.agentRuntimeInfo(id: mention.id), agent.serverId == serverId, !agent.deleted {
                    avatar = agent.avatarUrl
                } else {
                    continue
                }
            }
            let avatarJSON = avatar.map { jsonString($0) } ?? "null"
            let existing = storedMentions.first { $0.messageId == messageId && $0.targetType == mention.type && $0.targetId == mention.id }
            let resolutionId = existing?.id ?? UUID().uuidString.lowercased()
            if existing == nil {
                let senderId = humanMessageRows.first { $0.id == messageId }?.senderId ?? ""
                storedMentions.append(StoredMention(
                    id: resolutionId,
                    messageId: messageId,
                    channelId: channelId,
                    senderId: senderId,
                    targetType: mention.type,
                    targetId: mention.id,
                    handle: mention.name,
                    notifiableAtSend: false,
                    notifiedAt: nil,
                    notifiedByType: nil,
                    notifiedById: nil,
                    notifiedAction: nil
                ))
            }
            if directMessage { continue }
            parts.append("{\"resolutionId\":\(jsonString(resolutionId)),\"messageId\":\(jsonString(messageId)),\"targetType\":\(jsonString(mention.type)),\"targetHandle\":\(jsonString(mention.name)),\"targetAvatarUrl\":\(avatarJSON),\"reason\":\"not_member\",\"availableActions\":[\"notify\",\"add\"],\"expiresAt\":\(jsonString(expiresAt))}")
        }
        return parts.joined(separator: ",")
    }




    /// Caller holds the directory lock.
    func mentionHumanVisibleLocked(serverId: String, senderId: String, targetId: String) -> Bool {
        if targetId == senderId { return true }
        guard hideHumansFromMembers[serverId] == true else { return true }
        guard let targetRole = oauth.memberRole(serverId: serverId, userId: targetId) else { return false }
        let senderRole = oauth.memberRole(serverId: serverId, userId: senderId)
        let senderIsAgent = oauth.agentRuntimeInfo(id: senderId)?.serverId == serverId
        guard senderRole == "member" || senderIsAgent else { return true }
        if targetRole == "owner" || targetRole == "admin" { return true }
        for (id, channel) in postableChannels
        where channel.serverId == serverId && channel.deletedAt == nil && channel.memberIds.contains(senderId) {
            if channel.name != "all" && channel.memberIds.contains(targetId) { return true }
            if jointRosterLocked(channelId: id)?.contains(targetId) == true { return true }
        }
        return false
    }

    func resolvedMessageMentions(
        serverId: String,
        senderId: String,
        content: String,
        typed: [MentionInput],
        warnUnresolved: Bool
    ) -> (mentions: [MentionInput], unresolved: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var resolved: [MentionInput] = []
        var seen = Set<String>()
        func append(type: String, id: String, name: String) {
            let key = "\(type):\(id)"
            guard seen.insert(key).inserted else { return }
            resolved.append(MentionInput(type: type, id: id, name: name))
        }
        var typedNames = Set<String>()
        let senderIsAgent = oauth.agentRuntimeInfo(id: senderId)?.serverId == serverId
        let hiddenDirectoryForSender = hideHumansFromMembers[serverId] == true
        for mention in typed where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id), !mention.name.isEmpty else { continue }
            typedNames.insert(mention.name.lowercased())
            if mention.type == "user" {
                if hiddenDirectoryForSender {
                    guard mentionHumanVisibleLocked(serverId: serverId, senderId: senderId, targetId: mention.id) else { continue }
                } else {
                    guard accounts.values.contains(where: { $0.id == mention.id }) else { continue }
                }
                append(type: "user", id: mention.id, name: mention.name)
            } else {
                let runtime = oauth.agentRuntimeInfo(id: mention.id)
                let directory = serverAgents[mention.id]
                guard runtime?.serverId == serverId || directory?.serverId == serverId else { continue }
                append(type: "agent", id: mention.id, name: mention.name)
            }
        }
        var agentNames: [(id: String, name: String)] = oauth.serverAgents(serverId: serverId).map { ($0.id, $0.name) }
        for (id, agent) in serverAgents where agent.serverId == serverId {
            if !agentNames.contains(where: { $0.id == id }) { agentNames.append((id, agent.name)) }
        }
        var unresolved: [String] = []
        let hiddenDirectory = hiddenDirectoryForSender
        var seenHandles = Set<String>()
        for handle in Self.mentionHandlesOutsideCode(content)
            where !typedNames.contains(handle.lowercased()) && seenHandles.insert(handle).inserted {
            let humanMatches = accounts.values.filter { account in
                account.id != senderId
                    && (account.name.caseInsensitiveCompare(handle) == .orderedSame
                        || (account.displayName ?? "").caseInsensitiveCompare(handle) == .orderedSame)
                    && oauth.memberRole(serverId: serverId, userId: account.id) != nil
                    && (!hiddenDirectory || mentionHumanVisibleLocked(serverId: serverId, senderId: senderId, targetId: account.id))
            }.map(\.id)
            let agentMatches = agentNames.filter { $0.name.caseInsensitiveCompare(handle) == .orderedSame }.map(\.id)
            let total = humanMatches.count + agentMatches.count
            if warnUnresolved {
                guard total == 1 else {
                    unresolved.append("@" + handle)
                    continue
                }
            }
            for id in humanMatches { append(type: "user", id: id, name: handle) }
            for id in agentMatches { append(type: "agent", id: id, name: handle) }
        }
        return (resolved, unresolved)
    }

    func recordMemberMentionRows(messageId: String, channelId: String, mentions: [MentionInput]) {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId] else { return }
        for mention in mentions where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id) else { continue }
            let isMember = mention.type == "user"
                ? oauth.memberRole(serverId: channel.serverId, userId: mention.id) != nil
                : oauth.agentRuntimeInfo(id: mention.id)?.serverId == channel.serverId
            guard isMember else { continue }
            guard !storedMentions.contains(where: {
                $0.messageId == messageId && $0.targetType == mention.type && $0.targetId == mention.id
            }) else { continue }
            storedMentions.append(StoredMention(
                id: UUID().uuidString.lowercased(),
                messageId: messageId,
                channelId: channelId,
                senderId: "system",
                targetType: mention.type,
                targetId: mention.id,
                handle: mention.name,
                notifiableAtSend: true,
                notifiedAt: nil,
                notifiedByType: nil,
                notifiedById: nil,
                notifiedAction: nil
            ))
        }
    }


    /// An agent that belongs to a server but is not a member of a channel until someone adds it.
    public func addServerAgent(serverId: String, id: String, name: String, avatarUrl: String?, status: String = "inactive") {
        lock.lock()
        serverAgents[id] = ServerAgent(id: id, serverId: serverId, name: name, avatarUrl: avatarUrl, status: status)
        lock.unlock()
    }






    /// Stored forwarded-bundle metadata. The reaction route projects it for the HTTP body and the channel broadcast.
    public func setForwardedBundle(messageId: String, items: [ForwardedSource]) {
        lock.lock()
        forwardedBundles[messageId] = items
        lock.unlock()
    }

    /// An uploaded file on a channel. The send route keeps the caller's `attachmentIds` order, not upload time.
    public func addChannelAttachment(
        channelId: String,
        uploaderId: String,
        filename: String,
        mimeType: String? = nil,
        sizeBytes: Int? = nil,
        messageId: String? = nil
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: messageId,
            messagePosition: nil,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
        lock.unlock()
        return id
    }

    public func linkedAttachmentPositions(ids: [String]) -> [(id: String, messagePosition: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return ids.compactMap { id in
            guard let position = channelAttachments[id]?.messagePosition else { return nil }
            return (id, position)
        }.sorted { $0.messagePosition < $1.messagePosition }
    }

    /// Stored attachment rows for these ids, in `messagePosition` order. Unlinked rows keep a nil position and sort first.
    public func linkedAttachmentRecords(ids: [String]) -> [(id: String, messageId: String?, messagePosition: Int?)] {
        lock.lock()
        defer { lock.unlock() }
        return ids.compactMap { id in
            guard let row = channelAttachments[id] else { return nil }
            return (row.id, row.messageId, row.messagePosition)
        }.sorted { ($0.messagePosition ?? -1) < ($1.messagePosition ?? -1) }
    }

    func attachmentPreviewSecret() -> SymmetricKey {
        let raw = ProcessInfo.processInfo.environment["JWT_SECRET"] ?? "raft-test-preview-secret"
        return SymmetricKey(data: Data(raw.utf8))
    }



    public func mintAttachmentPreviewToken(
        attachmentId: String,
        serverId: String,
        actorId: String,
        audience: String = "attachment-html-preview",
        type: String = "attachment-html-preview",
        expiresIn: Int = 300
    ) -> String {
        let payload: [String: Any] = [
            "attachmentId": attachmentId,
            "serverId": serverId,
            "actorId": actorId,
            "audience": audience,
            "aud": audience,
            "type": type,
            "exp": Int(Date().timeIntervalSince1970) + expiresIn,
        ]
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        let payloadPart = Self.previewBase64URL(payloadData)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(payloadPart.utf8), using: attachmentPreviewSecret())
        return payloadPart + "." + Self.previewBase64URL(Data(signature))
    }

    func validateAttachmentPreviewToken(
        _ token: String,
        attachmentId: String,
        serverId: String
    ) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let payloadPart: String
        let signaturePart: String
        let signedPart: String
        if parts.count == 3 {
            payloadPart = parts[1]
            signaturePart = parts[2]
            signedPart = parts[0] + "." + parts[1]
        } else if parts.count == 2 {
            payloadPart = parts[0]
            signaturePart = parts[1]
            signedPart = parts[0]
        } else {
            return nil
        }
        guard let signature = Self.previewBase64URLDecode(signaturePart),
              let payloadData = Self.previewBase64URLDecode(payloadPart),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(signedPart.utf8), using: attachmentPreviewSecret()),
              let object = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }
        let audience = object["audience"] as? String ?? object["aud"] as? String
        guard audience == "attachment-html-preview",
              object["type"] as? String == "attachment-html-preview",
              object["attachmentId"] as? String == attachmentId,
              object["serverId"] as? String == serverId,
              let exp = object["exp"] as? Int,
              exp > Int(Date().timeIntervalSince1970)
        else { return nil }
        return object
    }

    public func attachmentDownloadURL(
        attachmentId: String,
        authorization: String?,
        serverId: String?,
        disposition: String? = nil,
        download: String? = nil,
        propagateQueryToken: String? = nil
    ) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        lock.lock()
        let retired = accounts.values.first { $0.id == userId }?.retiredAt != nil
        lock.unlock()
        guard !retired else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        guard ServerScope.isUUID(attachmentId) else {
            return Self.json(400, "{\"code\":\"invalid_attachment_id\",\"error\":\"Invalid attachment id\"}")
        }
        if !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let attachmentRecord = channelAttachments[attachmentId]
        lock.unlock()
        guard let attachmentRecord,
              visibleAttachment(userId: userId, serverId: serverId, attachment: attachmentRecord)
        else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        lock.lock()
        let mimeType = channelAttachments[attachmentId]?.mimeType
        lock.unlock()
        let isMedia = mimeType?.hasPrefix("video/") == true || mimeType?.hasPrefix("audio/") == true
        let inline = disposition == "inline" && download != "1"
        let ttl = inline && isMedia ? 3600 : 300
        var url = attachmentPresign?(attachmentId, mimeType, ttl) ?? "/api/attachments/\(attachmentId)"
        let expiresAtJSON: String
        if let queryToken = propagateQueryToken {
            let encoded = queryToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? queryToken
            let separator = url.contains("?") ? "&" : "?"
            url += "\(separator)token=\(encoded)&serverId=\(serverId)"
            expiresAtJSON = "null"
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAtJSON = jsonString(formatter.string(from: Date().addingTimeInterval(Double(ttl))))
        }
        return Self.json(200, "{\"url\":\(jsonString(url)),\"expiresAt\":\(expiresAtJSON)}")
    }

    /// `GET /api/messages/sync`. `since_seq=0` returns the channel page, including a joint canonical store.
    public func seedPostableChannelForTesting(
        serverId: String, channelId: String, name: String,
        humanIds: [String], agentIds: [String]
    ) {
        lock.lock()
        var channel = PostableChannel(serverId: serverId, memberIds: Set(humanIds), kind: "channel")
        channel.name = name
        for agentId in agentIds { channel.memberIds.insert(agentId) }
        postableChannels[channelId] = channel
        lock.unlock()
        for humanId in humanIds { oauth.addChannelHuman(channelId: channelId, userId: humanId) }
        for agentId in agentIds { oauth.addChannelAgent(channelId: channelId, agentId: agentId) }
    }

    public func softDeletePostableChannelForTesting(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.deletedAt = Date()
        lock.unlock()
    }

    public func removeThreadFollowForTesting(serverId: String, userId: String, threadChannelId: String) {
        lock.lock()
        let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
        threadFollows.removeValue(forKey: key)
        threadUnfollows.removeValue(forKey: key)
        threadFollowStarts.removeValue(forKey: key)
        lock.unlock()
    }

    public func followThreadForTesting(serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        lock.lock()
        threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] = (serverId, userId, threadChannelId, parentMessageId)
        lock.unlock()
    }

    public func addTaskForTesting(
        channelId: String,
        title: String,
        messageId: String,
        assigneeType: String?,
        assigneeId: String?
    ) {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: "in_progress",
            taskNumber: taskNumber,
            messageId: messageId,
            createdAt: Date(),
            assigneeId: assigneeId,
            assigneeType: assigneeType
        ))
        lock.unlock()
    }

    func canManageThreadLocked(serverId: String, thread: PostableChannel, userId: String) -> Bool {
        if oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" {
            return true
        }
        guard let parentMessageId = thread.parentMessageId else { return false }
        return humanMessageRows.first { $0.id == parentMessageId }?.senderId == userId
    }

    public func removeThreadFollower(authorization: String?, serverId: String, threadId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let thread = postableChannels[threadId], thread.serverId == serverId, thread.kind == "thread" else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        guard canManageThreadLocked(serverId: serverId, thread: thread, userId: userId) else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if let existing = threadFollowerRemovals.first(where: {
            $0.value.threadChannelId == threadId && $0.value.agentId == agentId
        }) {
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"removed\":true,\"undoToken\":\(jsonString(existing.key))}")
        }
        let undoToken = UUID().uuidString.lowercased()
        threadFollowerRemovals[undoToken] = (serverId, threadId, agentId)
        lock.unlock()
        oauth.removeChannelAgent(channelId: threadId, agentId: agentId)
        emitRealtime("channel:\(threadId)", "thread:followers-updated", "{\"threadChannelId\":\(jsonString(threadId))}")
        return Self.json(200, "{\"removed\":true,\"undoToken\":\(jsonString(undoToken))}")
    }

    public func restoreThreadFollower(authorization: String?, serverId: String, threadId: String, agentId: String, body: String = "{}") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let thread = postableChannels[threadId], thread.serverId == serverId, thread.kind == "thread" else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        guard canManageThreadLocked(serverId: serverId, thread: thread, userId: userId) else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let token = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["undoToken"] as? String ?? ""
        guard let record = threadFollowerRemovals[token],
              record.threadChannelId == threadId,
              record.agentId == agentId
        else {
            let stale = staleThreadFollowerUndoTokens.contains(token)
            lock.unlock()
            if stale {
                return Self.json(200, "{\"ok\":true,\"restored\":false}")
            }
            return Self.json(200, "{\"ok\":true,\"restored\":false}")
        }
        threadFollowerRemovals.removeValue(forKey: token)
        staleThreadFollowerUndoTokens.insert(token)
        lock.unlock()
        oauth.addChannelAgent(channelId: threadId, agentId: agentId)
        emitRealtime("channel:\(threadId)", "thread:followers-updated", "{\"threadChannelId\":\(jsonString(threadId))}")
        return Self.json(200, "{\"ok\":true,\"restored\":true}")
    }

}
