import Crypto
import Foundation

/// The translation half of the server-profile service: the per-server
/// settings routes and the member batch translator. The provider is the
/// injected override, the `TRANSLATION_PROVIDER` environment value, or none.
extension ServerProfileAndOrderService {

    // MARK: - Provider

    /// The configured provider name: the test-injected override first, then
    /// `TRANSLATION_PROVIDER`, else the empty string.
    func translationProviderName() -> String {
        dependencies.messages.translationProviderOverride
            ?? (dependencies.environment()["TRANSLATION_PROVIDER"] ?? "")
    }

    /// Whether the configured provider has every credential it needs. An
    /// injected override counts as available.
    func translationProviderAvailable() -> Bool {
        if dependencies.messages.translationProviderOverride != nil { return true }
        let environment = dependencies.environment()
        switch translationProviderName() {
        case "fake":
            return true
        case "volcengine":
            let id = environment["TRANSLATION_VOLCENGINE_ACCESS_KEY_ID"] ?? ""
            let secret = environment["TRANSLATION_VOLCENGINE_SECRET_ACCESS_KEY"] ?? ""
            return !id.isEmpty && !secret.isEmpty
        case "google":
            let project = environment["TRANSLATION_GOOGLE_PROJECT_ID"] ?? ""
            let token = environment["TRANSLATION_GOOGLE_ACCESS_TOKEN"] ?? ""
            return !project.isEmpty && !token.isEmpty
        case "openai-compatible":
            let apiKey = environment["TRANSLATION_OPENAI_COMPATIBLE_API_KEY"] ?? ""
            let model = environment["TRANSLATION_OPENAI_COMPATIBLE_MODEL"] ?? ""
            return !apiKey.isEmpty && !model.isEmpty
        default:
            return false
        }
    }

    // MARK: - Settings

    /// `GET /api/servers/:id/translation-settings`.
    public func serverTranslationSettings(
        authorization: String?,
        serverId: String
    ) throws -> ServerTranslationSettingsResponse {
        let userId = try requireUser(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        return ServerTranslationSettingsResponse(
            translationEnabled: dependencies.oauth.serverProfile(id: serverId)?.translationEnabled ?? false,
            translationAvailable: translationProviderAvailable(),
            canManageTranslation: role == "owner" || role == "admin"
        )
    }

    /// `PATCH /api/servers/:id/translation-settings`.
    public func patchServerTranslationSettings(
        authorization: String?,
        serverId: String,
        body: ServerTranslationSettingsPatchRequest?
    ) throws -> ServerTranslationSettingsResponse {
        let userId = try requireUser(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            throw ServerProfileAndOrderError.translationSettingsForbidden
        }
        guard let enabled = body?.translationEnabled else {
            throw ServerProfileAndOrderError.translationEnabledNotBoolean
        }
        dependencies.oauth.setServerTranslationEnabled(id: serverId, enabled: enabled)
        return ServerTranslationSettingsResponse(
            translationEnabled: enabled,
            translationAvailable: translationProviderAvailable(),
            canManageTranslation: true
        )
    }

    // MARK: - POST /api/message-translations:batch

    /// Translates up to 200 messages for a member. Each id resolves to one of
    /// `not_found`, `skipped` (with its reason) or `translated`; a skipped
    /// same-language message and a translated message record their outcome in
    /// the translation ledger.
    public func batchTranslateMessages(
        authorization: String?,
        serverId: String,
        body: MessageTranslationBatchRequest?
    ) throws -> MessageTranslationBatchResponse {
        let userId = try requireUser(authorization)
        _ = try requireRole(serverId: serverId, userId: userId)
        let oauth = dependencies.oauth
        guard oauth.serverProfile(id: serverId)?.translationEnabled == true else {
            throw ServerProfileAndOrderError.translationDisabled
        }
        guard let body,
              let targetLanguage = body.targetLanguage,
              let target = PublicTranslations.normalizeLanguage(targetLanguage),
              let mode = body.mode, mode == "auto" || mode == "manual",
              let ids = body.messageIds
        else {
            throw ServerProfileAndOrderError.invalidTranslationRequest
        }
        guard ids.count <= 200 else {
            throw ServerProfileAndOrderError.invalidTranslationRequest
        }
        let provider = translationProviderName()
        guard translationProviderAvailable() else {
            throw ServerProfileAndOrderError.translationProviderNotConfigured
        }
        if provider == "openai-compatible", oauth.serverProfile(id: serverId)?.plan != "pro" {
            throw ServerProfileAndOrderError.llmTranslationUnavailable
        }
        let providerVersion = provider == "fake" ? "fake@v0+fake-v0" : "\(provider)@v0"
        var results: [MessageTranslationResultDTO] = []
        for id in ids {
            guard let message = oauth.messageTranslationMetadata(id: id) else {
                results.append(.notFound(messageId: id, targetLanguage: target))
                continue
            }
            let resolvedChannelId: String? = {
                if let channel = oauth.channelInfo(id: message.channelId), channel.serverId == serverId {
                    return message.channelId
                }
                return dependencies.channels.activeJointLocalChannelId(
                    canonicalChannelId: message.channelId,
                    serverId: serverId
                )
            }()
            guard let resolvedChannelId,
                  let channel = oauth.channelInfo(id: resolvedChannelId),
                  channel.serverId == serverId,
                  oauth.channelType(id: resolvedChannelId) == "channel"
                      || oauth.isChannelParticipant(channelId: resolvedChannelId, userId: userId)
            else {
                results.append(.notFound(messageId: id, targetLanguage: target))
                continue
            }
            let source = Self.detectTranslationLanguage(message.content)
            var skipReason: String?
            if message.senderId == userId, mode == "auto" {
                skipReason = "own_message"
            } else if message.messageType == "system" || message.senderId == "system" {
                skipReason = "system_message"
            } else if Self.translationCodeOrLinkOnly(message.content) {
                skipReason = "code_or_link_only"
            } else if source.confidence < 50 {
                skipReason = "low_confidence"
            } else if source.language == target {
                skipReason = "same_language"
            }
            if let skipReason {
                if skipReason == "same_language" {
                    dependencies.messages.recordMessageTranslation(
                        messageId: id,
                        status: "skipped",
                        providerBilledChars: 0,
                        targetLanguage: target,
                        translatedContent: ""
                    )
                }
                results.append(.skipped(
                    messageId: id,
                    skipReason: skipReason,
                    sourceLanguage: source.language,
                    targetLanguage: target
                ))
                continue
            }
            let translated = "[\(target)] \(message.content)"
            dependencies.messages.recordMessageTranslation(
                messageId: id,
                status: "translated",
                providerBilledChars: message.content.count,
                targetLanguage: target,
                translatedContent: translated
            )
            results.append(.translated(
                messageId: id,
                contentHash: Self.sha256Hex(Data(message.content.utf8)),
                sourceLanguage: source.language,
                sourceConfidence: source.confidence,
                targetLanguage: target,
                translatedContent: translated,
                provider: provider,
                providerVersion: providerVersion
            ))
        }
        return MessageTranslationBatchResponse(results: results)
    }

    // MARK: - Detection helpers

    private static func detectTranslationLanguage(_ content: String) -> (language: String, confidence: Int) {
        let hasCJK = content.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
        }
        if hasCJK { return ("zh", 95) }
        let hasLetter = content.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        return hasLetter ? ("en", 99) : ("en", 20)
    }

    private static func translationCodeOrLinkOnly(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") && trimmed.count >= 6 { return true }
        let linkOnly = trimmed.split(whereSeparator: { $0.isWhitespace }).allSatisfy { token in
            token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://")
        }
        return !trimmed.isEmpty && linkOnly
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
