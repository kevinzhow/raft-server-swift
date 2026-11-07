import Foundation
import Synchronization

/// Per-turn activity summary (RFC 069 §6). One record per agent turn: when it
/// ran, how it ended, who woke the agent, the kinds of work it did, its
/// problems and last reply id. Ported from the shared upstream accumulator so
/// the daemon emits the same shape.
public struct DaemonTurnTrigger: Sendable, Equatable {
    public var target: String?
    public var channelId: String?
    public var sender: String?
    public var messageId: String?

    public init(target: String? = nil, channelId: String? = nil, sender: String? = nil, messageId: String? = nil) {
        self.target = target
        self.channelId = channelId
        self.sender = sender
        self.messageId = messageId
    }
}

public struct DaemonTurnProblem: Sendable, Equatable {
    public var kind: String
    public var reason: String
    public var exitCode: Int?
    public var at: Int

    public init(kind: String, reason: String, exitCode: Int? = nil, at: Int) {
        self.kind = kind
        self.reason = reason
        self.exitCode = exitCode
        self.at = at
    }
}

public struct DaemonTurnSummary: Sendable, Equatable {
    public var v: Int = 1
    public var startedAt: Int
    public var endedAt: Int
    public var outcome: String
    public var trigger: DaemonTurnTrigger?
    public var actions: [(kind: String, count: Int)]
    public var toolCalls: Int
    public var problems: [DaemonTurnProblem]
    public var problemCount: Int
    public var messagesSent: Int
    public var lastReplyMessageId: String?

    public static func == (lhs: DaemonTurnSummary, rhs: DaemonTurnSummary) -> Bool {
        lhs.v == rhs.v && lhs.startedAt == rhs.startedAt && lhs.endedAt == rhs.endedAt
            && lhs.outcome == rhs.outcome && lhs.trigger == rhs.trigger
            && lhs.actions.map { "\($0.kind):\($0.count)" } == rhs.actions.map { "\($0.kind):\($0.count)" }
            && lhs.toolCalls == rhs.toolCalls && lhs.problems == rhs.problems
            && lhs.problemCount == rhs.problemCount && lhs.messagesSent == rhs.messagesSent
            && lhs.lastReplyMessageId == rhs.lastReplyMessageId
    }
}

public enum DaemonTurnSummaryRules {
    public static let problemLimit = 20

    /// Whether a published activity ends the turn, and how.
    public static func outcomeForActivity(activityKind: String, detailKind: String?) -> String? {
        if activityKind == "online", detailKind == "idle" { return "completed" }
        if activityKind != "offline" { return nil }
        if detailKind == "runtime_crashed" || detailKind == "runtime_unavailable" { return "failed" }
        return "interrupted"
    }

    private static let checkCommand = try! NSRegularExpression(
        pattern: #"(?:^|[\s;&|/(])(?:vitest|jest|mocha|pytest|playwright|tsc|oxlint|eslint|ruff|mypy|cargo\s+(?:test|check|clippy)|go\s+(?:test|vet)|(?:npm|pnpm|yarn|bun)\s+(?:(?:--filter|-F)\s+\S+\s+)?(?:run\s+)?(?:test|typecheck|lint|check)\b|node\s+--test|run-vitest)"#
    )
    private static let vcsCommand = try! NSRegularExpression(pattern: #"^(?:git|stamp|gh|jj|hg)\s"#)
    private static let readCommand = try! NSRegularExpression(pattern: #"^(?:cat|head|tail|less|wc|sed\s+-n|nl|stat|file)\b"#)
    private static let searchCommand = try! NSRegularExpression(pattern: #"^(?:grep|rg|ag|find|fd|ls|tree)\b"#)
    private static let commandPrefix = try! NSRegularExpression(
        pattern: #"^(?:\s*(?:cd\s+[^;&|]+(?:&&|;)|export\s+[^;&|]+(?:&&|;)|[A-Za-z_][A-Za-z0-9_]*=\S*\s+))+"#
    )

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public static func classifyShellCommand(_ command: String) -> String {
        var body = command
        if let match = commandPrefix.firstMatch(in: command, range: NSRange(location: 0, length: (command as NSString).length)) {
            body = (command as NSString).replacingCharacters(in: match.range, with: "")
        }
        body = body.trimmingCharacters(in: .whitespaces)
        let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if matches(checkCommand, firstLine) { return "run_checks" }
        if matches(vcsCommand, firstLine) { return "version_control" }
        if matches(readCommand, firstLine) { return "read_file" }
        if matches(searchCommand, firstLine) { return "search" }
        return "run_command"
    }

    private static let semanticActions: [String: String] = [
        "send_message": "send_message", "check_messages": "read_messages", "wait_for_message": "read_messages",
        "receive_message": "read_messages", "read_history": "read_messages", "search_messages": "read_messages",
        "read_file": "read_file", "view_file": "read_file", "write_file": "edit_file", "edit_file": "edit_file",
        "bash": "run_command", "glob": "search", "grep": "search", "web_fetch": "fetch", "web_search": "web",
        "collab_tool_call": "subagent",
    ]

    private static let raftSemantics: Set<String> = [
        "list_server", "list_tasks", "create_tasks", "claim_tasks", "unclaim_task", "update_task_status",
        "add_channel_member", "join_channel", "leave_channel", "upload_file", "todo_write",
        "schedule_reminder", "list_reminders", "cancel_reminder",
    ]

    public static func classifyToolCall(toolName: String, toolInput: String) -> String {
        let command: String
        if toolInput.hasPrefix("{"), let data = toolInput.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["command"] as? String {
            command = value
        } else {
            command = toolInput
        }
        let lower = toolName.lowercased()
        if lower.contains("bash") || lower == "shell" { return classifyShellCommand(command) }
        if lower.contains("mcp__") || toolName.contains("/") { return "mcp" }
        if let action = semanticActions[lower] { return action }
        if raftSemantics.contains(lower) { return "raft_action" }
        return "other"
    }
}

/// A minimal trajectory entry: only what the summary folds.
public struct DaemonTrajectoryEntry: Sendable {
    public enum Kind: Sendable { case toolStart, toolEnd, other }
    public var kind: Kind
    public var toolName: String
    public var toolInput: String
    public var callId: String?
    public var ok: Bool?
    public var exitCode: Int?

    public init(kind: Kind, toolName: String = "", toolInput: String = "", callId: String? = nil, ok: Bool? = nil, exitCode: Int? = nil) {
        self.kind = kind
        self.toolName = toolName
        self.toolInput = toolInput
        self.callId = callId
        self.ok = ok
        self.exitCode = exitCode
    }

    public static func toolStart(toolName: String, toolInput: String, callId: String?) -> DaemonTrajectoryEntry {
        DaemonTrajectoryEntry(kind: .toolStart, toolName: toolName, toolInput: toolInput, callId: callId)
    }

    public static func toolEnd(callId: String?, ok: Bool?, exitCode: Int? = nil) -> DaemonTrajectoryEntry {
        DaemonTrajectoryEntry(kind: .toolEnd, callId: callId, ok: ok, exitCode: exitCode)
    }
}

public enum DaemonTurnSummaryEntry: Sendable, Equatable {
    case turnSummary(DaemonTurnSummary)
}

private struct DaemonTurnAccumulator: Sendable {
    private let startedAt: Int
    private let trigger: DaemonTurnTrigger?
    private var order: [String] = []
    private var counts: [String: Int] = [:]
    private var openCalls: [String: String] = [:]
    private var unmatched: [String] = []
    private var problems: [DaemonTurnProblem] = []
    private var problemCount = 0
    private var toolCalls = 0
    private var messagesSent = 0
    private var lastReplyMessageId: String?

    init(startedAt: Int, trigger: DaemonTurnTrigger?) {
        self.startedAt = startedAt
        self.trigger = trigger
    }

    mutating func add(_ entry: DaemonTrajectoryEntry, at: Int) {
        switch entry.kind {
        case .toolStart:
            let kind = DaemonTurnSummaryRules.classifyToolCall(toolName: entry.toolName, toolInput: entry.toolInput)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
            toolCalls += 1
            if let callId = entry.callId { openCalls[callId] = kind } else { unmatched.append(kind) }
        case .toolEnd:
            var kind = "other"
            if let callId = entry.callId, let open = openCalls[callId] {
                kind = open
                openCalls[callId] = nil
            } else if !unmatched.isEmpty {
                kind = unmatched.removeFirst()
            }
            if entry.ok == false {
                addProblem(DaemonTurnProblem(kind: kind, reason: "call_failed", exitCode: entry.exitCode, at: at))
            } else if let exitCode = entry.exitCode, exitCode != 0 {
                addProblem(DaemonTurnProblem(kind: kind, reason: "exit_nonzero", exitCode: exitCode, at: at))
            }
        case .other:
            break
        }
    }

    mutating func noteMessageSent(_ messageId: String?) {
        messagesSent += 1
        if let messageId { lastReplyMessageId = messageId }
    }

    mutating func noteSendHeld(at: Int) {
        addProblem(DaemonTurnProblem(kind: "send_message", reason: "send_held", at: at))
    }

    func finish(outcome: String, endedAt: Int) -> DaemonTurnSummary {
        let hasTrigger = trigger.map { $0.target != nil || $0.channelId != nil || $0.sender != nil || $0.messageId != nil } ?? false
        return DaemonTurnSummary(
            startedAt: startedAt,
            endedAt: max(endedAt, startedAt),
            outcome: outcome,
            trigger: hasTrigger ? trigger : nil,
            actions: order.map { ($0, counts[$0] ?? 0) },
            toolCalls: toolCalls,
            problems: problems,
            problemCount: problemCount,
            messagesSent: messagesSent,
            lastReplyMessageId: lastReplyMessageId
        )
    }

    private mutating func addProblem(_ problem: DaemonTurnProblem) {
        problemCount += 1
        if problems.count < DaemonTurnSummaryRules.problemLimit { problems.append(problem) }
    }
}

public final class DaemonTurnSummaryTracker: Sendable {
    private let open = Mutex<[String: DaemonTurnAccumulator]>([:])

    public init() {}

    public func begin(agentId: String, now: Int, trigger: DaemonTurnTrigger?, previousOutcome: String = "unknown") -> [DaemonTurnSummaryEntry] {
        open.withLock { open in
            let previous = finishLocked(&open, agentId: agentId, outcome: previousOutcome, now: now)
            open[agentId] = DaemonTurnAccumulator(startedAt: now, trigger: trigger)
            return previous
        }
    }

    public func observe(agentId: String, entries: [DaemonTrajectoryEntry], now: Int) {
        let relevant = entries.filter { $0.kind == .toolStart || $0.kind == .toolEnd }
        guard !relevant.isEmpty else { return }
        open.withLock { open in
            var acc = open.removeValue(forKey: agentId) ?? DaemonTurnAccumulator(startedAt: now, trigger: nil)
            for entry in relevant { acc.add(entry, at: now) }
            open[agentId] = acc
        }
    }

    public func noteSendOutcome(agentId: String, state: String, messageId: String?, now: Int) {
        open.withLock { open in
            guard var acc = open.removeValue(forKey: agentId) else { return }
            if state == "sent" { acc.noteMessageSent(messageId) } else { acc.noteSendHeld(at: now) }
            open[agentId] = acc
        }
    }

    public func finish(agentId: String, outcome: String, now: Int) -> [DaemonTurnSummaryEntry] {
        open.withLock { open in
            finishLocked(&open, agentId: agentId, outcome: outcome, now: now)
        }
    }

    private func finishLocked(_ open: inout [String: DaemonTurnAccumulator], agentId: String, outcome: String, now: Int) -> [DaemonTurnSummaryEntry] {
        guard let acc = open.removeValue(forKey: agentId) else { return [] }
        return [.turnSummary(acc.finish(outcome: outcome, endedAt: now))]
    }
}

/// The message that woke the agent: the first ordinary one handed over.
public struct DaemonAgentMessageInfo: Sendable {
    public var channelId: String
    public var channelName: String
    public var channelType: String
    public var parentChannelName: String?
    public var parentChannelType: String?
    public var senderName: String?
    public var messageId: String?

    public init(
        channelId: String, channelName: String, channelType: String,
        parentChannelName: String? = nil, parentChannelType: String? = nil,
        senderName: String? = nil, messageId: String? = nil
    ) {
        self.channelId = channelId
        self.channelName = channelName
        self.channelType = channelType
        self.parentChannelName = parentChannelName
        self.parentChannelType = parentChannelType
        self.senderName = senderName
        self.messageId = messageId
    }
}

public func turnTriggerFromMessages(_ messages: [DaemonAgentMessageInfo]) -> DaemonTurnTrigger? {
    guard let first = messages.first else { return nil }
    let target: String
    if first.channelType == "thread" {
        let suffix: String
        if first.channelName.hasPrefix("thread-") {
            suffix = String(first.channelName.dropFirst("thread-".count).prefix(8))
        } else {
            suffix = String(first.channelName.prefix(8))
        }
        let parent = first.parentChannelName ?? first.channelName
        target = "#\(parent):\(suffix)"
    } else if first.channelType == "dm" {
        target = "dm:@\(first.senderName ?? first.channelName)"
    } else {
        target = "#\(first.channelName)"
    }
    return DaemonTurnTrigger(
        target: target,
        channelId: first.channelId,
        sender: first.senderName,
        messageId: first.messageId
    )
}
