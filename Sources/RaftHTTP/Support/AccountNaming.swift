import Foundation

public enum AccountNaming {
    static func normalizeDisplayLocale(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        if value == "zh-cn" || value == "zh" || value == "zh-hans" || value == "zh-hans-cn" { return "zh-cn" }
        return nil
    }

    static let reservedAgentNames: Set<String> = [
        "all", "human", "humans", "agent", "agents", "here", "idle", "busy", "system", "reminders",
    ]

    static func pendingHandle(taken: Set<String>) -> String {
        for _ in 0..<10 {
            let handle = "pending_\(AuthTokenCodec.randomHex(10))"
            if !taken.contains(handle) { return handle }
        }
        return "pending_\(AuthTokenCodec.randomHex(10))"
    }

    static func slugifyUserName(_ seed: String) -> String {
        let lowered = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var normalized = ""
        for scalar in lowered.unicodeScalars {
            let value = scalar.value
            let allowed = (value >= 97 && value <= 122) || (value >= 48 && value <= 57) || value == 95 || value == 45
            normalized.append(allowed ? Character(scalar) : "-")
        }
        normalized = AccountNaming.trimHyphens(normalized)
        let prefixed = normalized.first?.isLetter == true ? normalized : "user-\(normalized)"
        var compact = ""
        var previousHyphen = false
        for character in prefixed {
            if character == "-" {
                if previousHyphen { continue }
                previousHyphen = true
            } else {
                previousHyphen = false
            }
            compact.append(character)
        }
        compact = AccountNaming.trimHyphens(compact)
        let fallback = compact.isEmpty ? "user-account" : compact
        return fallback.count >= 5 ? fallback : "\(fallback)-user"
    }

    static func availableUserName(seed: String, taken: Set<String>) -> String {
        let base = AccountNaming.slugifyUserName(seed)
        if !taken.contains(base) { return base }
        for suffix in 1..<100 {
            let candidate = "\(base)-\(suffix + 1)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(base)-\(AuthTokenCodec.randomHex(2))"
    }

    static func isReservedAgentName(_ name: String) -> Bool {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("@") { normalized.removeFirst() }
        return reservedAgentNames.contains(normalized.lowercased())
    }

    // MARK: - Shared handle validation

    /// Pinned `packages/shared/src/index.ts` `NAME_MAX_LENGTH`.
    static let nameMaxLength = 32

    /// Pinned `NAME_REGEX`: a letter first, then letters, numbers, `_` and `-`.
    ///
    /// The upstream pattern runs with the Unicode `u` flag, so `\p{L}` and
    /// `\p{N}` are Unicode general categories, not ASCII classes.
    private static let nameRegex = #"^[\p{L}][\p{L}\p{N}_-]*$"#

    /// Why a handle is invalid, matching pinned `validateNameReason`.
    enum NameValidationReason: Sendable, Equatable {
        case required
        case tooShort(minLength: Int)
        case tooLong(maxLength: Int)
        case pattern
    }

    /// Pinned `validateNameReason`: trim, then empty / minimum / maximum /
    /// pattern, in that order.
    ///
    /// Lengths count UTF-16 code units because the upstream checks JavaScript
    /// `String.length`; `String.count` would accept some multi-scalar names the
    /// server rejects.
    static func validateNameReason(_ name: String, minLength: Int = 1) -> NameValidationReason? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = trimmed.utf16.count
        if length == 0 { return .required }
        if length < minLength { return .tooShort(minLength: minLength) }
        if length > nameMaxLength { return .tooLong(maxLength: nameMaxLength) }
        guard let match = trimmed.range(of: nameRegex, options: [.regularExpression]),
              match == trimmed.startIndex..<trimmed.endIndex
        else { return .pattern }
        return nil
    }

    /// Pinned `validateName`: the exact English sentence the server publishes,
    /// or `nil` when the handle is valid.
    ///
    /// `label` and `minLength` are parameters so `complete-profile`/register
    /// (`Name`, 5) and the account username-available precheck (`Username`, 5)
    /// share one implementation and produce the same text.
    static func validateName(_ name: String, _ label: String = "Name", minLength: Int = 1) -> String? {
        guard let reason = validateNameReason(name, minLength: minLength) else { return nil }
        switch reason {
        case .required:
            return "\(label) is required"
        case .tooShort(let minimum):
            return "\(label) must be at least \(minimum) characters"
        case .tooLong(let maximum):
            return "\(label) must be at most \(maximum) characters"
        case .pattern:
            return "\(label) must start with a letter and can only contain letters, numbers, hyphens, and underscores"
        }
    }

    static let maxProfileAvatarBytes = 5 * 1024 * 1024

    /// Pinned `routes/auth.ts:93` `MAX_USER_DESCRIPTION_LENGTH`.
    static let maxUserDescriptionLength = 3000

    static func trimHyphens(_ value: String) -> String {
        var text = value
        while text.hasPrefix("-") { text.removeFirst() }
        while text.hasSuffix("-") { text.removeLast() }
        return text
    }

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static let timezoneAliases: [String: String] = [
        "US/Pacific": "America/Los_Angeles",
        "US/Eastern": "America/New_York",
        "US/Central": "America/Chicago",
        "US/Mountain": "America/Denver",
        "US/Alaska": "America/Anchorage",
        "US/Hawaii": "Pacific/Honolulu",
    ]
}
