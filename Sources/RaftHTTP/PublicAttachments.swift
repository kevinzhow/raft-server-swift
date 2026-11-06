import Foundation

/// Anonymous `GET /api/public/servers/:slug/attachments/:attachmentId`.
///
/// A readable raster image is inline. HTML, SVG, and `?download=1` are
/// downloads. Every refusal is the same 404 as a missing id. A non-UUID id
/// is the path guard, `Attachment not found`.

public struct PublicPresignRequest: Equatable, Sendable {
    public var key: String
    public var expiresIn: Int
    public var responseContentDisposition: String
    public var responseContentType: String

    public init(key: String, expiresIn: Int, responseContentDisposition: String, responseContentType: String) {
        self.key = key
        self.expiresIn = expiresIn
        self.responseContentDisposition = responseContentDisposition
        self.responseContentType = responseContentType
    }
}

/// One IP gets 120 public attachment reads per minute. The 121st is refused
/// before the handler, so a missing file stays a 404 until the budget is spent.
public final class PublicAttachmentBudget: @unchecked Sendable {
    public static let maxPerWindow = 120
    public static let windowSeconds: TimeInterval = 60
    private let lock = NSLock()
    private var hits: [String: (start: Date, count: Int)] = [:]

    public init() {}

    public func allow(ip: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let next: (start: Date, count: Int)
        if let existing = hits[ip], now.timeIntervalSince(existing.start) < Self.windowSeconds {
            next = (existing.start, existing.count + 1)
        } else {
            next = (now, 1)
        }
        hits[ip] = next
        return next.count <= Self.maxPerWindow
    }
}

public enum PublicAttachments {
    /// Anonymous presigned URLs expire after one minute.
    public static let presignedURLTTLSeconds = 60
    private static let previewableImages: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    public static func tooMany() -> PublicAttachmentError { .tooMany }

    public static func missing(attachmentId: String) -> PublicAttachmentError {
        ServerScope.isUUID(attachmentId) ? .notFound : .invalidId
    }

    public static func file(
        bytes: String,
        filename: String,
        mimeType: String,
        forceDownload: Bool,
        inlineDisposition: Bool = false,
        frameAncestors: [String] = []
    ) -> PublicAttachmentResponse {
        let fields = presentation(
            filename: filename,
            mimeType: mimeType,
            forceDownload: forceDownload,
            inlineDisposition: inlineDisposition
        )
        return .file(
            bytes: bytes,
            contentType: fields.contentType,
            disposition: fields.disposition,
            contentSecurityPolicy: fields.inlinePdf
                ? inlinePreviewPolicy(frameAncestors)
                : "default-src 'none'; sandbox",
            inlinePDF: fields.inlinePdf
        )
    }

    public static func presignRequest(
        key: String,
        filename: String,
        mimeType: String,
        forceDownload: Bool,
        inlineDisposition: Bool = false
    ) -> PublicPresignRequest {
        let fields = presentation(
            filename: filename,
            mimeType: mimeType,
            forceDownload: forceDownload,
            inlineDisposition: inlineDisposition
        )
        return PublicPresignRequest(
            key: key,
            expiresIn: presignedURLTTLSeconds,
            responseContentDisposition: fields.disposition,
            responseContentType: fields.contentType
        )
    }

    public static func redirect(location: String) -> PublicAttachmentResponse {
        .redirect(location: location)
    }

    private static func presentation(
        filename: String,
        mimeType: String,
        forceDownload: Bool,
        inlineDisposition: Bool
    ) -> (disposition: String, contentType: String, inlinePdf: Bool) {
        let resolved = resolveMime(filename: filename, mimeType: mimeType)
        let inlinePdf = !forceDownload && inlineDisposition && isPdf(resolved)
        let inlineImage = !forceDownload && previewableImages.contains(resolved)
        let inline = inlinePdf || inlineImage
        return (contentDisposition(inline: inline, filename: filename), contentType(resolved), inlinePdf)
    }

    private static func isPdf(_ mimeType: String) -> Bool {
        mimeType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/pdf"
    }

    /// Framed PDF preview. Chromium's viewer cannot run under `sandbox`.
    private static func inlinePreviewPolicy(_ origins: [String]) -> String {
        var ancestors = ["'self'"]
        for origin in origins where origin.hasPrefix("http://") || origin.hasPrefix("https://") {
            if !ancestors.contains(origin) { ancestors.append(origin) }
        }
        ancestors.append("app://raft")
        return "frame-ancestors \(ancestors.joined(separator: " "))"
    }

    private static func resolveMime(filename: String, mimeType: String) -> String {
        let normalized = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty, normalized != "application/octet-stream" { return normalized }
        let ext = filename.split(separator: ".").last.map { "." + $0.lowercased() } ?? ""
        let inferred = [
            ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
            ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
            ".html": "text/html", ".htm": "text/html",
        ][ext]
        return inferred ?? (normalized.isEmpty ? "application/octet-stream" : normalized)
    }

    private static func contentType(_ mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.contains("charset=") { return mimeType }
        if lower.hasPrefix("text/") || lower == "application/json" || lower == "application/xml"
            || lower.hasSuffix("+json") || lower.hasSuffix("+xml") {
            return "\(mimeType); charset=utf-8"
        }
        return mimeType
    }

    private static func contentDisposition(inline: Bool, filename: String) -> String {
        let kind = inline ? "inline" : "attachment"
        let fallback = filename.isEmpty ? "download" : filename
        return "\(kind); filename=\"\(fallback)\"; filename*=UTF-8''\(encodeURIComponent(filename))"
    }

    private static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        var out = ""
        for character in encoded {
            switch character {
            case "'", "(", ")", "*":
                if let ascii = character.asciiValue {
                    out += String(format: "%%%02X", ascii)
                }
            default:
                out.append(character)
            }
        }
        return out
    }
}
