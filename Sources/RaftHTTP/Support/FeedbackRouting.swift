import Crypto
import Foundation

public enum FeedbackRouting {
    static func feedbackUnavailableReason(
        source: String,
        appsJSON: String?,
        environment: [String: String]
    ) -> String {
        if FeedbackRouting.feedbackTrimmedBase(environment["HANDS_FEEDBACK_BASE_URL"]).isEmpty { return "base_url_missing" }
        guard let appsJSON else {
            return FeedbackRouting.feedbackAppsParameterName(environment) == nil ? "apps_parameter_not_configured" : "apps_parameter_unread"
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(appsJSON.utf8)) else { return "apps_json_invalid" }
        guard let record = parsed as? [String: Any] else { return "apps_json_not_object" }
        guard let entry = record[source] else { return "source_entry_missing" }
        let entryFields = ["app_slug", "app_id", "reporter_integration_id", "credential_revision", "client_key", "token"]
        let missingEntry = entryFields.filter { FeedbackRouting.feedbackStringField(entry, $0) == nil }
        if !missingEntry.isEmpty { return "source_fields_missing:" + missingEntry.joined(separator: ",") }
        let shared = record["shared"]
        let sharedFields = ["reporter_id_secret", "route_subject_root", "cursor_secret"]
        let missingShared = sharedFields.filter { FeedbackRouting.feedbackStringField(shared, $0) == nil }
        if !missingShared.isEmpty { return "shared_fields_missing:" + missingShared.joined(separator: ",") }
        return "unknown"
    }

    static func feedbackMultiRouteEnvironment(
        source: String,
        appsJSON: String?,
        environment: [String: String]
    ) throws -> FeedbackRouteEnvironment {
        let base = FeedbackRouting.feedbackTrimmedBase(environment["HANDS_FEEDBACK_BASE_URL"])
        let legacy = FeedbackRouting.feedbackLegacyRouteEnvironment(environment)
        guard !base.isEmpty else {
            throw FeedbackRouteFailure.sourceUnavailable(source: source, reason: "base_url_missing")
        }
        func fallBackForWeb() throws -> FeedbackRouteEnvironment {
            if source == "web" { return legacy }
            throw FeedbackRouteFailure.sourceUnavailable(
                source: source,
                reason: FeedbackRouting.feedbackUnavailableReason(source: source, appsJSON: appsJSON, environment: environment)
            )
        }
        guard let appsJSON else { return try fallBackForWeb() }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(appsJSON.utf8)) else {
            return try fallBackForWeb()
        }
        guard let record = parsed as? [String: Any] else { return try fallBackForWeb() }
        guard let entryObject = record[source] else { return try fallBackForWeb() }
        let entry = FeedbackSourceEntry(
            appSlug: FeedbackRouting.feedbackStringField(entryObject, "app_slug") ?? "",
            appId: FeedbackRouting.feedbackStringField(entryObject, "app_id") ?? "",
            reporterIntegrationId: FeedbackRouting.feedbackStringField(entryObject, "reporter_integration_id") ?? "",
            credentialRevision: FeedbackRouting.feedbackStringField(entryObject, "credential_revision") ?? "",
            clientKey: FeedbackRouting.feedbackStringField(entryObject, "client_key") ?? "",
            token: FeedbackRouting.feedbackStringField(entryObject, "token") ?? ""
        )
        let shared = record["shared"]
        let reporterIdSecret = FeedbackRouting.feedbackStringField(shared, "reporter_id_secret") ?? ""
        let routeSubjectRoot = FeedbackRouting.feedbackStringField(shared, "route_subject_root") ?? ""
        let cursorSecret = FeedbackRouting.feedbackStringField(shared, "cursor_secret") ?? ""
        guard !entry.appSlug.isEmpty, !entry.appId.isEmpty, !entry.reporterIntegrationId.isEmpty,
              !entry.credentialRevision.isEmpty, !entry.clientKey.isEmpty, !entry.token.isEmpty,
              !reporterIdSecret.isEmpty, !routeSubjectRoot.isEmpty, !cursorSecret.isEmpty
        else {
            return try fallBackForWeb()
        }
        let appCursorKey = FeedbackRouting.feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
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
        guard FeedbackService.productFeedbackSources.contains(normalized) else { throw FeedbackRouteFailure.invalidSource }
        return normalized
    }

    static func feedbackBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func feedbackReporterId(userId: String, secret: String) -> String {
        FeedbackRouting.feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
            for: Data("raft-web-feedback:\(userId)".utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )))
    }

    static func feedbackRouteRootBytes(_ root: String) -> Data? {
        guard root.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { return nil }
        var padded = root.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded), data.count == 32,
              FeedbackRouting.feedbackBase64URL(data) == root
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
        let rootValid = FeedbackRouting.feedbackRouteRootBytes(environment.routeSubjectRoot) != nil
        let reporterIntegrationValid = FeedbackRouting.feedbackCanonicalUUID(environment.reporterIntegrationId)
            || environment.reporterIntegrationId == "legacy-feedback:\(environment.appId)"
        let baseValid = !environment.baseURL.isEmpty
        let appValid = FeedbackRouting.feedbackCanonicalUUID(environment.appId)
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
                ? FeedbackService.productFeedbackMultiCommitmentLabel
                : FeedbackService.productFeedbackLegacyCommitmentLabel,
            reporterIdSecret: environment.reporterIdSecret
        )
    }

    static func feedbackRouteSubject(
        config: FeedbackRouteConfig,
        userId: String,
        reporterId: String
    ) -> String? {
        guard let root = FeedbackRouting.feedbackRouteRootBytes(config.root) else { return nil }
        let coordinate = "v1\u{0}\(config.appId)\u{0}\(config.reporterIntegrationId)\u{0}\(reporterId)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("raft-feedback-route\u{0}\(coordinate)\u{0}\(userId)".utf8),
            using: SymmetricKey(data: root)
        )
        return "rfr_v1_" + FeedbackRouting.feedbackBase64URL(Data(mac))
    }

    static func feedbackUserBinding(userId: String, cursorKey: String) -> String {
        FeedbackRouting.feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
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
        let userBinding = FeedbackRouting.feedbackUserBinding(userId: userId, cursorKey: cursorKey)
        let payload = OrderedJSON.object([
            OrderedJSONField("hands_cursor", handsCursor),
            OrderedJSONField("issued_at_ms", Int(Date().timeIntervalSince1970 * 1000)),
            OrderedJSONField("route", route), OrderedJSONField("ticket_id", optional: ticketId),
            OrderedJSONField("user_binding", userBinding), OrderedJSONField("v", 1),
        ]).render()
        let payloadBytes = Data(payload.utf8)
        let mac = FeedbackRouting.feedbackBase64URL(Data(HMAC<SHA256>.authenticationCode(
            for: payloadBytes,
            using: SymmetricKey(data: Data(cursorKey.utf8))
        )))
        return FeedbackRouting.feedbackBase64URL(payloadBytes) + "." + mac
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
            guard let data = Data(base64Encoded: padded), FeedbackRouting.feedbackBase64URL(data) == segment else { return nil }
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
              object["user_binding"] as? String == FeedbackRouting.feedbackUserBinding(userId: userId, cursorKey: cursorKey),
              let handsCursor = object["hands_cursor"] as? String, !handsCursor.isEmpty,
              handsCursor.utf8.count <= 2048,
              let issuedAt = (object["issued_at_ms"] as? NSNumber)?.doubleValue
        else { throw invalid() }
        let now = Date().timeIntervalSince1970 * 1000
        guard issuedAt <= now + 5 * 60 * 1000, now - issuedAt <= 24 * 60 * 60 * 1000 else { throw invalid() }
        return handsCursor
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
        return LegacySortedJSON.render(.object([
            "r2_key": .string(r2Key), "filename": .string(filename),
            "content_type": .string(contentType), "size": .integer(Int64(size)),
        ]))
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
            baseURL: FeedbackRouting.feedbackTrimmedBase(environment["HANDS_FEEDBACK_BASE_URL"]),
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
