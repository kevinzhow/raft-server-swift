import Foundation

/// Anonymous message row for `GET /api/public/servers/:slug/channels/:id/messages`.
///
/// The HTTP body is an explicit projection. Actor ids and hidden control-plane
/// text stay on this value and are never written out.

public struct PublicHistorySender: Sendable {
    public var displayName: String
    public var handle: String?
    public var avatarUrl: String?
    public var description: String?
    public var actorId: String
    public var homeServerId: String?

    public init(
        displayName: String,
        handle: String?,
        avatarUrl: String?,
        description: String?,
        actorId: String,
        homeServerId: String? = nil
    ) {
        self.displayName = displayName
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.description = description
        self.actorId = actorId
        self.homeServerId = homeServerId
    }
}

public struct PublicHistoryReply: Sendable {
    public var id: String
    public var content: String
    public var createdAt: String
    public var seq: Int
    public var senderType: String
    public var sender: PublicHistorySender

    public init(
        id: String,
        content: String,
        createdAt: String,
        seq: Int,
        senderType: String,
        sender: PublicHistorySender
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.seq = seq
        self.senderType = senderType
        self.sender = sender
    }
}

public struct PublicHistoryAttachment: Sendable {
    public var id: String
    public var filename: String
    public var mimeType: String
    public var sizeBytes: Int
    public var width: Int?
    public var height: Int?
    /// Storage and thumbnail locations stay off the public body.
    public var storageKey: String?
    public var thumbnailKey: String?
    public var uploaderId: String?

    public init(
        id: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        width: Int?,
        height: Int?,
        storageKey: String? = nil,
        thumbnailKey: String? = nil,
        uploaderId: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.storageKey = storageKey
        self.thumbnailKey = thumbnailKey
        self.uploaderId = uploaderId
    }
}

public struct PublicHistoryMention: Sendable {
    public var type: String
    public var name: String
    public var displayName: String
    public var createdAt: String
    /// Target id is stored for the member fact and never serialized.
    public var targetId: String?

    public init(type: String, name: String, displayName: String, createdAt: String, targetId: String? = nil) {
        self.type = type
        self.name = name
        self.displayName = displayName
        self.createdAt = createdAt
        self.targetId = targetId
    }
}

public struct PublicHistoryReaction: Sendable {
    public var emoji: String
    public var createdAt: String
    /// Reactor id is stored so a count can be formed, and is never serialized.
    public var reactorId: String?

    public init(emoji: String, createdAt: String, reactorId: String? = nil) {
        self.emoji = emoji
        self.createdAt = createdAt
        self.reactorId = reactorId
    }
}

public struct PublicHistoryMessage: Sendable {
    public var id: String
    public var channelId: String
    public var content: String
    public var createdAt: String
    public var seq: Int
    public var messageType: String
    public var senderType: String
    public var sender: PublicHistorySender
    public var secret: String?
    public var threadId: String?
    public var replies: [PublicHistoryReply]
    public var attachments: [PublicHistoryAttachment]
    public var mentions: [PublicHistoryMention]
    public var reactions: [PublicHistoryReaction]

    public init(
        id: String,
        channelId: String,
        content: String,
        createdAt: String,
        seq: Int,
        messageType: String = "text",
        senderType: String,
        sender: PublicHistorySender,
        secret: String? = nil,
        threadId: String? = nil,
        replies: [PublicHistoryReply] = [],
        attachments: [PublicHistoryAttachment] = [],
        mentions: [PublicHistoryMention] = [],
        reactions: [PublicHistoryReaction] = []
    ) {
        self.id = id
        self.channelId = channelId
        self.content = content
        self.createdAt = createdAt
        self.seq = seq
        self.messageType = messageType
        self.senderType = senderType
        self.sender = sender
        self.secret = secret
        self.threadId = threadId
        self.replies = replies
        self.attachments = attachments
        self.mentions = mentions
        self.reactions = reactions
    }
}

/// Current members and agents used to highlight a typed `@name` that has no stored mention.
/// Actor ids stay off this value.
public struct PublicMentionDirectory: Sendable {
    public struct Entry: Sendable {
        public var type: String
        public var displayName: String

        public init(type: String, displayName: String) {
            self.type = type
            self.displayName = displayName
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public static let empty = PublicMentionDirectory()
}

public struct PublicHistoryResponse: JSONBodyConvertible {
    public let messages: [PublicHistoryMessage]
    public let serverId: String
    public let mentions: PublicMentionDirectory
    public var jsonBody: OrderedJSON {
        PublicHistoryProjection.messagesBody(messages, serverId: serverId, mentions: mentions)
    }
}

enum PublicHistoryProjection {
    static func messagesBody(
        _ messages: [PublicHistoryMessage],
        serverId: String,
        mentions directory: PublicMentionDirectory = .empty
    ) -> OrderedJSON {
        .object([.init("messages", .array(messages.map {
            messageBody($0, serverId: serverId, mentions: directory)
        }))])
    }

    static func messageBody(
        _ message: PublicHistoryMessage,
        serverId: String,
        mentions directory: PublicMentionDirectory = .empty
    ) -> OrderedJSON {
        let replies = message.replies.sorted { $0.seq < $1.seq }
        return .object([
            .init("id", message.id),
            .init("senderType", message.senderType),
            .init("sender", senderBody(message.sender, type: message.senderType, serverId: serverId)),
            .init("messageType", message.messageType),
            .init("content", message.content),
            .init("createdAt", message.createdAt),
            .init("attachments", .array(message.attachments.map(attachmentBody))),
            .init("mentions", .array(visibleMentions(message, directory: directory).map(mentionBody))),
            .init("reactions", .array(groupedReactions(message.reactions).map(reactionBody))),
            .init("threadId", optional: message.threadId),
            .init("replyCount", replies.count),
            .init("lastReplyAt", optional: replies.last?.createdAt),
            .init("latestReplies", .array(replies.suffix(3).map { replyBody($0, serverId: serverId) })),
        ])
    }

    /// Stored facts whose token is still in the content, then typed `@name`s that name a current member or agent.
    /// External-origin text does not consult that directory.
    static func visibleMentions(_ message: PublicHistoryMessage, directory: PublicMentionDirectory) -> [PublicHistoryMention] {
        let ordered = message.mentions.sorted {
            $0.createdAt == $1.createdAt ? $0.name < $1.name : $0.createdAt < $1.createdAt
        }
        var kept: [PublicHistoryMention] = []
        for fact in ordered {
            guard mentionAppears(message.content, handle: fact.name) else { continue }
            if kept.contains(where: { $0.name == fact.name }) { continue }
            kept.append(fact)
        }
        guard message.senderType != "external_projection" else { return kept }
        let known = Set(kept.map(\.name))
        for handle in mentionHandles(message.content) where !known.contains(handle) {
            guard let entry = directory.entries[handle] else { continue }
            kept.append(PublicHistoryMention(
                type: entry.type,
                name: handle,
                displayName: entry.displayName,
                createdAt: ""
            ))
        }
        return kept
    }

    /// Free-text `@handle`s outside markdown code, in first-seen order.
    static func mentionHandles(_ content: String) -> [String] {
        let prose = stripMarkdownCode(content)
        var handles: [String] = []
        var seen = Set<String>()
        let chars = Array(prose)
        var index = 0
        while index < chars.count {
            if chars[index] == "@" {
                let leftOpen = index == 0 || !continuesHandle(chars[index - 1])
                if leftOpen {
                    var end = index + 1
                    while end < chars.count, continuesHandle(chars[end]) { end += 1 }
                    if end > index + 1 {
                        let handle = String(chars[(index + 1)..<end])
                        if seen.insert(handle).inserted { handles.append(handle) }
                        index = end
                        continue
                    }
                }
            }
            index += 1
        }
        return handles
    }

    /// Drops fenced and inline code so a backtick `@name` is not a mention.
    private static func stripMarkdownCode(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix("```") {
                let after = source.index(index, offsetBy: 3)
                if let close = source[after...].range(of: "```") {
                    index = close.upperBound
                    out.append(" ")
                    continue
                }
                break
            }
            if source[index] == "`" {
                let after = source.index(after: index)
                if let close = source[after...].firstIndex(of: "`") {
                    index = source.index(after: close)
                    out.append(" ")
                    continue
                }
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }

    static func groupedReactions(_ reactions: [PublicHistoryReaction]) -> [(emoji: String, count: Int)] {
        var first: [String: String] = [:]
        var count: [String: Int] = [:]
        for reaction in reactions {
            count[reaction.emoji, default: 0] += 1
            if let existing = first[reaction.emoji] {
                if reaction.createdAt < existing { first[reaction.emoji] = reaction.createdAt }
            } else {
                first[reaction.emoji] = reaction.createdAt
            }
        }
        return count.keys.sorted { lhs, rhs in
            let left = first[lhs] ?? ""
            let right = first[rhs] ?? ""
            return left == right ? lhs < rhs : left < right
        }.map { ($0, count[$0] ?? 0) }
    }

    private static func attachmentBody(_ item: PublicHistoryAttachment) -> OrderedJSON {
        .object([
            .init("id", item.id), .init("filename", normalizeFilename(item.filename)),
            .init("mimeType", resolveMime(item.mimeType)), .init("sizeBytes", item.sizeBytes),
            .init("width", optional: item.width), .init("height", optional: item.height),
        ])
    }

    private static func mentionBody(_ item: PublicHistoryMention) -> OrderedJSON {
        .object([
            .init("type", item.type), .init("name", item.name),
            .init("displayName", item.displayName.isEmpty ? item.name : item.displayName),
        ])
    }

    private static func reactionBody(_ item: (emoji: String, count: Int)) -> OrderedJSON {
        .object([.init("emoji", item.emoji), .init("count", item.count)])
    }

    /// ASCII names pass through. A non-ASCII name is left unchanged until a test needs the latin1 repair.
    private static func normalizeFilename(_ filename: String) -> String {
        filename
    }

    private static func resolveMime(_ mimeType: String) -> String {
        let normalized = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty, normalized != "application/octet-stream" { return normalized }
        return normalized.isEmpty ? "application/octet-stream" : normalized
    }

    /// `@handle` still visible, with the same right-edge rule as `createRaftStructuredUserRefRegex`.
    static func mentionAppears(_ content: String, handle: String) -> Bool {
        guard handle.wholeMatch(of: /^[\p{L}\p{N}_-]+$/) != nil else { return false }
        let needle = "@" + handle
        var rest = content[...]
        while let range = rest.range(of: needle) {
            let after = rest[range.upperBound...]
            if let next = after.first, continuesHandle(next), !isCJK(next) {
                rest = after
                continue
            }
            return true
        }
        return false
    }

    private static func continuesHandle(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return CharacterSet.letters.contains(scalar)
            || CharacterSet.decimalDigits.contains(scalar)
            || scalar == "_"
            || scalar == "-"
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    static func replyBody(_ reply: PublicHistoryReply, serverId: String) -> OrderedJSON {
        .object([
            .init("messageId", reply.id), .init("seq", reply.seq), .init("preview", reply.content),
            .init("senderType", reply.senderType),
            .init("senderName", senderName(reply.sender, type: reply.senderType, serverId: serverId)),
            .init("senderAvatarUrl", optional: avatarURL(reply.sender, type: reply.senderType, serverId: serverId)),
            .init("createdAt", reply.createdAt),
        ])
    }

    static func page<Item: SequenceItem>(_ items: [Item], limit: Int, beforeId: String?) -> [Item]? {
        let sorted = items.sorted { $0.seq < $1.seq }
        let pool: [Item]
        if let beforeId {
            guard let index = sorted.firstIndex(where: { $0.id == beforeId }) else { return nil }
            pool = Array(sorted.prefix(index))
        } else {
            pool = sorted
        }
        if pool.isEmpty { return [] }
        let start = max(0, pool.count - limit)
        return Array(pool[start...])
    }

    private static func senderBody(_ sender: PublicHistorySender, type: String, serverId: String) -> OrderedJSON {
        let foreignAgent = type == "agent" && sender.homeServerId.map { $0 != serverId } == true
        return .object([
            .init("displayName", senderName(sender, type: type, serverId: serverId)),
            .init("handle", optional: foreignAgent ? nil : sender.handle),
            .init("avatarUrl", optional: avatarURL(sender, type: type, serverId: serverId)),
            .init("description", optional: foreignAgent ? nil : sender.description),
        ])
    }

    private static func senderName(_ sender: PublicHistorySender, type: String, serverId: String) -> String {
        if type == "agent", let home = sender.homeServerId, home != serverId {
            return "Unknown agent"
        }
        return sender.displayName
    }

    private static func avatarURL(_ sender: PublicHistorySender, type: String, serverId: String) -> String? {
        if type == "agent", let home = sender.homeServerId, home != serverId { return nil }
        if type == "user" { return storedUserAvatar(sender.avatarUrl) }
        if type == "agent" { return storedAgentAvatar(sender.avatarUrl, serverId: serverId) }
        return nil
    }

    static func storedUserAvatar(_ avatarUrl: String?) -> String? {
        guard let avatarUrl else { return nil }
        guard avatarUrl.range(of: #"^/(?:api/)?avatars/users/[0-9a-fA-F]{32}\.webp$"#, options: .regularExpression) != nil else {
            return nil
        }
        return avatarUrl
    }

    static func storedAgentAvatar(_ avatarUrl: String?, serverId: String) -> String? {
        guard let avatarUrl else { return nil }
        let scope = NSRegularExpression.escapedPattern(for: serverId)
        let pattern = "^/(?:api/)?avatars/\(scope)/[0-9a-fA-F]{32}\\.webp$"
        guard avatarUrl.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return avatarUrl
    }
}

protocol SequenceItem {
    var id: String { get }
    var seq: Int { get }
}

extension PublicHistoryMessage: SequenceItem {}
extension PublicHistoryReply: SequenceItem {}
