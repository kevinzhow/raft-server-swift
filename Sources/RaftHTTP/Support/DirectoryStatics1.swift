import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoreFoundation



// Extracted static helpers from EmailLogin.swift (behavior unchanged).



extension EmailLoginDirectory {

    static func rfc5987Encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func empty(_ status: Int) -> HTTPReply {
        HTTPReply(status: status, headers: ["Content-Length": "0"], body: "")
    }

    static func searchSnippet(_ content: String) -> String {
        let compact = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if compact.count <= 180 { return compact }
        return String(compact.prefix(177)) + "..."
    }

    static func searchTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        func flush() {
            let word = latin.lowercased()
            latin = ""
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            tokens.append(word)
        }
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flush()
                tokens.append(String(scalar))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                latin.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    static func tokenCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in searchTokens(text) {
            counts[token, default: 0] += 1
        }
        return counts
    }

    static func matchScore(_ counts: [String: Int], _ queryTokens: [String], requireAll: Bool) -> Int? {
        var total = 0
        for token in queryTokens {
            let count = counts[token] ?? 0
            if count == 0 {
                if requireAll { return nil }
                continue
            }
            total += count
        }
        return total > 0 ? total : nil
    }

    static func messageIdMatches(_ stored: String, _ given: String) -> Bool {
        if ServerScope.isUUID(given) {
            return stored.caseInsensitiveCompare(given) == .orderedSame
        }
        return stored.lowercased().hasPrefix(given.lowercased())
    }

    static func contextWindowSide(_ raw: String?) -> Int {
        guard let raw, raw.wholeMatch(of: /^\d+$/) != nil, let value = Int(raw) else { return 15 }
        return min(value, 15)
    }

    static func contextJSON(channelId: String, message: StoredHumanMessage, seq: Int, archived: Bool, canonical: String?, actionMetadata: String? = nil, messagesJSON: String? = nil, hasOlder: Bool = false, hasNewer: Bool = false, threadSummariesJSON: String = "") -> HTTPReply {
        var messageJSON = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(message.content)),\"seq\":\(seq)"
        if let actionMetadata {
            messageJSON += ",\"actionMetadata\":\(actionMetadata)"
        }
        messageJSON += "}"
        let renderedMessages = messagesJSON ?? messageJSON
        var body = "{\"channelId\":\(jsonString(channelId)),\"targetMessageId\":\(jsonString(message.id)),\"hasOlder\":\(hasOlder ? "true" : "false"),\"hasNewer\":\(hasNewer ? "true" : "false"),\"messages\":[\(renderedMessages)]"
        if let canonical {
            body += ",\"canonicalTarget\":\(canonical)"
        }
        body += ",\"threadSummariesByParentMessageId\":{\(threadSummariesJSON)},\"historyLimited\":false,\"channelArchived\":\(archived ? "true" : "false")}"
        return Self.json(200, body)
    }

    static func forwardAttachmentSnapshotsJSON(_ snapshots: [ForwardAttachmentSnapshot]) -> String {
        snapshots.map { snap in
            let width = snap.width.map(String.init) ?? "null"
            let height = snap.height.map(String.init) ?? "null"
            return "{\"id\":\(jsonString(snap.id)),\"filename\":\(jsonString(snap.filename)),\"mimeType\":\(jsonString(snap.mimeType)),\"sizeBytes\":\(snap.sizeBytes),\"width\":\(width),\"height\":\(height)}"
        }.joined(separator: ",")
    }

    static func forwardItemJSON(_ item: ForwardItemRecord) -> String {
        let attachments = forwardAttachmentSnapshotsJSON(item.attachments)
        let snapshotId = item.snapshotId.map { jsonString($0) } ?? "null"
        let parent = item.sourceIsThreadParent ? "true" : "false"
        let target = item.sourceTargetId.map { jsonString($0) } ?? "null"
        let messageIdJSON = item.exposesPointers ? jsonString(item.sourceMessageId) : "null"
        var body = "{\"sourceMessageId\":\(messageIdJSON),\"sourceIsThreadParent\":\(parent),\"contentSnapshot\":\(jsonString(item.contentSnapshot)),\"sourceAuthorSnapshot\":{\"uniqueName\":\(jsonString(item.sourceAuthorUniqueName))},\"sourceTargetId\":\(target)"
        if !item.exposesPointers {
            body += ",\"sourceMessageSeq\":null,\"sourceServerId\":null"
        }
        if let threadId = item.sourceThreadId {
            body += ",\"sourceThreadId\":\(jsonString(threadId))"
        }
        if let parentChannelId = item.parentChannelId {
            body += ",\"parentChannelId\":\(jsonString(parentChannelId))"
        }
        body += ",\"sourceTargetSnapshot\":{\"id\":\(snapshotId),\"type\":\(jsonString(item.snapshotType)),\"label\":\(jsonString(item.snapshotLabel)),\"labelVisibility\":\(jsonString(item.snapshotLabelVisibility))},\"attachmentSnapshots\":[\(attachments)],\"attachmentPolicy\":\(jsonString(item.attachmentPolicy)),\"provenanceState\":\(jsonString(item.provenanceState))}"
        return body
    }

    static func scrubbedForwardItemJSON(_ item: ForwardItemRecord) -> String {
        let attachments = forwardAttachmentSnapshotsJSON(item.attachments)
        let parent = item.sourceIsThreadParent ? "true" : "false"
        let type = item.snapshotType.isEmpty ? "channel" : item.snapshotType
        return "{\"sourceMessageId\":null,\"sourceIsThreadParent\":\(parent),\"contentSnapshot\":\(jsonString(item.contentSnapshot)),\"sourceServerId\":null,\"sourceTargetId\":null,\"sourceThreadId\":null,\"parentChannelId\":null,\"sourceTargetSnapshot\":{\"id\":null,\"type\":\(jsonString(type)),\"label\":\"\",\"labelVisibility\":\"restricted\"},\"attachmentSnapshots\":[\(attachments)],\"attachmentPolicy\":\(jsonString(item.attachmentPolicy)),\"provenanceState\":\"original_unavailable\"}"
    }

    static func mentionBindingConflict(_ mentions: [MentionInput]) -> Bool {
        var byName: [String: String] = [:]
        for mention in mentions where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id), !mention.name.isEmpty else { continue }
            let key = mention.name.lowercased()
            let signature = "\(mention.type):\(mention.id)"
            if let previous = byName[key], previous != signature { return true }
            byName[key] = signature
        }
        return false
    }

    static func rawMentionHandles(_ content: String) -> [String] {
        var handles: [String] = []
        for match in content.matches(of: /(?:^|[^A-Za-z0-9_.-])@([A-Za-z0-9_.-]+)/) {
            let handle = String(match.1)
            if !handle.isEmpty, !handles.contains(handle) { handles.append(handle) }
        }
        return handles
    }

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
        let json = "{\"principalId\":\(jsonString(cursor.principalId)),\"serverId\":\(jsonString(cursor.serverId)),\"messageId\":\(jsonString(cursor.messageId)),\"emoji\":\(jsonString(cursor.emoji)),\"discussionVersion\":\(cursor.discussionVersion),\"visibilityHash\":\(jsonString(cursor.visibilityHash)),\"actorKind\":\(jsonString(cursor.actorKind)),\"actorId\":\(jsonString(cursor.actorId))}"
        var encoded = Data(json.utf8).base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return encoded
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

    static func utf16Ascending(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        for index in 0..<min(left.count, right.count) where left[index] != right[index] {
            return left[index] < right[index]
        }
        return left.count < right.count
    }

    static func messageIdHasShortPrefix(_ id: String, prefix: String) -> Bool {
        let normalized = prefix.lowercased()
        guard normalized.count == 8, let start = UInt64(normalized, radix: 16) else { return false }
        let value = id.lowercased()
        let lower = normalized + "-0000-0000-0000-000000000000"
        guard value >= lower else { return false }
        let next = start + 1
        if next > 0xffff_ffff { return true }
        let hex = String(next, radix: 16)
        let upper = String(repeating: "0", count: 8 - hex.count) + hex + "-0000-0000-0000-000000000000"
        return value < upper
    }

    static func reactionEmoji(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["emoji"] as? String
        else { return nil }
        let emoji = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if emoji.isEmpty || emoji.utf16.count > 16 || emoji.contains(where: \.isWhitespace) {
            return nil
        }
        return emoji
    }

    static func appLoginExpiresAt(_ now: Date = Date()) -> Date {
        now.addingTimeInterval(600)
    }

    static func appLoginRedirect(_ returnUri: String, requestId: String, query: String) -> String {
        let separator = returnUri.contains("?") ? "&" : "?"
        return "\(returnUri)\(separator)requestId=\(requestId)&\(query)"
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func deviceLoginEnabled(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return true }
        return !(value == "0" || value == "false" || value == "no" || value == "off")
    }

    static func deviceSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dvc_\(encoded)"
    }

    static func parseConfiguredMobileReturnURIs(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        var values: Set<String> = []
        for part in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "\n" }) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values.insert(trimmed) }
        }
        return values
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
        if let stored, !stored.isEmpty { return stored }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    static func attachmentJSON(_ ids: [String]) -> String {
        ids.map { "{\"id\":\(jsonString($0))}" }.joined(separator: ",")
    }

    static func humanMessageJSON(_ message: StoredHumanMessage) -> HTTPReply {
        let mentionJSON = message.mentions.map { mention in
            "{\"type\":\(jsonString(mention.type)),\"id\":\(jsonString(mention.id)),\"name\":\(jsonString(mention.name))}"
        }.joined(separator: ",")
        var body = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"content\":\(jsonString(message.content)),\"attachments\":[\(attachmentJSON(message.attachmentIds))],\"mentions\":[\(mentionJSON)]"
        if let randomId = message.randomId {
            body += ",\"randomId\":\(jsonString(randomId))"
        }
        body += "}"
        return json(200, body)
    }

    static func serializeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

}
