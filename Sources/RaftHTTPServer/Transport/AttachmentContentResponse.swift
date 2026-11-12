import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// Node presentation and raw Range grammar select an authorized plaintext window.
/// Vapor resolves and clamps the single accepted range against its actual size.
enum AttachmentContentResponse {
    static func make(
        _ content: AttachmentBinaryContent, request: Request, frameAncestors: [String] = []
    ) -> Response {
        let size = content.bytes.count
        var bytes = content.bytes
        var status = HTTPResponse.Status.ok
        var contentRange: HTTPFields.ContentRange?
        let rawRanges = request.headers.filter { $0.name == .range }
        if size > 0, rawRanges.count == 1,
           let raw = rawRanges.first?.value.trimmingCharacters(in: .whitespacesAndNewlines),
           let match = raw.wholeMatch(of: /bytes=([0-9]*)-([0-9]*)/),
           !match.1.isEmpty || !match.2.isEmpty {
            // Vapor accepts partial numeric strings and multiple ranges. The
            // gate above preserves Node's narrower single ASCII-digit grammar.
            // A huge start is unsatisfiable; a finite huge end/suffix is clamped.
            // Normalize only Int overflow before delegating window resolution.
            if !match.1.isEmpty && Int(match.1) == nil { return unsatisfiable(size: size) }
            if !match.2.isEmpty {
                guard let end = Double(String(match.2)), end.isFinite else { return unsatisfiable(size: size) }
            }
            let end = match.2.isEmpty || Int(match.2) != nil ? String(match.2) : String(size)
            var rangeHeaders = HTTPFields()
            rangeHeaders[.range] = "bytes=\(match.1)-\(end)"
            guard let range = rangeHeaders.range, range.unit == .bytes, range.ranges.count == 1,
                  let selection = range.ranges.first else { return unsatisfiable(size: size) }
            do {
                let resolved = try selection.asResponseContentRange(limit: size)
                guard case .withinWithLimit(let start, let end, _) = resolved else {
                    return unsatisfiable(size: size)
                }
                let lower = bytes.index(bytes.startIndex, offsetBy: start)
                let upper = bytes.index(bytes.startIndex, offsetBy: end + 1)
                bytes = Data(bytes[lower..<upper])
                status = .partialContent
                contentRange = .init(unit: .bytes, range: resolved)
            } catch { return unsatisfiable(size: size) }
        }
        let filename = normalizedFilename(content.filename)
        let mime = resolvedMime(filename: filename, stored: content.mimeType)
        let preview = desktopQuery(request.url.query, "disposition") == "inline" && previewableMedia(mime)
        let download = desktopQuery(request.url.query, "disposition") == "attachment"
            || desktopQuery(request.url.query, "download") == "1"
        let inline = !download && (preview || AttachmentPresentationRules.isPreviewableImage(mime))
        var headers = HTTPFields()
        headers[.cacheControl] = "private, immutable, max-age=31536000"
        headers[.contentType] = responseContentType(mime)
        headers[.contentLength] = String(bytes.count)
        headers[.acceptRanges] = "bytes"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        headers[.contentDisposition] = disposition(filename: filename, inline: inline)
        headers.contentRange = contentRange
        if preview {
            headers[HTTPField.Name("X-Frame-Options")!] = nil
            headers[HTTPField.Name("Content-Security-Policy")!] = framePolicy(frameAncestors)
            headers[HTTPField.Name("Cross-Origin-Resource-Policy")!] = "cross-origin"
            headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        }
        return Response(status: status, headers: headers, body: .init(data: bytes))
    }

    // attachments.ts FILENAME_MIME_MAP; do not use a platform MIME registry whose
    // additional extensions would change the pinned fallback contract.
    private static func resolvedMime(filename: String, stored: String?) -> String {
        ChannelFileRules.resolveAttachmentMimeType(filename: filename, stored: stored)
    }

    private static func previewableMedia(_ mime: String) -> Bool {
        let base = mime.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ["application/pdf", "video/mp4", "video/webm", "video/quicktime", "audio/mpeg", "audio/mp3",
                "audio/wav", "audio/x-wav", "audio/wave", "audio/aac", "audio/mp4", "audio/x-m4a",
                "audio/ogg", "audio/opus", "audio/webm", "audio/flac", "audio/x-flac"].contains(base)
    }

    private static func responseContentType(_ mime: String) -> String {
        AttachmentPresentationRules.contentType(mime)
    }

    private static func normalizedFilename(_ name: String) -> String {
        AttachmentPresentationRules.normalizedFilename(name)
    }

    private static func disposition(filename: String, inline: Bool) -> String {
        AttachmentPresentationRules.disposition(filename: filename, inline: inline)
    }

    private static func framePolicy(_ configured: [String]) -> String {
        var origins = ["'self'"]
        for raw in configured {
            guard let url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.url?.host?.lowercased(), !host.isEmpty else { continue }
            let port = url.port.flatMap { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? nil : $0 }
            let origin = "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
            if !origins.contains(origin) { origins.append(origin) }
        }
        origins.append("app://raft")
        return "frame-ancestors " + origins.joined(separator: " ")
    }

    private static func unsatisfiable(size: Int) -> Response {
        var headers = HTTPFields()
        headers.contentRange = .init(unit: .bytes, range: .any(size: size))
        headers[.contentLength] = "0"
        return Response(status: .rangeNotSatisfiable, headers: headers, body: .empty)
    }
}
