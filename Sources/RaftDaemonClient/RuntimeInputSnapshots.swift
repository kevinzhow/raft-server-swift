import Foundation

/// Turn-input copy the daemon hands an agent at wake/resume time. These are
/// snapshots: complete output, independent of the runtime delivery mode.
/// Ported from the upstream daemon runtime input copy.
public struct UnreadTarget: Sendable, Equatable {
    public var target: String
    public var count: Int
    public init(target: String, count: Int) {
        self.target = target
        self.count = count
    }
}

public struct InboxTargetSummary: Sendable, Equatable {
    public var target: String
    public var pendingCount: Int
    public var firstMessageId: String
    public var latestSenderName: String
    public var latestMessageId: String
    public init(target: String, pendingCount: Int, firstMessageId: String, latestSenderName: String, latestMessageId: String) {
        self.target = target
        self.pendingCount = pendingCount
        self.firstMessageId = firstMessageId
        self.latestSenderName = latestSenderName
        self.latestMessageId = latestMessageId
    }
}

public enum RuntimeInputSnapshots {
    public static func formatResumeEmptyPrompt() -> String {
        "No new messages while you were away. Nothing to do — just stop."
    }

    public static func formatResumeUnreadSummaryPrompt(_ unread: [UnreadTarget]) -> String {
        let lines = unread.map { "- \($0.target): \($0.count) unread" }.joined(separator: "\n")
        return """
        You have unread messages from while you were offline:
        \(lines)

        Use `raft message read` to catch up on the channels listed above, then stop. Read each listed channel at most once unless a read fails. Do NOT call `raft message check` in this mode. If the history reveals a direct request, assignment, @mention, review request, or task clearly addressed to you, switch into active handling instead of stopping: reply using `raft message send --target <exact target>` and claim the relevant task with `raft task claim` before starting work. Otherwise, do NOT send any message in this mode.
        """
    }

    static func pluralized(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    public static func formatInboxUpdateRuntimeInput(
        _ targets: [InboxTargetSummary],
        pendingMessages: Int,
        changedTargets: Int
    ) -> String {
        let messageCopy = pluralized(pendingMessages, "message", "messages")
        let targetCopy = pluralized(changedTargets, "changed target", "changed targets")
        var lines: [String] = [
            "[Raft inbox notice:",
            "Inbox update: \(messageCopy) pending your read across all conversations; \(targetCopy)",
        ]
        for target in targets {
            let pending = pluralized(target.pendingCount, "message", "messages")
            lines.append(
                "\(target.target)  pending: \(pending) · first msg=\(target.firstMessageId) · latest sender @\(target.latestSenderName) · latest msg=\(target.latestMessageId)"
            )
        }
        lines.append("]")
        lines.append("These messages have not been read. Choose when to read them: `raft message read --target <target> --unread` reads one conversation's unread messages; `raft message check` reads all of them.")
        return lines.joined(separator: "\n")
    }

    static func unreadList(_ unread: [UnreadTarget]) -> String {
        unread.map { "- \($0.target): \($0.count) unread" }.joined(separator: "\n")
    }

    public static func formatOtherUnreadChannelsSuffix(_ unread: [UnreadTarget]?) -> String {
        guard let unread, !unread.isEmpty else { return "" }
        return """


        You also have unread messages in other channels:
        \(unreadList(unread))

        Run `raft inbox check` at a natural breakpoint if you choose to inspect those targets; it lists every unread conversation with the command that opens it.
        """
    }

    public static func formatBoundedStartupUnreadSuffix(_ unread: [UnreadTarget]?) -> String {
        guard let unread, !unread.isEmpty else { return "" }
        return """


        Some unread channels may not be included in this bounded startup batch:
        \(unreadList(unread))

        Run `raft inbox check` at a natural breakpoint if you choose to inspect those targets; it lists every unread conversation with the command that opens it.
        """
    }
}
