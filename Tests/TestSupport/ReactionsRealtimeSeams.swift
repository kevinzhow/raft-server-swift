import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func inboxFactsForTesting(messageId: String) -> [(receiverType: String, receiverId: String, personalMention: Bool, unreadEligible: Bool)] {
        return inboxFactStore.all().filter { $0.messageId == messageId }.map {
            ($0.receiverType, $0.receiverId, $0.personalMention, $0.unreadEligible)
        }
    }

    public func markInboxResidueForTesting(userId: String, channelId: String) {
        messagesAndThreadsStore.withState { _ = $0.inboxResidues.insert("\(userId)\n\(channelId)") }
    }

    public func addInboxFactForTesting(receiverId: String, serverId: String, channelId: String, messageId: String) {
        inboxFactStore.append(StoredInboxFact(
            messageId: messageId,
            receiverType: "user",
            receiverId: receiverId,
            channelId: channelId,
            serverId: serverId,
            personalMention: false
        ))
    }

    @discardableResult
    public func addChannelMessageForTesting(
        id explicitId: String? = nil,
        channelId: String,
        content: String,
        senderId: String,
        createdAt: Date = Date(),
        senderType: String = "user",
        messageType: String = "chat"
    ) -> String {
        let id = explicitId ?? UUID().uuidString.lowercased()
        messagesAndThreadsStore.appendMessage(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil,
            messageType: messageType,
            senderType: senderType,
            createdAt: createdAt
        ), ledger: .init(oauth: oauth))
        return id
    }

    @discardableResult
    public func addSystemMessageForTesting(channelId: String, content: String) -> String {
        let id = UUID().uuidString.lowercased()
        messagesAndThreadsStore.appendMessage(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: "system",
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "user"
        ), ledger: .init(oauth: oauth))
        return id
    }

    @discardableResult
    public func addSystemNoticeForTesting(
        channelId: String,
        subtype: String,
        content: String,
        causalActorType: String? = nil,
        causalActorId: String? = nil
    ) -> String {
        let id = UUID().uuidString.lowercased()
        messagesAndThreadsStore.appendMessage(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: "system",
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "system",
            systemSubtype: subtype,
            causalActorType: causalActorType,
            causalActorId: causalActorId
        ), ledger: .init(oauth: oauth))
        return id
    }

    public func addExternalProjectionMessageForTesting(
        channelId: String,
        senderName: String,
        content: String,
        externalMessageId: String,
        provider: String = "slack"
    ) -> String {
        let id = UUID().uuidString.lowercased()
        let rendered = provider == "slack" ? content : ExternalProjectionFixturePolicy.neutralize(content)
        messagesAndThreadsStore.appendMessage(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: "external-projection-\(id.prefix(8))",
            content: rendered,
            randomId: nil,
            messageType: "chat",
            senderType: "external_projection",
            externalMessageId: externalMessageId,
            externalProvider: provider,
            externalSenderName: senderName
        ), ledger: .init(oauth: oauth))
        return id
    }
}

private enum ExternalProjectionFixturePolicy {
    /// Third-party content stays inert: mentions read as plain `user:<handle>`.
    static func neutralize(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        value = value.replacingOccurrences(of: "@([A-Za-z0-9_.-]+)", with: "user:$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "#([A-Za-z0-9_.-]+)", with: "channel:$1", options: .regularExpression)
        return value
    }

}
