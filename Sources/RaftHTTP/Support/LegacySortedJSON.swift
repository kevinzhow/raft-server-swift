import Foundation
import RaftShared

/// Renders a decoded `JSONValue` with the bytes the retired
/// `JSONSerialization.data(withJSONObject:options: [.sortedKeys])` call
/// produced, so a payload a client sent in and the server stores verbatim (the
/// resource-receipt notes, the idempotency fingerprint) keeps its stored text.
///
/// This is a serializer for an already-decoded tree, not a body type: response
/// bodies are `OrderedJSON` (see `docs/PHASE6_JSON.md`). The legacy writer's
/// quirks are reproduced on purpose and locked by a differential test:
/// - object members sort with the localized-standard string order
///   (case-insensitive, numeric-aware), not by code point;
/// - `/` is escaped as `\/`; control characters other than `\b \f \n \r \t`
///   print as lowercase `\u00xx`; every other scalar prints raw;
/// - an integral double prints without `.0`;
/// - a non-finite number is unrepresentable (`nil`).
public enum LegacySortedJSON {
    public static func render(_ value: JSONValue) -> String? {
        var out = ""
        guard append(value, to: &out) else { return nil }
        return out
    }

    private static func append(_ value: JSONValue, to out: inout String) -> Bool {
        switch value {
        case .object(let members):
            out += "{"
            let keys = members.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                appendString(key, to: &out)
                out += ":"
                guard let child = members[key], append(child, to: &out) else { return false }
            }
            out += "}"
        case .array(let values):
            out += "["
            for (index, child) in values.enumerated() {
                if index > 0 { out += "," }
                guard append(child, to: &out) else { return false }
            }
            out += "]"
        case .string(let string):
            appendString(string, to: &out)
        case .integer(let integer):
            out += String(integer)
        case .number(let number):
            guard number.isFinite else { return false }
            var text = number.description
            if text.hasSuffix(".0") { text.removeLast(2) }
            out += text
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .null:
            out += "null"
        }
        return true
    }

    private static func appendString(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "/": out += "\\/"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
