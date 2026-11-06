import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func addPendingAgentMentionForTesting(
        messageId: String,
        channelId: String,
        senderAgentId: String,
        targetType: String,
        targetId: String,
        handle: String,
        createdAt: Date = Date()
    ) -> String {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        storedMentions.append(StoredMention(
            id: id,
            messageId: messageId,
            channelId: channelId,
            senderId: senderAgentId,
            targetType: targetType,
            targetId: targetId,
            handle: handle,
            notifiableAtSend: false,
            createdAt: createdAt,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil
        ))
        lock.unlock()
        return id
    }
}
