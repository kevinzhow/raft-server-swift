import Foundation

/// `POST /api/public/servers/:slug/message-translations:batch`.
///
/// The IP budget is separate from public attachment reads. Invalid bodies are
/// refused before any lookup, so an empty request is a 400 until the budget
/// is spent.

public enum PublicTranslations {
    public static func tooMany() -> PublicTranslationError { .tooMany }

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
    ) throws -> PublicTranslationResponse {
        guard let request = parse(body) else {
            throw PublicTranslationError.invalidRequest
        }
        guard let gate,
              gate.publiclyVisible,
              gate.publicEnabled,
              gate.translationEnabled,
              gate.providerConfigured
        else {
            throw PublicTranslationError.notFound
        }
        if gate.llmUnavailable {
            throw PublicTranslationError.unavailable
        }
        let rows = translator?(request.messageIds, request.targetLanguage) ?? request.messageIds.map { id in
            ["messageId": id, "status": "not_found", "targetLanguage": request.targetLanguage]
        }
        return PublicTranslationResponse(results: rows)
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

}
