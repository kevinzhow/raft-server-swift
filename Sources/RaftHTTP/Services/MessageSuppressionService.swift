import Foundation

/// Reads the current mute preferences and mention rows without constructing
/// either the execute service or the tool-execution service.
struct MessageSuppressionService: Sendable {
    private let messages: MessagesAndThreadsStore
    private let oauth: OAuthLedger

    init(messages: MessagesAndThreadsStore, oauth: OAuthLedger) {
        self.messages = messages
        self.oauth = oauth
    }

    func isSuppressed(_ message: StoredHumanMessage, agentId: String) -> Bool {
        MessagesAndThreadsStore.agentMessageSuppressed(
            message,
            agentId: agentId,
            prefs: oauth.notificationPrefs(channelId: message.channelId, userId: agentId),
            mentions: messages.storedMentions
        )
    }
}
