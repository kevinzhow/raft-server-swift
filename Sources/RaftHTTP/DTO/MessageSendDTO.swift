import Foundation

// MARK: - Requests

/// `POST /api/channels/threads/:threadId/followers/agents/:agentId/restore`.
///
/// The retired handler parsed the body with a raw object cast and
/// `as? String`: a missing key, a JSON `null`, a non-string value or a body
/// that is not an object all read as the empty token, and the route answered
/// its published `{"ok":true,"restored":false}` instead of a 400. The decoder
/// below keeps that tolerance.
public struct RestoreThreadFollowerRequest: Codable, Sendable, Equatable {
    public var undoToken: String

    public init(undoToken: String = "") {
        self.undoToken = undoToken
    }

    private enum CodingKeys: String, CodingKey {
        case undoToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        undoToken = ((try? container?.decodeIfPresent(String.self, forKey: .undoToken)) ?? nil) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(undoToken, forKey: .undoToken)
    }
}

// MARK: - Responses

/// `GET /api/attachments/:id/url`.
///
/// Published order is `url` then `expiresAt`. The query-token path publishes
/// JSON `null` for `expiresAt`, so the member is always present.
public struct AttachmentDownloadURLResponse: JSONBodyConvertible, Sendable, Equatable {
    public var url: String
    public var expiresAt: String?

    public init(url: String, expiresAt: String?) {
        self.url = url
        self.expiresAt = expiresAt
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("url", url)
        body.append("expiresAt", optional: expiresAt)
        return body.json
    }
}

/// `DELETE /api/channels/threads/:threadId/followers/agents/:agentId`.
///
/// The first removal publishes `{"removed":true,"undoToken":…}`; an idempotent
/// replay of the same thread/agent pair publishes the extra leading
/// `"ok":true` member the legacy handler emitted on that branch.
public struct ThreadFollowerRemovalResponse: JSONBodyConvertible, Sendable, Equatable {
    public var removed: Bool
    public var undoToken: String
    /// `nil` on a first removal, `true` on an idempotent replay.
    public var ok: Bool?

    public init(removed: Bool, undoToken: String, ok: Bool? = nil) {
        self.removed = removed
        self.undoToken = undoToken
        self.ok = ok
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", ifPresent: ok)
        body.append("removed", removed)
        body.append("undoToken", undoToken)
        return body.json
    }
}

/// `POST /api/channels/threads/:threadId/followers/agents/:agentId/restore`.
///
/// Both branches publish `ok` before `restored`; a stale or foreign undo token
/// answers the published `{"ok":true,"restored":false}` without a write.
public struct ThreadFollowerRestoreResponse: JSONBodyConvertible, Sendable, Equatable {
    public var restored: Bool

    public init(restored: Bool) {
        self.restored = restored
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("restored", restored)
        return body.json
    }
}
