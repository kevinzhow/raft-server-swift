import Foundation

public enum MessageSearchText {
    static func searchSnippet(_ content: String) -> String {
        let compact = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if compact.count <= 180 { return compact }
        return String(compact.prefix(177)) + "..."
    }

    static func searchTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        func flush() {
            let word = latin.lowercased()
            latin = ""
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            tokens.append(word)
        }
        for scalar in text.unicodeScalars {
            if MessageSearchText.isCJK(scalar) {
                flush()
                tokens.append(String(scalar))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                latin.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    static func tokenCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in MessageSearchText.searchTokens(text) {
            counts[token, default: 0] += 1
        }
        return counts
    }

    static func matchScore(_ counts: [String: Int], _ queryTokens: [String], requireAll: Bool) -> Int? {
        var total = 0
        for token in queryTokens {
            let count = counts[token] ?? 0
            if count == 0 {
                if requireAll { return nil }
                continue
            }
            total += count
        }
        return total > 0 ? total : nil
    }

    static func messageIdMatches(_ stored: String, _ given: String) -> Bool {
        if ServerScope.isUUID(given) {
            return stored.caseInsensitiveCompare(given) == .orderedSame
        }
        return stored.lowercased().hasPrefix(given.lowercased())
    }

    static func contextWindowSide(_ raw: String?) -> Int {
        guard let raw, raw.wholeMatch(of: /^\d+$/) != nil, let value = Int(raw) else { return 15 }
        return min(value, 15)
    }

    static func utf16Ascending(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        for index in 0..<min(left.count, right.count) where left[index] != right[index] {
            return left[index] < right[index]
        }
        return left.count < right.count
    }

    static func messageIdHasShortPrefix(_ id: String, prefix: String) -> Bool {
        let normalized = prefix.lowercased()
        guard normalized.count == 8, let start = UInt64(normalized, radix: 16) else { return false }
        let value = id.lowercased()
        let lower = normalized + "-0000-0000-0000-000000000000"
        guard value >= lower else { return false }
        let next = start + 1
        if next > 0xffff_ffff { return true }
        let hex = String(next, radix: 16)
        let upper = String(repeating: "0", count: 8 - hex.count) + hex + "-0000-0000-0000-000000000000"
        return value < upper
    }
}
