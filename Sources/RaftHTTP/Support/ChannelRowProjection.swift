import Foundation

/// Canonical channel-type eligibility for human Activity mute, mirroring the
/// upstream `channelTypeSupportsActivityMute` predicate: `channel`, `private`
/// and `joint` expose a user-reachable control; `dm` and `thread` do not.
enum ChannelActivityMuteSupport {
    static func supports(_ type: String) -> Bool {
        type == "channel" || type == "private" || type == "joint"
    }
}

/// Upstream's last-message summary normalization for `listDMChannels`:
/// `btrim(regexp_replace(content, '\s+', ' ', 'g'))`, then `null` when empty,
/// otherwise the first 139 characters plus `…` when longer than 140.
enum ChannelLastMessageSummary {
    static func preview(_ content: String) -> String? {
        var normalized = ""
        var pendingSpace = false
        for scalar in content.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !normalized.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                normalized.unicodeScalars.append(" ")
                pendingSpace = false
            }
            normalized.unicodeScalars.append(scalar)
        }
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > 140 else { return normalized }
        return String(normalized.prefix(139)) + "…"
    }
}
