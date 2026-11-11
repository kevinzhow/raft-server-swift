import Foundation

/// The preview providers from `packages/server/src/services/attachmentPreviews/`
/// and the shared limits in `packages/shared/src/attachmentPreview.ts`.
///
/// Provider order is the published specificity order: diff, csv, xlsx,
/// markdown, pdf, text. Images, video, audio and HTML have no preview provider;
/// they stay readable downloads and answer `status:"unsupported"`.
enum AttachmentPreviewBuilder {
    static let diffStreamLimit = 256 * 1024
    static let diffPayloadLimit = 8 * 1024
    static let csvStreamLimit = 128 * 1024
    static let csvPayloadLimit = 32 * 1024
    static let csvMaxFileSize = 5 * 1024 * 1024
    static let csvMaxRows = 200
    static let csvMaxColumns = 12
    static let xlsxMaxFileSize = 5 * 1024 * 1024
    static let markdownStreamLimit = 128 * 1024
    static let markdownPayloadLimit = 64 * 1024
    static let pdfStreamLimit = 4
    static let pdfPayloadLimit = 512
    static let textStreamLimit = 96 * 1024
    static let textPayloadLimit = 128 * 1024

    private enum Provider { case diff, csv, xlsx, markdown, pdf, text }

    private static let textMimeTypes: Set<String> = [
        "text/plain", "application/json", "application/xml", "application/yaml",
        "application/x-yaml", "application/toml", "application/x-sh",
    ]
    private static let textMimeExclusions: Set<String> = ["text/markdown", "text/csv", "text/html"]
    private static let textExtensions: [String] = [
        ".txt", ".text", ".log", ".ini", ".conf", ".cfg", ".properties", ".toml",
        ".yaml", ".yml", ".json", ".xml", ".sql", ".gradle",
        ".sh", ".bash", ".zsh",
        ".kt", ".kts", ".java", ".swift", ".ets",
        ".ts", ".tsx", ".js", ".jsx", ".mjs",
        ".py", ".rb", ".go", ".rs", ".c", ".h", ".cpp", ".hpp",
    ]
    private static let csvMimeTypes: Set<String> = ["text/csv", "application/csv"]
    private static let legacyExcelMime = "application/vnd.ms-excel"
    private static let legacyExcelExtensions = [".xls", ".xlt", ".xla", ".xlm", ".xlc", ".xlw"]
    private static let xlsxMimeTypes: Set<String> = [
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ]
    private static let markdownMimeTypes: Set<String> = ["text/markdown", "text/x-markdown"]
    private static let diffMimeTypes: Set<String> = ["text/x-diff", "text/x-patch", "application/x-patch"]

    static func build(filename: String, storedMimeType: String?, bytes: Data) -> AttachmentPreviewResponse {
        let lowerName = filename.lowercased()
        let mime = normalizedMime(storedMimeType)
        let size = bytes.count

        if isXlsx(lowerName, mime) {
            // The pinned xlsx provider runs SheetJS in a worker. This port has
            // no spreadsheet parser, so a readable small workbook advertises no
            // preview rather than invented sheet data; only the published size
            // gate survives.
            return .unsupported(reason: size <= xlsxMaxFileSize ? "unsupported" : "too_large")
        }
        guard let provider = provider(lowerName, mime, size) else {
            return .unsupported(reason: "unsupported")
        }
        switch provider {
        case .diff:
            let (prefix, streamTruncated) = readPrefix(bytes, diffStreamLimit)
            guard let data = buildDiff(String(decoding: prefix, as: UTF8.self)) else {
                return .unsupported(reason: "unsupported")
            }
            return finish(.diff(data), streamTruncated: streamTruncated, payloadLimit: diffPayloadLimit)
        case .csv:
            let (prefix, streamTruncated) = readPrefix(bytes, csvStreamLimit)
            guard let csv = buildCSV(prefix) else { return .unsupported(reason: "unsupported") }
            return finish(.csv(csv), streamTruncated: streamTruncated, payloadLimit: csvPayloadLimit)
        case .markdown:
            let (prefix, streamTruncated) = readPrefix(bytes, markdownStreamLimit)
            let markdown = String(decoding: prefix, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else { return .unsupported(reason: "unsupported") }
            let data = AttachmentPreviewData.markdown(markdown)
            let payloadSize = data.jsonBody.render().utf8.count
            guard payloadSize <= markdownPayloadLimit else { return .unsupported(reason: "too_large") }
            return .ok(data, truncated: streamTruncated)
        case .pdf:
            let (prefix, streamTruncated) = readPrefix(bytes, pdfStreamLimit)
            guard prefix.starts(with: Data([0x25, 0x50, 0x44, 0x46])) else {
                return .unsupported(reason: "unsupported")
            }
            return finish(.pdf, streamTruncated: streamTruncated, payloadLimit: pdfPayloadLimit)
        case .text:
            let (prefix, streamTruncated) = readPrefix(bytes, textStreamLimit)
            guard let text = String(data: prefix, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .unsupported(reason: "unsupported") }
            return finish(.text(text), streamTruncated: streamTruncated, payloadLimit: textPayloadLimit)
        case .xlsx:
            return .unsupported(reason: "unsupported")
        }
    }

    private static func finish(
        _ data: AttachmentPreviewData, streamTruncated: Bool, payloadLimit: Int
    ) -> AttachmentPreviewResponse {
        let payloadSize = data.jsonBody.render().utf8.count
        guard payloadSize <= payloadLimit else { return .unsupported(reason: "too_large") }
        var truncated = streamTruncated
        if case .csv(let csv) = data { truncated = truncated || csv.rows.count < csv.rowCount }
        return .ok(data, truncated: truncated)
    }

    private static func provider(_ filename: String, _ mime: String, _ size: Int) -> Provider? {
        if isDiff(filename, mime) { return .diff }
        if isCSV(filename, mime) && size <= csvMaxFileSize { return .csv }
        if isXlsx(filename, mime) && size <= xlsxMaxFileSize { return .xlsx }
        if isMarkdown(filename, mime) { return .markdown }
        if isPDF(filename, mime) { return .pdf }
        if isText(filename, mime) { return .text }
        return nil
    }

    private static func normalizedMime(_ raw: String?) -> String {
        raw?.lowercased().split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isDiff(_ filename: String, _ mime: String) -> Bool {
        filename.hasSuffix(".diff") || filename.hasSuffix(".patch") || diffMimeTypes.contains(mime)
    }

    private static func isCSV(_ filename: String, _ mime: String) -> Bool {
        guard !legacyExcelExtensions.contains(where: filename.hasSuffix) else { return false }
        return filename.hasSuffix(".csv") || csvMimeTypes.contains(mime)
            || (mime == legacyExcelMime && !legacyExcelExtensions.contains(where: filename.hasSuffix))
    }

    private static func isXlsx(_ filename: String, _ mime: String) -> Bool {
        filename.hasSuffix(".xlsx") || xlsxMimeTypes.contains(mime)
    }

    private static func isMarkdown(_ filename: String, _ mime: String) -> Bool {
        filename.hasSuffix(".md") || filename.hasSuffix(".markdown") || markdownMimeTypes.contains(mime)
    }

    private static func isPDF(_ filename: String, _ mime: String) -> Bool {
        filename.hasSuffix(".pdf") || mime == "application/pdf"
    }

    private static func isText(_ filename: String, _ mime: String) -> Bool {
        if textExtensions.contains(where: filename.hasSuffix) { return true }
        if textMimeTypes.contains(mime) { return true }
        return mime.hasPrefix("text/") && !textMimeExclusions.contains(mime)
    }

    private static func readPrefix(_ bytes: Data, _ limit: Int) -> (Data, Bool) {
        guard bytes.count > limit else { return (bytes, false) }
        return (Data(bytes.prefix(limit)), true)
    }

    // MARK: - Diff

    private static func buildDiff(_ text: String) -> AttachmentPreviewData.DiffStats? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var files: Set<String> = []
        var hunks = 0
        var additions = 0
        var deletions = 0
        for line in lines {
            if line.hasPrefix("diff --git ") {
                if let range = line.range(of: " b/") {
                    files.insert(String(line[range.upperBound...]))
                } else {
                    files.insert(line)
                }
            } else if line.hasPrefix("Index: ") {
                files.insert(String(line.dropFirst("Index: ".count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("+++ "), !line.hasPrefix("+++ /dev/null") {
                var name = String(line.dropFirst(4))
                if name.hasPrefix("b/") { name.removeFirst(2) }
                files.insert(name.trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("@@") {
                hunks += 1
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                additions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                deletions += 1
            }
        }
        guard hunks > 0 || additions > 0 || deletions > 0 || !files.isEmpty else { return nil }
        return .init(files: files.isEmpty ? 1 : files.count, hunks: hunks, additions: additions, deletions: deletions)
    }

    // MARK: - CSV

    private static func buildCSV(_ bytes: Data) -> AttachmentPreviewData.CSV? {
        let ole = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
        guard !bytes.starts(with: ole), let text = String(data: bytes, encoding: .utf8) else { return nil }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value <= 0x08 || (0x0b...0x0c).contains(value) || (0x0e...0x1f).contains(value) || value == 0x7f {
                return nil
            }
        }
        let delimiter = detectDelimiter(text)
        let parsed = parseCSV(text, delimiter: delimiter)
        guard !parsed.isEmpty else { return nil }
        let columnCount = parsed.map(\.count).max() ?? 0
        let headers = Array(parsed[0].prefix(csvMaxColumns))
        var rows = parsed.dropFirst().prefix(csvMaxRows).map { Array($0.prefix(csvMaxColumns)) }
        let rowCount = max(0, parsed.count - 1)
        var preview = AttachmentPreviewData.CSV(
            delimiter: delimiter, headers: headers, rows: rows,
            rowCount: rowCount, columnCount: columnCount)
        func payloadSize() -> Int { AttachmentPreviewData.csv(preview).jsonBody.render().utf8.count }
        while !preview.rows.isEmpty && payloadSize() > csvPayloadLimit {
            preview.rows.removeLast()
        }
        rows = preview.rows
        guard !(rowCount > 0 && rows.isEmpty) else { return nil }
        return preview
    }

    private static func detectDelimiter(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var best = ","
        var bestCount = -1
        for candidate in [",", "\t", ";"] {
            let count = firstLine.components(separatedBy: candidate).count - 1
            if count > bestCount { best = candidate; bestCount = count }
        }
        return best
    }

    private static func parseCSV(_ text: String, delimiter: String) -> [[String]] {
        let separator = Character(delimiter)
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inQuotes {
                if character == "\"", next == "\"" {
                    field.append("\"")
                    index += 2
                    continue
                }
                if character == "\"" { inQuotes = false }
                else { field.append(character) }
                index += 1
                continue
            }
            if character == "\"" { inQuotes = true }
            else if character == separator {
                row.append(field); field = ""
            } else if character == "\n" {
                row.append(field); field = ""; rows.append(row); row = []
            } else if character == "\r" {
                // ignored
            } else {
                field.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { cells in
            cells.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }
}
