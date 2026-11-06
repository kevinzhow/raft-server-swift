import Crypto
import Foundation

/// The pure credential codec of the native notification surface: opaque
/// `prefix.id.secret` tokens, canonical base64url, the signed transcripts and
/// the Ed25519 proof check. No state, no HTTP.
public enum NativeNotificationCredentials {
    static var uuidPattern: Regex<Substring> { /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/ }

    /// The bytes an Ed25519 enrollment proof signs. The secret stays out of the stored row.
    public static func enrollmentProofTranscript(grant: String, appId: String, protocolVersion: Int, appVersion: String, releaseChannel: String, appInstanceId: String, publicKey: String, nonce: String) -> Data {
        let joined = [
            "raft-desktop-notification-enrollment-v1",
            EmailLoginDirectory.sha256(grant),
            appId,
            String(protocolVersion),
            appVersion,
            releaseChannel,
            appInstanceId,
            publicKey,
            nonce,
        ].joined(separator: "\u{0}")
        return Data(joined.utf8)
    }

    /// The bytes an Ed25519 rotation proof signs.
    public static func rotationProofTranscript(credential: String, deviceId: String) -> Data {
        let joined = ["raft-desktop-notification-rotation-v1", EmailLoginDirectory.sha256(credential), deviceId].joined(separator: "\u{0}")
        return Data(joined.utf8)
    }

    static func parseOpaque(_ value: String, prefix: String) -> (id: String, secret: String)? {
        guard value.count <= 160 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix,
              parts[1].wholeMatch(of: uuidPattern) != nil,
              canonicalBase64URL(parts[2], minBytes: 32, maxBytes: 32) != nil
        else { return nil }
        return (parts[1], parts[2])
    }

    /// The bearer token of `Authorization: Bearer …`, or `nil`.
    static func bearer(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    static func canonicalBase64URL(_ value: String, minBytes: Int, maxBytes: Int) -> Data? {
        guard value.wholeMatch(of: /^[A-Za-z0-9_-]+$/) != nil,
              let bytes = EmailLoginDirectory.base64urlDecode(value),
              (minBytes...maxBytes).contains(bytes.count),
              EmailLoginDirectory.base64url(bytes) == value
        else { return nil }
        return bytes
    }

    static func mint(prefix: String, id: String) -> (opaque: String, secretHash: String) {
        var bytes = Data(count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let secret = EmailLoginDirectory.base64url(bytes)
        return ("\(prefix).\(id).\(secret)", EmailLoginDirectory.sha256(secret))
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
}
