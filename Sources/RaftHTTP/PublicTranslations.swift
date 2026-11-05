import Foundation

/// `POST /api/public/servers/:slug/message-translations:batch`.
///
/// The IP budget is separate from public attachment reads. Invalid bodies are
/// refused before any lookup, so an empty request is a 400 until the budget
/// is spent.

public enum PublicTranslations {
    public static func tooMany() -> HTTPReply {
        let body = "{\"error\":\"Too many public translation requests, please slow down\"}"
        return json(429, body)
    }

    public struct Gate: Sendable {
        public var publiclyVisible: Bool
        public var publicEnabled: Bool
        public var translationEnabled: Bool
        public var providerConfigured: Bool
        public var llmUnavailable: Bool

        public init(
            publiclyVisible: Bool,
            publicEnabled: Bool,
            translationEnabled: Bool,
            providerConfigured: Bool,
            llmUnavailable: Bool
        ) {
            self.publiclyVisible = publiclyVisible
            self.publicEnabled = publicEnabled
            self.translationEnabled = translationEnabled
            self.providerConfigured = providerConfigured
            self.llmUnavailable = llmUnavailable
        }
    }

    public static func reply(
        body: String,
        gate: Gate?,
        translator: (([String], String) -> [[String: String]])? = nil
    ) -> HTTPReply {
        guard let request = parse(body) else {
            return json(400, "{\"error\":\"Invalid public translation request\"}")
        }
        guard let gate,
              gate.publiclyVisible,
              gate.publicEnabled,
              gate.translationEnabled,
              gate.providerConfigured
        else {
            return PublicVisits.pageReply(found: false, mode: nil)
        }
        if gate.llmUnavailable {
            return json(403, "{\"error\":\"LLM translation is not available for this server\"}")
        }
        let rows = translator?(request.messageIds, request.targetLanguage) ?? request.messageIds.map { id in
            ["messageId": id, "status": "not_found", "targetLanguage": request.targetLanguage]
        }
        let leadingKeys = ["messageId", "status", "targetLanguage"]
        let results = rows.map { row -> String in
            var parts: [String] = []
            for key in leadingKeys {
                if let value = row[key] { parts.append("\(jsonString(key)):\(jsonString(value))") }
            }
            for key in row.keys.sorted() where !leadingKeys.contains(key) {
                if let value = row[key] { parts.append("\(jsonString(key)):\(jsonString(value))") }
            }
            return "{\(parts.joined(separator: ","))}"
        }.joined(separator: ",")
        return json(200, "{\"results\":[\(results)]}")
    }

    private struct Request {
        var targetLanguage: String
        var mode: String
        var messageIds: [String]
    }

    private static func parse(_ body: String) -> Request? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let language = object["targetLanguage"] as? String,
              !language.isEmpty,
              let normalized = normalizeLanguage(language),
              let mode = object["mode"] as? String,
              mode == "auto" || mode == "manual",
              let rawIds = object["messageIds"] as? [Any]
        else { return nil }
        let messageIds = rawIds.compactMap { value -> String? in
            guard let string = value as? String, ServerScope.isUUID(string) else { return nil }
            return string
        }
        guard messageIds.count <= 200 else { return nil }
        return Request(targetLanguage: normalized, mode: mode, messageIds: messageIds)
    }

    static func detectSourceLanguage(_ content: String) -> String {
        let hasCJK = content.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
        }
        return hasCJK ? "zh" : "en"
    }

    static func normalizeLanguage(_ language: String) -> String? {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return nil }
        let aliases = ["zh": "zh-cn", "zh-hans": "zh-cn", "zh-hant": "zh-tw"]
        if let alias = aliases[normalized] { return alias }
        let supported: Set<String> = ["en", "zh-cn", "zh-tw", "ja", "ko", "es", "fr", "de", "pt-br", "it"]
        if supported.contains(normalized) { return normalized }
        let base = String(normalized.split(separator: "-").first ?? "")
        if supported.contains(base) { return base }
        return nil
    }

    private static func json(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "no-store",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }
}
