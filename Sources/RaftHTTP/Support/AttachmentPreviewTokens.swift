import Foundation
import JWTKit

public enum AttachmentPreviewTokenError: Error, Sendable { case unavailable }

/// One shared issuer/verifier for Node's preview-only HS256 capability. Root
/// composition supplies the existing raw JWT key; no fallback key is generated.
public struct AttachmentPreviewTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum ActorType: String, Codable, Sendable { case user, machine }

    /// Only successful cryptographic verification can construct this proof.
    public struct Payload: Sendable, Equatable {
        public let attachmentId: String
        public let serverId: String
        public let actorType: ActorType
        public let actorId: String
        public let expiresAt: Int

        fileprivate init(attachmentId: String, serverId: String, actorType: ActorType, actorId: String, expiresAt: Int) {
            self.attachmentId = attachmentId
            self.serverId = serverId
            self.actorType = actorType
            self.actorId = actorId
            self.expiresAt = expiresAt
        }

        /// A pure recheck after object I/O. The HTTP layer cannot construct or
        /// alter a proof to bypass the original SDK verification.
        public func isValid(attachmentId: String, serverId: String, now: Date = Date()) -> Bool {
            self.attachmentId == attachmentId && self.serverId == serverId && !actorId.isEmpty
                && Double(expiresAt) > now.timeIntervalSince1970
        }
    }

    public static let audience = "attachment-html-preview"
    public static let type = "attachment-html-preview"
    public static let issuer = "slock-server"
    private let secret: String

    public init(secret: String) { self.secret = secret }
    public var description: String { "AttachmentPreviewTokens(redacted)" }
    public var debugDescription: String { description }

    public func mint(
        attachmentId: String, serverId: String, actorId: String, actorType: ActorType = .user,
        audience: String = Self.audience, type: String = Self.type,
        expiresIn: Int = 300, now: Date = Date()
    ) async throws -> String {
        do {
            let expiration = floor(now.timeIntervalSince1970) + Double(expiresIn)
            guard expiration.isFinite, expiration >= 0, expiration < Double(Int.max) else {
                throw AttachmentPreviewTokenError.unavailable
            }
            let payload = WirePayload(iss: .init(value: Self.issuer), aud: .init(value: [audience]),
                sub: .init(value: actorId), iat: .init(value: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))),
                exp: .init(value: Date(timeIntervalSince1970: expiration)),
                type: type, attachmentId: attachmentId, serverId: serverId, actorType: actorType, actorId: actorId)
            return try await keys().sign(payload)
        } catch { throw AttachmentPreviewTokenError.unavailable }
    }

    public func verify(
        _ token: String, attachmentId: String, serverId: String, now: Date = Date()
    ) async -> Payload? {
        guard let proof = await verifyForFlex(token, attachmentId: attachmentId, now: now),
              proof.isValid(attachmentId: attachmentId, serverId: serverId, now: now) else { return nil }
        return proof
    }

    /// Flex learns server scope only from a fully verified signed claim. Every
    /// consumer uses the same SDK verifier and closed set of accepted claims.
    public func verifyForFlex(_ token: String, attachmentId: String, now: Date = Date()) async -> Payload? {
        do {
            guard token.utf8.count <= 16_384 else { return nil }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            let header = try DefaultJWTParser().parse(Data(token.utf8), as: WirePayload.self).header
            guard header.alg == "HS256", header.kid == nil else { return nil }
            let wire = try await keys().verify(token, as: WirePayload.self)
            let expiration = wire.exp.value.timeIntervalSince1970
            guard expiration.isFinite, expiration >= 0, expiration < Double(Int.max),
                  wire.attachmentId == attachmentId, !wire.serverId.isEmpty else { return nil }
            let proof = Payload(attachmentId: wire.attachmentId, serverId: wire.serverId,
                actorType: wire.actorType, actorId: wire.actorId, expiresAt: Int(expiration))
            guard proof.isValid(attachmentId: attachmentId, serverId: wire.serverId, now: now) else { return nil }
            return proof
        } catch { return nil }
    }

    private func keys() async throws -> JWTKeyCollection {
        // JWTKit's HMAC signer asserts on undersized keys. Validate before SDK
        // construction and retain Node's exact raw key, without hashing it.
        guard secret.utf8.count >= 32 else { throw AttachmentPreviewTokenError.unavailable }
        return await JWTKeyCollection().add(hmac: HMACKey(from: secret), digestAlgorithm: .sha256)
    }

    private struct WirePayload: JWTPayload {
        let iss: IssuerClaim
        let aud: AudienceClaim
        let sub: SubjectClaim
        let iat: IssuedAtClaim?
        let exp: ExpirationClaim
        let type: String
        let attachmentId: String
        let serverId: String
        let actorType: ActorType
        let actorId: String

        func verify(using algorithm: some JWTAlgorithm) throws {
            guard algorithm.name == "HS256", iss.value == AttachmentPreviewTokens.issuer,
                  type == AttachmentPreviewTokens.type, !actorId.isEmpty, sub.value == actorId,
                  !attachmentId.isEmpty, !serverId.isEmpty else { throw InvalidClaims.invalid }
            try aud.verifyIntendedAudience(includes: AttachmentPreviewTokens.audience)
            // Expiry uses the caller's injectable clock after SDK verification;
            // no proof escapes verification before that explicit comparison.
        }
    }
    private enum InvalidClaims: Error { case invalid }
}
