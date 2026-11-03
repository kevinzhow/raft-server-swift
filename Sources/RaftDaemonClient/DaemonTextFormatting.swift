import Foundation

/// Pure formatting helpers shared by the daemon CLI surface. Ported from the
/// upstream daemon package so the same lines and hints appear on both sides.
public enum DaemonTextFormatting {
    /// `2026-04-15T00:00:00.000Z` -> `2026-04-15 00:00:00Z`; an unparsable value
    /// is echoed back unchanged (the upstream contract).
    public static func utcTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: value)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: value)
        }
        guard let date else { return value }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = TimeZone(secondsFromGMT: 0)
        output.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(output.string(from: date))Z"
    }

    public static func attachmentDownloadHint(style: String = "slock_cli") -> String {
        style == "mcp_tool"
            ? "use view_file to download"
            : "use `raft attachment view --id <attachmentId> --output <path>` to download"
    }

    public static func indentContinuationLines(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\n  ")
    }

    public struct HistoryAttachment: Sendable, Equatable {
        public var id: String
        public var filename: String
        public init(id: String, filename: String) {
            self.id = id
            self.filename = filename
        }
    }

    public struct HistoryMessageLine: Sendable, Equatable {
        public var seq: Int
        public var id: String?
        public var createdAt: String?
        public var senderType: String?
        public var senderName: String
        public var senderDescription: String?
        public var content: String
        public var attachments: [HistoryAttachment]?
        public var taskStatus: String?
        public var taskNumber: Int?
        public var taskAssigneeType: String?
        public var taskAssigneeId: String?
        public var threadId: String?
        public var replyCount: Int?
        public init(
            seq: Int,
            id: String? = nil,
            createdAt: String? = nil,
            senderType: String? = nil,
            senderName: String,
            senderDescription: String? = nil,
            content: String,
            attachments: [HistoryAttachment]? = nil,
            taskStatus: String? = nil,
            taskNumber: Int? = nil,
            taskAssigneeType: String? = nil,
            taskAssigneeId: String? = nil,
            threadId: String? = nil,
            replyCount: Int? = nil
        ) {
            self.seq = seq
            self.id = id
            self.createdAt = createdAt
            self.senderType = senderType
            self.senderName = senderName
            self.senderDescription = senderDescription
            self.content = content
            self.attachments = attachments
            self.taskStatus = taskStatus
            self.taskNumber = taskNumber
            self.taskAssigneeType = taskAssigneeType
            self.taskAssigneeId = taskAssigneeId
            self.threadId = threadId
            self.replyCount = replyCount
        }
    }

    public static func formatAttachmentSuffix(
        _ attachments: [HistoryAttachment]?,
        style: String = "slock_cli"
    ) -> String {
        guard let attachments, !attachments.isEmpty else { return "" }
        let list = attachments
            .map { "\(indentContinuationLines($0.filename)) (id:\($0.id))" }
            .joined(separator: ", ")
        let plural = attachments.count > 1 ? "s" : ""
        return " [\(attachments.count) attachment\(plural): \(list) — \(attachmentDownloadHint(style: style))]"
    }

    public static func formatHistoryMessageLine(_ message: HistoryMessageLine) -> String {
        var header = [
            "seq=\(message.seq)",
            "msg=\(message.id ?? "-")",
            "time=\(message.createdAt.map(utcTimestamp) ?? "-")",
        ]
        if let senderType = message.senderType { header.append("type=\(senderType)") }
        if let threadId = message.threadId { header.append("threadId=\(threadId)") }
        if (message.replyCount ?? 0) > 0 { header.append("replyCount=\(message.replyCount ?? 0)") }
        let handle = message.senderDescription.map { "@\(message.senderName) — \($0)" } ?? "@\(message.senderName)"
        let attachSuffix = formatAttachmentSuffix(message.attachments)
        var taskSuffix = ""
        if let status = message.taskStatus {
            taskSuffix = " [task #\(message.taskNumber ?? 0) status=\(status)"
            if let assigneeId = message.taskAssigneeId {
                taskSuffix += " assignee=\(message.taskAssigneeType ?? "human"):\(assigneeId)"
            }
            taskSuffix += "]"
        }
        return "[\(header.joined(separator: " "))] \(handle): \(message.content)\(attachSuffix)\(taskSuffix)"
    }
}
