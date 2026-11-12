import Foundation

/// Pinned attachments.ts presentation helpers shared by human and Agent
/// transports. This policy changes response metadata, never attachment bytes.
public enum AttachmentPresentationRules {
    public static func normalizedFilename(_ name: String) -> String {
        let scalars = name.unicodeScalars
        guard scalars.contains(where: { $0.value > 127 }), scalars.allSatisfy({ $0.value <= 255 }),
              let repaired = String(data: Data(scalars.map { UInt8($0.value) }), encoding: .utf8),
              !repaired.contains("\u{FFFD}") else { return name }
        return repaired
    }

    public static func contentType(_ mime: String) -> String {
        let mime = mime.isEmpty ? "application/octet-stream" : mime
        if mime.range(of: #"\bcharset="#, options: [.regularExpression, .caseInsensitive]) != nil { return mime }
        let lower = mime.lowercased()
        if lower.hasPrefix("text/") || ["application/json", "application/ld+json", "application/xml"].contains(lower)
            || lower.hasSuffix("+json") || lower.hasSuffix("+xml") { return mime + "; charset=utf-8" }
        return mime
    }

    public static func isPreviewableImage(_ mime: String) -> Bool {
        ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime)
    }

    public static func encodedFilename(_ filename: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~")
        return filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    public static func disposition(filename: String, inline: Bool) -> String {
        disposition(normalizedFilename: normalizedFilename(filename), inline: inline)
    }

    /// Format a filename that the caller already repaired for MIME resolution.
    public static func disposition(normalizedFilename filename: String, inline: Bool) -> String {
        let ascii = filename.utf16.map { unit -> UInt8 in
            if unit == 10 || unit == 13 { return 32 }
            if unit == 34 || unit == 92 || unit < 32 || unit > 126 { return 95 }
            return UInt8(unit)
        }
        let fallback = String(decoding: ascii, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(inline ? "inline" : "attachment"); filename=\"\(fallback.isEmpty ? "download" : fallback)\"; filename*=UTF-8''\(encodedFilename(filename))"
    }

    public static func defaultDisposition(filename: String, mimeType: String?) -> String {
        disposition(filename: filename, inline: isPreviewableImage(
            ChannelFileRules.resolveAttachmentMimeType(filename: filename, stored: mimeType)))
    }
}
