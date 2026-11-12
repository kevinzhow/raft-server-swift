import CRaftMarkdown
import Foundation

/// Immutable original-source runs from one mature parser invocation. The bridge
/// supplies UTF16 ranges from the pinned parser, never cooked text or store facts.
struct MessageMentionSurface: Sendable {
    let source: String
    let runs: [String]
    let linkedHandles: [String]

    fileprivate init(source: String, runs: [String], linkedHandles: [String]) {
        self.source = source
        self.runs = runs
        self.linkedHandles = linkedHandles
    }
}

enum MessageMentionParsingError: DomainError {
    case unavailable

    var status: UInt { 500 }
    var errorMessage: String { "Failed to parse message mentions" }
}

/// Native parser scratch belongs to this invocation. Requests share no parser
/// context or lock; the parser returns ranges into the unchanged UTF16 source.
enum MessageMentionMarkdown {
    static func parse(_ source: String) throws -> MessageMentionSurface {
        var error: CInt = 0
        guard let context = raft_markdown_create(&error), error == 0 else {
            throw MessageMentionParsingError.unavailable
        }
        defer { raft_markdown_destroy(context) }
        let input = Array(source.utf16)
        var allocation: UnsafeMutablePointer<CChar>?
        var size = 0
        let result = input.withUnsafeBufferPointer { buffer in
            raft_markdown_parse(context, buffer.baseAddress, buffer.count, &allocation, &size)
        }
        defer { if let allocation { raft_markdown_free(allocation) } }
        guard result == 0, let allocation, size > 0 else { throw MessageMentionParsingError.unavailable }
        return try decode(Data(bytes: allocation, count: size), source: source)
    }

    private struct ParsedRange: Decodable {
        enum Kind: String, Decodable {
            case code
            case link
            case image
            case definition
        }
        let kind: Kind
        let start: Int
        let end: Int
        let href: String?
    }

    /// Contract: a JSON array of normalized code/link/image/definition records;
    /// offsets are half-open original UTF16 positions and href is parser-decoded.
    static func decode(_ rangeJSON: Data, source: String) throws -> MessageMentionSurface {
        let ranges: [ParsedRange]
        do { ranges = try JSONDecoder().decode([ParsedRange].self, from: rangeJSON) }
        catch { throw MessageMentionParsingError.unavailable }
        let original = source as NSString
        let units = Array(source.utf16)
        func boundary(_ offset: Int) -> Bool {
            guard offset >= 0, offset <= units.count else { return false }
            if offset == 0 || offset == units.count { return true }
            return !(0xD800...0xDBFF).contains(units[offset - 1])
                || !(0xDC00...0xDFFF).contains(units[offset])
        }
        var linkedHandles: [String] = []
        for range in ranges {
            guard range.start <= range.end, boundary(range.start), boundary(range.end) else {
                throw MessageMentionParsingError.unavailable
            }
            // Node appends angle references in the parser's original links
            // order. Only the skip-run union is sorted by source position.
            if range.kind == .link, let href = range.href {
                let raw = original.substring(with: NSRange(location: range.start, length: range.end - range.start))
                let angle = raw == "<" + href + ">"
                    || raw.range(of: #"\]\(<[^<>\n]+>\)$"#, options: .regularExpression) != nil
                let target = MessageMentionRules.trimmingJavaScriptWhitespace(href)
                if angle, target.range(of: #"\A@[\p{L}\p{N}_-]+\z"#, options: .regularExpression) != nil {
                    linkedHandles.append(String(target.dropFirst()))
                }
            }
        }
        let ordered = ranges.sorted { $0.start < $1.start }
        var cursor = 0
        var runs: [String] = []
        for range in ordered {
            if range.end <= cursor { continue }
            if range.start > cursor { runs.append(prose(original, start: cursor, end: range.start)) }
            cursor = max(cursor, range.end)
        }
        if cursor < units.count { runs.append(prose(original, start: cursor, end: units.count)) }
        return MessageMentionSurface(source: source, runs: runs, linkedHandles: linkedHandles)
    }

    /// Node's two explicit post-parser prose filters. Each original run starts
    /// with its actual new boundary after a skipped code/link range. No entity
    /// decoding, text-leaf concatenation or Markdown recognition occurs here.
    private static func prose(_ source: NSString, start: Int, end: Int) -> String {
        let bareHTTP = "https?://[^" + MessageMentionRules.javaScriptWhitespaceClass + "<>]+"
        return source.substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: #"\\<@[\p{L}\p{N}_-]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: bareHTTP, with: " ", options: .regularExpression)
    }
}
