import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Security headers are installed before any hostile attachment byte is written.
/// The document remains opaque even when the preview URL is opened directly.
enum AttachmentHTMLPreviewResponse {
    static let maximumPlaintextBytes = 200 * 1024 * 1024
    static let headScanLimitBytes = 1024 * 1024

    static func make(_ content: AttachmentBinaryContent, frameAncestors: [String]) throws -> Response {
        guard content.bytes.count <= maximumPlaintextBytes else { throw AttachmentContentError.previewFailed }
        let bytes = content.bytes
        let insertion = cspMetaStart(bytes) ?? bytes.count
        let bridge = Data(AttachmentPreviewBridge.script.utf8)
        var headers = HTTPFields()
        let mime = content.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "text/html"
        headers[.contentType] = mime.range(of: #"\bcharset="#, options: .regularExpression) == nil
            ? mime + "; charset=utf-8" : mime
        headers[.cacheControl] = "private, no-store"
        headers[.contentDisposition] = disposition(content.filename)
        headers[HTTPField.Name("Content-Security-Policy")!] = policy(frameAncestors)
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        var response = Response(status: .ok, headers: headers)
        response.body = Response.Body { writer in
            // Writes are backpressured and copy at most one 64 KiB window. The
            // authenticated plaintext buffer is bounded by the storage contract.
            var cursor = bytes.startIndex
            let split = bytes.index(bytes.startIndex, offsetBy: insertion)
            while cursor < split {
                let end = min(cursor + 64 * 1024, split)
                try await writer.write(bytes[cursor..<end])
                cursor = end
            }
            try await writer.write(bridge)
            while cursor < bytes.endIndex {
                let end = min(cursor + 64 * 1024, bytes.endIndex)
                try await writer.write(bytes[cursor..<end])
                cursor = end
            }
        }
        return response
    }

    static func policy(_ configured: [String]) -> String {
        var ancestors = ["'self'"]
        for raw in configured {
            guard let url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.user == nil, url.password == nil,
                  let host = url.host?.lowercased(), !host.isEmpty, !host.contains("*"),
                  !host.contains(where: { $0.isWhitespace }) else { continue }
            let port = url.port.flatMap { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? nil : $0 }
            var originURL = url
            originURL.scheme = scheme
            originURL.host = host
            originURL.port = port
            originURL.path = ""
            originURL.query = nil
            originURL.fragment = nil
            guard let origin = originURL.string else { continue }
            if !ancestors.contains(origin) { ancestors.append(origin) }
        }
        ancestors.append("app://raft")
        return [
            "default-src 'none'", "sandbox allow-scripts",
            "script-src 'unsafe-inline' https:", "style-src 'unsafe-inline' https:",
            "img-src data: blob: https:", "font-src data: https:", "media-src data: blob: https:",
            "connect-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'", "worker-src 'none'",
            "frame-ancestors " + ancestors.joined(separator: " "),
        ].joined(separator: "; ")
    }

    private static func disposition(_ filename: String) -> String {
        let fallback = String(decoding: filename.utf16.map { unit -> UInt8 in
            if unit == 10 || unit == 13 { return 32 }
            if unit == 34 || unit == 92 || unit < 32 || unit > 126 { return 95 }
            return UInt8(unit)
        }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~")
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "inline; filename=\"\(fallback.isEmpty ? "download" : fallback)\"; filename*=UTF-8''\(encoded)"
    }

    /// Mirrors Node's bounded, parser-active head scan. Offsets refer to original
    /// bytes: no UTF-8 decoding/re-encoding can alter the stored document.
    static func cspMetaStart(_ data: Data) -> Int? {
        let bytes = Array(data.prefix(headScanLimitBytes))
        let lower = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        let rawText: Set<String> = ["script", "style", "title", "textarea", "noscript", "template"]
        var cursor = 0
        while cursor < bytes.count {
            guard let start = bytes[cursor...].firstIndex(of: 60) else { return nil }
            if matches(lower, at: start, "<!--") {
                guard let end = find(lower, "-->", from: start + 4) else { return nil }
                cursor = end + 3
                continue
            }
            guard let end = tagEnd(bytes, from: start) else { return nil }
            if matches(lower, at: start, "<!") || matches(lower, at: start, "<?") {
                cursor = end + 1
                continue
            }
            var nameStart = start + 1
            let closing = nameStart < bytes.count && bytes[nameStart] == 47
            if closing { nameStart += 1 }
            while nameStart < end && whitespace(bytes[nameStart]) { nameStart += 1 }
            var nameEnd = nameStart
            while nameEnd < end && nameByte(lower[nameEnd]) { nameEnd += 1 }
            guard nameEnd > nameStart else {
                // Browsers ignore nameless closing tags such as </>. Keep
                // scanning so a later active CSP meta remains an injection point.
                if closing { cursor = end + 1; continue }
                return nil
            }
            let name = String(decoding: lower[nameStart..<nameEnd], as: UTF8.self)
            if closing {
                if name == "head" { return nil }
                cursor = end + 1
                continue
            }
            if name == "body" || name == "frameset" { return nil }
            if name == "meta", declaresCSP(bytes[start...end]) { return start }
            if rawText.contains(name) {
                guard let close = find(lower, "</" + name, from: end + 1),
                      let closeEnd = tagEnd(bytes, from: close) else { return nil }
                cursor = closeEnd + 1
            } else { cursor = end + 1 }
        }
        return nil
    }

    private static func declaresCSP(_ tag: ArraySlice<UInt8>) -> Bool {
        // Latin-1 maps each scanned byte to exactly one code point. The result
        // is used only for matching; output always uses the untouched Data.
        guard let text = String(bytes: tag, encoding: .isoLatin1),
              let range = text.range(of: #"\bhttp-equiv\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return false }
        let attribute = String(text[range])
        guard let equal = attribute.firstIndex(of: "=") else { return false }
        var value = attribute[attribute.index(after: equal)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "\"" || value.first == "'" { value.removeFirst(); value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-security-policy"
    }

    private static func tagEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var quote: UInt8?
        for index in (start + 1)..<bytes.count {
            let byte = bytes[index]
            if let held = quote { if held == byte { quote = nil }; continue }
            if byte == 34 || byte == 39 { quote = byte }
            else if byte == 62 { return index }
        }
        return nil
    }
    private static func whitespace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
    private static func nameByte(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte) || byte == 58 || byte == 45
    }
    private static func matches(_ bytes: [UInt8], at index: Int, _ text: String) -> Bool {
        let needle = Array(text.utf8)
        guard index >= 0, index + needle.count <= bytes.count else { return false }
        return bytes[index..<(index + needle.count)].elementsEqual(needle)
    }
    private static func find(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        let needle = Array(text.utf8)
        return (start..<bytes.count).first { index in
            index + needle.count <= bytes.count && bytes[index..<(index + needle.count)].elementsEqual(needle)
        }
    }
}
