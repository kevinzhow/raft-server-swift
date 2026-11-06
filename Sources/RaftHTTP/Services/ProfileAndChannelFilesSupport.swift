import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Shared helpers still owned by unmigrated domains

extension EmailLoginDirectory {

    /// Third-party content stays inert: mentions read as plain `user:<handle>`.
    static func neutralizeExternalProjectionContent(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        value = value.replacingOccurrences(of: "@([A-Za-z0-9_.-]+)", with: "user:$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "#([A-Za-z0-9_.-]+)", with: "channel:$1", options: .regularExpression)
        return value
    }

    /// The typed agent read check. The third-party delivery operation uses it
    /// through `ProfileAndChannelFilesService`; `agentReadCredential` keeps the
    /// legacy reply projection for the unmigrated callers.
    func profileAgentReadOutcome(_ authorization: String?) -> ProfileAgentReadOutcome {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .missingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.scopes.contains("read") else {
            return .invalidCredential
        }
        recordAgentCredentialUse(token: token)
        return .success(agentId: credential.agentId)
    }

    func agentReadCredential(_ authorization: String?) -> AgentRead {
        switch profileAgentReadOutcome(authorization) {
        case .success(let agentId):
            return .success(agentId)
        case .missingAuthorization:
            return .failure(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        case .invalidCredential:
            return .failure(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
    }

    /// A raw agent API key. The mentions inbox accepts it when `mentions` is one of the scopes.
    public func mintAgentCredential(agentId: String, scopes: [String], name: String) -> String {
        let key = "sk_agent_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        lock.lock()
        agentCredentials[key] = AgentCredential(agentId: agentId, scopes: Set(scopes), name: name)
        lock.unlock()
        return key
    }

    /// Binds a machine key to one agent. The legacy agent reaction route accepts that bearer.
    public func registerMachineForAgent(serverId: String, agentId: String) -> String {
        let key = "mk_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        lock.lock()
        machineKeys[key] = (serverId: serverId, agentId: agentId)
        lock.unlock()
        return key
    }

    func recordAttestedSendEvent(
        _ eventType: String,
        agentId: String,
        messageId: String?,
        metadata: [String: JSONValue]
    ) {
        let metadataJSON = (try? JSONValue.object(metadata).string()) ?? "{}"
        lock.lock()
        attestedSendEventRecords.append(AttestedSendEventRecord(
            eventType: eventType,
            agentId: agentId,
            messageId: messageId,
            metadataJSON: metadataJSON
        ))
        lock.unlock()
    }

    /// Typed metadata overload: the execute service names the attested-send
    /// fields, and the legacy sorted-key encoding still renders the row.
    func recordAttestedSendEvent(
        _ eventType: String,
        agentId: String,
        messageId: String?,
        metadata: AttestedSendEventMetadata
    ) {
        switch metadata {
        case .gateTriggered(
            let lastSeenMessageId,
            let latestMessageId,
            let draftReplacedExisting,
            let newMessageCount,
            let boundarySource,
            let boundarySeq,
            let latestSeq
        ):
            recordAttestedSendEvent(eventType, agentId: agentId, messageId: messageId, metadata: [
                "last_seen_msg_id": lastSeenMessageId.map(JSONValue.string) ?? .null,
                "latest_msg_id": latestMessageId.map(JSONValue.string) ?? .null,
                "has_formal_mention_since_last_seen": .bool(false),
                "draft_replaced_existing": .bool(draftReplacedExisting),
                "new_message_count": .integer(Int64(newMessageCount)),
                "boundary_source": .string(boundarySource),
                "boundary_seq": .integer(Int64(boundarySeq)),
                "latest_seq": .integer(Int64(latestSeq)),
            ])
        case .mentionExemption(
            let mentionMessageId,
            let mentionedHandle,
            let newMessageCountSinceLastSeen
        ):
            recordAttestedSendEvent(eventType, agentId: agentId, messageId: messageId, metadata: [
                "mention_message_id": .string(mentionMessageId),
                "mentioned_handle": .string(mentionedHandle),
                "new_message_count_since_last_seen": .integer(Int64(newMessageCountSinceLastSeen)),
            ])
        }
    }

    func recordAgentSendActivity(agentId: String, title: String, text: String, producerFactId: String?) {
        lock.lock()
        agentSendActivityRecords[agentId, default: []].append((title: title, text: text, producerFactId: producerFactId))
        lock.unlock()
    }

    func recordServerMemberEvent(serverId: String, eventType: String, subjectType: String, subjectId: String, provenanceJSON: String) {
        serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId, eventType: eventType, subjectType: subjectType,
            subjectId: subjectId, provenanceJSON: provenanceJSON, deliveryQueued: true
        ))
    }

    public func addChannelAgent(channelId: String, agentId: String) {
        lock.lock()
        var members = channelAgentMembers[channelId] ?? []
        members.insert(agentId)
        channelAgentMembers[channelId] = members
        lock.unlock()
    }

    public func storedMessageReactionActors(messageId: String) -> [(reactorType: String, reactorId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return messageReactions.filter { $0.messageId == messageId }.map { ($0.reactorType, $0.reactorId) }
    }

    /// Reaction rows still stored for this message. An idempotent add leaves one row; a delete leaves none.
    public func storedMessageReactions(messageId: String) -> [(emoji: String, reactorId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return messageReactions.filter { $0.messageId == messageId }.map { ($0.emoji, $0.reactorId) }
    }

    /// The discussion-version bump the reaction test seam still uses.
    func noteDiscussionChangeLocked(messageId: String, emoji: String) {
        let key = "\(messageId)\n\(emoji)"
        reactionDiscussionVersions[key] = (reactionDiscussionVersions[key] ?? 0) + 1
    }

    func jointLocalChannelIdLocked(canonicalChannelId: String, serverId: String?, userId: String) -> String? {
        guard let serverId else { return nil }
        return jointProjections.first { link in
            link.canonicalChannelId == canonicalChannelId
                && link.serverId == serverId
                && postableChannels[link.localChannelId]?.memberIds.contains(userId) == true
        }?.localChannelId
    }

    /// Members of every local projection of one joint channel. Nil when this channel is not joint.
    func jointRosterLocked(channelId: String) -> Set<String>? {
        let canonical = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
            ?? (jointProjections.contains { $0.canonicalChannelId == channelId } ? channelId : nil)
        guard let canonical else { return nil }
        var ids = postableChannels[canonical]?.memberIds ?? []
        for link in jointProjections where link.canonicalChannelId == canonical {
            ids.formUnion(postableChannels[link.localChannelId]?.memberIds ?? [])
        }
        return ids
    }

    func reactionJSONLocked(messageId: String) -> String {
        var order: [String] = []
        var buckets: [String: (ids: [String], names: [String])] = [:]
        for row in messageReactions where row.messageId == messageId {
            if buckets[row.emoji] == nil {
                order.append(row.emoji)
                buckets[row.emoji] = ([], [])
            }
            let name: String
            if row.reactorType == "agent" {
                if let runtime = oauth.agentRuntimeInfo(id: row.reactorId) {
                    name = runtime.displayName.isEmpty ? runtime.name : runtime.displayName
                } else {
                    name = serverAgents[row.reactorId]?.name ?? "Unknown agent"
                }
            } else {
                name = accounts.values.first { $0.id == row.reactorId }.map { $0.displayName ?? $0.name } ?? "Unknown user"
            }
            var bucket = buckets[row.emoji] ?? ([], [])
            bucket.ids.append(row.reactorId)
            bucket.names.append(name)
            buckets[row.emoji] = bucket
        }
        return order.map { emoji in
            let bucket = buckets[emoji] ?? ([], [])
            let ids = bucket.ids.map { jsonString($0) }.joined(separator: ",")
            let names = bucket.names.map { jsonString($0) }.joined(separator: ",")
            return "{\"emoji\":\(jsonString(emoji)),\"count\":\(bucket.ids.count),\"reactorIds\":[\(ids)],\"reactorNames\":[\(names)]}"
        }.joined(separator: ",")
    }

    /// Appends one message row and stamps its server-wide sequence.
    @discardableResult
    func appendHumanMessageLocked(_ message: StoredHumanMessage, seq explicitSeq: Int? = nil) -> Int {
        var stored = message
        stored.seq = explicitSeq ?? (humanMessageRows.count + 1)
        humanMessageRows.append(stored)
        // Mirror into the ledger so ledger-backed reads (agent history, thread
        // anchors) see the same server-wide sequence and sender metadata.
        oauth.appendMirroredMessage(
            id: stored.id,
            channelId: stored.channelId,
            content: stored.content,
            senderId: stored.senderId,
            seq: stored.seq,
            createdAt: stored.createdAt,
            senderTimezone: stored.senderTimezone,
            senderType: stored.senderType,
            messageType: stored.messageType
        )
        return stored.seq
    }

    /// The outcome of one human-message insert, shaped so this file owns no
    /// reply type. The message-create service turns it into the published reply.
    struct StoredHumanMessageWrite: Sendable {
        let status: Int
        let body: String
        let created: Bool
    }

    func storeHumanMessage(channelId: String, senderId: String, content: String, randomId: String?, attachmentIds: [String], senderTimezone: String? = nil, mentions: [MentionInput] = []) -> StoredHumanMessageWrite {
        lock.lock()
        if let randomId, let existing = humanMessageRows.first(where: { $0.senderId == senderId && $0.randomId == randomId }) {
            if existing.channelId != channelId {
                lock.unlock()
                return StoredHumanMessageWrite(
                    status: 409,
                    body: "{\"error\":\"randomId has already been used for a different message\",\"code\":\"random_id_conflict\"}",
                    created: false
                )
            }
            let matches = attachmentOrderMatches(message: existing, attachmentIds: attachmentIds, uploaderId: senderId)
            let snapshot = existing
            lock.unlock()
            if matches {
                return StoredHumanMessageWrite(
                    status: 200,
                    body: Self.humanMessageJSON(snapshot).body,
                    created: false
                )
            }
            return StoredHumanMessageWrite(
                status: 400,
                body: "{\"error\":\"This idempotent send was already committed with a different ordered attachment set.\",\"code\":\"attachment_replay_conflict\"}",
                created: false
            )
        }
        var seenAttachmentIds = Set<String>()
        for id in attachmentIds {
            if seenAttachmentIds.contains(id) {
                lock.unlock()
                return StoredHumanMessageWrite(
                    status: 400,
                    body: "{\"error\":\"Attachment \(id) was requested more than once. Send each attachment ID exactly once.\",\"code\":\"attachment_duplicate\"}",
                    created: false
                )
            }
            seenAttachmentIds.insert(id)
            guard let row = channelAttachments[id], row.channelId == channelId, row.uploaderId == senderId else {
                lock.unlock()
                return StoredHumanMessageWrite(
                    status: 400,
                    body: "{\"error\":\"Attachment \(id) is not available for this sender. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_not_found\"}",
                    created: false
                )
            }
            if row.messageId != nil {
                lock.unlock()
                return StoredHumanMessageWrite(
                    status: 400,
                    body: "{\"error\":\"Attachment \(id) is already attached to another message. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_already_linked\"}",
                    created: false
                )
            }
        }
        let storedMentionsForEcho = postableChannels[channelId]?.kind == "dm"
            ? []
            : mentions.map { StoredMessageMention(type: $0.type, id: $0.id, name: $0.name) }
        let stored = StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: randomId,
            attachmentIds: attachmentIds,
            senderTimezone: senderTimezone,
            mentions: storedMentionsForEcho
        )
        for (position, id) in attachmentIds.enumerated() {
            channelAttachments[id]?.messageId = stored.id
            channelAttachments[id]?.messagePosition = position
        }
        let sequence = appendHumanMessageLocked(stored)
        if postableChannels[channelId]?.kind == "thread" {
            inboxDoneScopes = inboxDoneScopes.filter { !$0.hasSuffix("\n\(channelId)") }
            inboxDoneFrontiers = inboxDoneFrontiers.filter { !$0.key.hasSuffix("\n\(channelId)") }
        }
        // One read-cursor store: the ledger's per-user frontier. Sending is
        // reading your own message, so the sender never counts it as unread.
        let ownCursor = oauth.channelReadCursor(channelId: channelId, userId: senderId)
        if sequence > ownCursor {
            oauth.setChannelReadCursor(channelId: channelId, userId: senderId, seq: sequence)
        }
        recordedChannelMessageEvents.append(ChannelMessageEvent(
            room: "channel:\(channelId)",
            name: "message:new",
            messageId: stored.id,
            attachmentIds: attachmentIds
        ))
        lock.unlock()
        let reply = Self.humanMessageJSON(stored)
        emitRealtime("channel:\(channelId)", "message:new", reply.body)
        return StoredHumanMessageWrite(status: 200, body: reply.body, created: true)
    }

    /// Replay accepts only the stored ids, positions, and uploader. It does not write.
    func attachmentOrderMatches(message: StoredHumanMessage, attachmentIds: [String], uploaderId: String) -> Bool {
        guard message.attachmentIds.count == attachmentIds.count else { return false }
        for (index, id) in attachmentIds.enumerated() {
            guard message.attachmentIds[index] == id,
                  let row = channelAttachments[id],
                  row.messageId == message.id,
                  row.messagePosition == index,
                  row.uploaderId == uploaderId
            else { return false }
        }
        return true
    }

    public func channelMessageEvents() -> [ChannelMessageEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedChannelMessageEvents
    }

    func emitRealtime(_ room: String, _ event: String, _ payload: String?) {
        realtimeEmitterLock.lock()
        let emitter = realtimeEmitterStorage
        realtimeEmitterLock.unlock()
        emitter?(room, event, payload)
    }
}
