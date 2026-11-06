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

}
