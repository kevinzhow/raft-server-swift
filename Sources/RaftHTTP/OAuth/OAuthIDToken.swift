import Crypto
import Foundation

struct OAuthIdentity: Sendable {
    var sub: String
    var clientId: String
    var scopes: [String]
    var name: String
    var email: String
    var serverId: String
    var serverSlug: String
    var serverRole: String
}

enum OAuthIDToken {
    static func signAgentAudience(
        agentId: String,
        agentName: String,
        clientKey: String,
        serverId: String,
        serverSlug: String,
        issuer: String,
        secret: String,
        ttl: Int = 300
    ) -> (token: String, jti: String, issuedAt: Int)? {
        guard !secret.isEmpty, let privateKey = signingKey(secret: secret) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let jti = UUID().uuidString.lowercased()
        let kidValue = kid(secret: secret) ?? ""
        let login = "raft-agent-\(agentId)"
        let header = OrderedJSON.object([
            OrderedJSONField("alg", "ES256"),
            OrderedJSONField("typ", "at+jwt"),
            OrderedJSONField("kid", kidValue),
        ]).render()
        let payload = OrderedJSON.object([
            OrderedJSONField("iss", issuer),
            OrderedJSONField("aud", clientKey),
            OrderedJSONField("sub", agentId),
            OrderedJSONField("server_id", serverId),
            OrderedJSONField("server_slug", serverSlug),
            OrderedJSONField("type", "agent"),
            OrderedJSONField("token_use", "agent_access"),
            OrderedJSONField("login", login),
            OrderedJSONField("preferred_username", agentName),
            OrderedJSONField("iat", now),
            OrderedJSONField("nbf", now),
            OrderedJSONField("exp", now + ttl),
            OrderedJSONField("jti", jti),
        ]).render()
        let signingInput = "\(base64url(Data(header.utf8))).\(base64url(Data(payload.utf8)))"
        guard let signature = try? privateKey.signature(for: Data(signingInput.utf8)) else { return nil }
        return ("\(signingInput).\(base64url(signature.rawRepresentation))", jti, now)
    }

    static func kid(secret: String) -> String? {
        guard let key = signingKey(secret: secret) else { return nil }
        return base64url(Data(SHA256.hash(data: key.publicKey.x963Representation).prefix(16)))
    }

    static func sign(
        identity: OAuthIdentity,
        issuer: String,
        expiresIn: Int,
        secret: String,
        nonce: String? = nil
    ) -> String? {
        guard !secret.isEmpty, let privateKey = signingKey(secret: secret) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        var payload = OrderedJSONObject()
        payload.append("iss", issuer)
        payload.append("sub", identity.sub)
        payload.append("aud", identity.clientId)
        payload.append("iat", now)
        payload.append("exp", now + expiresIn)
        if let nonce, !nonce.isEmpty {
            payload.append("nonce", nonce)
        }
        if identity.scopes.contains("profile"), !identity.name.isEmpty {
            payload.append("name", identity.name)
            payload.append("preferred_username", identity.name)
        }
        if identity.scopes.contains("email"), !identity.email.isEmpty {
            payload.append("email", identity.email)
            payload.append("email_verified", true)
        }
        payload.append("type", "human")
        payload.append("server_id", identity.serverId)
        payload.append("server_slug", identity.serverSlug)
        payload.append("server_role", identity.serverRole)
        let publicBytes = privateKey.publicKey.x963Representation
        let kid = base64url(Data(SHA256.hash(data: publicBytes).prefix(16)))
        let header = OrderedJSON.object([
            OrderedJSONField("alg", "ES256"),
            OrderedJSONField("typ", "JWT"),
            OrderedJSONField("kid", kid),
        ]).render()
        let signingInput = "\(base64url(Data(header.utf8))).\(base64url(Data(payload.json.render().utf8)))"
        guard let signature = try? privateKey.signature(for: Data(signingInput.utf8)) else { return nil }
        return "\(signingInput).\(base64url(signature.rawRepresentation))"
    }

    static func verificationKey(secret: String) -> OAuthVerificationKeyFacts? {
        guard !secret.isEmpty, let key = signingKey(secret: secret) else { return nil }
        let publicBytes = key.publicKey.x963Representation
        guard publicBytes.count == 65, publicBytes.first == 0x04 else { return nil }
        let x = base64url(Data(publicBytes[1..<33]))
        let y = base64url(Data(publicBytes[33..<65]))
        let kid = base64url(Data(SHA256.hash(data: publicBytes).prefix(16)))
        return OAuthVerificationKeyFacts(kid: kid, x: x, y: y)
    }

    private static func signingKey(secret: String) -> P256.Signing.PrivateKey? {
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data("raft-oidc-v1".utf8),
            info: Data("id-token-es256-private".utf8),
            outputByteCount: 32
        )
        let seedBytes: [UInt8] = seed.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt8.self))
        }
        let scalar = p256Scalar(seedBytes)
        return try? P256.Signing.PrivateKey(rawRepresentation: scalar)
    }

    /// `(seed mod (n-1)) + 1`, matching the Node P-256 reduction.
    private static func p256Scalar(_ seed: [UInt8]) -> Data {
        let modulus = hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")
        var reduced = seed
        if compare(reduced, modulus) >= 0 {
            reduced = subtract(reduced, modulus)
        }
        return Data(addOne(reduced))
    }

    private static func hex(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    private static func compare(_ left: [UInt8], _ right: [UInt8]) -> Int {
        for (lhs, rhs) in zip(left, right) where lhs != rhs {
            return lhs < rhs ? -1 : 1
        }
        return 0
    }

    private static func subtract(_ value: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
        var result = value
        var borrow = 0
        for index in stride(from: result.count - 1, through: 0, by: -1) {
            let diff = Int(result[index]) - Int(modulus[index]) - borrow
            if diff < 0 {
                result[index] = UInt8(diff + 256)
                borrow = 1
            } else {
                result[index] = UInt8(diff)
                borrow = 0
            }
        }
        return result
    }

    private static func addOne(_ value: [UInt8]) -> [UInt8] {
        var result = value
        var carry = 1
        for index in stride(from: result.count - 1, through: 0, by: -1) {
            let sum = Int(result[index]) + carry
            result[index] = UInt8(sum & 0xff)
            carry = sum >> 8
            if carry == 0 { break }
        }
        return result
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
