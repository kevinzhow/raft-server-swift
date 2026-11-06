import Foundation

public enum ThirdPartyText {
    static func inertThirdPartyText(_ raw: String) -> String {
        var text = raw
        if text.count > 4_000 {
            text = String(text.prefix(4_000)) + "\n[truncated]"
        }
        let markupPattern = try! NSRegularExpression(
            pattern: "</?(?:result|preview|match)\\b[^>]*>|<omit\\s*/>",
            options: [.caseInsensitive]
        )
        let escaped = NSMutableString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        for match in markupPattern.matches(in: text, options: [], range: full).reversed() {
            let tag = (text as NSString).substring(with: match.range)
            let neutral = tag
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            escaped.replaceCharacters(in: match.range, with: neutral)
        }
        text = escaped as String
        return ThirdPartyText.neutralizeRaftRefsOutsideCode(text)
    }

    static func neutralizeRaftRefsOutsideCode(_ text: String) -> String {
        let refPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])@([A-Za-z0-9][A-Za-z0-9_.-]*)")
        var output = ""
        var cursor = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                let fence = String(text[index...].prefix(3)) == "```"
                let marker = fence ? "```" : "`"
                let contentStart = text.index(index, offsetBy: marker.count)
                if let close = text.range(of: marker, range: contentStart..<text.endIndex) {
                    output += ThirdPartyText.neutralizeRaftRefs(String(text[cursor..<index]), pattern: refPattern)
                    output += String(text[index..<close.upperBound])
                    cursor = close.upperBound
                    index = close.upperBound
                    continue
                }
            }
            index = text.index(after: index)
        }
        output += ThirdPartyText.neutralizeRaftRefs(String(text[cursor...]), pattern: refPattern)
        return output
    }

    static func neutralizeRaftRefs(_ source: String, pattern: NSRegularExpression) -> String {
        let full = NSRange(location: 0, length: (source as NSString).length)
        let matches = pattern.matches(in: source, options: [], range: full)
        guard !matches.isEmpty else { return source }
        var output = ""
        var cursor = 0
        for match in matches {
            output += (source as NSString).substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += "user:" + (source as NSString).substring(with: match.range(at: 1))
            cursor = match.range.location + match.range.length
        }
        output += (source as NSString).substring(from: cursor)
        return output
    }

    static func marketplaceAppNameBinding(_ raw: String) -> (name: String, sha256: String) {
        (ThirdPartyText.inertThirdPartyText(raw), AuthTokenCodec.sha256Hex(raw))
    }

    static func generatedIntegrationClientKey(_ name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty || !(slug.first?.isLetter == true) { slug = "app-" + slug }
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6)
        return "\(slug.prefix(32))-\(hex)"
    }
}
