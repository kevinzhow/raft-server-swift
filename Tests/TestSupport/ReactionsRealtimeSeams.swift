import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func inboxFactsForTesting(messageId: String) -> [(receiverType: String, receiverId: String, personalMention: Bool, unreadEligible: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return inboxFactStore.all().filter { $0.messageId == messageId }.map {
            ($0.receiverType, $0.receiverId, $0.personalMention, $0.unreadEligible)
        }
    }

    public func markInboxResidueForTesting(userId: String, channelId: String) {
        lock.lock()
        inboxResidues.insert("\(userId)\n\(channelId)")
        lock.unlock()
    }

    public func addInboxFactForTesting(receiverId: String, serverId: String, channelId: String, messageId: String) {
        lock.lock()
        inboxFactStore.append(StoredInboxFact(
            messageId: messageId,
            receiverType: "user",
            receiverId: receiverId,
            channelId: channelId,
            serverId: serverId,
            personalMention: false
        ))
        lock.unlock()
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
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil,
            messageType: messageType,
            senderType: senderType,
            createdAt: createdAt
        ))
        lock.unlock()
        return id
    }

    @discardableResult
    public func addSystemMessageForTesting(channelId: String, content: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: "system",
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "user"
        ))
        lock.unlock()
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
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
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
        ))
        lock.unlock()
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
        let rendered = provider == "slack" ? content : Self.neutralizeExternalProjectionContent(content)
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
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
        ))
        lock.unlock()
        return id
    }
}
