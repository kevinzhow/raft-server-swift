import Foundation

/// Frontmatter scalar parsing for SKILL.md metadata: a deliberately small YAML
/// subset (plain/quoted scalars, literal and folded blocks with chomping and an
/// explicit indentation indicator). Unsupported syntax fails closed to the
/// empty string rather than leaking raw text. Ported from the upstream daemon
/// metadata reader.
public enum SkillFrontmatter {
    struct BlockHeader {
        var folded: Bool
        var chomp: String  // strip | keep | clip
        var explicitIndent: Int?
    }

    static let alwaysIndicator: Set<Character> = [",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "%", "@", "`", "'", "\""]
    static let spaceSensitiveIndicator: Set<Character> = ["-", "?", ":"]

    static func parseBlockHeader(_ raw: String) -> BlockHeader? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: "^([|>])([1-9]?)([-+]?)\\s*(?:#.*)?$"),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed))
        else { return nil }
        func group(_ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: trimmed) else { return nil }
            return String(trimmed[range])
        }
        let style = group(1) ?? ""
        let digits = group(2) ?? ""
        let chompChar = group(3) ?? ""
        return BlockHeader(
            folded: style == ">",
            chomp: chompChar == "-" ? "strip" : chompChar == "+" ? "keep" : "clip",
            explicitIndent: digits.isEmpty ? nil : Int(digits)
        )
    }

    static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    static func stripPlainComment(_ value: String) -> String {
        if let range = value.range(of: "\\s#", options: .regularExpression) {
            return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    static func isUnsupportedPlainScalar(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        if alwaysIndicator.contains(first) { return true }
        if spaceSensitiveIndicator.contains(first) {
            if value.count == 1 { return true }
            let second = value[value.index(after: value.startIndex)]
            return second == " " || second == "\t"
        }
        return false
    }

    /// Read a quoted scalar; returns nil when it never closes or carries
    /// trailing junk that is not a comment.
    static func unquote(_ value: String) -> String? {
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        var index = value.index(after: value.startIndex)
        var inner = ""
        var closed = false
        while index < value.endIndex {
            let character = value[index]
            if quote == "\"" && character == "\\" {
                let nextIndex = value.index(after: index)
                if nextIndex < value.endIndex {
                    let next = value[nextIndex]
                    if next == "\"" || next == "\\" { inner.append(next) } else { inner.append("\\\(next)") }
                    index = value.index(after: nextIndex)
                    continue
                }
            }
            if character == quote {
                if quote == "'" {
                    let nextIndex = value.index(after: index)
                    if nextIndex < value.endIndex && value[nextIndex] == "'" {
                        inner.append("'")
                        index = value.index(after: nextIndex)
                        continue
                    }
                }
                closed = true
                break
            }
            inner.append(character)
            index = value.index(after: index)
        }
        guard closed else { return nil }
        let rest = String(value[value.index(after: index)...])
        if rest.trimmingCharacters(in: .whitespaces).isEmpty { return inner }
        if rest.range(of: "^\\s+#", options: .regularExpression) != nil { return inner }
        return nil
    }

    static func applyChomp(_ lines: [String], _ chomp: String) -> String {
        var lastContent = -1
        for index in stride(from: lines.count - 1, through: 0, by: -1) where !lines[index].isEmpty {
            lastContent = index
            break
        }
        if lastContent == -1 {
            return chomp == "keep" ? String(repeating: "\n", count: lines.count) : ""
        }
        let content = lines[0...lastContent].joined(separator: "\n")
        if chomp == "strip" { return content }
        if chomp == "clip" { return content + "\n" }
        return content + String(repeating: "\n", count: lines.count - lastContent)
    }

    static func foldLines(_ lines: [String]) -> String {
        var out = ""
        var pendingBreaks = 0
        var started = false
        var previousWasMoreIndented = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingBreaks += 1
                continue
            }
            let moreIndented = line.first == " " || line.first == "\t"
            if !started {
                out = String(repeating: "\n", count: pendingBreaks) + line
                started = true
                previousWasMoreIndented = moreIndented
                pendingBreaks = 0
                continue
            }
            let structural = (moreIndented || previousWasMoreIndented) ? 1 : 0
            let breaks = pendingBreaks + structural
            out += breaks > 0 ? String(repeating: "\n", count: breaks) : " "
            out += line
            previousWasMoreIndented = moreIndented
            pendingBreaks = 0
        }
        return out
    }

    static func fold(_ lines: [String], _ chomp: String) -> String {
        var lastContent = -1
        for index in stride(from: lines.count - 1, through: 0, by: -1) where !lines[index].isEmpty {
            lastContent = index
            break
        }
        if lastContent == -1 {
            return chomp == "keep" ? String(repeating: "\n", count: lines.count) : ""
        }
        var folded = foldLines(Array(lines[0...lastContent]))
        while folded.hasSuffix("\n") { folded.removeLast() }
        if chomp == "strip" { return folded }
        if chomp == "clip" { return folded + "\n" }
        return folded + String(repeating: "\n", count: lines.count - lastContent)
    }

    public static func parse(_ rawContent: String) -> [String: String] {
        let content = rawContent.replacingOccurrences(of: "\r\n", with: "\n")
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\r?\\n([\\s\\S]*?)\\r?\\n---", options: [.anchorsMatchLines]
        ) else { return [:] }
        let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: fullRange),
              let bodyRange = Range(match.range(at: 1), in: content)
        else { return [:] }
        let lines = String(content[bodyRange]).components(separatedBy: "\n")
        var result: [String: String] = [:]

        func isStructural(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") && line.contains(":")
        }
        var baseIndent = Int.max
        for line in lines where isStructural(line) {
            baseIndent = min(baseIndent, indentWidth(line))
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                index += 1
                continue
            }
            if indentWidth(line) > baseIndent {
                index += 1
                continue
            }
            guard let colonIndex = line.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                index += 1
                continue
            }
            let rawValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            let keyIndent = indentWidth(line)

            if let block = parseBlockHeader(rawValue) {
                var body: [String] = []
                var bodyIndent = block.explicitIndent.map { keyIndent + $0 } ?? -1
                var next = index + 1
                while next < lines.count {
                    let candidate = lines[next]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        body.append("")
                        next += 1
                        continue
                    }
                    let width = indentWidth(candidate)
                    if width <= keyIndent { break }
                    if bodyIndent < 0 { bodyIndent = width }
                    if width < bodyIndent { break }
                    let start = candidate.index(candidate.startIndex, offsetBy: bodyIndent)
                    body.append(String(candidate[start...]))
                    next += 1
                }
                index = next
                result[key] = block.folded ? fold(body, block.chomp) : applyChomp(body, block.chomp)
                continue
            }

            if let unquoted = unquote(rawValue) {
                result[key] = unquoted
            } else if isUnsupportedPlainScalar(rawValue) {
                result[key] = ""
            } else {
                result[key] = stripPlainComment(rawValue)
            }
            index += 1
        }
        return result
    }
}
