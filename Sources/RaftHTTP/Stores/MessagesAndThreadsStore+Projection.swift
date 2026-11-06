import Foundation

extension MessagesAndThreadsStore {
    func reactionRows(messageId: String) -> [StoredReaction] {
        withState { $0.messageReactions.filter { $0.messageId == messageId } }
    }

    func forwardRecord(messageId: String) -> StoredForwardRecord? {
        withState { $0.forwardRecords[messageId] }
    }

    func threadProjectionRows(channelIds: Set<String>) -> [StoredHumanMessage] {
        withState { $0.humanMessageRows.filter { channelIds.contains($0.channelId) } }
    }

    func recordAttestedSendEvent(_ record: AttestedSendEventRecord) {
        withState { $0.attestedSendEventRecords.append(record) }
    }

    func recordAgentSendActivity(agentId: String, title: String, text: String, producerFactId: String?) {
        withState { $0.agentSendActivityRecords[agentId, default: []].append((title, text, producerFactId)) }
    }
}
