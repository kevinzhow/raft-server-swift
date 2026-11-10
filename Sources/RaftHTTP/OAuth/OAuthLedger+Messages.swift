import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public func createChannelMessage(
        channelId: String,
        content: String,
        createdAt: Date = Date(),
        senderId: String = "user"
    ) -> Date {
        self.state.withLock { ledgerState in
            let seq = ledgerState.channelMessages.filter { $0.channelId == channelId }.count
                + ledgerState.channelSystemMessages.filter { $0.channelId == channelId }.count + 1
            ledgerState.channelMessages.append(ChannelMessageRecord(
                id: UUID().uuidString.lowercased(),
                channelId: channelId,
                content: content,
                createdAt: createdAt,
                senderId: senderId,
                seq: seq
            ))
        }
        return createdAt
    }

    /// Records a message row the directory already sequenced. The directory
    /// keeps the authoritative message list; this mirror makes the same rows
    /// visible to the ledger-backed reads (history, thread anchors).
    public func appendMirroredMessage(
        id: String,
        channelId: String,
        content: String,
        senderId: String,
        seq: Int,
        createdAt: Date,
        senderTimezone: String?,
        senderType: String?,
        messageType: String?
    ) {
        self.state.withLock { ledgerState in
            if !ledgerState.channelMessages.contains(where: { $0.id == id }) {
                ledgerState.channelMessages.append(ChannelMessageRecord(
                    id: id,
                    channelId: channelId,
                    content: content,
                    createdAt: createdAt,
                    senderId: senderId,
                    seq: seq,
                    senderTimezone: senderTimezone,
                    senderType: senderType,
                    messageType: messageType
                ))
            }
        }
    }

    public func createMessageRecord(
        channelId: String,
        content: String,
        senderId: String,
        id explicitId: String? = nil,
        seq explicitSeq: Int? = nil,
        createdAt: Date = Date(),
        senderTimezone: String? = nil,
        senderType: String? = nil,
        messageType: String? = nil,
        systemSubtype: String? = nil,
        causalActorType: String? = nil,
        causalActorId: String? = nil
    ) -> (id: String, seq: Int) {
        return self.state.withLock { ledgerState in
            let seq = explicitSeq ?? (ledgerState.channelMessages.filter { $0.channelId == channelId }.count
                + ledgerState.channelSystemMessages.filter { $0.channelId == channelId }.count + 1)
            let id = explicitId ?? UUID().uuidString.lowercased()
            ledgerState.channelMessages.append(ChannelMessageRecord(
                id: id,
                channelId: channelId,
                content: content,
                createdAt: createdAt,
                senderId: senderId,
                seq: seq,
                senderTimezone: senderTimezone,
                senderType: senderType,
                messageType: messageType,
                systemSubtype: systemSubtype,
                causalActorType: causalActorType,
                causalActorId: causalActorId
            ))
            return (id, seq)
        }
    }
    public struct SavedMessageInfo: Sendable {
        public var messageId: String
        public var savedAt: Int
        public var content: String
        public var channelId: String
        public var channelType: String
        public var parentChannelId: String?
        public var parentMessageId: String?
        public var parentMessagePreview: String?
        public var replyCount: Int
    }

    public func createThreadChannel(parentChannelId: String, parentMessageId: String) -> String {
        return self.state.withLock { ledgerState in
            let id = UUID().uuidString.lowercased()
            ledgerState.channelRecords.append(ChannelRecord(
                id: id,
                serverId: ledgerState.channelRecords.first(where: { $0.id == parentChannelId })?.serverId ?? "",
                name: "",
                type: "thread",
                parentChannelId: parentChannelId,
                parentMessageId: parentMessageId,
                createdAt: Date()
            ))
            return id
        }
    }

    public struct HistoryMessage: Sendable {
        public var id: String
        public var content: String
        public var senderId: String
        public var seq: Int
        public var createdAt: Date
        public var senderTimezone: String?
        public var senderType: String?
        public var messageType: String?
    }

    public func historyMessages(channelId: String) -> [HistoryMessage] {
        return self.state.withLock { ledgerState in
            return ledgerState.channelMessages
                .filter { $0.channelId == channelId }
                .sorted { $0.seq < $1.seq }
                .map { HistoryMessage(id: $0.id, content: $0.content, senderId: $0.senderId, seq: $0.seq, createdAt: $0.createdAt, senderTimezone: $0.senderTimezone, senderType: $0.senderType, messageType: $0.messageType) }
        }
    }

    public func reminderMessageMetadata(id: String) -> (channelId: String, senderId: String, senderType: String, messageType: String, systemSubtype: String?, causalActorId: String?)? {
        return self.state.withLock { ledgerState in
            guard let message = ledgerState.channelMessages.first(where: { $0.id == id }) else { return nil }
            return (message.channelId, message.senderId, message.senderType ?? "user", message.messageType ?? "chat", message.systemSubtype, message.causalActorId)
        }
    }
    public func messageTranslationMetadata(id: String) -> (channelId: String, content: String, senderId: String, senderType: String, messageType: String)? {
        return self.state.withLock { ledgerState in
            guard let message = ledgerState.channelMessages.first(where: { $0.id == id }) else { return nil }
            return (message.channelId, message.content, message.senderId, message.senderType ?? "user", message.messageType ?? "chat")
        }
    }

    public func messageContent(id: String) -> (channelId: String, content: String)? {
        return self.state.withLock { ledgerState in
            guard let message = ledgerState.channelMessages.first(where: { $0.id == id }) else { return nil }
            return (message.channelId, message.content)
        }
    }

    public func messageChannelId(_ messageId: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelMessages.first(where: { $0.id == messageId })?.channelId
        }
    }

    public func saveMessage(userId: String, messageId: String) -> Bool {
        return self.state.withLock { ledgerState in
            guard let message = ledgerState.channelMessages.first(where: { $0.id == messageId }) else { return false }
            if ledgerState.savedMessageRecords.contains(where: { $0.userId == userId && $0.messageId == messageId }) {
                return true
            }
            ledgerState.savedMessageCounter += 1
            ledgerState.savedMessageRecords.append(SavedMessageRecord(userId: userId, messageId: messageId, savedAt: ledgerState.savedMessageCounter))
            _ = message
            return true
        }
    }

    public func savedMessages(userId: String) -> [SavedMessageInfo] {
        return self.state.withLock { ledgerState in
            return ledgerState.savedMessageRecords
                .filter { $0.userId == userId }
                .compactMap { saved -> SavedMessageInfo? in
                    guard let message = ledgerState.channelMessages.first(where: { $0.id == saved.messageId }),
                          let channel = ledgerState.channelRecords.first(where: { $0.id == message.channelId })
                    else { return nil }
                    let parentPreview = channel.parentMessageId.flatMap { parentId in
                        ledgerState.channelMessages.first(where: { $0.id == parentId })?.content
                    }
                    let replyCount = channel.type == "thread"
                        ? ledgerState.channelMessages.filter { $0.channelId == channel.id }.count
                        : 0
                    return SavedMessageInfo(
                        messageId: saved.messageId,
                        savedAt: saved.savedAt,
                        content: message.content,
                        channelId: channel.id,
                        channelType: channel.type,
                        parentChannelId: channel.parentChannelId,
                        parentMessageId: channel.parentMessageId,
                        parentMessagePreview: parentPreview,
                        replyCount: replyCount
                    )
                }
        }
    }

    struct SavedMessageRecord: Sendable {
        var userId: String
        var messageId: String
        var savedAt: Int
    }
    struct ChannelRecord: Sendable {
        var id: String
        var serverId: String
        var name: String
        var type: String
        var description: String?
        var parentChannelId: String?
        var parentMessageId: String?
        var archived = false
        var archivedAt: Date?
        /// Creation time of the channel row. Optional because snapshots
        /// written before this fact was retained decode it as absent; the
        /// route projection then publishes `null` instead of inventing a time.
        var createdAt: Date?
    }

    struct ChannelMessageRecord: Sendable {
        var id: String
        var channelId: String
        var content: String
        var createdAt: Date
        var senderId: String
        var seq: Int
        var senderTimezone: String? = nil
        var senderType: String? = nil
        var messageType: String? = nil
        var systemSubtype: String? = nil
        var causalActorType: String? = nil
        var causalActorId: String? = nil
    }
}
