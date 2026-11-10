import Foundation

public enum MessageMentionRules {
    static let pendingLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Regex class contents for the same ECMAScript whitespace set. ICU's
    /// shorthand also matches NEL, so it is not the source JavaScript class.
    static let javaScriptWhitespaceClass = #"\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"#

    /// ECMAScript WhiteSpace and LineTerminator set. Foundation also trims NEL,
    /// which JavaScript preserves, so use the actual source string semantics.
    static func trimmingJavaScriptWhitespace(_ value: String) -> String {
        let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        return value.trimmingCharacters(in: whitespace)
    }

    static func mentionBindingConflict(_ mentions: [MentionInput]) -> Bool {
        var byName: [String: String] = [:]
        for mention in mentions where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id), !mention.name.isEmpty else { continue }
            let signature = "\(mention.type):\(mention.id)"
            if let previous = byName[mention.name], previous != signature { return true }
            byName[mention.name] = signature
        }
        return false
    }

    /// A typed identity has no left boundary. Each run is original authored
    /// prose outside actual parser ranges; labels/code never become identities.
    static func structuredMentionStillAppears(_ surface: MessageMentionSurface, handle: String) -> Bool {
        guard handle.range(of: #"^[\p{L}\p{N}_-]+$"#, options: .regularExpression) != nil else { return false }
        if surface.linkedHandles.contains(handle) { return true }
        let escaped = NSRegularExpression.escapedPattern(for: handle)
        let cjk = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#
        let pattern = "@" + escaped + "(?!(?!" + cjk + #")[\p{L}\p{N}_-])"#
        return surface.runs.contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    static func mentionHandlesOutsideCode(_ surface: MessageMentionSurface) -> [String] {
        let pattern = #"(^|[^\p{L}\p{N}_-])@([\p{L}\p{N}_-]+)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        var handles = surface.runs.flatMap { run in
            let text = run as NSString
            return expression.matches(in: run, range: NSRange(location: 0, length: text.length))
                .map { text.substring(with: $0.range(at: 2)) }
        }
        handles.append(contentsOf: surface.linkedHandles)
        var seen = Set<String>()
        return handles.filter { seen.insert($0).inserted }
    }

    static func resolvedHandle(_ token: String, known: Set<String>) -> String? {
        if known.contains(token) { return token }
        let scalars = Array(token.unicodeScalars)
        guard scalars.count > 1 else { return nil }
        var splits: [(Int, String)] = []
        for length in 1..<scalars.count {
            let handle = String(String.UnicodeScalarView(scalars.prefix(length)))
            let next = String(scalars[length])
            if handle.range(of: #"[\p{Latin}\p{N}_-]$"#, options: .regularExpression) != nil,
               next.range(of: #"^[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil,
               known.contains(handle) { splits.append((length, handle)) }
        }
        guard splits.count == 1, let split = splits.first else { return nil }
        if split.0 + 1 < scalars.count {
            for length in (split.0 + 1)..<scalars.count {
                if known.contains(String(String.UnicodeScalarView(scalars.prefix(length)))) { return nil }
            }
        }
        return split.1
    }

    static func expiry(_ createdAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: createdAt.addingTimeInterval(pendingLifetime))
    }

    /// Only an already retained mention can produce a pending action identity.
    static func pendingMentionActionJSON(mention: StoredMention, avatarUrl: String?, actions: [String]) -> String {
        OrderedJSON.object([
            OrderedJSONField("resolutionId", mention.id), OrderedJSONField("messageId", mention.messageId),
            OrderedJSONField("targetType", mention.targetType), OrderedJSONField("targetHandle", mention.handle),
            OrderedJSONField("targetAvatarUrl", avatarUrl.map(OrderedJSON.string) ?? .null),
            OrderedJSONField("reason", "not_member"),
            OrderedJSONField("availableActions", .array(actions.map(OrderedJSON.string))),
            OrderedJSONField("expiresAt", expiry(mention.createdAt)),
        ]).render()
    }
}
