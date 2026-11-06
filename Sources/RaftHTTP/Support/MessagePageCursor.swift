import Foundation

public enum MessagePageCursor {
    static func previewBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func previewBase64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static func parsePageCursor(_ raw: String?) -> PageCursor {
        guard let raw else { return .absent }
        if raw == "0" { return .value(0) }
        guard let parsed = Int(raw), parsed > 0 else { return .invalid }
        return .value(parsed)
    }

    static func messagePageLimit(_ raw: String?) -> Int {
        guard let raw, let parsed = Int(raw), parsed > 0 else { return 50 }
        return min(parsed, 200)
    }

    static func inboxQueryParameters(_ query: String?) -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(item[0]).removingPercentEncoding ?? String(item[0])
            let value = item.count == 2 ? (String(item[1]).removingPercentEncoding ?? String(item[1])) : ""
            result[name] = value
        }
        return result
    }

    static func validReactionEmoji(_ raw: String) -> String? {
        let emoji = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if emoji.isEmpty || emoji.utf16.count > 16 || emoji.contains(where: \.isWhitespace) {
            return nil
        }
        return emoji
    }

    static func encodeActorCursor(_ cursor: ActorCursor) -> String {
        let json = OrderedJSON.object([
            OrderedJSONField("principalId", cursor.principalId), OrderedJSONField("serverId", cursor.serverId),
            OrderedJSONField("messageId", cursor.messageId), OrderedJSONField("emoji", cursor.emoji),
            OrderedJSONField("discussionVersion", cursor.discussionVersion), OrderedJSONField("visibilityHash", cursor.visibilityHash),
            OrderedJSONField("actorKind", cursor.actorKind), OrderedJSONField("actorId", cursor.actorId),
        ]).render()
        return AuthTokenCodec.base64url(Data(json.utf8))
    }

    static func decodeActorCursor(_ raw: String) -> ActorCursor? {
        if raw.isEmpty || raw.utf8.count > 2048 { return nil }
        var base = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base.count % 4
        if remainder != 0 { base += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let principalId = object["principalId"] as? String,
              let serverId = object["serverId"] as? String,
              let messageId = object["messageId"] as? String,
              let emoji = object["emoji"] as? String,
              let visibilityHash = object["visibilityHash"] as? String,
              let actorKind = object["actorKind"] as? String,
              let actorId = object["actorId"] as? String,
              actorKind == "user" || actorKind == "agent"
        else { return nil }
        let version: Int
        if let number = object["discussionVersion"] as? NSNumber {
            version = number.intValue
        } else if let int = object["discussionVersion"] as? Int {
            version = int
        } else {
            return nil
        }
        return ActorCursor(
            principalId: principalId,
            serverId: serverId,
            messageId: messageId,
            emoji: emoji,
            discussionVersion: version,
            visibilityHash: visibilityHash,
            actorKind: actorKind,
            actorId: actorId
        )
    }
}
