import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func addMessageReactionForTesting(messageId: String, emoji: String, reactorId: String, reactorType: String) {
        lock.lock()
        messageReactions.append(StoredReaction(messageId: messageId, emoji: emoji, reactorId: reactorId, reactorType: reactorType))
        noteDiscussionChangeLocked(messageId: messageId, emoji: emoji)
        lock.unlock()
    }

    public func markAgentLegacyReadForTesting(agentId: String, channelId: String, seq: Int) {
        lock.lock()
        let key = "\(channelId)\n\(agentId)"
        let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
        agentChannelReadCursors[key] = (max(previous.seq, seq), previous.version + 1)
        lock.unlock()
    }

    public func agentReadCursorForTesting(agentId: String, channelId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
    }

    public func setMachineModelSeenCapabilityForTesting(agentId: String, enabled: Bool) {
        lock.lock()
        if enabled {
            machineModelSeenCapability.insert(agentId)
        } else {
            machineModelSeenCapability.remove(agentId)
        }
        lock.unlock()
    }

    /// Written attested-send events (`gate_triggered`, `e1_exempt`), oldest first.
    public func attestedSendEventsForTesting() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return attestedSendEventRecords.map { record in
            var row: [String: Any] = ["eventType": record.eventType, "agentId": record.agentId]
            if let messageId = record.messageId { row["messageId"] = messageId }
            row["metadata"] = (try? JSONSerialization.jsonObject(with: Data(record.metadataJSON.utf8))) ?? [:]
            return row
        }
    }

    /// Send-side activity log projections (held context / E1 exemption).
    public func recentAgentSendActivityForTesting(agentId: String) -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return (agentSendActivityRecords[agentId] ?? []).map { entry in
            var row = ["title": entry.title, "text": entry.text]
            if let producerFactId = entry.producerFactId { row["producerFactId"] = producerFactId }
            return row
        }
    }

    public func setSidebarReadAllEnabledForTesting(_ enabled: Bool) {
        lock.lock(); sidebarReadAllEnabled = enabled; lock.unlock()
    }

    public func serverMemberEventsForTesting(serverId: String, eventType: String?) -> [(subjectType: String, subjectId: String, provenanceJSON: String, deliveryQueued: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return serverMemberEvents
            .filter { $0.serverId == serverId && (eventType == nil || $0.eventType == eventType) }
            .map { ($0.subjectType, $0.subjectId, $0.provenanceJSON, $0.deliveryQueued) }
    }

    public func setJointProjectionStatusForTesting(localChannelId: String, serverId: String, status: String) {
        lock.lock()
        if let index = jointProjections.firstIndex(where: { $0.localChannelId == localChannelId && $0.serverId == serverId }) {
            jointProjections[index].status = status
        }
        lock.unlock()
    }

    public func setAgentChannelJoinedAtForTesting(agentId: String, channelId: String, at: Date) {
        lock.lock()
        var joined = agentsRuntimeStore.agentChannelJoinedAt
        joined["\(channelId)\n\(agentId)"] = at
        agentsRuntimeStore.agentChannelJoinedAt = joined
        lock.unlock()
    }
}
