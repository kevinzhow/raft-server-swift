import Foundation

public struct ReleaseNoteDTO: JSONBodyConvertible {
    public let note: ReleaseNoteRecord
    public var jsonBody: OrderedJSON {
        let entries = note.retracted ? [] : note.entries
            .filter { $0.revision == note.currentRevision }
            .sorted { $0.ordinal < $1.ordinal }
        return .object([
            .init("releaseId", note.id), .init("releaseKey", note.releaseKey),
            .init("version", note.version), .init("tag", note.tag), .init("date", note.date),
            .init("revision", note.currentRevision ?? 0), .init("snapshotHash", note.snapshotHash),
            .init("publishedAt", optional: note.publishedAt),
            .init("state", note.retracted ? "retracted" : "published"),
            .init("entries", .array(entries.map { .object([
                .init("entryId", $0.entryId), .init("type", $0.type), .init("text", $0.text),
                .init("emphasis", $0.emphasis), .init("ordinal", $0.ordinal),
            ]) })),
        ])
    }
}
public struct ReleaseNotesListDTO: JSONBodyConvertible {
    public let items: [ReleaseNoteDTO]
    public let nextCursor: String?
    public var jsonBody: OrderedJSON { .object([
        .init("items", .array(items.map(\.jsonBody))), .init("nextCursor", optional: nextCursor),
    ]) }
}

/// Conditional release-note reads keep the entity tag even when the body is absent.
public enum ReleaseNotesResponse<Payload: JSONBodyConvertible>: JSONBodyConvertible {
    case published(Payload, etag: String)
    case notModified(etag: String)
    public var status: UInt { if case .notModified = self { 304 } else { 200 } }
    public var headers: ResponseHeaders {
        switch self {
        case .published(_, let etag):
            .standard(extra: ["ETag": etag, "Cache-Control": "public, max-age=30"])
        case .notModified(let etag):
            .exact(["X-Robots-Tag": AppFallback.robotsTag, "ETag": etag, "Cache-Control": "public, max-age=30"])
        }
    }
    public var jsonBody: OrderedJSON {
        switch self { case .published(let payload, _): payload.jsonBody; case .notModified: .raw("") }
    }
}
public enum ReleaseNotesError: String, DomainError {
    case invalidLimit = "invalid_limit"
    case invalidCursor = "invalid_cursor"
    case invalidReleaseId = "invalid_release_id"
    case notFound = "not_found"
    public var status: UInt { self == .notFound ? 404 : 400 }
    public var errorMessage: String { rawValue }
    public var errorBody: OrderedJSON? { .object([.init("code", rawValue)]) }
}
