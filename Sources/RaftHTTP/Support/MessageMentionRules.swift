import Foundation

public enum MessageMentionRules {
    static func mentionBindingConflict(_ mentions: [MentionInput]) -> Bool {
        var byName: [String: String] = [:]
        for mention in mentions where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id), !mention.name.isEmpty else { continue }
            let key = mention.name.lowercased()
            let signature = "\(mention.type):\(mention.id)"
            if let previous = byName[key], previous != signature { return true }
            byName[key] = signature
        }
        return false
    }

    static func mentionHandlesOutsideCode(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])@([A-Za-z0-9][A-Za-z0-9_.-]*)")
        var handles: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            var prose = String(line)
            prose = prose.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
            let full = NSRange(location: 0, length: (prose as NSString).length)
            for match in pattern.matches(in: prose, options: [], range: full) {
                handles.append((prose as NSString).substring(with: match.range(at: 1)))
            }
        }
        return handles
    }

    static func pendingMentionActionJSON(messageId: String, handle: String, avatarUrl: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAt = formatter.string(from: Date().addingTimeInterval(86_400))
        return OrderedJSON.object([
            OrderedJSONField("resolutionId", UUID().uuidString.lowercased()),
            OrderedJSONField("messageId", messageId), OrderedJSONField("targetType", "agent"),
            OrderedJSONField("targetHandle", handle), OrderedJSONField("targetAvatarUrl", optional: avatarUrl),
            OrderedJSONField("reason", "not_member"),
            OrderedJSONField("availableActions", .array([.string("notify")])), OrderedJSONField("expiresAt", expiresAt),
        ]).render()
    }
}
