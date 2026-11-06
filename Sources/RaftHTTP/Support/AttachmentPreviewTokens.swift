import Crypto
import Foundation

/// The signed `token` query value of `GET /api/attachments/:id/html-preview`.
///
/// The payload is a fixed, sorted-key JSON object signed with
/// `HMAC<SHA256>` over the base64url payload text; the token is
/// `payload.signature`. Verification re-reads the published fields instead of
/// handing back an untyped object, so the two routes that consume it
/// (`html-preview` and `html-preview-url`) get a typed value.
///
/// The secret stays the legacy `JWT_SECRET` environment value with the
/// in-process test fallback.
public struct AttachmentPreviewTokens: Sendable {
    /// The verified payload of a preview token.
    public struct Payload: Sendable, Equatable {
        public var attachmentId: String
        public var serverId: String
        public var actorId: String?
        public var expiresAt: Int

        public init(attachmentId: String, serverId: String, actorId: String?, expiresAt: Int) {
            self.attachmentId = attachmentId
            self.serverId = serverId
            self.actorId = actorId
            self.expiresAt = expiresAt
        }
    }

    public static let audience = "attachment-html-preview"
    public static let type = "attachment-html-preview"

    public init() {}

    public func mint(
        attachmentId: String,
        serverId: String,
        actorId: String,
        audience: String = AttachmentPreviewTokens.audience,
        type: String = AttachmentPreviewTokens.type,
        expiresIn: Int = 300,
        now: Date = Date()
    ) -> String {
        // Legacy wrote the object with `JSONSerialization` and `.sortedKeys`:
        // attachmentId, actorId, aud, audience, exp, serverId, type.
        let expiry = Int(now.timeIntervalSince1970) + expiresIn
        let payload = "{"
            + "\"attachmentId\":\(jsonString(attachmentId))"
            + ",\"actorId\":\(jsonString(actorId))"
            + ",\"aud\":\(jsonString(audience))"
            + ",\"audience\":\(jsonString(audience))"
            + ",\"exp\":\(expiry)"
            + ",\"serverId\":\(jsonString(serverId))"
            + ",\"type\":\(jsonString(type))"
            + "}"
        let payloadPart = EmailLoginDirectory.previewBase64URL(Data(payload.utf8))
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(payloadPart.utf8),
            using: secret()
        )
        return payloadPart + "." + EmailLoginDirectory.previewBase64URL(Data(signature))
    }

    /// The verified payload, or `nil` for a malformed, mis-signed, mis-scoped
    /// or expired token.
    public func verify(
        _ token: String,
        attachmentId: String,
        serverId: String,
        now: Date = Date()
    ) -> Payload? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let payloadPart: String
        let signaturePart: String
        let signedPart: String
        if parts.count == 3 {
            payloadPart = parts[1]
            signaturePart = parts[2]
            signedPart = parts[0] + "." + parts[1]
        } else if parts.count == 2 {
            payloadPart = parts[0]
            signaturePart = parts[1]
            signedPart = parts[0]
        } else {
            return nil
        }
        guard let signature = EmailLoginDirectory.previewBase64URLDecode(signaturePart),
              let payloadData = EmailLoginDirectory.previewBase64URLDecode(payloadPart),
              HMAC<SHA256>.isValidAuthenticationCode(
                  signature,
                  authenticating: Data(signedPart.utf8),
                  using: secret()
              ),
              let wire = try? JSONDecoder().decode(WirePayload.self, from: payloadData)
        else { return nil }
        let wireAudience = wire.audience ?? wire.aud
        guard wireAudience == Self.audience,
              wire.type == Self.type,
              wire.attachmentId == attachmentId,
              wire.serverId == serverId,
              let expiry = wire.exp,
              expiry > Int(now.timeIntervalSince1970)
        else { return nil }
        return Payload(
            attachmentId: attachmentId,
            serverId: serverId,
            actorId: wire.actorId,
            expiresAt: expiry
        )
    }

    private func secret() -> SymmetricKey {
        let raw = ProcessInfo.processInfo.environment["JWT_SECRET"] ?? "raft-test-preview-secret"
        return SymmetricKey(data: Data(raw.utf8))
    }

    /// The published payload shape. Every field is optional so a value of the
    /// wrong JSON type reads as absent, exactly like the legacy per-key `as?`
    /// cast.
    private struct WirePayload: Decodable {
        var attachmentId: String?
        var serverId: String?
        var actorId: String?
        var audience: String?
        var aud: String?
        var type: String?
        var exp: Int?

        private enum CodingKeys: String, CodingKey {
            case attachmentId
            case serverId
            case actorId
            case audience
            case aud
            case type
            case exp
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            attachmentId = Self.string(container, .attachmentId)
            serverId = Self.string(container, .serverId)
            actorId = Self.string(container, .actorId)
            audience = Self.string(container, .audience)
            aud = Self.string(container, .aud)
            type = Self.string(container, .type)
            exp = (try? container.decodeIfPresent(Int.self, forKey: .exp)) ?? nil
        }

        private static func string(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> String? {
            guard container.contains(key),
                  (try? container.decodeNil(forKey: key)) == false
            else { return nil }
            guard let value = try? container.decode(String.self, forKey: key) else { return nil }
            return value
        }
    }
}
