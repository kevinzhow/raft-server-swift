import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    /// Turns on Computer and App references for one server. Installed apps stay
    /// empty until recorded separately.
    public func allowComposerResourceReferencesForTesting(serverId: String) {
        serversAndChannelsStore.mutex.withLock { _ = $0.composerResourceServers.insert(serverId) }
    }

    public func addPendingAgentMentionForTesting(
        messageId: String,
        channelId: String,
        senderAgentId: String,
        targetType: String,
        targetId: String,
        handle: String,
        createdAt: Date = Date()
    ) -> String {
        messagesAndThreadsStore.withState { state in
            let id = UUID().uuidString.lowercased()
            state.storedMentions.append(StoredMention(
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

            return id
        }
    }
}
