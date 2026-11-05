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

    static func evaluateAttestation(body: String, mode: String?, nodeEnv: String, verifier: ((String) -> Bool)?) -> (state: String, evidenceHash: String?) {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let raw = object?["attestation"] as? String
        let evidence = (raw?.isEmpty == false && (raw?.count ?? 0) <= 4096) ? raw : nil
        let enforce = nodeEnv == "production" || mode == "enforce" || (mode != nil && mode != "observe")
        let verified = evidence != nil && verifier?(evidence!) == true
        let hash = evidence.map { sha256($0) }
        if enforce && !verified { return ("rejected", hash) }
        if verified { return ("verified", hash) }
        return (evidence == nil ? "missing" : "observed", hash)
    }

    static func parseEnrollmentRequest(_ body: String) -> (appId: String, protocolVersion: Int, appVersion: String, releaseChannel: String, appInstanceId: String, publicKey: String, nonce: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let appId = object["appId"] as? String,
              appId == "ai.slock.desktop",
              appId.wholeMatch(of: /^[a-z0-9]+(?:\.[a-z0-9-]+){2,7}$/) != nil,
              ((object["protocolVersion"] as? NSNumber)?.intValue ?? object["protocolVersion"] as? Int) == 1,
              let appVersion = object["appVersion"] as? String,
              appVersion.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._+()-]{0,63}$/) != nil,
              let releaseChannel = object["releaseChannel"] as? String,
              releaseChannel == "development" || releaseChannel == "staging" || releaseChannel == "production",
              let appInstanceId = object["appInstanceId"] as? String,
              appInstanceId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
              let publicKey = object["publicKey"] as? String,
              canonicalBase64URL(publicKey, minBytes: 32, maxBytes: 128) != nil,
              let nonce = object["nonce"] as? String,
              canonicalBase64URL(nonce, minBytes: 32, maxBytes: 32) != nil
        else { return nil }
        return (appId, 1, appVersion, releaseChannel, appInstanceId, publicKey, nonce)
    }

    static func parseOpaqueCredential(_ value: String, prefix: String) -> (id: String, secret: String)? {
        guard value.count <= 160 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix,
              parts[1].wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
              canonicalBase64URL(parts[2], minBytes: 32, maxBytes: 32) != nil
        else { return nil }
        return (parts[1], parts[2])
    }

    static func canonicalBase64URL(_ value: String, minBytes: Int, maxBytes: Int) -> Data? {
        guard value.wholeMatch(of: /^[A-Za-z0-9_-]+$/) != nil,
              let bytes = base64urlDecode(value),
              (minBytes...maxBytes).contains(bytes.count),
              base64url(bytes) == value
        else { return nil }
        return bytes
    }

    static func mintOpaqueCredential(prefix: String, id: String) -> (opaque: String, secretHash: String) {
        var bytes = Data(count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let secret = base64url(bytes)
        return ("\(prefix).\(id).\(secret)", sha256(secret))
    }

    static func verifyEd25519(publicKeySPKI: String, transcript: Data, proof: String) -> Bool {
        guard let signature = canonicalBase64URL(proof, minBytes: 64, maxBytes: 64),
              let spki = canonicalBase64URL(publicKeySPKI, minBytes: 44, maxBytes: 44)
        else { return false }
        let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
        guard spki.starts(with: prefix), spki.count == 44,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: spki.dropFirst(prefix.count))
        else { return false }
        return key.isValidSignature(signature, for: transcript)
    }

    static func sseFrame(_ event: StoredNativeNotificationEvent) -> String {
        let data = "{\"body\":\(jsonString(event.body)),\"createdAt\":\(jsonString(iso8601(event.createdAt))),\"eventId\":\(jsonString(event.eventId)),\"serverId\":\(jsonString(event.serverId)),\"targetUri\":\(jsonString(event.targetUri)),\"title\":\(jsonString(event.title)),\"version\":1}"
        return "event: native-notification.v1\nid: \(event.eventId)\ndata: \(data)\n\n"
    }

    static func empty(_ status: Int) -> HTTPReply {
        HTTPReply(status: status, headers: ["Content-Length": "0"], body: "")
    }

    static func featureFlagClientFacts(_ object: [String: Any]) -> FeatureFlagClientFacts {
        let osValues: Set<String> = ["android", "ios", "ohos"]
        let buildTypes: Set<String> = ["release", "alpha", "debug"]
        let os = (object["os"] as? String).flatMap { osValues.contains($0) ? $0 : nil }
        let buildType = (object["buildType"] as? String).flatMap { buildTypes.contains($0) ? $0 : nil }
        var buildNumber: Int?
        if let raw = object["buildNumber"] {
            if let string = raw as? String, string.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil {
                buildNumber = Int(string)
            } else if let number = raw as? NSNumber,
                      String(cString: number.objCType) != "c",
                      String(cString: number.objCType) != "B",
                      number.doubleValue >= 0,
                      number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue <= Double(Int.max) {
                buildNumber = number.intValue
            }
        }
        return FeatureFlagClientFacts(os: os, buildNumber: buildNumber, buildType: buildType)
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

    static func forwardTargetScore(_ query: String, _ candidate: String) -> Int {
        if candidate.isEmpty { return 0 }
        if candidate == query { return 400 }
        if candidate.hasPrefix(query) { return 300 }
        if candidate.range(of: " \(query)") != nil { return 250 }
        if let range = candidate.range(of: query) {
            let index = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return max(1, 150 - index)
        }
        return 0
    }

    static func forwardTargetJSON(
        type: String,
        channelType: String?,
        id: String,
        title: String,
        subtitle: String,
        avatarUrl: String?,
        channelId: String?,
        joined: Bool?,
        dmExists: Bool?,
        canForwardNow: Bool,
        requiredAction: String?
    ) -> String {
        let channelTypeJSON = channelType.map { jsonString($0) } ?? "null"
        let avatarJSON = avatarUrl.map { jsonString($0) } ?? "null"
        let channelJSON = channelId.map { jsonString($0) } ?? "null"
        let joinedJSON = joined.map { $0 ? "true" : "false" } ?? "null"
        let dmJSON = dmExists.map { $0 ? "true" : "false" } ?? "null"
        let requiredJSON = requiredAction.map { jsonString($0) } ?? "null"
        return "{\"type\":\(jsonString(type)),\"channelType\":\(channelTypeJSON),\"id\":\(jsonString(id)),\"title\":\(jsonString(title)),\"subtitle\":\(jsonString(subtitle)),\"avatarUrl\":\(avatarJSON),\"channelId\":\(channelJSON),\"joined\":\(joinedJSON),\"dmExists\":\(dmJSON),\"canForwardNow\":\(canForwardNow ? "true" : "false"),\"requiredAction\":\(requiredJSON)}"
    }

    static func forwardMessageReply(message: StoredHumanMessage, record: StoredForwardRecord, outcome: String) -> HTTPReply {
        let items = forwardItemsJSON(record.items)
        var body = "{\"id\":\(jsonString(message.id)),\"messageType\":\"chat\",\"channelId\":\(jsonString(message.channelId)),\"content\":\(jsonString(message.content)),\"attachments\":[\(attachmentJSON(message.attachmentIds))]"
        if let randomId = message.randomId {
            body += ",\"randomId\":\(jsonString(randomId))"
        }
        body += ",\"actionMetadata\":{\"kind\":\"forwarded-bundle\",\"destinationTargetId\":\(jsonString(record.destinationTargetId)),\"forwardedItems\":[\(items)]}}"
        var reply = json(200, body)
        reply.headers["X-Raft-Forward-Outcome"] = outcome
        return reply
    }

    static func forwardItemsJSON(_ items: [ForwardItemRecord]) -> String {
        items.map { forwardItemJSON($0) }.joined(separator: ",")
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

    static func forwardDestinationIds(_ value: Any?) -> [String]? {
        guard let rows = value as? [Any], !rows.isEmpty else { return nil }
        var ids: [String] = []
        var seen = Set<String>()
        for row in rows {
            guard let raw = row as? String else { return nil }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ServerScope.isUUID(id) else { return nil }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        if ids.isEmpty || ids.count > 10 { return nil }
        return ids
    }

    static func forwardSourceIds(_ value: Any?) -> [String]? {
        guard let rows = value as? [Any], !rows.isEmpty, rows.count <= 20 else { return nil }
        var ids: [String] = []
        for row in rows {
            guard let raw = row as? String else { return nil }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ServerScope.isUUID(id), !ids.contains(id) else { return nil }
            ids.append(id)
        }
        return ids
    }

    static func pendingMentionExpiry() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(7 * 24 * 60 * 60))
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

    static func mentionInputs(_ value: Any?) -> [MentionInput] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { row in
            guard let object = row as? [String: Any],
                  let type = object["type"] as? String,
                  let id = object["id"] as? String,
                  let name = object["name"] as? String
            else { return nil }
            return MentionInput(type: type, id: id, name: name)
        }
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

    static func mentionDeliveryFields(handle: String, terminalCode: String?) -> String {
        guard let terminalCode, terminalCode != "INSTRUMENT_FAILED" else {
            return "\"targetHandle\":\(jsonString(handle)),\"outcome\":\"unknown\""
        }
        let category: String
        switch terminalCode {
        case "QUOTA_LIMITED":
            category = "quota"
        case "DELIVERY_REJECTED":
            category = "runtime_error"
        default:
            category = "unclassified"
        }
        return "\"targetHandle\":\(jsonString(handle)),\"outcome\":\"lost\",\"reasonCategory\":\(jsonString(category))"
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

    static func parseDoneFrontier(_ raw: Any?) -> Int? {
        guard let text = raw as? String, !text.isEmpty,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count <= 19,
              text.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
              let value = Int(text), value > 0
        else { return nil }
        return value
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

    static func inertThirdPartyMentions(_ text: String) -> String {
        text.replacingOccurrences(
            of: "@([A-Za-z0-9_.-]+)",
            with: "user:$1",
            options: .regularExpression
        )
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

    static func deviceNotReady(_ code: String, status: Int) -> HTTPReply {
        json(status, "{\"error\":\"Device authorization not ready\",\"code\":\(jsonString(code))}")
    }

    static func deviceUpdateFailed(_ code: String, status: Int) -> HTTPReply {
        json(status, "{\"error\":\"Device authorization could not be updated\",\"code\":\(jsonString(code))}")
    }

    static func stagingCapability(_ value: Any?, into issues: inout [Issue]) -> String? {
        guard let value else { return nil }
        guard let text = value as? String else {
            issues.append(Issue(path: "stagingSelfAccountCapability", message: "Expected string, received \(kind(value))"))
            return nil
        }
        if text.count < 32 {
            issues.append(Issue(path: "stagingSelfAccountCapability", message: "String must contain at least 32 character(s)"))
            return nil
        }
        if text.count > 256 {
            issues.append(Issue(path: "stagingSelfAccountCapability", message: "String must contain at most 256 character(s)"))
            return nil
        }
        return text
    }

    static func retirementJSON(_ receipt: RetirementReceipt) -> HTTPReply {
        let body = "{\"receipt\":{\"userId\":\(jsonString(receipt.userId)),\"actorUserId\":\(jsonString(receipt.actorUserId)),\"environment\":\(jsonString(receipt.environment)),\"terminalState\":\(jsonString(receipt.terminalState)),\"sessionsRevoked\":\(receipt.sessionsRevoked)}}"
        return json(200, body)
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

    static func parse(_ body: String) -> Parsed {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .invalid([Issue(path: "", message: "Expected object, received string")])
        }
        var issues: [Issue] = []
        let email = stringField(object["email"], path: "email", into: &issues)
        let password = stringField(object["password"], path: "password", into: &issues)
        if !issues.isEmpty { return .invalid(issues) }
        let pendingLinkToken = object["pendingLinkToken"] as? String
        return .request(Request(email: email ?? "", password: password ?? "", pendingLinkToken: pendingLinkToken))
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

    static func appReferenceIds(_ content: String) -> [String] {
        var ids: [String] = []
        for match in content.matches(of: /<app:([a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+)>/) {
            let id = String(match.1)
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    static func parseOptionalIanaTimezone(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 128 { return nil }
        if trimmed != "UTC" && !trimmed.contains("/") { return nil }
        if trimmed == "UTC" { return "UTC" }
        guard let zone = TimeZone(identifier: trimmed) else { return nil }
        let canonical = zone.identifier
        if canonical != "UTC" && !canonical.contains("/") { return nil }
        return canonical
    }

    static func humanMessageBodyIsValid(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelId = object["channelId"] as? String,
              ServerScope.isUUID(channelId)
        else { return false }
        if let attachments = object["attachmentIds"] {
            guard let ids = attachments as? [Any] else { return false }
            for id in ids {
                guard let string = id as? String, ServerScope.isUUID(string) else { return false }
            }
        }
        if object["asTask"] != nil {
            guard object["asTask"] is Bool else { return false }
        }
        return true
    }

    static func featureFlagKey(_ value: Any) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^[a-z0-9][a-z0-9_.-]{0,127}$/) != nil else { return nil }
        return trimmed
    }

    static func stringField(_ value: Any?, path: String, into issues: inout [Issue]) -> String? {
        guard let value else {
            issues.append(Issue(path: path, message: "Required"))
            return nil
        }
        if let string = value as? String {
            if string.isEmpty {
                issues.append(Issue(path: path, message: "String must contain at least 1 character(s)"))
                return nil
            }
            return string
        }
        issues.append(Issue(path: path, message: "Expected string, received \(kind(value))"))
        return nil
    }

    static func kind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if value is NSDictionary { return "object" }
        if value is NSArray { return "array" }
        if value is Bool { return "boolean" }
        if value is NSNumber { return "number" }
        return "object"
    }

    static func invalid(_ issues: [Issue]) -> HTTPReply {
        bodyIssues(issues, error: "Invalid email login body", code: "email_login_body_invalid")
    }

    static func registerInvalid(_ issues: [Issue]) -> HTTPReply {
        bodyIssues(issues, error: "Invalid email registration body", code: "email_register_body_invalid")
    }

    static func bodyIssues(_ issues: [Issue], error: String, code: String) -> HTTPReply {
        let listed = issues.map {
            "{\"path\":\(jsonString($0.path)),\"message\":\(jsonString($0.message))}"
        }.joined(separator: ",")
        return json(400, "{\"error\":\(jsonString(error)),\"code\":\(jsonString(code)),\"issues\":[\(listed)]}")
    }

    static func deviceContext(userAgent: String, country: String) -> [String: Any] {
        var context: [String: Any] = [:]
        if let range = userAgent.range(of: "Chrome/") {
            let rest = userAgent[range.upperBound...]
            let major = rest.prefix(while: { $0 != "." && !$0.isWhitespace })
            context["$browser"] = "chrome"
            if let version = Int(major) { context["$browser_version"] = version }
        } else if userAgent.contains("Firefox/") {
            context["$browser"] = "firefox"
        } else if userAgent.contains("Safari/") {
            context["$browser"] = "safari"
        } else {
            context["$browser"] = "unknown"
        }
        if userAgent.contains("Windows") {
            context["$os"] = "windows"
        } else if userAgent.contains("Mac OS X") {
            context["$os"] = "macos"
        } else if userAgent.contains("Android") {
            context["$os"] = "android"
        } else if userAgent.contains("iPhone") || userAgent.contains("iPad") {
            context["$os"] = "ios"
        } else if userAgent.contains("Linux") {
            context["$os"] = "linux"
        } else {
            context["$os"] = "unknown"
        }
        context["$device_type"] = userAgent.contains("Mobile") ? "mobile" : "desktop"
        let normalizedCountry = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedCountry.wholeMatch(of: /^[A-Z]{2}$/) != nil {
            context["$country"] = normalizedCountry
        }
        return context
    }

    static func deprecatedRuntimeReply(_ runtime: String) -> HTTPReply {
        Self.json(400, "{\"error\":\"Runtime is deprecated and cannot be selected: \(runtime)\"}")
    }

    static func runtimeConfigStructureError(_ config: [String: Any]) -> HTTPReply? {
        if let model = config["model"] as? [String: Any],
           model["kind"] as? String == "custom",
           (model["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.json(400, "{\"error\":\"runtimeConfig.model.name is required\"}")
        }
        guard let provider = config["provider"] as? [String: Any],
              provider["kind"] as? String == "custom"
        else { return nil }
        let runtime = config["runtime"] as? String ?? ""
        if runtime == "cursor" {
            return Self.json(400, "{\"error\":\"runtimeConfig.provider is not supported for runtime: cursor\"}")
        }
        if (provider["apiKey"] as? String ?? "").isEmpty {
            return Self.json(400, "{\"error\":\"runtimeConfig.provider.apiKey is required\"}")
        }
        return nil
    }

    static func validatedEnvVars(_ value: Any?) -> (env: [String: String]?, error: String?) {
        guard let value, !(value is NSNull) else { return (nil, nil) }
        guard let object = value as? [String: Any] else {
            return (nil, "envVars must be an object")
        }
        var env: [String: String] = [:]
        for (key, raw) in object {
            guard let text = raw as? String else {
                return (nil, "envVars keys and values must be strings")
            }
            guard key.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_]*$/) != nil else {
                return (nil, "Invalid env var key \"\(key)\": must match [A-Za-z_][A-Za-z0-9_]*")
            }
            guard !key.contains("\0"), !text.contains("\0") else {
                return (nil, "envVars keys and values must not contain null bytes")
            }
            env[key] = text
        }
        return (env, nil)
    }

    static func normalizeRuntimeConfig(_ raw: [String: Any]) -> [String: Any] {
        var config = raw
        if config["version"] == nil { config["version"] = 1 }
        if config["mode"] == nil { config["mode"] = ["kind": "default"] }
        if config["reasoningEffort"] == nil { config["reasoningEffort"] = NSNull() }
        var userEnv: [String: String] = [:]
        if let env = config["envVars"] as? [String: String] {
            for (key, value) in env where !key.hasPrefix("ANTHROPIC_") {
                userEnv[key] = value
            }
        }
        config["envVars"] = userEnv
        return config
    }

    static func derivedAgentEnvVars(_ config: [String: Any], userEnv: [String: String]) -> [String: String] {
        var env = userEnv
        if config["runtime"] as? String == "claude" {
            if let provider = config["provider"] as? [String: Any], provider["kind"] as? String == "custom" {
                if let apiUrl = provider["apiUrl"] as? String { env["ANTHROPIC_BASE_URL"] = apiUrl }
                if let apiKey = provider["apiKey"] as? String { env["ANTHROPIC_API_KEY"] = apiKey }
            }
            if let model = config["model"] as? [String: Any], model["kind"] as? String == "custom",
               let name = model["name"] as? String {
                env["ANTHROPIC_CUSTOM_MODEL_OPTION"] = name
            }
        }
        return env
    }

    static func privateJSON(_ body: String) -> HTTPReply {
        HTTPReply(
            status: 200,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "private, no-store",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    static func serializeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func redactedRuntimeConfigJSON(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return raw }
        if var provider = object["provider"] as? [String: Any], provider["apiKey"] != nil {
            provider["apiKey"] = ""
            object["provider"] = provider
        }
        guard let redacted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return raw
        }
        return String(decoding: redacted, as: UTF8.self)
    }

    static func agentModel(from runtimeConfigJSON: String?, external: Bool) -> String {
        if external { return "external" }
        guard let runtimeConfigJSON,
              let config = (try? JSONSerialization.jsonObject(with: Data(runtimeConfigJSON.utf8))) as? [String: Any],
              let model = config["model"] as? [String: Any]
        else { return "" }
        return (model["name"] as? String) ?? (model["id"] as? String) ?? ""
    }

    static func agentRuntimeJSON(
        id: String,
        name: String,
        runtime: String,
        runtimeConfigJSON: String,
        envVarsJSON: String,
        external: Bool,
        includeEnvVars: Bool = true
    ) -> String {
        let config = (try? JSONSerialization.jsonObject(with: Data(runtimeConfigJSON.utf8))) as? [String: Any] ?? [:]
        let model: String
        if external {
            model = "external"
        } else {
            model = (config["model"] as? [String: Any])?["name"] as? String
                ?? (config["model"] as? [String: Any])?["id"] as? String
                ?? ""
        }
        let env = includeEnvVars ? (envVarsJSON.isEmpty ? "{}" : envVarsJSON) : "null"
        return "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"runtime\":\(jsonString(runtime)),\"model\":\(jsonString(model)),\"external\":\(external),\"machineId\":null,\"reasoningEffort\":null,\"envVars\":\(env),\"runtimeConfig\":\(runtimeConfigJSON.isEmpty ? "{}" : runtimeConfigJSON)}"
    }

    static func applyAgentServerRole(
        directory: EmailLoginDirectory,
        actorUserId: String,
        actorRole: String,
        info: OAuthLedger.AgentManagementInfo,
        object: [String: Any]
    ) -> HTTPReply? {
        guard let targetRole = object["serverRole"] as? String else {
            return json(400, "{\"error\":\"serverRole must be a string\"}")
        }
        guard targetRole == "member" || targetRole == "admin" else {
            return json(400, "{\"error\":\"Invalid server role\"}")
        }
        guard actorRole == "owner" || actorRole == "admin" else {
            return json(403, "{\"error\":\"Forbidden\"}")
        }
        let currentRole = directory.oauth.agentRole(serverId: info.serverId, agentId: info.id) ?? "member"
        if targetRole == currentRole { return nil }
        if targetRole == "member", currentRole == "admin", actorRole != "owner" {
            return json(403, "{\"error\":\"Only the owner can demote an admin agent\"}")
        }
        if targetRole == "admin", actorRole == "admin", info.creatorUserId != actorUserId {
            return json(403, "{\"error\":\"Only the owner can promote this agent\"}")
        }
        directory.oauth.setAgentRole(serverId: info.serverId, agentId: info.id, role: targetRole)
        directory.postAgentRoleNotice(
            serverId: info.serverId,
            actorUserId: actorUserId,
            agentId: info.id,
            agentName: info.name,
            from: currentRole,
            to: targetRole
        )
        return nil
    }

    static func isoOrNull(_ date: Date?) -> String {
        guard let date else { return "null" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return jsonString(formatter.string(from: date))
    }

    static func agentSurfaceQueryInt(_ query: String?, _ name: String) -> Int? {
        guard let query, !query.isEmpty else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            guard key == name, parts.count == 2 else { continue }
            let raw = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            return Int(raw)
        }
        return nil
    }

    static func agentSurfaceQueryString(_ query: String?, _ name: String) -> String? {
        guard let query, !query.isEmpty else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            guard key == name else { continue }
            let raw = parts.count > 1 ? String(parts[1]) : ""
            return (raw.removingPercentEncoding ?? raw)
        }
        return nil
    }

    static func migrationSourceArchiveBackoff(attempts: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(0, attempts - 1))), 6 * 60 * 60)
    }

    static func migrationArchiveFailureCode(_ error: Error) -> String {
        if let typed = error as? MachineMigrationArchiveFailure,
           typed.code.range(of: "^[A-Za-z0-9_:.-]{1,160}$", options: .regularExpression) != nil {
            return typed.code
        }
        return "MIGRATION_SOURCE_WORKSPACE_ARCHIVE_FAILED"
    }

    static func isAgentConnectionIdentifier(_ value: String) -> Bool {
        value.range(of: agentConnectionIDPattern, options: .regularExpression) != nil
    }

    static func parseConnectionStatus(_ body: String) -> HostedConnectionStatusRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return nil
        }
        let connected = object["connected"] as? Bool ?? false
        var connectors: [HostedConnectionConnectorRecord] = []
        if let raw = object["connectors"] as? [Any] {
            for entry in raw {
                guard let row = entry as? [String: Any],
                      let id = row["id"] as? String,
                      isAgentConnectionIdentifier(id)
                else { continue }
                connectors.append(HostedConnectionConnectorRecord(
                    id: id,
                    account: row["account"] as? String ?? "",
                    creatorRaftUserId: row["creatorRaftUserId"] as? String,
                    createdAt: row["createdAt"] as? String,
                    current: row["current"] as? Bool ?? false
                ))
                if connectors.count >= 100 { break }
            }
        }
        let rawConnectorId = object["connectorId"] as? String
        let connectorId = connected ? rawConnectorId.flatMap { isAgentConnectionIdentifier($0) ? $0 : nil } : nil
        return HostedConnectionStatusRecord(
            connected: connected,
            account: object["account"] as? String,
            connectedAt: object["connectedAt"] as? String,
            connectedBy: object["connectedBy"] as? String,
            scopes: (object["scopes"] as? [Any])?.compactMap { $0 as? String } ?? [],
            connectorId: connectorId,
            connectors: connectors
        )
    }

    static func providerErrorParts(_ body: String) -> (code: String?, message: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (error["code"] as? String, error["message"] as? String)
    }

    static func machineAPIKeyMaterial() -> String {
        machineAPIKeyPrefix + credentialHex64()
    }

    static func computerAPIKeyMaterial() -> String {
        computerAPIKeyPrefix + credentialHex64()
    }

    static func credentialHex64() -> String {
        (UUID().uuidString + UUID().uuidString)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
    }

    static func resolveRuntimeModelProbe(
        machineId: String,
        runtimeId: String,
        refresh: Bool,
        routedLocally: (@Sendable (String) -> Bool)?,
        probe: (@Sendable (String, String, Bool) -> RuntimeModelProbeOutcome)?,
        cached: () -> [(id: String, label: String)]
    ) -> RuntimeProbeResolution {
        guard routedLocally?(machineId) ?? true else { return .notLive(reason: "machine_offline") }
        let outcome: RuntimeModelProbeOutcome
        if let probe {
            outcome = probe(machineId, runtimeId, refresh)
        } else {
            let models = cached()
            outcome = models.isEmpty
                ? .missingConfig
                : .live(models: models.map { RuntimeModelProbeModel(id: $0.id, label: $0.label) }, default: models.first?.id)
        }
        switch outcome {
        case .live(let models, let defaultModel), .models(let models, let defaultModel):
            return models.isEmpty ? .notLive(reason: "no_models") : .live(models: models, default: defaultModel)
        case .missingConfig:
            return .notLive(reason: "missing_config")
        case .noModels:
            return .notLive(reason: "no_models")
        case .unsupported:
            return .notLive(reason: "unsupported")
        case .error(let code, _):
            if code == "detect_timeout" { return .notLive(reason: "probe_timeout") }
            if code == "computer_offline" { return .notLive(reason: "machine_offline") }
            return .notLive(reason: "probe_failed")
        case .failed:
            return .notLive(reason: "probe_failed")
        }
    }

    static func runtimeReasonRetryable(_ reason: String) -> Bool {
        ["probe_timeout", "probe_failed", "machine_offline", "no_models"].contains(reason)
    }

    static func runtimeProbeOptionJSON(_ model: RuntimeModelProbeModel, reasoning: Bool) -> String {
        var json = "{\"value\":\(jsonString(model.id)),\"label\":\(jsonString(model.label))"
        if reasoning, let efforts = model.supportedReasoningEfforts, !efforts.isEmpty {
            json += ",\"supportedReasoningEfforts\":[\(efforts.map(jsonString).joined(separator: ","))]"
            if let defaultEffort = model.defaultReasoningEffort {
                json += ",\"defaultReasoningEffort\":\(jsonString(defaultEffort))"
            }
        }
        return json + "}"
    }

    static func kimiSDKSource(
        resolution: RuntimeProbeResolution,
        protocolVersion: Int,
        expected: String
    ) -> HTTPReply {
        let managed = RuntimeModelProbeModel(id: "kimi-code/kimi-for-coding", label: "Kimi for Coding (default)")
        switch resolution {
        case .live(let models, let defaultModel):
            let options = models.map { runtimeProbeOptionJSON($0, reasoning: true) }.joined(separator: ",")
            let defaultValue = defaultModel ?? models.first?.id ?? ""
            let status = protocolVersion == 2 ? ",\"status\":\"live\"" : ""
            return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"kimi-sdk\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[\(options)],\"defaultValue\":\(jsonString(defaultValue))\(status)}")
        case .notLive(let reason):
            let retryable = runtimeReasonRetryable(reason)
            if protocolVersion == 2 {
                if reason == "missing_config" || reason == "machine_offline" {
                    let option = runtimeProbeOptionJSON(managed, reasoning: true)
                    return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"kimi-sdk\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[\(option)],\"defaultValue\":\"kimi-code/kimi-for-coding\",\"status\":\"fallback\",\"reason\":\(jsonString(reason)),\"retryable\":\(retryable)}")
                }
                return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"kimi-sdk\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[],\"defaultValue\":\"\",\"status\":\"unavailable\",\"reason\":\(jsonString(reason)),\"retryable\":\(retryable)}")
            }
            if reason == "missing_config" || reason == "machine_offline" {
                let option = runtimeProbeOptionJSON(managed, reasoning: true)
                return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"kimi-sdk\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[\(option)],\"defaultValue\":\"kimi-code/kimi-for-coding\"}")
            }
            let code: String
            switch reason {
            case "no_models": code = "runtime_model_source_no_models"
            case "unsupported": code = "runtime_model_source_unsupported"
            default: code = "runtime_model_source_error"
            }
            return Self.json(409, "{\"issues\":[{\"code\":\"\(code)\",\"pointer\":\"/optionSources/model\"}]}")
        }
    }

    static func prefersChinese(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.lowercased().hasPrefix("zh")
    }

    static func adoptedComputerReply(
        apiKey: String,
        computerId: String,
        machineId: String,
        serverId: String,
        resumed: Bool
    ) -> HTTPReply {
        Self.json(201, "{\"apiKey\":\(jsonString(apiKey)),\"computerId\":\(jsonString(computerId)),\"machineId\":\(jsonString(machineId)),\"serverId\":\(jsonString(serverId)),\"resumed\":\(resumed)}")
    }

    static func adoptedComputerName(_ supplied: String?, fallback: String) -> String {
        if let supplied {
            let trimmed = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 200 { return trimmed }
        }
        if !fallback.isEmpty, fallback.count <= 200 { return fallback }
        return "raft-computer"
    }

    static func runnerModel(from runtimeConfigJSON: String?) -> String {
        guard let runtimeConfigJSON,
              let object = (try? JSONSerialization.jsonObject(with: Data(runtimeConfigJSON.utf8))) as? [String: Any],
              let model = object["model"]
        else { return "" }
        if let text = model as? String { return text }
        if let structured = model as? [String: Any], let id = structured["id"] as? String { return id }
        return ""
    }

    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func timezoneJSON(_ observation: TimezoneObservation) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "{\"firstObservedTimezone\":\(jsonString(observation.firstTimezone)),\"firstObservedTimezoneAt\":\(jsonString(formatter.string(from: observation.firstAt))),\"lastObservedTimezone\":\(jsonString(observation.lastTimezone)),\"lastObservedTimezoneAt\":\(jsonString(formatter.string(from: observation.lastAt)))}"
    }

    static func attestationString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value
    }

    static func attestationInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= 0, double <= 9_007_199_254_740_991 else { return nil }
        return number.intValue
    }

    static func signHS256(header: [String: Any], claims: [String: Any], secret: String) -> String {
        func base64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let headerJSON = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data("{}".utf8)
        let claimsJSON = (try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data("{}".utf8)
        let signingInput = "\(base64url(headerJSON)).\(base64url(claimsJSON))"
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: Data(secret.utf8))))
        return "\(signingInput).\(base64url(mac))"
    }

    static func agreementJSON(_ agreement: OAuthLedger.ServerAgreementInfo) -> String {
        "{\"id\":\(jsonString(agreement.id)),\"version\":\(agreement.version),\"title\":\(jsonString(agreement.title)),\"bodyMarkdown\":\(jsonString(agreement.bodyMarkdown)),\"enabled\":\(agreement.enabled)}"
    }

    static func detectTranslationLanguage(_ content: String) -> (language: String, confidence: Int) {
        let hasCJK = content.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
        }
        if hasCJK { return ("zh", 95) }
        let hasLetter = content.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        return hasLetter ? ("en", 99) : ("en", 20)
    }

    static func translationCodeOrLinkOnly(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") && trimmed.count >= 6 { return true }
        let linkOnly = trimmed.split(whereSeparator: { $0.isWhitespace }).allSatisfy { token in
            token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://")
        }
        return !trimmed.isEmpty && linkOnly
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func integrationValueJSON(_ service: [String: Any], _ key: String) -> String {
        guard let raw = service[key], !(raw is NSNull) else { return "null" }
        if let string = raw as? String { return jsonString(string) }
        if let values = raw as? [String] { return "[\(values.map(jsonString).joined(separator: ","))]" }
        return "null"
    }

    static func integrationServiceJSON(_ service: [String: Any]) -> String {
        let renderedName = (service["name"] as? String).map { jsonString(inertThirdPartyText($0)) } ?? "null"
        return "{\"id\":\(integrationValueJSON(service, "id")),\"clientId\":\(integrationValueJSON(service, "clientId")),\"name\":\(renderedName),\"description\":\(integrationValueJSON(service, "description")),\"homepageUrl\":\(integrationValueJSON(service, "homepageUrl")),\"agentManifestUrl\":\(integrationValueJSON(service, "agentManifestUrl")),\"agentManifestUrlSource\":\(integrationValueJSON(service, "agentManifestUrlSource")),\"allowedScopes\":\(integrationValueJSON(service, "allowedScopes")),\"whenToUse\":\((service["whenToUse"] as? String).map { jsonString(inertThirdPartyText($0)) } ?? "null"),\"appType\":\(integrationValueJSON(service, "appType"))}"
    }

    static func jsonNoStore(_ status: Int, _ body: String) -> HTTPReply {
        var reply = json(status, body)
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }

    static func agentAppEventJSON(_ event: OAuthLedger.AgentAppEventSummary) -> String {
        let deliveredAt = event.deliveredAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        let externalEventId = event.externalEventId.map(jsonString) ?? "null"
        let createdAt = jsonString(ISO8601DateFormatter().string(from: event.createdAt))
        let expiresAt = jsonString(ISO8601DateFormatter().string(from: event.expiresAt))
        let app = "{\"clientKey\":\(jsonString(event.clientKey)),\"clientName\":\(jsonString(event.clientName)),\"logoUrl\":null}"
        return "{\"id\":\(jsonString(event.id)),\"kind\":\(jsonString(event.kind)),\"summary\":\(jsonString(event.summary)),\"status\":\(jsonString(event.status)),\"createdAt\":\(createdAt),\"expiresAt\":\(expiresAt),\"deliveredAt\":\(deliveredAt),\"externalEventId\":\(externalEventId),\"app\":\(app)}"
    }

    static func canonicalCommentAnchor(_ raw: Any?) -> (json: String?, code: String?) {
        guard let value = raw, !(value is NSNull) else { return (nil, nil) }
        guard let object = value as? [String: Any],
              let data = object["data"] as? [String: Any]
        else { return (nil, "anchor_invalid") }
        guard let type = object["type"] as? String else { return (nil, "anchor_type_invalid") }
        // The cap measures the whole client payload: a 5 KB quote is rejected
        // as too large instead of being reported as a shape error.
        if let encoded = try? JSONSerialization.data(withJSONObject: object), encoded.count > 4_096 {
            return (nil, "anchor_too_large")
        }
        func quoted(_ key: String = "quote") -> String? {
            guard let quote = data[key] as? String else { return nil }
            return jsonString(quote)
        }
        func integer(_ key: String) -> Int? {
            guard let number = data[key] as? NSNumber else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double,
                  double >= Double(Int.min), double <= Double(Int.max)
            else { return nil }
            return Int(double)
        }
        func nonNegativeInteger(_ key: String) -> Int? {
            guard let value = integer(key), value >= 1 else { return nil }
            return value
        }
        func roundedNumber(_ key: String) -> Int? {
            guard let number = data[key] as? NSNumber else { return nil }
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return Int(double.rounded())
        }
        switch type {
        case "lines", "csv-rows":
            guard let start = integer("start"), let end = integer("end"), start >= 1, end >= start else {
                return (nil, "anchor_invalid")
            }
            var payload = "{\"start\":\(start),\"end\":\(end)"
            if let quote = quoted() { payload += ",\"quote\":\(quote)" }
            return ("{\"type\":\(jsonString(type)),\"data\":\(payload)}}", nil)
        case "md-section":
            guard let headingId = data["headingId"] as? String, !headingId.isEmpty,
                  let headingTitle = data["headingTitle"] as? String
            else { return (nil, "anchor_invalid") }
            var payload = "{\"headingId\":\(jsonString(headingId)),\"headingTitle\":\(jsonString(headingTitle))"
            if let quote = quoted() { payload += ",\"quote\":\(quote)" }
            return ("{\"type\":\"md-section\",\"data\":\(payload)}}", nil)
        case "html-region":
            guard let x = roundedNumber("x"), let y = roundedNumber("y"),
                  let w = roundedNumber("w"), let h = roundedNumber("h"),
                  let viewportWidth = roundedNumber("viewportWidth"),
                  let documentWidth = roundedNumber("documentWidth"),
                  let documentHeight = roundedNumber("documentHeight"),
                  x >= 0, y >= 0, w >= 0, h >= 0,
                  viewportWidth > 0, documentWidth > 0, documentHeight > 0
            else { return (nil, "anchor_invalid") }
            var payload = "{\"x\":\(x),\"y\":\(y),\"w\":\(w),\"h\":\(h),\"viewportWidth\":\(viewportWidth),\"documentWidth\":\(documentWidth),\"documentHeight\":\(documentHeight)"
            if let quote = quoted() { payload += ",\"quote\":\(quote)" }
            return ("{\"type\":\"html-region\",\"data\":\(payload)}}", nil)
        default:
            return (nil, "anchor_type_invalid")
        }
    }

    static func strictCommentMentions(_ raw: Any?) -> [MentionInput]? {
        guard let value = raw, !(value is NSNull) else { return [] }
        guard let rows = value as? [Any] else { return nil }
        var result: [MentionInput] = []
        for row in rows {
            guard let object = row as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "agent",
                  let id = object["id"] as? String, ServerScope.isUUID(id),
                  let name = object["name"] as? String, !name.isEmpty
            else { return nil }
            result.append(MentionInput(type: type, id: id, name: name))
        }
        return result
    }

    static func joinLinkExpired(_ link: JoinLinkRecord, now: Date) -> Bool {
        if let expiresAt = link.expiresAt, expiresAt <= now { return true }
        return false
    }

    static func joinLinkExhausted(_ link: JoinLinkRecord) -> Bool {
        if let maxUses = link.maxUses, link.useCount >= maxUses { return true }
        return false
    }

    static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func taskStatusFilter(_ rawQuery: String?) -> TaskStatusFilterResult {
        guard let rawQuery else { return .valid(nil) }
        let statusOccurrences = rawQuery.split(separator: "&").filter { $0.hasPrefix("status=") }
        guard statusOccurrences.count <= 1 else {
            return .invalid(Self.json(400, "{\"error\":\"status must be a single valid task status\"}"))
        }
        guard let occurrence = statusOccurrences.first else { return .valid(nil) }
        let value = String(occurrence.dropFirst("status=".count)).removingPercentEncoding ?? ""
        guard validTaskStatuses.contains(value) else {
            return .invalid(Self.json(400, "{\"error\":\"status must be a single valid task status\"}"))
        }
        return .valid(value)
    }

    static func normalizeFeedbackKey(_ key: String) -> String {
        var result = ""
        var previous: Character?
        for character in key {
            if character == "-" || character == " " {
                result.append("_")
            } else if character.isUppercase, let prior = previous, prior.isLowercase {
                result.append("_")
                result.append(Character(character.lowercased()))
            } else {
                result.append(Character(character.lowercased()))
            }
            previous = character
        }
        return result
    }

    static func feedbackContainsForbiddenKey(_ value: Any) -> Bool {
        if let array = value as? [Any] {
            return array.contains(where: feedbackContainsForbiddenKey)
        }
        guard let object = value as? [String: Any] else { return false }
        for (key, nested) in object {
            if feedbackLocatorForbiddenKeys.contains(normalizeFeedbackKey(key)) { return true }
            if feedbackContainsForbiddenKey(nested) { return true }
        }
        return false
    }

    static func feedbackStableJSON(_ value: Any) -> String {
        if let array = value as? [Any] {
            return "[" + array.map { feedbackStableJSON($0) }.joined(separator: ",") + "]"
        }
        if let object = value as? [String: Any] {
            let parts = object.keys.sorted().map { key in
                "\(jsonString(key)):\(feedbackStableJSON(object[key] as Any))"
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" || type == "B" {
                return number.boolValue ? "true" : "false"
            }
            if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 {
                return String(number.int64Value)
            }
            return String(number.doubleValue)
        }
        if let string = value as? String {
            return jsonString(string)
        }
        return "null"
    }

    static func appConfigDefaults() -> [String: Any] {
        ["enabled": true, "threshold_bytes": 65536, "interval_seconds": 3600]
    }

    static func appConfigValueJSON(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber { return String(number.intValue) }
        if let string = value as? String { return jsonString(string) }
        return "null"
    }

    static func freshnessDecisionProducerFactId(
        agentId: String,
        target: String,
        reason: String,
        pendingMaxSeq: Int,
        modelSeenSeq: Int,
        heldMessageCount: Int,
        omittedMessageCount: Int
    ) -> String {
        let payload = "{"
            + "\"action\":\"send\","
            + "\"agentId\":\(jsonString(agentId)),"
            + "\"decision\":\"syncing_hold\","
            + "\"heldMessageCount\":\(heldMessageCount),"
            + "\"modelSeenSeq\":\(modelSeenSeq),"
            + "\"omittedMessageCount\":\(omittedMessageCount),"
            + "\"pendingMaxSeq\":\(pendingMaxSeq),"
            + "\"reason\":\(jsonString(reason)),"
            + "\"target\":\(jsonString(target))"
            + "}"
        return "freshness_decision_fact:" + sha256Hex(payload)
    }

    static func mentionHandlesOutsideCode(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])@([A-Za-z0-9][A-Za-z0-9_.-]*)")
        var handles: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            var prose = String(line)
            prose = prose.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
            let full = NSRange(location: 0, length: (prose as NSString).length)
            for match in pattern.matches(in: prose, options: [], range: full) {
                handles.append((prose as NSString).substring(with: match.range(at: 1)))
            }
        }
        return handles
    }

    static func pendingMentionActionJSON(messageId: String, handle: String, avatarUrl: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAt = formatter.string(from: Date().addingTimeInterval(86_400))
        let avatar = avatarUrl.map(jsonString) ?? "null"
        return "{\"resolutionId\":\(jsonString(UUID().uuidString.lowercased())),\"messageId\":\(jsonString(messageId)),\"targetType\":\"agent\",\"targetHandle\":\(jsonString(handle)),\"targetAvatarUrl\":\(avatar),\"reason\":\"not_member\",\"availableActions\":[\"notify\"],\"expiresAt\":\(jsonString(expiresAt))}"
    }

    static func isoMillis(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func inertThirdPartyText(_ raw: String) -> String {
        var text = raw
        if text.count > 4_000 {
            text = String(text.prefix(4_000)) + "\n[truncated]"
        }
        let markupPattern = try! NSRegularExpression(
            pattern: "</?(?:result|preview|match)\\b[^>]*>|<omit\\s*/>",
            options: [.caseInsensitive]
        )
        let escaped = NSMutableString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        for match in markupPattern.matches(in: text, options: [], range: full).reversed() {
            let tag = (text as NSString).substring(with: match.range)
            let neutral = tag
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            escaped.replaceCharacters(in: match.range, with: neutral)
        }
        text = escaped as String
        return neutralizeRaftRefsOutsideCode(text)
    }

    static func neutralizeRaftRefsOutsideCode(_ text: String) -> String {
        let refPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])@([A-Za-z0-9][A-Za-z0-9_.-]*)")
        var output = ""
        var cursor = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                let fence = String(text[index...].prefix(3)) == "```"
                let marker = fence ? "```" : "`"
                let contentStart = text.index(index, offsetBy: marker.count)
                if let close = text.range(of: marker, range: contentStart..<text.endIndex) {
                    output += neutralizeRaftRefs(String(text[cursor..<index]), pattern: refPattern)
                    output += String(text[index..<close.upperBound])
                    cursor = close.upperBound
                    index = close.upperBound
                    continue
                }
            }
            index = text.index(after: index)
        }
        output += neutralizeRaftRefs(String(text[cursor...]), pattern: refPattern)
        return output
    }

    static func neutralizeRaftRefs(_ source: String, pattern: NSRegularExpression) -> String {
        let full = NSRange(location: 0, length: (source as NSString).length)
        let matches = pattern.matches(in: source, options: [], range: full)
        guard !matches.isEmpty else { return source }
        var output = ""
        var cursor = 0
        for match in matches {
            output += (source as NSString).substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += "user:" + (source as NSString).substring(with: match.range(at: 1))
            cursor = match.range.location + match.range.length
        }
        output += (source as NSString).substring(from: cursor)
        return output
    }

    static func marketplaceAppNameBinding(_ raw: String) -> (name: String, sha256: String) {
        (inertThirdPartyText(raw), sha256Hex(raw))
    }

    static func generatedIntegrationClientKey(_ name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty || !(slug.first?.isLetter == true) { slug = "app-" + slug }
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6)
        return "\(slug.prefix(32))-\(hex)"
    }

    static func managedMCPEndpointError(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !raw.contains("?"), !raw.contains("#")
        else { return "managed_mcp_endpoint_invalid" }
        return nil
    }

    static func managedMCPEndpointSanitized(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }

    static func encodeCursor(channelId: String, taskNumber: Int) -> String {
        let payload = "{\"c\":\(jsonString(channelId)),\"n\":\(taskNumber)}"
        return Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeCursor(_ raw: String) -> (channelId: String, taskNumber: Int)? {
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let channelId = object["c"] as? String,
              channelId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil,
              let taskNumber = object["n"] as? Int
        else { return nil }
        return (channelId, taskNumber)
    }

    static func canonicalJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dict {
                if key == "idempotencyKey" { continue }
                if let bool = child as? Bool, bool == false { continue }
                if child is NSNull { continue }
                result[key] = canonicalJSON(child)
            }
            return result
        }
        if let array = value as? [Any] { return array.map(canonicalJSON) }
        return value
    }

    static func agentApiRequestFingerprint(_ object: [String: Any]) -> String {
        let canonical = canonicalJSON(object)
        let data = (try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])) ?? Data()
        return sha256Hex(String(decoding: data, as: UTF8.self))
    }

    static func reminderListJSON(_ rows: [ReminderRecord]) -> HTTPReply {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items = rows.map { reminder in
            "{\"id\":\(jsonString(reminder.id)),\"title\":\(jsonString(reminder.title)),\"ownerAgentId\":\(jsonString(reminder.ownerAgentId)),\"fireAt\":\(jsonString(formatter.string(from: reminder.fireAt)))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"reminders\":[\("\(items)")]}")
    }

    static func reminderSummaryJSON(
        _ row: (id: String, status: String, version: Int, title: String),
        ownerAgentId: String? = nil,
        fireAt: Date? = nil
    ) -> String {
        let fireJSON = fireAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        let ownerJSON = ownerAgentId.map(jsonString) ?? "null"
        return "{\"id\":\(jsonString(row.id)),\"reminderId\":\(jsonString(row.id)),\"ownerAgentId\":\(ownerJSON),\"status\":\(jsonString(row.status)),\"version\":\(row.version),\"title\":\(jsonString(row.title)),\"fireAt\":\(fireJSON)}"
    }

    static func reminderLogJSON(_ events: [(eventType: String, version: Int)]) -> String {
        let items = events.map { "{\"eventType\":\(jsonString($0.eventType)),\"version\":\($0.version)}" }.joined(separator: ",")
        return "{\"events\":[\(items)]}"
    }

    static func announcementContextQuery(_ query: String?, headerServerId: String? = nil) -> AnnouncementContext {
        let values = (query ?? "").split(separator: "&").compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first == "server_id" else { return nil }
            return parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : ""
        }
        if values.count > 1 {
            return .failure(json(400, "{\"error\":\"server_id must be provided at most once\"}"))
        }
        if let value = values.first {
            guard ServerScope.isUUID(value) else {
                return .failure(json(400, "{\"error\":\"server_id must be a valid UUID\"}"))
            }
            return .success(value)
        }
        return .success(headerServerId)
    }

    static func avatarPlainText(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    static func isPublicHTTPSPushEndpoint(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if host.contains(":") { return false }
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            guard let first = UInt8(octets[0]), let second = UInt8(octets[1]) else { return false }
            if first == 10 || first == 127 || first == 0 { return false }
            if first == 172, (16...31).contains(second) { return false }
            if first == 192, second == 168 { return false }
            if first == 169, second == 254 { return false }
            return false
        }
        return true
    }

    static func providerConnectionLabel(_ id: String) -> String {
        switch id {
        case "openai-compatible": return "OpenAI compatible"
        case "anthropic-compatible": return "Anthropic compatible"
        case "minimax-cn": return "MiniMax CN"
        case "zai-coding-cn": return "Z.ai Coding CN"
        case "moonshotai-cn": return "Moonshot AI CN"
        case "kimi-coding": return "Kimi Coding"
        case "qwen-token-plan": return "Qwen Token Plan"
        case "qwen-token-plan-cn": return "Qwen Token Plan CN"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    static func providerConnectionJSON(_ connection: ProviderConnection) -> String {
        let endpoint = connection.endpointUrl.map { jsonString($0) } ?? "null"
        return "{\"id\":\(jsonString(connection.id)),\"name\":\(jsonString(connection.name)),\"providerId\":\(jsonString(connection.providerId)),\"authMethod\":\"api_key\",\"endpointUrl\":\(endpoint),\"supportsImageInput\":\(connection.supportsImageInput),\"enabled\":true,\"status\":\(jsonString(connection.status)),\"configVersion\":\(connection.configVersion),\"credentialVersion\":\(connection.credentialVersion),\"hasCredential\":\(connection.hasCredential),\"assignedAgentCount\":0,\"latestVerified\":null,\"lastCheckedAt\":null,\"lastErrorCategory\":null,\"createdAt\":\(jsonString(ISO8601DateFormatter().string(from: connection.createdAt))),\"updatedAt\":\(jsonString(ISO8601DateFormatter().string(from: connection.updatedAt)))}"
    }

    static func feedbackTimingHeader(elapsedMs: Double, upstreamHeaders: [String: String]) -> String {
        let clamped = min(max(elapsedMs, 0), 60_000)
        var parts = [String(format: "raft_feedback_hands;dur=%.1f", clamped)]
        let raw = upstreamHeaders.first { $0.key.lowercased() == "server-timing" }?.value ?? ""
        var seen = Set<String>()
        for piece in raw.split(separator: ",") {
            let value = piece.trimmingCharacters(in: .whitespaces)
            guard let match = value.wholeMatch(of: /^([a-z_]+);dur=(\d+(?:\.\d+)?)$/),
                  feedbackTimingNames.contains(String(match.1)),
                  !seen.contains(String(match.1)),
                  let duration = Double(match.2), duration >= 0, duration <= 60_000
            else { continue }
            seen.insert(String(match.1))
            parts.append(String(format: "%@;dur=%.1f", String(match.1), duration))
        }
        return parts.joined(separator: ", ")
    }

    static func feedbackUpstreamError(_ raw: String?) -> String {
        guard var text = raw else { return "" }
        text = text.map { character in
            character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } ? " " : character
        }.reduce(into: "") { $0.append($1) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(256))
    }

    static func feedbackTrimmedBase(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func feedbackStringField(_ record: Any?, _ key: String) -> String? {
        guard let object = record as? [String: Any], let raw = object[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func feedbackAppsParameterName(_ environment: [String: String]) -> String? {
        guard let name = environment["HANDS_FEEDBACK_APPS_SSM_PARAMETER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name.range(of: "^/slock/[a-z]+/HANDS_FEEDBACK_APPS$", options: .regularExpression) != nil ? name : nil
    }

    static func feedbackLegacyRouteEnvironment(_ environment: [String: String]) -> FeedbackRouteEnvironment {
        FeedbackRouteEnvironment(
            baseURL: feedbackTrimmedBase(environment["HANDS_FEEDBACK_BASE_URL"]),
            appSlug: environment["HANDS_FEEDBACK_APP_SLUG"] ?? "",
            appId: environment["HANDS_FEEDBACK_APP_ID"] ?? "",
            clientKey: environment["HANDS_FEEDBACK_CLIENT_KEY"] ?? "",
            appToken: environment["HANDS_FEEDBACK_APP_TOKEN"] ?? "",
            conversationToken: environment["HANDS_FEEDBACK_CONVERSATION_APP_TOKEN"] ?? "",
            credentialRevision: environment["HANDS_FEEDBACK_CONVERSATION_CREDENTIAL_REVISION"] ?? "",
            reporterIntegrationId: environment["HANDS_FEEDBACK_REPORTER_INTEGRATION_ID"] ?? "",
            reporterIdSecret: environment["HANDS_FEEDBACK_REPORTER_ID_SECRET"] ?? "",
            routeSubjectKeyId: environment["HANDS_FEEDBACK_ROUTE_SUBJECT_KEY_ID"] ?? "v1",
            routeSubjectRoot: environment["HANDS_FEEDBACK_ROUTE_SUBJECT_ROOT"] ?? "",
            routeCommitmentScope: environment["HANDS_FEEDBACK_ROUTE_SUBJECT_COMMITMENT_SCOPE"] ?? "",
            cursorSecret: environment["HANDS_FEEDBACK_CURSOR_SECRET"] ?? "",
            conversationSessionEnabled: environment["HANDS_FEEDBACK_CONVERSATION_SESSION_ENABLED"] == "true",
            isMultiApp: false
        )
    }

    static func feedbackUnavailableReason(
        source: String,
        appsJSON: String?,
        environment: [String: String]
    ) -> String {
        if feedbackTrimmedBase(environment["HANDS_FEEDBACK_BASE_URL"]).isEmpty { return "base_url_missing" }
        guard let appsJSON else {
            return feedbackAppsParameterName(environment) == nil ? "apps_parameter_not_configured" : "apps_parameter_unread"
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(appsJSON.utf8)) else { return "apps_json_invalid" }
        guard let record = parsed as? [String: Any] else { return "apps_json_not_object" }
        guard let entry = record[source] else { return "source_entry_missing" }
        let entryFields = ["app_slug", "app_id", "reporter_integration_id", "credential_revision", "client_key", "token"]
        let missingEntry = entryFields.filter { feedbackStringField(entry, $0) == nil }
        if !missingEntry.isEmpty { return "source_fields_missing:" + missingEntry.joined(separator: ",") }
        let shared = record["shared"]
        let sharedFields = ["reporter_id_secret", "route_subject_root", "cursor_secret"]
        let missingShared = sharedFields.filter { feedbackStringField(shared, $0) == nil }
        if !missingShared.isEmpty { return "shared_fields_missing:" + missingShared.joined(separator: ",") }
        return "unknown"
    }

    static func feedbackMultiRouteEnvironment(
        source: String,
        appsJSON: String?,
        environment: [String: String]
    ) throws -> FeedbackRouteEnvironment {
        let base = feedbackTrimmedBase(environment["HANDS_FEEDBACK_BASE_URL"])
        let legacy = feedbackLegacyRouteEnvironment(environment)
        guard !base.isEmpty else {
            throw FeedbackRouteFailure.sourceUnavailable(source: source, reason: "base_url_missing")
        }
        func fallBackForWeb() throws -> FeedbackRouteEnvironment {
            if source == "web" { return legacy }
            throw FeedbackRouteFailure.sourceUnavailable(
                source: source,
                reason: feedbackUnavailableReason(source: source, appsJSON: appsJSON, environment: environment)
            )
        }
        guard let appsJSON else { return try fallBackForWeb() }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(appsJSON.utf8)) else {
            return try fallBackForWeb()
        }
        guard let record = parsed as? [String: Any] else { return try fallBackForWeb() }
        guard let entryObject = record[source] else { return try fallBackForWeb() }
        let entry = FeedbackSourceEntry(
            appSlug: feedbackStringField(entryObject, "app_slug") ?? "",
            appId: feedbackStringField(entryObject, "app_id") ?? "",
            reporterIntegrationId: feedbackStringField(entryObject, "reporter_integration_id") ?? "",
            credentialRevision: feedbackStringField(entryObject, "credential_revision") ?? "",
            clientKey: feedbackStringField(entryObject, "client_key") ?? "",
            token: feedbackStringField(entryObject, "token") ?? ""
        )
        let shared = record["shared"]
        let reporterIdSecret = feedbackStringField(shared, "reporter_id_secret") ?? ""
        let routeSubjectRoot = feedbackStringField(shared, "route_subject_root") ?? ""
        let cursorSecret = feedbackStringField(shared, "cursor_secret") ?? ""
        guard !entry.appSlug.isEmpty, !entry.appId.isEmpty, !entry.reporterIntegrationId.isEmpty,
              !entry.credentialRevision.isEmpty, !entry.clientKey.isEmpty, !entry.token.isEmpty,
              !reporterIdSecret.isEmpty, !routeSubjectRoot.isEmpty, !cursorSecret.isEmpty
        else {
            return try fallBackForWeb()
        }
        let appCursorKey = feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
            for: Data("feedback-cursor-app:\(entry.appId)".utf8),
            using: SymmetricKey(data: Data(cursorSecret.utf8))
        )))
        return FeedbackRouteEnvironment(
            baseURL: base,
            appSlug: entry.appSlug,
            appId: entry.appId,
            clientKey: entry.clientKey,
            appToken: entry.token,
            conversationToken: entry.token,
            credentialRevision: entry.credentialRevision,
            reporterIntegrationId: entry.reporterIntegrationId,
            reporterIdSecret: reporterIdSecret,
            routeSubjectKeyId: "v1",
            routeSubjectRoot: routeSubjectRoot,
            routeCommitmentScope: "multi",
            cursorSecret: appCursorKey,
            conversationSessionEnabled: environment["HANDS_FEEDBACK_CONVERSATION_SESSION_ENABLED"] == "true",
            isMultiApp: true
        )
    }

    static func feedbackSource(_ header: String) throws -> String {
        let normalized = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return "web" }
        guard productFeedbackSources.contains(normalized) else { throw FeedbackRouteFailure.invalidSource }
        return normalized
    }

    static func feedbackBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func feedbackReporterId(userId: String, secret: String) -> String {
        feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
            for: Data("raft-web-feedback:\(userId)".utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )))
    }

    static func feedbackRouteRootBytes(_ root: String) -> Data? {
        guard root.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { return nil }
        var padded = root.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded), data.count == 32,
              feedbackBase64URL(data) == root
        else { return nil }
        return data
    }

    static func feedbackCanonicalUUID(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil
    }

    static func feedbackRouteConfig(_ environment: FeedbackRouteEnvironment) throws -> FeedbackRouteConfig? {
        let rootValid = feedbackRouteRootBytes(environment.routeSubjectRoot) != nil
        let reporterIntegrationValid = feedbackCanonicalUUID(environment.reporterIntegrationId)
            || environment.reporterIntegrationId == "legacy-feedback:\(environment.appId)"
        let baseValid = !environment.baseURL.isEmpty
        let appValid = feedbackCanonicalUUID(environment.appId)
        let tokenValid = !environment.conversationToken.isEmpty
        let revisionValid = !environment.credentialRevision.isEmpty
        let secretValid = !environment.reporterIdSecret.isEmpty
        let keyValid = environment.routeSubjectKeyId == "v1"
        if !environment.isMultiApp {
            // Legacy deployments without the route-subject env keep working
            // without binding, exactly like the pre-multi-app port.
            guard baseValid, appValid, tokenValid, revisionValid, reporterIntegrationValid,
                  keyValid, rootValid, secretValid
            else { return nil }
        } else {
            guard baseValid, appValid, tokenValid, revisionValid, reporterIntegrationValid,
                  keyValid, secretValid
            else { throw FeedbackRouteFailure.routeBinding(reason: "config_invalid") }
            guard rootValid else { throw FeedbackRouteFailure.routeBinding(reason: "root_invalid") }
        }
        return FeedbackRouteConfig(
            baseURL: environment.baseURL,
            appId: environment.appId,
            appToken: environment.conversationToken,
            credentialRevision: environment.credentialRevision,
            reporterIntegrationId: environment.reporterIntegrationId,
            keyId: environment.routeSubjectKeyId,
            root: environment.routeSubjectRoot,
            commitmentLabel: environment.routeCommitmentScope == "multi"
                ? Self.productFeedbackMultiCommitmentLabel
                : Self.productFeedbackLegacyCommitmentLabel,
            reporterIdSecret: environment.reporterIdSecret
        )
    }

    static func feedbackRouteSubject(
        config: FeedbackRouteConfig,
        userId: String,
        reporterId: String
    ) -> String? {
        guard let root = feedbackRouteRootBytes(config.root) else { return nil }
        let coordinate = "v1\u{0}\(config.appId)\u{0}\(config.reporterIntegrationId)\u{0}\(reporterId)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("raft-feedback-route\u{0}\(coordinate)\u{0}\(userId)".utf8),
            using: SymmetricKey(data: root)
        )
        return "rfr_v1_" + feedbackBase64URL(Data(mac))
    }

    static func feedbackUserBinding(userId: String, cursorKey: String) -> String {
        feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
            for: Data("feedback-cursor-user:\(userId)".utf8),
            using: SymmetricKey(data: Data(cursorKey.utf8))
        )))
    }

    static func feedbackEncodeCursor(
        route: String,
        userId: String,
        ticketId: String?,
        handsCursor: String,
        cursorKey: String
    ) -> String? {
        guard !handsCursor.isEmpty, handsCursor.utf8.count <= 2048 else { return nil }
        let userBinding = feedbackUserBinding(userId: userId, cursorKey: cursorKey)
        let ticketJSON = ticketId.map { jsonString($0) } ?? "null"
        let payload = "{\"hands_cursor\":\(jsonString(handsCursor)),\"issued_at_ms\":\(Int(Date().timeIntervalSince1970 * 1000)),\"route\":\(jsonString(route)),\"ticket_id\":\(ticketJSON),\"user_binding\":\(jsonString(userBinding)),\"v\":1}"
        let payloadBytes = Data(payload.utf8)
        let mac = feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
            for: payloadBytes,
            using: SymmetricKey(data: Data(cursorKey.utf8))
        )))
        return feedbackBase64URL(payloadBytes) + "." + mac
    }

    static func feedbackDecodeCursor(
        _ token: String,
        route: String,
        userId: String,
        ticketId: String?,
        cursorKey: String
    ) throws -> String {
        func invalid() -> FeedbackRouteFailure { FeedbackRouteFailure.routeBinding(reason: "invalid_cursor") }
        guard !token.isEmpty, token.utf8.count <= 4096, !cursorKey.isEmpty else { throw invalid() }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw invalid() }
        func decodeSegment(_ segment: String) -> Data? {
            guard segment.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
            var padded = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while padded.count % 4 != 0 { padded += "=" }
            guard let data = Data(base64Encoded: padded), feedbackBase64URL(data) == segment else { return nil }
            return data
        }
        guard let payloadBytes = decodeSegment(String(parts[0])),
              let macBytes = decodeSegment(String(parts[1])),
              let object = (try? JSONSerialization.jsonObject(with: payloadBytes)) as? [String: Any]
        else { throw invalid() }
        let expectedMAC = Data(HMAC<SHA256>.authenticationCode(
            for: payloadBytes,
            using: SymmetricKey(data: Data(cursorKey.utf8))
        ))
        guard macBytes == expectedMAC,
              Set(object.keys) == ["hands_cursor", "issued_at_ms", "route", "ticket_id", "user_binding", "v"],
              object["v"] as? Int == 1,
              object["route"] as? String == route,
              (object["ticket_id"] as? String) == ticketId,
              object["user_binding"] as? String == feedbackUserBinding(userId: userId, cursorKey: cursorKey),
              let handsCursor = object["hands_cursor"] as? String, !handsCursor.isEmpty,
              handsCursor.utf8.count <= 2048,
              let issuedAt = (object["issued_at_ms"] as? NSNumber)?.doubleValue
        else { throw invalid() }
        let now = Date().timeIntervalSince1970 * 1000
        guard issuedAt <= now + 5 * 60 * 1000, now - issuedAt <= 24 * 60 * 60 * 1000 else { throw invalid() }
        return handsCursor
    }

    static func jsonWithHeaders(_ status: Int, _ body: String, headers: [String: String]) -> HTTPReply {
        var merged: [String: String] = [
            "Content-Type": AppFallback.jsonContentType,
            "Cache-Control": "no-store",
            "Content-Length": String(body.utf8.count),
        ]
        for (key, value) in headers { merged[key] = value }
        return HTTPReply(status: status, headers: merged, body: body)
    }

    static func feedbackPercentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        ) ?? value
    }

    static func validatedFeedbackDiagnostics(_ raw: String, appId: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              Set(object.keys).isSubset(of: ["r2_key", "filename", "content_type", "size"]),
              let r2Key = object["r2_key"] as? String,
              let filename = object["filename"] as? String, filename == "diagnostics.zip",
              let contentType = object["content_type"] as? String, contentType == "application/zip",
              let size = (object["size"] as? NSNumber)?.intValue, object["size"] is NSNumber,
              size > 0, size <= 200 * 1024 * 1024
        else { return nil }
        let escapedApp = NSRegularExpression.escapedPattern(for: appId)
        let pattern = "^feedback/\(escapedApp)/presigned/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[A-Za-z0-9._-]+\\.zip$"
        guard r2Key.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return serializeJSON(["r2_key": r2Key, "filename": filename, "content_type": contentType, "size": size])
    }

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

    static func parseDisplayLanguage(_ raw: Any) -> DisplayLanguage {
        if raw is NSNull { return .value(nil) }
        guard let string = raw as? String else {
            return .invalid("displayLanguage must be a string or null")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .value(nil) }
        guard let normalized = normalizeDisplayLocale(trimmed) else {
            return .invalid("displayLanguage must be a supported UI display locale")
        }
        return .value(normalized)
    }

    static func userJSON(_ account: Account) -> String {
        let hash = sha256(account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let language = account.displayLanguage.map { jsonString($0) } ?? "null"
        let provider = account.profileSetupProvider.map { jsonString($0) } ?? "null"
        let displayName = jsonString(account.displayName ?? account.name)
        let suggestedHandle = account.profileSetupSuggestedHandle.map { jsonString($0) } ?? "null"
        let completedAt: String
        if let completed = account.profileSetupCompletedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            completedAt = jsonString(formatter.string(from: completed))
        } else {
            completedAt = "null"
        }
        let avatar = account.avatarUrl.map { jsonString($0) } ?? "null"
        let share: String
        if let value = account.shareUsageData {
            share = value ? "true" : "false"
        } else {
            share = "null"
        }
        let preferredLanguage = account.preferredLanguage.map { jsonString($0) } ?? "null"
        let preferredTimezone = account.preferredTimezone.map { jsonString($0) } ?? "null"
        let preferredTimeFormat = account.preferredTimeFormat.map { jsonString($0) } ?? "null"
        let preferredFontSize = account.preferredMessageBodyFontSize.map { jsonString($0) } ?? "null"
        let referralSource = account.referralSource.map { jsonString($0) } ?? "null"
        let referralOther = account.referralSourceOther.map { jsonString($0) } ?? "null"
        let skippedAt: String
        if let date = account.referralSourceSkippedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            skippedAt = jsonString(formatter.string(from: date))
        } else {
            skippedAt = "null"
        }
        return "{\"id\":\(jsonString(account.id)),\"email\":\(jsonString(account.email)),\"name\":\(jsonString(account.name)),\"displayName\":\(displayName),\"gravatarHash\":\(jsonString(hash)),\"displayLanguage\":\(language),\"profileSetupCompletedAt\":\(completedAt),\"profileSetupSuggestedHandle\":\(suggestedHandle),\"profileSetupProvider\":\(provider),\"avatarUrl\":\(avatar),\"shareUsageData\":\(share),\"preferredLanguage\":\(preferredLanguage),\"preferredTimezone\":\(preferredTimezone),\"preferredTranslationMode\":\(jsonString(account.preferredTranslationMode)),\"autoTranslationEnabled\":\(account.autoTranslationEnabled),\"preferredTranslationDisplay\":\(jsonString(account.preferredTranslationDisplay)),\"preferredTimeFormat\":\(preferredTimeFormat),\"preferredMessageBodyFontSize\":\(preferredFontSize),\"referralSource\":\(referralSource),\"referralSourceOther\":\(referralOther),\"referralSourceSkippedAt\":\(skippedAt)}"
    }

    static func trimHyphens(_ value: String) -> String {
        var text = value
        while text.hasPrefix("-") { text.removeFirst() }
        while text.hasSuffix("-") { text.removeLast() }
        return text
    }

    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func multipartFile(named name: String, contentType: String?, body: Data) -> Data? {
        guard let boundary = boundaryParameter(contentType) else { return nil }
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

    static func isDesktopLoopback(_ returnUri: String) -> Bool {
        guard let url = URL(string: returnUri),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.path == "/auth/done",
              let port = url.port,
              (1024...65535).contains(port),
              let fragment = url.fragment,
              fragment.wholeMatch(of: /^state=[A-Za-z0-9_-]{16,256}$/) != nil
        else { return false }
        return url.absoluteString == returnUri || "\(url.absoluteString)" == returnUri
    }

    static func desktopNonce(from returnUri: String) -> String? {
        guard isDesktopLoopback(returnUri), let fragment = URL(string: returnUri)?.fragment else { return nil }
        return String(fragment.dropFirst("state=".count))
    }

    static func authorizationURL(provider: String, state: String) -> String {
        switch provider {
        case "github":
            var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "configured"),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/api/auth/github/callback"),
                URLQueryItem(name: "scope", value: "read:user user:email"),
                URLQueryItem(name: "state", value: state),
            ]
            return components.string ?? ""
        default:
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "configured"),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/api/auth/google/callback"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "openid email profile"),
                URLQueryItem(name: "state", value: state),
            ]
            return components.string ?? ""
        }
    }

    static func pkceS256(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func failureLocation(returnUri: String, provider: String, mode: String, error: String) -> String {
        let pieces = returnUri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let base = pieces[0]
        let hash = pieces.count > 1 ? "#\(pieces[1])" : ""
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)provider=\(provider)&mode=\(mode)&error=\(error)\(hash)"
    }

    static func loopbackLocation(returnUri: String, provider: String, mode: String, code: String) -> String {
        let pieces = returnUri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let base = pieces[0]
        let hash = pieces.count > 1 ? "#\(pieces[1])" : ""
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)provider=\(provider)&mode=\(mode)&code=\(code)\(hash)"
    }

    static func redirect(_ location: String, cookie: String? = nil) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Location": location,
            "Content-Length": "0",
        ]
        if let cookie { headers["Set-Cookie"] = cookie }
        return HTTPReply(status: 302, headers: headers, body: "")
    }

    static func isMobileUnsubscribeUserId(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.ignoresCase()) != nil
    }

    static func mobileAppUnsubscribeLocale(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if value == "zh-cn" || value == "zh" || value == "zh-hans" || value == "zh-hans-cn" { return "zh-cn" }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        return "en"
    }

    static func mobileAppUnsubscribeSignature(payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data("mobile-app-email-unsubscribe:v1:\(payload)".utf8)
        return base64url(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    static func mobileAppUnsubscribeCopy(_ locale: String) -> (htmlLang: String, confirmationTitle: String, confirmationHeading: String, confirmationBody: String, submit: String, successTitle: String, successHeading: String, successBody: String, invalidTitle: String, invalidHeading: String, invalidBody: String) {
        if locale == "zh-cn" {
            return (
                "zh-CN",
                "退订 Raft 移动端应用邮件",
                "要退订移动端应用邮件吗？",
                "Raft 将不再向你发送关于移动端应用的邮件。",
                "退订",
                "已退订",
                "你已退订。",
                "Raft 不会再向你发送移动端应用邮件。",
                "退订链接无效",
                "这个退订链接无效。",
                "请使用 Raft 原始邮件中的链接。"
            )
        }
        return (
            "en",
            "Unsubscribe from Raft mobile-app emails",
            "Unsubscribe from mobile-app emails?",
            "Raft will stop sending you emails about the mobile app.",
            "Unsubscribe",
            "Unsubscribed",
            "You are unsubscribed.",
            "Raft will no longer send you mobile-app emails.",
            "Invalid unsubscribe link",
            "This unsubscribe link is invalid.",
            "Please use the link from the original Raft email."
        )
    }

    static func mobileAppUnsubscribeInvalid() -> HTTPReply {
        let copy = mobileAppUnsubscribeCopy("en")
        let body = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.invalidHeading)</h1><p style=\"margin:0;line-height:1.5;\">\(copy.invalidBody)</p>"
        return mobileAppUnsubscribeHTML(status: 400, lang: copy.htmlLang, title: copy.invalidTitle, body: body)
    }

    static func mobileAppUnsubscribeHTML(status: Int = 200, lang: String, title: String, body: String) -> HTTPReply {
        let page = """
        <!doctype html>
        <html lang="\(lang)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
        </head>
        <body style="margin:0;padding:40px 20px;background:#fffaf0;color:#141111;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
          <main style="box-sizing:border-box;max-width:520px;margin:0 auto;padding:28px;background:#fff;border:2px solid #141111;border-radius:16px;box-shadow:4px 4px 0 #141111;">
            \(body)
          </main>
        </body>
        </html>
        """
        return HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
                "Content-Type": "text/html; charset=utf-8",
            ],
            body: page
        )
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

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    static func text(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    static func sealSuccessor(_ token: String) -> String {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-session-refresh-rotation-receipt".utf8))))
        if let sealed = try? AES.GCM.seal(Data(token.utf8), using: key) {
            return sealed.ciphertext.base64EncodedString()
        }
        return sha256("sealed:\(token)")
    }

    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func verifyNativeAppleRequestToken(_ token: String, secret: String) -> NativeAppleRequestToken {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return .invalid }
        guard header["alg"] as? String == "HS256" else { return .invalid }
        let key = SymmetricKey(data: Data(secret.utf8))
        let signing = Data("\(parts[0]).\(parts[1])".utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: signing, using: key))
        guard let given = base64urlDecode(parts[2]), given == expected else { return .invalid }
        guard let payloadData = base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              object["kind"] as? String == "native_apple_ios",
              let requestId = object["requestId"] as? String, !requestId.isEmpty,
              let mode = object["mode"] as? String, mode == "login" || mode == "link",
              let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil,
              (object["iss"] as? String) == "slock-native-apple-auth",
              (object["aud"] as? String) == "native-apple-auth-request"
        else { return .invalid }
        let tokenUserId: String?
        if object["userId"] == nil || object["userId"] is NSNull {
            tokenUserId = nil
        } else if let id = object["userId"] as? String, !id.isEmpty {
            tokenUserId = id
        } else {
            return .invalid
        }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return .expired }
        return .valid(NativeAppleRequestClaims(requestId: requestId, mode: mode, codeChallenge: challenge, userId: tokenUserId))
    }

    static func providerLabel(_ id: String) -> String {
        switch id {
        case "google": "Google"
        case "github": "GitHub"
        case "apple": "Apple"
        default: id
        }
    }

    static func sanitizeReturnTo(_ input: String?) -> String {
        guard let input, input.hasPrefix("/"), !input.hasPrefix("//"), !input.contains("\\"), !input.contains("://") else {
            return "/"
        }
        return input
    }

    static func returnToField(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["returnTo"] as? String
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

    static func socialCallbackURL(appURL: String, provider: String, mode: String, returnTo: String, error: String? = nil, code: String? = nil) -> String {
        let base = appURL.hasSuffix("/") ? String(appURL.dropLast()) : appURL
        var items = [
            URLQueryItem(name: "auth_callback", value: "social"),
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "returnTo", value: returnTo),
        ]
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        if let error { items.append(URLQueryItem(name: "error", value: error)) }
        var components = URLComponents(string: base) ?? URLComponents()
        components.queryItems = items
        return components.string ?? base
    }

    static func noContent() -> HTTPReply {
        HTTPReply(
            status: 204,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Length": "0",
            ],
            body: ""
        )
    }

    static func json(_ status: Int, _ body: String, cookie: String? = nil) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ]
        if let cookie { headers["Set-Cookie"] = cookie }
        return HTTPReply(status: status, headers: headers, body: body)
    }

}
