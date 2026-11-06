import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoreFoundation



// Extracted static helpers from EmailLogin.swift (behavior unchanged).



extension EmailLoginDirectory {
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

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    static func feedbackTimingHeader(elapsedMs: Double, upstreamHeaders: [String: String]) -> String {
        let clamped = min(max(elapsedMs, 0), 60_000)
        var parts = [String(format: "raft_feedback_hands;dur=%.1f", clamped)]
        let raw = upstreamHeaders.first { $0.key.lowercased() == "server-timing" }?.value ?? ""
        var seen = Set<String>()
        for piece in raw.split(separator: ",") {
            let value = piece.trimmingCharacters(in: .whitespaces)
            guard let match = value.wholeMatch(of: /^([a-z_]+);dur=(\d+(?:\.\d+)?)$/),
                  FeedbackService.feedbackTimingNames.contains(String(match.1)),
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

}
