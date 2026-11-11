import Foundation

/// The preview payload published by `GET /api/attachments/:id/preview`
/// (`packages/server/src/routes/attachments.ts:1319-1366` and
/// `packages/shared/src/attachmentPreview.ts`).
public enum AttachmentPreviewData: Sendable, Equatable {
    public struct DiffStats: Sendable, Equatable {
        public var files: Int
        public var hunks: Int
        public var additions: Int
        public var deletions: Int
    }

    public struct CSV: Sendable, Equatable {
        public var delimiter: String
        public var headers: [String]
        public var rows: [[String]]
        public var rowCount: Int
        public var columnCount: Int
    }

    case diff(DiffStats)
    case csv(CSV)
    case markdown(String)
    case pdf
    case text(String)

    var jsonBody: OrderedJSON {
        switch self {
        case .diff(let stats):
            return .object([
                OrderedJSONField("kind", "diff"),
                OrderedJSONField("stats", .object([
                    OrderedJSONField("files", stats.files),
                    OrderedJSONField("hunks", stats.hunks),
                    OrderedJSONField("additions", stats.additions),
                    OrderedJSONField("deletions", stats.deletions),
                ])),
            ])
        case .csv(let csv):
            return .object([
                OrderedJSONField("kind", "csv"),
                OrderedJSONField("delimiter", csv.delimiter),
                OrderedJSONField("headers", .array(csv.headers.map(OrderedJSON.string))),
                OrderedJSONField("rows", .array(csv.rows.map { .array($0.map(OrderedJSON.string)) })),
                OrderedJSONField("rowCount", csv.rowCount),
                OrderedJSONField("columnCount", csv.columnCount),
            ])
        case .markdown(let markdown):
            return .object([OrderedJSONField("kind", "markdown"), OrderedJSONField("markdown", markdown)])
        case .pdf:
            return .object([OrderedJSONField("kind", "pdf")])
        case .text(let text):
            return .object([OrderedJSONField("kind", "text"), OrderedJSONField("text", text)])
        }
    }
}

/// `200` for both a built preview and a readable file no provider supports.
/// `truncated` is always present on a built preview, matching the pinned
/// `buildAttachmentPreviewResponse` return object.
public enum AttachmentPreviewResponse: JSONBodyConvertible, Sendable, Equatable {
    case ok(AttachmentPreviewData, truncated: Bool)
    case unsupported(reason: String?)

    public var jsonBody: OrderedJSON {
        switch self {
        case .ok(let data, let truncated):
            return .object([
                OrderedJSONField("status", "ok"),
                OrderedJSONField("data", data.jsonBody),
                OrderedJSONField("truncated", truncated),
            ])
        case .unsupported(let reason):
            var body = OrderedJSONObject()
            body.append("status", "unsupported")
            body.append("reason", ifPresent: reason)
            return body.json
        }
    }
}

/// The route-specific refusals. A readable but unsupported file is not one of
/// them: the preview route answers `200 status:"unsupported"` for those.
public enum AttachmentPreviewError: DomainError, Equatable {
    case invalidAttachmentId
    case notFound
    case storageNotConfigured
    case buildFailed

    public var status: UInt {
        switch self {
        case .invalidAttachmentId: 400
        case .notFound: 404
        case .storageNotConfigured: 503
        case .buildFailed: 500
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidAttachmentId: "A valid attachment id is required"
        case .notFound: "Attachment not found"
        case .storageNotConfigured: "File storage is not configured on this server"
        case .buildFailed: "Failed to build attachment preview"
        }
    }

    public var errorCode: String? {
        self == .invalidAttachmentId ? "invalid_attachment_id" : nil
    }

    public var errorBody: OrderedJSON? {
        guard self == .invalidAttachmentId else { return nil }
        return .object([
            OrderedJSONField("error", errorMessage),
            OrderedJSONField("code", "invalid_attachment_id"),
        ])
    }
}
