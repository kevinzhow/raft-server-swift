import Foundation

public enum FormPayload {
    static func multipartFields(body: String, contentType: String) -> [String: String]? {
        guard let boundaryRange = contentType.range(of: "boundary=") else { return nil }
        var boundary = String(contentType[boundaryRange.upperBound...])
        boundary = boundary.split(separator: ";").first.map(String.init) ?? boundary
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" \""))
        guard !boundary.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for part in body.components(separatedBy: "--\(boundary)") {
            guard part.contains("name=\"") else { continue }
            let segments = part.components(separatedBy: "\r\n\r\n")
            guard segments.count >= 2 else { continue }
            let header = segments[0]
            guard let nameRange = header.range(of: "name=\"") else { continue }
            let rest = header[nameRange.upperBound...]
            guard let closing = rest.firstIndex(of: "\"") else { continue }
            let name = String(rest[..<closing])
            var value = segments[1]
            if value.hasSuffix("\r\n") { value.removeLast() }
            fields[name] = value
        }
        return fields.isEmpty ? nil : fields
    }

    /// The same part lookup as `multipartFile`, retaining the part's declared
    /// `Content-Type` and `filename` because the avatar routes validate MIME
    /// the way multer's `fileFilter` does.
    public static func multipartFilePart(
        named name: String, contentType: String?, body: Data
    ) -> AvatarUploadFile? {
        guard let boundary = FormPayload.boundaryParameter(contentType) else { return nil }
        let delimiter = Data("--\(boundary)".utf8)
        let headerBreak = Data("\r\n\r\n".utf8)
        let crlf = Data("\r\n".utf8)
        let marker = "name=\"\(name)\""
        var remainder = body[body.startIndex...]
        var parts: [Data] = []
        while let range = remainder.range(of: delimiter) {
            let piece = remainder[..<range.lowerBound]
            if !piece.isEmpty { parts.append(Data(piece)) }
            remainder = remainder[range.upperBound...]
        }
        if !remainder.isEmpty { parts.append(Data(remainder)) }
        for var part in parts {
            if part.starts(with: crlf) { part.removeFirst(crlf.count) }
            guard let split = part.range(of: headerBreak) else { continue }
            let headers = part[..<split.lowerBound]
            var file = Data(part[split.upperBound...])
            if file.count >= crlf.count, file.suffix(crlf.count) == crlf {
                file.removeLast(crlf.count)
            }
            guard let headerText = String(data: Data(headers), encoding: .utf8), headerText.contains(marker) else {
                continue
            }
            return AvatarUploadFile(
                bytes: file,
                contentType: FormPayload.headerValue("content-type", in: headerText),
                filename: FormPayload.headerValue("filename", in: headerText)
            )
        }
        return nil
    }

    private static func headerValue(_ name: String, in headerText: String) -> String? {
        for line in headerText.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == name else { continue }
            let raw = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var value = raw
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func multipartFile(named name: String, contentType: String?, body: Data) -> Data? {
        guard let boundary = FormPayload.boundaryParameter(contentType) else { return nil }
        let delimiter = Data("--\(boundary)".utf8)
        let headerBreak = Data("\r\n\r\n".utf8)
        let crlf = Data("\r\n".utf8)
        let marker = "name=\"\(name)\""
        var remainder = body[body.startIndex...]
        var parts: [Data] = []
        while let range = remainder.range(of: delimiter) {
            let piece = remainder[..<range.lowerBound]
            if !piece.isEmpty { parts.append(Data(piece)) }
            remainder = remainder[range.upperBound...]
        }
        if !remainder.isEmpty { parts.append(Data(remainder)) }
        for var part in parts {
            if part.starts(with: crlf) { part.removeFirst(crlf.count) }
            guard let split = part.range(of: headerBreak) else { continue }
            let headers = part[..<split.lowerBound]
            var file = Data(part[split.upperBound...])
            if file.count >= crlf.count, file.suffix(crlf.count) == crlf {
                file.removeLast(crlf.count)
            }
            guard let headerText = String(data: Data(headers), encoding: .utf8), headerText.contains(marker) else { continue }
            return file
        }
        return nil
    }

    static func boundaryParameter(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func formField(_ body: String, _ name: String) -> String? {
        for pair in body.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.first?.removingPercentEncoding == name || parts.first == name else { continue }
            let raw = parts.count > 1 ? parts[1] : ""
            return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return nil
    }

    static func urlQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func formFields(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0].removingPercentEncoding ?? parts[0]
            let raw = parts.count > 1 ? parts[1] : ""
            fields[name] = raw.removingPercentEncoding ?? raw
        }
        return fields
    }

    static func cookieValue(_ header: String?, name: String) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            let halves = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard halves.first == name else { continue }
            let raw = halves.count > 1 ? halves[1] : ""
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }
}
