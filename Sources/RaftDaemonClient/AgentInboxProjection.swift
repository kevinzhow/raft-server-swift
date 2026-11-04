import Foundation

/// Projection of delivered inbox messages into per-target inbox rows (the
/// "Inbox update" / snapshot rows), shared by the daemon and the server's
/// External Agent inbox notice push so both render identical rows. Ported from
/// the shared contract used by the daemon.
public enum AgentInboxFlags {
    public static let all = ["mention", "non_member_mention", "thread", "dm", "task"]
    public static let unknownDisplayLimit = 40
    public static let thirdPartyEventsTargetPrefix = "dm:@third-party-agent-events:"
    public static let thirdPartyEventsLabel = "Third-party app events"
    public static let nonMemberMentionReplyGuidance = "[Raft notice: You were notified as a non-member, so you cannot reply in that channel. If no reply is needed, no action is required. Otherwise, DM the person who mentioned you or join the channel to participate.]"
    public static let targetRowKeys = [
        "target", "channelId", "channelType", "pendingCount", "firstPendingMsgId", "firstPendingSeq",
        "latestMsgId", "latestSeq", "latestSenderName", "latestSenderType", "flags",
        "suppressedCount", "attentionHint",
    ]
    public static func isThirdPartyEventsTarget(_ target: String) -> Bool {
        target.hasPrefix(thirdPartyEventsTargetPrefix)
    }
}

public struct AttentionHintThresholds: Sendable, Equatable {
    public var K: Int?
    public var k: Int?
    public var windowMs: Int
    public init(K: Int? = nil, k: Int? = nil, windowMs: Int) {
        self.K = K
        self.k = k
        self.windowMs = windowMs
    }
}

public struct AttentionHint: Sendable, Equatable {
    public var schema: String
    public var trigger: String
    public var scope: String
    public var suggestedCommand: String
    public var copy: String
    public var copyVersion: Int
    public var epochMs: Int
    public var thresholds: AttentionHintThresholds
    public init(
        schema: String, trigger: String, scope: String, suggestedCommand: String,
        copy: String, copyVersion: Int, epochMs: Int, thresholds: AttentionHintThresholds
    ) {
        self.schema = schema
        self.trigger = trigger
        self.scope = scope
        self.suggestedCommand = suggestedCommand
        self.copy = copy
        self.copyVersion = copyVersion
        self.epochMs = epochMs
        self.thresholds = thresholds
    }

    var json: String {
        var thresholdParts: [String] = []
        if let upper = thresholds.K { thresholdParts.append("\"K\":\(upper)") }
        if let lower = thresholds.k { thresholdParts.append("\"k\":\(lower)") }
        thresholdParts.append("\"window_ms\":\(thresholds.windowMs)")
        return "{\"schema\":\(Self.quote(schema)),\"trigger\":\(Self.quote(trigger)),\"scope\":\(Self.quote(scope)),\"suggested_command\":\(Self.quote(suggestedCommand)),\"copy\":\(Self.quote(copy)),\"copy_version\":\(copyVersion),\"epoch_ms\":\(epochMs),\"thresholds\":{\(thresholdParts.joined(separator: ","))}}"
    }

    static func quote(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}

public struct AgentInboxProjectionMessage: Sendable, Equatable {
    public var seq: Int?
    public var id: String?
    public var messageId: String?
    public var channelId: String?
    public var channelType: String?
    public var channelName: String?
    public var parentChannelId: String?
    public var parentChannelType: String?
    public var parentChannelName: String?
    public var senderType: String?
    public var senderName: String?
    public var taskNumber: Int?
    public var taskStatus: String?
    public var mentioned: Bool?
    public var nonMemberMention: Bool?
    public var attentionHint: AttentionHint?

    public init(
        seq: Int? = nil, id: String? = nil, messageId: String? = nil,
        channelId: String? = nil, channelType: String? = nil, channelName: String? = nil,
        parentChannelId: String? = nil, parentChannelType: String? = nil, parentChannelName: String? = nil,
        senderType: String? = nil, senderName: String? = nil,
        taskNumber: Int? = nil, taskStatus: String? = nil,
        mentioned: Bool? = nil, nonMemberMention: Bool? = nil, attentionHint: AttentionHint? = nil
    ) {
        self.seq = seq
        self.id = id
        self.messageId = messageId
        self.channelId = channelId
        self.channelType = channelType
        self.channelName = channelName
        self.parentChannelId = parentChannelId
        self.parentChannelType = parentChannelType
        self.parentChannelName = parentChannelName
        self.senderType = senderType
        self.senderName = senderName
        self.taskNumber = taskNumber
        self.taskStatus = taskStatus
        self.mentioned = mentioned
        self.nonMemberMention = nonMemberMention
        self.attentionHint = attentionHint
    }
}

public struct AgentInboxTargetRow: Sendable, Equatable {
    public var target: String
    public var channelId: String?
    public var channelType: String?
    public var pendingCount: Int
    public var firstPendingMsgId: String?
    public var firstPendingSeq: Int?
    public var latestMsgId: String?
    public var latestSeq: Int?
    public var latestSenderName: String?
    public var latestSenderType: String?
    public var flags: [String] = []
    public var suppressedCount: Int?
    public var attentionHint: AttentionHint?

    public init(target: String, pendingCount: Int) {
        self.target = target
        self.pendingCount = pendingCount
    }
}

public enum AgentInboxProjection {
    static func usableCount(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value > 0, value <= Double(Int.max), value == value.rounded() else { return nil }
        return Int(value)
    }

    public static func formatInboxMessageTarget(_ message: AgentInboxProjectionMessage) -> String? {
        if message.channelType == "thread", let parentName = message.parentChannelName,
           let channelName = message.channelName {
            let raw = channelName.hasPrefix("thread-") ? String(channelName.dropFirst("thread-".count)) : channelName
            let shortId = String(raw.prefix(8))
            if message.parentChannelType == "dm" { return "dm:@\(parentName):\(shortId)" }
            return "#\(parentName):\(shortId)"
        }
        if message.channelType == "dm", let name = message.channelName { return "dm:@\(name)" }
        if let name = message.channelName { return "#\(name)" }
        return nil
    }

    static func messageId(_ message: AgentInboxProjectionMessage?) -> String? {
        guard let message else { return nil }
        if let messageId = message.messageId, !messageId.trimmingCharacters(in: .whitespaces).isEmpty { return messageId }
        if let id = message.id, !id.trimmingCharacters(in: .whitespaces).isEmpty { return id }
        return nil
    }

    static func messageSeq(_ message: AgentInboxProjectionMessage?) -> Int? {
        guard let message, let seq = message.seq, seq > 0 else { return nil }
        return seq
    }

    static func compareMessages(_ a: AgentInboxProjectionMessage, _ b: AgentInboxProjectionMessage) -> Bool {
        let seqA = messageSeq(a) ?? 0
        let seqB = messageSeq(b) ?? 0
        if seqA != seqB { return seqA < seqB }
        return (messageId(a) ?? "") < (messageId(b) ?? "")
    }

    public static func projectSnapshot(
        _ messages: [AgentInboxProjectionMessage],
        suppressedByTarget: [String: Double]? = nil
    ) -> [AgentInboxTargetRow] {
        var buckets: [String: [AgentInboxProjectionMessage]] = [:]
        var order: [String] = []
        for message in messages {
            guard let target = formatInboxMessageTarget(message) else { continue }
            if buckets[target] == nil { order.append(target) }
            buckets[target, default: []].append(message)
        }

        var rows: [AgentInboxTargetRow] = []
        for target in order {
            var row = projectBucket(target: target, messages: buckets[target] ?? [])
            if let suppressed = usableCount(suppressedByTarget?[target]) {
                row.suppressedCount = suppressed
            }
            rows.append(row)
        }
        // A target whose notifications were ALL suppressed has no messages and
        // therefore no bucket; it must still produce a row rather than vanish.
        for target in (suppressedByTarget ?? [:]).keys.sorted() where buckets[target] == nil {
            guard let suppressed = usableCount(suppressedByTarget?[target]) else { continue }
            var row = AgentInboxTargetRow(target: target, pendingCount: 0)
            row.suppressedCount = suppressed
            rows.append(row)
        }
        return rows.sorted { left, right in
            let leftSeq = left.latestSeq ?? 0
            let rightSeq = right.latestSeq ?? 0
            if leftSeq != rightSeq { return leftSeq > rightSeq }
            return left.target < right.target
        }
    }

    static func projectBucket(target: String, messages: [AgentInboxProjectionMessage]) -> AgentInboxTargetRow {
        let sorted = messages.sorted(by: compareMessages)
        guard let first = sorted.first, let latest = sorted.last else {
            return AgentInboxTargetRow(target: target, pendingCount: messages.count)
        }
        var flags: Set<String> = []
        for message in messages {
            if message.channelType == "thread" { flags.insert("thread") }
            if message.channelType == "dm" { flags.insert("dm") }
            if message.taskNumber != nil || message.taskStatus != nil { flags.insert("task") }
            if message.mentioned == true { flags.insert("mention") }
            if message.nonMemberMention == true { flags.insert("non_member_mention") }
        }
        let attentionHint = sorted.reversed().first { $0.attentionHint != nil }?.attentionHint
        var row = AgentInboxTargetRow(target: target, pendingCount: messages.count)
        row.channelId = latest.channelId ?? latest.parentChannelId
        row.channelType = latest.channelType
        row.firstPendingMsgId = messageId(first)
        row.firstPendingSeq = messageSeq(first)
        row.latestMsgId = messageId(latest)
        row.latestSeq = messageSeq(latest)
        row.latestSenderName = latest.senderName
        if let raw = latest.senderType, ["human", "agent", "system", "third_party_app"].contains(raw) {
            row.latestSenderType = raw
        }
        row.flags = flags.sorted()
        row.attentionHint = attentionHint
        return row
    }

    public static func formatSnapshot(_ rows: [AgentInboxTargetRow]) -> String {
        if rows.isEmpty { return "Inbox: empty" }
        let pending = rows.filter { $0.pendingCount > 0 }.count
        let suppressedOnly = rows.filter { $0.pendingCount == 0 && ($0.suppressedCount ?? 0) > 0 }.count
        let header: String
        if suppressedOnly > 0 {
            header = "Inbox: \(pending) pending target\(pending == 1 ? "" : "s") · \(suppressedOnly) target\(suppressedOnly == 1 ? "" : "s") with suppressed items"
        } else {
            header = "Inbox: \(rows.count) pending target\(rows.count == 1 ? "" : "s")"
        }
        var lines = [header, ""]
        for row in rows {
            lines.append(formatRowTarget(row))
            lines.append(formatRowDetails(row))
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingTrailingNewlines()
    }

    public static func formatDelta(_ rows: [AgentInboxTargetRow], totalPendingMessages: Int? = nil) -> String {
        let header: String
        if let total = totalPendingMessages {
            header = "Inbox update: \(total) message\(total == 1 ? "" : "s") pending your read across all conversations; \(rows.isEmpty ? "no" : "\(rows.count)") changed target\(rows.count == 1 ? "" : "s")"
        } else {
            header = "Inbox update: \(rows.count) changed target\(rows.count == 1 ? "" : "s")"
        }
        if rows.isEmpty {
            return totalPendingMessages != nil ? header : "Inbox update: no pending targets"
        }
        var lines = [header]
        lines.append(contentsOf: rows.map { "\(formatRowTarget($0))  \(formatRowDetails($0))" })
        return lines.joined(separator: "\n")
    }

    static func formatRowTarget(_ row: AgentInboxTargetRow) -> String {
        AgentInboxFlags.isThirdPartyEventsTarget(row.target) ? AgentInboxFlags.thirdPartyEventsLabel : row.target
    }

    static func formatRowDetails(_ row: AgentInboxTargetRow) -> String {
        var parts = ["pending: \(row.pendingCount) message\(row.pendingCount == 1 ? "" : "s")"]
        if let suppressed = row.suppressedCount, suppressed > 0 {
            parts.append("\(suppressed) suppressed (not delivered)")
        }
        if let first = row.firstPendingMsgId { parts.append("first msg=\(String(first.prefix(8)))") }
        if let sender = row.latestSenderName { parts.append("latest sender @\(sender)") }
        if let latest = row.latestMsgId { parts.append("latest msg=\(String(latest.prefix(8)))") }
        let isThirdParty = AgentInboxFlags.isThirdPartyEventsTarget(row.target)
        let flags = isThirdParty ? row.flags.filter { $0 != "dm" } : row.flags
        parts.append(contentsOf: flags.map(formatFlag))
        if let hint = row.attentionHint { parts.append("attention_hint=\(hint.json)") }
        if isThirdParty { parts.append("fetch with raft message check") }
        return parts.joined(separator: " · ")
    }

    static func formatFlag(_ flag: String) -> String {
        if flag == "mention" { return "you were mentioned" }
        if flag == "non_member_mention" { return AgentInboxFlags.nonMemberMentionReplyGuidance }
        if !AgentInboxFlags.all.contains(flag) {
            let bounded = flag.count > AgentInboxFlags.unknownDisplayLimit
                ? String(flag.prefix(AgentInboxFlags.unknownDisplayLimit)) + "…"
                : flag
            return "unknown inbox flag: \(AttentionHint.quote(bounded))"
        }
        return flag
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var value = self
        while value.hasSuffix("\n") { value.removeLast() }
        return value
    }
}
