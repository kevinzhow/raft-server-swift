import Foundation

/// Renders the concrete-message block an agent runtime receives. Every
/// header-looking line lives at column 0; continuation lines (body, sender
/// text, attachment names, thread context) are prefixed with `  │ ` so a
/// line-anchored reader can never see a forged header. Ported from the
/// upstream daemon runtime input formatter.
public struct RuntimeInputMessage: Sendable {
    public var messageId: String
    public var channelId: String
    public var channelName: String
    public var channelType: String
    public var parentChannelName: String?
    public var parentChannelType: String?
    public var senderId: String
    public var senderName: String
    public var senderType: String
    public var senderDescription: String?
    public var content: String
    public var timestamp: String
    public var mentioned: Bool?
    public var threadFollowReactivation: RuntimeInputReactivation?
    public var threadJoinContext: RuntimeInputThreadJoinContext?
    public var attachments: [RuntimeInputAttachment]

    public init(
        messageId: String, channelId: String, channelName: String, channelType: String,
        parentChannelName: String? = nil, parentChannelType: String? = nil,
        senderId: String, senderName: String, senderType: String,
        senderDescription: String? = nil, content: String, timestamp: String,
        mentioned: Bool? = nil, threadFollowReactivation: RuntimeInputReactivation? = nil,
        threadJoinContext: RuntimeInputThreadJoinContext? = nil,
        attachments: [RuntimeInputAttachment] = []
    ) {
        self.messageId = messageId
        self.channelId = channelId
        self.channelName = channelName
        self.channelType = channelType
        self.parentChannelName = parentChannelName
        self.parentChannelType = parentChannelType
        self.senderId = senderId
        self.senderName = senderName
        self.senderType = senderType
        self.senderDescription = senderDescription
        self.content = content
        self.timestamp = timestamp
        self.mentioned = mentioned
        self.threadFollowReactivation = threadFollowReactivation
        self.threadJoinContext = threadJoinContext
        self.attachments = attachments
    }
}

public struct RuntimeInputReactivation: Sendable {
    public var threadTarget: String
    public init(threadTarget: String) { self.threadTarget = threadTarget }
}

public struct RuntimeInputAttachment: Sendable {
    public var id: String
    public var filename: String
    public var mimeType: String
    public var sizeBytes: Int
    public init(id: String, filename: String, mimeType: String, sizeBytes: Int) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

public struct RuntimeInputContextMessage: Sendable {
    public var messageId: String
    public var senderName: String
    public var senderType: String
    public var content: String
    public var timestamp: String
    public var seq: Int
    public init(messageId: String, senderName: String, senderType: String, content: String, timestamp: String, seq: Int) {
        self.messageId = messageId
        self.senderName = senderName
        self.senderType = senderType
        self.content = content
        self.timestamp = timestamp
        self.seq = seq
    }
}

public struct RuntimeInputThreadJoinContext: Sendable {
    public var reason: String
    public var parentTarget: String
    public var threadTarget: String
    public var suggestedReadHistoryTarget: String
    public var parentMessage: RuntimeInputContextMessage?
    public var recentMessages: [RuntimeInputContextMessage]
    public var historyTruncated: Bool
    public init(
        reason: String, parentTarget: String, threadTarget: String, suggestedReadHistoryTarget: String,
        parentMessage: RuntimeInputContextMessage? = nil, recentMessages: [RuntimeInputContextMessage] = [],
        historyTruncated: Bool = false
    ) {
        self.reason = reason
        self.parentTarget = parentTarget
        self.threadTarget = threadTarget
        self.suggestedReadHistoryTarget = suggestedReadHistoryTarget
        self.parentMessage = parentMessage
        self.recentMessages = recentMessages
        self.historyTruncated = historyTruncated
    }
}

public enum ConcreteMessagesRuntimeInput {
    /// Every separator `splitlines()` recognises; all are neutralised.
    static let separators: [Character] = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}"]

    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for character in text {
            if separators.contains(character) {
                lines.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        lines.append(current)
        return lines
    }

    /// First line inline, later lines prefixed so they cannot start a header.
    static func neutralized(_ text: String) -> String {
        splitLines(text).enumerated().map { index, line in
            index == 0 ? line : "  │ \(line)"
        }.joined(separator: "\n")
    }

    static func singleLine(_ text: String) -> String {
        splitLines(text).joined(separator: " ")
    }

    static func formatTimestamp(_ raw: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else {
            return raw
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    static func target(_ message: RuntimeInputMessage) -> String {
        let base = "#\(message.parentChannelName ?? message.channelName)"
        return message.channelType == "thread" ? "\(base):\(message.channelName)" : base
    }

    static func contextLine(_ context: RuntimeInputContextMessage) -> String {
        let first = "- [msg=\(context.messageId) seq=\(context.seq) time=\(formatTimestamp(context.timestamp)) type=\(context.senderType)] @\(singleLine(context.senderName)): "
        return first + neutralized(context.content)
    }

    public static func format(_ messages: [RuntimeInputMessage], driver: String = "slock_cli") -> String {
        messages.map { message in
            var lines: [String] = []
            if let reactivation = message.threadFollowReactivation {
                lines.append("Note: this @mention re-subscribed you to ordinary replies in this thread.")
                lines.append("Run `raft thread unfollow --target \"\(reactivation.threadTarget)\"` to leave it again.")
            }
            if let join = message.threadJoinContext {
                lines.append("Thread context (joined because \(join.reason)); history: \(join.threadTarget)")
                if let parent = join.parentMessage {
                    lines.append(contextLine(parent))
                }
                for recent in join.recentMessages {
                    lines.append(contextLine(recent))
                }
                if join.historyTruncated {
                    lines.append("- ... history truncated ...")
                }
            }
            var header = "[target=\(target(message)) msg=\(message.messageId) time=\(formatTimestamp(message.timestamp)) type=\(message.senderType)] @\(singleLine(message.senderName)): \(neutralized(message.content))"
            if let description = message.senderDescription {
                header += "\n  from: \(neutralized(description))"
            }
            for attachment in message.attachments {
                header += "\n  attachment: \(neutralized(attachment.filename)) (\(attachment.mimeType), \(attachment.sizeBytes) bytes)"
            }
            lines.append(header)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
