import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func insertHumanMessage(id: String, channelId: String, senderId: String, content: String, messageType: String = "chat", senderType: String = "user", actionKind: String? = nil) {
        messagesAndThreadsStore.appendMessage(StoredHumanMessage(
            id: id, channelId: channelId, senderId: senderId, content: content,
            messageType: messageType, senderType: senderType, actionKind: actionKind
        ), ledger: .init(oauth: oauth))
    }

    public func setHumanMessageTask(messageId: String, status: String, number: Int, assigneeType: String, assigneeId: String, claimedAt: String, completedAt: String) {
        messagesAndThreadsStore.withState { state in
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
                state.humanMessageRows[index].taskStatus = status
                state.humanMessageRows[index].taskNumber = number
                state.humanMessageRows[index].taskAssigneeType = assigneeType
                state.humanMessageRows[index].taskAssigneeId = assigneeId
                state.humanMessageRows[index].taskClaimedAt = claimedAt
                state.humanMessageRows[index].taskCompletedAt = completedAt
            }
        }
    }

    public func recordAgentMentionDelivery(messageId: String, agentId: String, handle: String, terminalCode: String) {
        messagesAndThreadsStore.withState { state in
            let message = state.humanMessageRows.first { $0.id == messageId }
            state.storedMentions.append(StoredMention(
                id: UUID().uuidString.lowercased(),
                messageId: messageId,
                channelId: message?.channelId ?? "",
                senderId: message?.senderId ?? "",
                targetType: "agent",
                targetId: agentId,
                handle: handle,
                notifiableAtSend: true,
                notifiedAt: nil,
                notifiedByType: nil,
                notifiedById: nil,
                notifiedAction: nil,
                terminalCode: terminalCode
            ))
        }
    }

    public func addMessageMention(
        messageId: String,
        targetType: String,
        targetId: String,
        notifiableAtSend: Bool = true,
        notifiedAt: Date? = nil,
        notifiedByType: String? = nil,
        notifiedById: String? = nil,
        notifiedAction: String? = nil
    ) {
        messagesAndThreadsStore.withState { state in
            let message = state.humanMessageRows.first { $0.id == messageId }
            state.storedMentions.append(StoredMention(
                id: UUID().uuidString.lowercased(),
                messageId: messageId,
                channelId: message?.channelId ?? "",
                senderId: message?.senderId ?? "",
                targetType: targetType,
                targetId: targetId,
                handle: "",
                notifiableAtSend: notifiableAtSend,
                notifiedAt: notifiedAt,
                notifiedByType: notifiedByType,
                notifiedById: notifiedById,
                notifiedAction: notifiedAction
            ))
        }
    }

    public func setHumanMessageCreatedAt(messageId: String, createdAt: Date) {
        messagesAndThreadsStore.withState { state in
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
                state.humanMessageRows[index].createdAt = createdAt
            }
        }
    }

    public func markMessageSystem(messageId: String) {
        messagesAndThreadsStore.withState { state in
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
                state.humanMessageRows[index].messageType = "system"
            }
        }
    }

    public func archiveChannel(channelId: String) {
        serversAndChannelsStore.mutex.withLock { state in
            state.postableChannels[channelId]?.archived = true
        }
    }

    public func markChannelDeleted(channelId: String) {
        serversAndChannelsStore.mutex.withLock { state in
            state.postableChannels[channelId]?.deletedAt = Date()
        }
    }

    public func removeChannelMember(channelId: String, memberId: String) {
        serversAndChannelsStore.mutex.withLock { state in
            _ = state.postableChannels[channelId]?.memberIds.remove(memberId)
        }
    }

    public func humanMessageRandomIds(channelId: String) -> [String] {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.filter { $0.channelId == channelId }.compactMap(\.randomId)
        }
    }

    public func humanMessageIds(channelId: String) -> [String] {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.filter { $0.channelId == channelId }.map(\.id)
        }
    }

    public func storedSenderTimezone(messageId: String) -> String? {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.first { $0.id == messageId }?.senderTimezone
        }
    }

    public func mentionActionRecord(id: String) -> MentionActionRecord? {
        messagesAndThreadsStore.withState { state in
            guard let row = state.storedMentions.first(where: { $0.id == id }) else { return nil }
            return MentionActionRecord(
                notified: row.notifiedAt != nil,
                notifiedByType: row.notifiedByType,
                notifiedById: row.notifiedById,
                notifiedAction: row.notifiedAction
            )
        }
    }

    public func channelAgentIds(channelId: String) -> [String] {
        agentsRuntimeStore.withState { state in
            return Array(state.channelAgentMembers[channelId] ?? []).sorted()
        }
    }

    public func channelMemberIds(channelId: String) -> [String] {
        serversAndChannelsStore.mutex.withLock { state in
            return Array(state.postableChannels[channelId]?.memberIds ?? []).sorted()
        }
    }

    public func messageMentionRows(messageId: String) -> [MentionFact] {
        messagesAndThreadsStore.withState { state in
            return state.storedMentions.filter { $0.messageId == messageId }.map {
                MentionFact(targetType: $0.targetType, targetId: $0.targetId, notifiableAtSend: $0.notifiableAtSend, notified: $0.notifiedAt != nil)
            }
        }
    }

    public func inboxFacts(messageId: String, receiverIds: [String]) -> [InboxFact] {
        let wanted = Set(receiverIds)
        return inboxFactStore.all().filter { $0.messageId == messageId && wanted.contains($0.receiverId) }.map {
            InboxFact(
                receiverType: $0.receiverType,
                receiverId: $0.receiverId,
                personalMention: $0.personalMention,
                unreadEligible: $0.unreadEligible
            )
        }
    }

    public func agentDeliveries(agentId: String) -> [String] {
        agentsRuntimeStore.withState { state in
            return state.storedAgentDeliveries.filter { $0.agentId == agentId }.map(\.messageId)
        }
    }

    public func agentDeliveryChannelTypes(agentId: String) -> [String] {
        agentsRuntimeStore.withState { state in
            return state.storedAgentDeliveries.filter { $0.agentId == agentId }.map(\.channelType)
        }
    }

    public func addServerAgent(serverId: String, id: String, name: String, avatarUrl: String?, status: String = "inactive") {
        agentsRuntimeStore.withState { state in
            state.serverAgents[id] = ServerAgent(id: id, serverId: serverId, name: name, avatarUrl: avatarUrl, status: status)
        }
    }

    /// A message-domain server agent that also exists in the OAuth agent ledger.
    /// The machine-authenticated legacy routes resolve the canonical agent row
    /// before applying machine ownership, so fixtures that exercise those
    /// routes seed both projections with the same id.
    public func addLedgerServerAgent(
        serverId: String, id: String, name: String, avatarUrl: String?, status: String = "inactive"
    ) {
        addServerAgent(serverId: serverId, id: id, name: name, avatarUrl: avatarUrl, status: status)
        oauth.state.withLock { state in
            state.agents[id] = OAuthLedger.Agent(
                id: id,
                serverId: serverId,
                name: name,
                displayName: name,
                avatarUrl: avatarUrl,
                description: nil,
                status: status
            )
            state.agentRoles["\(serverId)\n\(id)"] = "member"
        }
    }

    public func setForwardedBundle(messageId: String, items: [ForwardedSource]) {
        messagesAndThreadsStore.withState { state in
            state.forwardedBundles[messageId] = items
        }
    }

    public func addChannelAttachment(
        channelId: String,
        uploaderId: String,
        filename: String,
        mimeType: String? = nil,
        sizeBytes: Int? = nil,
        messageId: String? = nil,
        bytes: Data? = nil
    ) -> String {
        if let bytes, let sizeBytes { precondition(bytes.count == sizeBytes) }
        return messagesAndThreadsStore.withState { state in
            let id = UUID().uuidString.lowercased()
            state.channelAttachments[id] = ChannelAttachment(
                id: id,
                channelId: channelId,
                uploaderId: uploaderId,
                filename: filename,
                messageId: messageId,
                messagePosition: nil,
                mimeType: mimeType,
                sizeBytes: bytes?.count ?? sizeBytes
            )
            if let bytes { state.developmentAttachmentBytes[id] = bytes }

            return id
        }
    }

    public func linkedAttachmentPositions(ids: [String]) -> [(id: String, messagePosition: Int)] {
        messagesAndThreadsStore.withState { state in
            return ids.compactMap { id in
                guard let position = state.channelAttachments[id]?.messagePosition else { return nil }
                return (id, position)
            }.sorted { $0.messagePosition < $1.messagePosition }
        }
    }

    public func linkedAttachmentRecords(ids: [String]) -> [(id: String, messageId: String?, messagePosition: Int?)] {
        messagesAndThreadsStore.withState { state in
            return ids.compactMap { id in
                guard let row = state.channelAttachments[id] else { return nil }
                return (row.id, row.messageId, row.messagePosition)
            }.sorted { ($0.messagePosition ?? -1) < ($1.messagePosition ?? -1) }
        }
    }

    public func addChannelAgent(channelId: String, agentId: String) {
        agentsRuntimeStore.withState { state in
            var members = state.channelAgentMembers[channelId] ?? []
            members.insert(agentId)
            state.channelAgentMembers[channelId] = members
        }
    }

    public func storedMessageReactionActors(messageId: String) -> [(reactorType: String, reactorId: String)] {
        messagesAndThreadsStore.withState { state in
            return state.messageReactions.filter { $0.messageId == messageId }.map { ($0.reactorType, $0.reactorId) }
        }
    }

    public func storedMessageReactions(messageId: String) -> [(emoji: String, reactorId: String)] {
        messagesAndThreadsStore.withState { state in
            return state.messageReactions.filter { $0.messageId == messageId }.map { ($0.emoji, $0.reactorId) }
        }
    }
}
