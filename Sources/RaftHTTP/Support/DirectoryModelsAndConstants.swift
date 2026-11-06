import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoreFoundation



// Extracted static helpers from EmailLogin.swift (behavior unchanged).



extension EmailLoginDirectory {
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

    /// The `user` object, rendered from the one ordered description in
    /// `AuthUserDTO` for the domains that still embed it in their own bodies.
    static func userJSON(_ account: Account) -> String {
        AuthUserDTO(account: account).jsonBody.render()
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

// MARK: - Moved model types

public struct RefreshRotationReceipt: Equatable, Sendable {
    public var attemptId: String
    public var installationId: String
    public var successorTokenCiphertext: String

    public init(attemptId: String, installationId: String, successorTokenCiphertext: String) {
        self.attemptId = attemptId
        self.installationId = installationId
        self.successorTokenCiphertext = successorTokenCiphertext
    }
}

public struct NativeAppleCodeExchange: Equatable, Sendable {
    public var code: String
    public var clientId: String
    public var clientSecret: String
    public var grantType: String
    public var redirectUri: String?

    public init(code: String, clientId: String, clientSecret: String, grantType: String, redirectUri: String?) {
        self.code = code
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.grantType = grantType
        self.redirectUri = redirectUri
    }
}

public struct MobileProviderProfile: Equatable, Sendable {
    public var providerUserId: String
    public var email: String
    public var displayName: String?
    /// Apple rejects a link when this is false. Google and GitHub profiles are already verified.
    public var emailVerified: Bool

    public init(providerUserId: String, email: String, displayName: String?, emailVerified: Bool = true) {
        self.providerUserId = providerUserId
        self.email = email
        self.displayName = displayName
        self.emailVerified = emailVerified
    }
}

public struct SocialAuthState: Equatable, Sendable {
    public var provider: String
    public var mode: String
    public var nonce: String
    public var kind: String
    public var mobileRequestId: String
    public var desktopNonce: String?
    public var returnTo: String?
    public var linkUserId: String?
    public var linkOnConflict: Bool = false

    public init(provider: String, mode: String, nonce: String, kind: String, mobileRequestId: String, desktopNonce: String?, returnTo: String? = nil, linkUserId: String? = nil, linkOnConflict: Bool = false) {
        self.provider = provider
        self.mode = mode
        self.nonce = nonce
        self.kind = kind
        self.mobileRequestId = mobileRequestId
        self.desktopNonce = desktopNonce
        self.returnTo = returnTo
        self.linkUserId = linkUserId
        self.linkOnConflict = linkOnConflict
    }
}

public struct EmailLegalAcceptance: Equatable, Sendable {
    public var termsVersion: String
    public var privacyVersion: String
    public var termsUrl: String
    public var privacyUrl: String
    public var source: String
    public var userAgentHash: String?
    public var locale: String?

    public init(
        termsVersion: String,
        privacyVersion: String,
        termsUrl: String,
        privacyUrl: String,
        source: String,
        userAgentHash: String?,
        locale: String?
    ) {
        self.termsVersion = termsVersion
        self.privacyVersion = privacyVersion
        self.termsUrl = termsUrl
        self.privacyUrl = privacyUrl
        self.source = source
        self.userAgentHash = userAgentHash
        self.locale = locale
    }
}

public struct RecordedProductEvent: Sendable {
    public var subjectType: String
    public var subjectId: String
    public var eventType: String
    public var actorType: String
    public var actorId: String
    public var source: String
    public var idempotencyKey: String?
    public var metadataJSON: String
}

public struct ClientEventRecord: Sendable {
    public var event: String
    public var analyticsId: String
    public var serverId: String
    public var source: String
    public var sessionId: String
    public var appVersion: String?
    public var propertiesJSON: String
}

// MARK: - Moved nested types and constants

extension EmailLoginDirectory {
    // MARK: Types

    public struct MobileAppEmailContact: Equatable, Sendable {
        public var userId: String
        public var email: String
        public var audienceId: String
        public var status: String
        public var optedOutAt: Date?
    }

    public struct NativeNotificationIntent: Sendable {
        public var recipientUserId: String
        public var eventKey: String
        public var serverId: String
        public var kind: String
        public var channelId: String
        public var threadId: String?
        public var parentChannelId: String?
        public var parentMessageId: String?
        public var messageId: String
        public var title: String
        public var body: String
        public var createdAt: Date

        public init(recipientUserId: String, eventKey: String, serverId: String, kind: String, channelId: String, threadId: String?, parentChannelId: String?, parentMessageId: String?, messageId: String, title: String, body: String, createdAt: Date) {
            self.recipientUserId = recipientUserId
            self.eventKey = eventKey
            self.serverId = serverId
            self.kind = kind
            self.channelId = channelId
            self.threadId = threadId
            self.parentChannelId = parentChannelId
            self.parentMessageId = parentMessageId
            self.messageId = messageId
            self.title = title
            self.body = body
            self.createdAt = createdAt
        }
    }

    public struct NativeEnrollmentGrantRecord: Sendable {
        public var secretHash: String
        public var json: String
    }

    public enum NativeStreamOpen: Sendable {
        case closed(HTTPReply)
        case streaming(userId: String, cursorSeq: Int, replay: [(seq: Int, frame: String)])
    }

    public struct MobileAppEmailJourney: Equatable, Sendable {
        public var userId: String
        public var email: String
        public var journeyKey: String
        public var day1Status: String
        public var day1EmailId: String?
        public var suppressedReason: String?
        public var canceledAt: Date?
    }

    public struct ForwardedSource: Equatable, Sendable {
        public var sourceServerId: String
        public var sourceTargetId: String
        public var sourceMessageId: String
        public var snapshotId: String
        public var snapshotType: String
        public var snapshotLabel: String
        public var snapshotLabelVisibility: String
        public var provenanceState: String

        public init(sourceServerId: String, sourceTargetId: String, sourceMessageId: String, snapshotId: String, snapshotType: String, snapshotLabel: String, snapshotLabelVisibility: String, provenanceState: String) {
            self.sourceServerId = sourceServerId
            self.sourceTargetId = sourceTargetId
            self.sourceMessageId = sourceMessageId
            self.snapshotId = snapshotId
            self.snapshotType = snapshotType
            self.snapshotLabel = snapshotLabel
            self.snapshotLabelVisibility = snapshotLabelVisibility
            self.provenanceState = provenanceState
        }
    }

    public struct MentionFact: Equatable, Sendable {
        public var targetType: String
        public var targetId: String
        public var notifiableAtSend: Bool
        public var notified: Bool
    }

    public struct InboxFact: Equatable, Sendable {
        public var receiverType: String
        public var receiverId: String
        public var personalMention: Bool = false
        public var unreadEligible: Bool = true

        public init(receiverType: String, receiverId: String, personalMention: Bool = false, unreadEligible: Bool = true) {
            self.receiverType = receiverType
            self.receiverId = receiverId
            self.personalMention = personalMention
            self.unreadEligible = unreadEligible
        }
    }

    public struct MentionActionRecord: Equatable, Sendable {
        public var notified: Bool
        public var notifiedByType: String?
        public var notifiedById: String?
        public var notifiedAction: String?
    }

    public struct ChannelMessageEvent: Equatable, Sendable {
        public var room: String
        public var name: String
        public var messageId: String
        public var attachmentIds: [String]
    }

    public struct TimezoneObservation: Sendable {
        public var firstTimezone: String
        public var firstAt: Date
        public var lastTimezone: String
        public var lastAt: Date
    }

    // MARK: Statics

    public static let termsVersion = "2026-05-12"

    public static let privacyVersion = "2026-05-12"

    public static let termsURL = "https://raft.build/terms"

    public static let privacyURL = "https://raft.build/privacy"

    static let doneFrontierInt4Limit = 2_147_483_647

    static let selfCausedFreshnessExemptSubtypes: Set<String> = ["task.created_summary"]

    /// `GET /internal/agent-api/events`. Durable channel messages for the
    /// external agent plus pending third-party events; the call drains both.
    /// At most this many channel rows per conversation in one pull. The pull
    /// advances each conversation's cursor, and `has_more` says whether
    /// another call has anything left.
    static let agentInboxPullCap = 5

    static let appLoginReturnUris: Set<String> = [
        "raft://login/callback",
        "raft-debug://login/callback",
    ]

    static let socialProviders: Set<String> = ["google", "github", "apple"]

    static let defaultMobileReturnURIs: Set<String> = [
        "raft://oauth/callback",
        "raft-alpha://oauth/callback",
        "raft-beta://oauth/callback",
        "raft-debug://oauth/callback",
        "raft-dev://oauth/callback",
    ]

    static let missingAuthorization = json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")

    static let invalidToken = json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")

    static let linkAuthRequired = json(401, "{\"code\":\"auth_required\",\"error\":\"Authentication is required to link an account\"}")

    static let linkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Social auth link does not match the authenticated user\"}")

    static let legalObject = "{\"termsVersion\":\"\(termsVersion)\",\"privacyVersion\":\"\(privacyVersion)\",\"termsUrl\":\"\(termsURL)\",\"privacyUrl\":\"\(privacyURL)\"}"

    static let legalRequired = json(422, "{\"error\":\"LEGAL_ACCEPTANCE_REQUIRED\",\"legal\":\(legalObject)}")

    static let termsChanged = json(409, "{\"error\":\"TERMS_CHANGED\",\"legal\":\(legalObject)}")

    static let deprecatedAgentRuntimes: Set<String> = ["kimi", "gemini", "antigravity", "copilot"]

    /// Terminal migration failure codes a Computer may report over
    /// `transport-lost`; anything else collapses to the generic reason.
    static let migrationTerminalFailureCodes: Set<String> = [
        "MIGRATION_TRANSPORT_LOST",
        "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE",
        "MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE",
        "MIGRATION_OBJECT_STORE_INSUFFICIENT_DISK",
        "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED",
        "MIGRATION_WORKSPACE_ALREADY_EXISTS",
        "MIGRATION_WORKSPACE_COMPLETE_OLD_COPY",
        "MIGRATION_CHUNK_DIGEST_MISMATCH",
        "MIGRATION_WHOLE_BUNDLE_DIGEST_MISMATCH",
        "MIGRATION_LEASE_EXPIRED",
        "MIGRATION_GENERATION_STALE",
        "MIGRATION_CONTROL_MANIFEST_INVALID",
        "MIGRATION_CONTROL_MANIFEST_TOO_LARGE",
    ]

    static let migrationSourceArchiveMaxAttempts = 12

    static let migrationSourceArchiveMovedCodes: Set<String> = [
        "MIGRATION_WORKSPACE_ARCHIVE_AGENT_RUNNING",
        "MIGRATION_WORKSPACE_ARCHIVE_NEWER_OWNER",
    ]

    /// A `starting` row is observed, not re-dispatched, inside this window.
    static let migrationAutoStartLease: TimeInterval = 30



    static let machineAPIKeyPrefix = "sk_machine_"

    static let computerAPIKeyPrefix = "sk_computer_"

    static let computerAPIKeyPrefixLength = 16

    public static let sharePNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()

    static let timezoneAliases: [String: String] = [
        "US/Pacific": "America/Los_Angeles",
        "US/Eastern": "America/New_York",
        "US/Central": "America/Chicago",
        "US/Mountain": "America/Denver",
        "US/Alaska": "America/Anchorage",
        "US/Hawaii": "Pacific/Honolulu",
    ]

    static let scopeAttestationMaxChars = 16 * 1024

    static let validTaskStatuses: Set<String> = ["todo", "in_progress", "in_review", "done", "cancelled"]

    static let labDefinitions: [(key: String, name: String, description: String, state: String)] = [
        ("open_lab", "Open Lab", "Available", "open"),
        ("paused_lab", "Paused Lab", "Paused", "paused"),
        ("draft_lab", "Draft Lab", "Hidden", "draft"),
        ("retired_lab", "Retired Lab", "Historical", "retired"),
    ]

    /// Raft's own default for hosted agents; naming it always follows the provider default.
    static let hostedDefaultModel = "deepseek-flash"

    /// Production throttle for credential-use writes.
    public static let agentCredentialUseDefaultThrottleMs = 60_000

    // MARK: Computed

    public var experimentalSurfacesDisabled: Bool {
        lock.lock()
        let override = experimentalSurfacesDisabledOverride
        lock.unlock()
        if let override { return override }
        return (ProcessInfo.processInfo.environment["SLOCK_EXPERIMENTAL_SURFACES_DISABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }

    public var wakeStreamHeartbeatMs: Int? {
        lock.lock()
        let override = wakeStreamHeartbeatOverrideMs
        lock.unlock()
        if let override { return override }
        return ProcessInfo.processInfo.environment["SLOCK_WAKE_STREAM_HEARTBEAT_MS"].flatMap(Int.init)
    }
}
