import Crypto
import Foundation

/// Public release-notes reads from `routes/releaseNotes.ts`.
///
/// Anonymous. A missing `limit` is 20; anything outside 1...100 is 400
/// `invalid_limit`. A cursor must be a base64url `{date,id}` or 400
/// `invalid_cursor`. Drafts never appear. Retracted releases keep their
/// metadata and lose their entries. Detail wants a UUID: anything else is 400
/// `invalid_release_id`, and an unknown id is 404 `not_found`.

public struct ReleaseNoteEntry: Equatable, Sendable {
    public var entryId: String
    public var type: String
    public var text: String
    public var emphasis: Bool
    public var ordinal: Int
    public var revision: Int

    public init(entryId: String, type: String, text: String, emphasis: Bool = false, ordinal: Int, revision: Int) {
        self.entryId = entryId
        self.type = type
        self.text = text
        self.emphasis = emphasis
        self.ordinal = ordinal
        self.revision = revision
    }
}

public struct ReleaseNoteRecord: Equatable, Sendable {
    public var id: String
    public var releaseKey: String
    public var version: String
    public var tag: String
    public var date: String
    public var currentRevision: Int?
    public var retracted: Bool
    public var snapshotHash: String
    public var publishedAt: String?
    public var entries: [ReleaseNoteEntry]

    public init(
        id: String,
        releaseKey: String,
        version: String,
        tag: String,
        date: String,
        currentRevision: Int?,
        retracted: Bool = false,
        snapshotHash: String,
        publishedAt: String? = nil,
        entries: [ReleaseNoteEntry] = []
    ) {
        self.id = id
        self.releaseKey = releaseKey
        self.version = version
        self.tag = tag
        self.date = date
        self.currentRevision = currentRevision
        self.retracted = retracted
        self.snapshotHash = snapshotHash
        self.publishedAt = publishedAt
        self.entries = entries
    }
}

public struct DatabaseConstraintError: Error, Equatable, Sendable {
    public var code: String
    public var constraint: String

    public init(code: String, constraint: String) {
        self.code = code
        self.constraint = constraint
    }
}

public enum ReleaseNotes {
    private static let identityConstraints: Set<String> = [
        "release_notes_release_key_unique",
        "release_notes_version_unique",
        "release_notes_tag_unique",
    ]

    public static func isReleaseIdentityUnique(_ error: (any Error)?) -> Bool {
        guard let error = error as? DatabaseConstraintError else { return false }
        return error.code == "23505" && identityConstraints.contains(error.constraint)
    }

    public static func list(limit rawLimit: String?, cursor: String?, ifNoneMatch: String?, notes: [ReleaseNoteRecord]) -> HTTPReply {
        let limit: Int
        if let rawLimit {
            guard let parsed = Int(rawLimit), rawLimit.allSatisfy(\.isNumber), (1...100).contains(parsed) else {
                return failure(400, "invalid_limit")
            }
            limit = parsed
        } else {
            limit = 20
        }
        let after: (date: String, id: String)?
        if let cursor {
            guard cursor.count <= 256, let decoded = decodeCursor(cursor) else {
                return failure(400, "invalid_cursor")
            }
            after = decoded
        } else {
            after = nil
        }
        let published = notes.filter { $0.currentRevision != nil }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id > $1.id
        }.filter { note in
            guard let after else { return true }
            if note.date < after.date { return true }
            return note.date == after.date && note.id < after.id
        }
        let page = Array(published.prefix(limit))
        let items = page.map { itemJSON($0) }.joined(separator: ",")
        let next: String
        if published.count > limit, let last = page.last {
            next = jsonString(encodeCursor(date: last.date, id: last.id))
        } else {
            next = "null"
        }
        let body = "{\"items\":[\(items)],\"nextCursor\":\(next)}"
        return cached(body, ifNoneMatch: ifNoneMatch)
    }

    public static func detail(id: String, ifNoneMatch: String?, notes: [ReleaseNoteRecord]) -> HTTPReply {
        guard id.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return failure(400, "invalid_release_id")
        }
        guard let note = notes.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame && $0.currentRevision != nil }) else {
            return failure(404, "not_found")
        }
        return cached(rowJSON(note), ifNoneMatch: ifNoneMatch)
    }

    private static func itemJSON(_ note: ReleaseNoteRecord) -> String {
        rowJSON(note)
    }

    private static func rowJSON(_ note: ReleaseNoteRecord) -> String {
        let state = note.retracted ? "retracted" : "published"
        let entries = note.retracted ? "" : note.entries
            .filter { $0.revision == note.currentRevision }
            .sorted { $0.ordinal < $1.ordinal }
            .map { entry in
                "{\"entryId\":\(jsonString(entry.entryId)),\"type\":\(jsonString(entry.type)),\"text\":\(jsonString(entry.text)),\"emphasis\":\(entry.emphasis),\"ordinal\":\(entry.ordinal)}"
            }
            .joined(separator: ",")
        let publishedAt = note.publishedAt.map(jsonString) ?? "null"
        return "{\"releaseId\":\(jsonString(note.id)),\"releaseKey\":\(jsonString(note.releaseKey)),\"version\":\(jsonString(note.version)),\"tag\":\(jsonString(note.tag)),\"date\":\(jsonString(note.date)),\"revision\":\(note.currentRevision ?? 0),\"snapshotHash\":\(jsonString(note.snapshotHash)),\"publishedAt\":\(publishedAt),\"state\":\(jsonString(state)),\"entries\":[\(entries)]}"
    }

    private static func cached(_ body: String, ifNoneMatch: String?) -> HTTPReply {
        let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        let etag = "\"\(digest)\""
        if ifNoneMatch == etag {
            return HTTPReply(status: 304, headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "ETag": etag,
                "Cache-Control": "public, max-age=30",
                "Content-Length": "0",
            ], body: "")
        }
        return HTTPReply(status: 200, headers: [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "ETag": etag,
            "Cache-Control": "public, max-age=30",
            "Content-Length": String(Data(body.utf8).count),
        ], body: body)
    }

    private static func failure(_ status: Int, _ code: String) -> HTTPReply {
        let body = "{\"code\":\(jsonString(code))}"
        return HTTPReply(status: status, headers: [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ], body: body)
    }

    private static func decodeCursor(_ value: String) -> (date: String, id: String)? {
        var base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base.append("=") }
        guard let data = Data(base64Encoded: base),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = object["date"] as? String,
              let id = object["id"] as? String,
              date.wholeMatch(of: /^\d{4}-\d{2}-\d{2}$/) != nil,
              id.wholeMatch(of: /^[0-9a-fA-F-]{36}$/) != nil
        else { return nil }
        return (date, id)
    }

    private static func encodeCursor(date: String, id: String) -> String {
        let raw = "{\"date\":\(jsonString(date)),\"id\":\(jsonString(id))}"
        var encoded = Data(raw.utf8).base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return encoded
    }
}
