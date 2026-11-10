import Foundation

public enum ChannelFileRules {
    static func rfc5987Encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func channelFilesBase64URLEncode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func channelFilesBase64URLDecode(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func channelFilesLimit(_ raw: String?) -> Int {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = Double(raw), value.isFinite
        else { return 500 }
        return max(1, min(Int(value.rounded(.down)), 500))
    }

    static func channelFileMimeType(filename: String, stored: String?) -> String {
        resolveAttachmentMimeType(filename: filename, stored: stored)
    }

    /// Node's read/transport MIME policy for an actual resolved attachment:
    /// explicit non-generic MIME wins; otherwise use the real filename suffix,
    /// then the generic binary default. This does not sniff or mutate bytes.
    public static func resolveAttachmentMimeType(filename: String, stored: String?) -> String {
        let normalized = stored?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !normalized.isEmpty && normalized != "application/octet-stream" { return normalized }
        let suffix = filename.lastIndex(of: ".").map { String(filename[$0...]).lowercased() } ?? ""
        return attachmentFilenameMimes[suffix] ?? (normalized.isEmpty ? "application/octet-stream" : normalized)
    }

    private static let attachmentFilenameMimes = [
        ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp",
        ".svg": "image/svg+xml", ".heic": "image/heic", ".heif": "image/heif", ".html": "text/html", ".htm": "text/html",
        ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime", ".mp3": "audio/mpeg", ".wav": "audio/wav",
        ".m4a": "audio/mp4", ".aac": "audio/aac", ".ogg": "audio/ogg", ".oga": "audio/ogg", ".opus": "audio/opus",
        ".weba": "audio/webm", ".flac": "audio/flac", ".pdf": "application/pdf", ".txt": "text/plain",
        ".md": "text/markdown", ".json": "application/json", ".csv": "text/csv",
    ]
}
