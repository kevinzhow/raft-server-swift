import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func addMessageReactionForTesting(messageId: String, emoji: String, reactorId: String, reactorType: String) {
        messagesAndThreadsStore.withState { state in
            state.messageReactions.append(StoredReaction(messageId: messageId, emoji: emoji, reactorId: reactorId, reactorType: reactorType))
            let key = "\(messageId)\n\(emoji)"
            state.reactionDiscussionVersions[key] = (state.reactionDiscussionVersions[key] ?? 0) + 1
        }
    }

    public func markAgentLegacyReadForTesting(agentId: String, channelId: String, seq: Int) {
        messagesAndThreadsStore.withState { state in
            let key = "\(channelId)\n\(agentId)"
            let previous = state.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            state.agentChannelReadCursors[key] = (max(previous.seq, seq), previous.version + 1)
        }
    }

    public func agentReadCursorForTesting(agentId: String, channelId: String) -> Int {
        messagesAndThreadsStore.agentReadSeq(channelId: channelId, agentId: agentId)
    }

    public func setMachineModelSeenCapabilityForTesting(agentId: String, enabled: Bool) {
        machinesAndComputersStore.storage.withLock { state in
            if enabled { state.machineModelSeenCapability.insert(agentId) }
            else { state.machineModelSeenCapability.remove(agentId) }
        }
    }

    public func attestedSendEventsForTesting() -> [[String: Any]] {
        messagesAndThreadsStore.withState { state in
            state.attestedSendEventRecords.map { record in
                var row: [String: Any] = ["eventType": record.eventType, "agentId": record.agentId]
                if let messageId = record.messageId { row["messageId"] = messageId }
                row["metadata"] = (try? JSONSerialization.jsonObject(with: Data(record.metadataJSON.utf8))) ?? [:]
                return row
            }
        }
    }

    public func recentAgentSendActivityForTesting(agentId: String) -> [[String: String]] {
        messagesAndThreadsStore.withState { state in
            (state.agentSendActivityRecords[agentId] ?? []).map { entry in
                var row = ["title": entry.title, "text": entry.text]
                if let producerFactId = entry.producerFactId { row["producerFactId"] = producerFactId }
                return row
            }
        }
    }

    public func setSidebarReadAllEnabledForTesting(_ enabled: Bool) {
        serversAndChannelsStore.mutex.withLock { $0.sidebarReadAllEnabled = enabled }
    }

    public func serverMemberEventsForTesting(serverId: String, eventType: String?) -> [(subjectType: String, subjectId: String, provenanceJSON: String, deliveryQueued: Bool)] {
        serversAndChannelsStore.mutex.withLock { state in
            state.serverMemberEvents
                .filter { $0.serverId == serverId && (eventType == nil || $0.eventType == eventType) }
                .map { ($0.subjectType, $0.subjectId, $0.provenanceJSON, $0.deliveryQueued) }
        }
    }

    public func setJointProjectionStatusForTesting(localChannelId: String, serverId: String, status: String) {
        serversAndChannelsStore.mutex.withLock { state in
            if let index = state.jointProjections.firstIndex(where: { $0.localChannelId == localChannelId && $0.serverId == serverId }) {
                state.jointProjections[index].status = status
            }
        }
    }

    public func setAgentChannelJoinedAtForTesting(agentId: String, channelId: String, at: Date) {
        agentsRuntimeStore.withState { $0.agentChannelJoinedAt["\(channelId)\n\(agentId)"] = at }
    }
}
