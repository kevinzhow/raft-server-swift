import Crypto
import Foundation

public enum AuthTokenCodec {
    public static func sha256Hex(_ value: String) -> String {
        AuthTokenCodec.sha256(value)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func refreshAttempt(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^arf_[0-9a-f]{16}$/) != nil else { return nil }
        return trimmed
    }

    static func refreshInstallation(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^ari_[0-9a-f]{32}$/) != nil else { return nil }
        return trimmed
    }

    public static func signSocialAuthState(_ state: SocialAuthState) -> String {
        let header = AuthTokenCodec.base64url(Data(OrderedJSON.object([OrderedJSONField("alg", "HS256"), OrderedJSONField("typ", "JWT")]).render().utf8))
        var payload = OrderedJSONObject([
            OrderedJSONField("provider", state.provider), OrderedJSONField("mode", state.mode),
            OrderedJSONField("nonce", state.nonce), OrderedJSONField("kind", state.kind),
            OrderedJSONField("mobileRequestId", state.mobileRequestId), OrderedJSONField("iss", "slock-social-auth"),
            OrderedJSONField("aud", "social-auth-state"), OrderedJSONField("exp", Int(Date().timeIntervalSince1970) + 600),
        ])
        payload.append("desktopNonce", ifPresent: state.desktopNonce)
        payload.append("returnTo", ifPresent: state.returnTo)
        payload.append("linkUserId", ifPresent: state.linkUserId)
        if state.linkOnConflict { payload.append("linkOnConflict", true) }
        let encoded = Data(payload.json.render().utf8)
        let body = AuthTokenCodec.base64url(encoded)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: stateKey))
        return "\(header).\(body).\(AuthTokenCodec.base64url(mac))"
    }

    public static func verifySocialAuthState(_ token: String) -> SocialAuthState? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3 else { return nil }
        let signing = Data("\(parts[0]).\(parts[1])".utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: signing, using: stateKey))
        guard let given = AuthTokenCodec.base64urlDecode(parts[2]), given == expected else { return nil }
        guard let payload = AuthTokenCodec.base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let provider = object["provider"] as? String,
              let mode = object["mode"] as? String,
              let nonce = object["nonce"] as? String,
              let kind = object["kind"] as? String,
              let requestId = object["mobileRequestId"] as? String,
              (object["iss"] as? String) == "slock-social-auth",
              (object["aud"] as? String) == "social-auth-state"
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        return SocialAuthState(
            provider: provider,
            mode: mode,
            nonce: nonce,
            kind: kind,
            mobileRequestId: requestId,
            desktopNonce: object["desktopNonce"] as? String,
            returnTo: object["returnTo"] as? String,
            linkUserId: object["linkUserId"] as? String,
            linkOnConflict: object["linkOnConflict"] as? Bool ?? false
        )
    }

    static let stateKey = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-social-auth-state".utf8))))

    public static func signNativeAppleRequestToken(secret: String, requestId: String, mode: String, codeChallenge: String, expiresAt: Date, userId: String? = nil) -> String {
        let header = AuthTokenCodec.base64url(Data(OrderedJSON.object([OrderedJSONField("alg", "HS256"), OrderedJSONField("typ", "JWT")]).render().utf8))
        var payload = OrderedJSONObject([
            OrderedJSONField("kind", "native_apple_ios"), OrderedJSONField("requestId", requestId),
            OrderedJSONField("mode", mode), OrderedJSONField("codeChallenge", codeChallenge),
            OrderedJSONField("iss", "slock-native-apple-auth"), OrderedJSONField("aud", "native-apple-auth-request"),
            OrderedJSONField("exp", Int(expiresAt.timeIntervalSince1970)),
        ])
        payload.append("userId", ifPresent: userId)
        let encoded = Data(payload.json.render().utf8)
        let body = AuthTokenCodec.base64url(encoded)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: key))
        return "\(header).\(body).\(AuthTokenCodec.base64url(mac))"
    }

    static func parseAppleIdentity(_ token: String, clientId: String) -> AppleIdentityClaims? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = AuthTokenCodec.base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let payloadData = AuthTokenCodec.base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              object["iss"] as? String == "https://appleid.apple.com",
              object["aud"] as? String == clientId,
              let subject = object["sub"] as? String, !subject.isEmpty,
              let nonce = object["nonce"] as? String, !nonce.isEmpty
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        let rawEmail = (object["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if rawEmail.isEmpty {
            return AppleIdentityClaims(subject: subject, nonce: nonce, email: nil)
        }
        let verified: Bool
        if let flag = object["email_verified"] as? Bool {
            verified = flag
        } else if let flag = object["email_verified"] as? String {
            verified = flag == "true"
        } else {
            verified = false
        }
        guard verified else { return nil }
        return AppleIdentityClaims(subject: subject, nonce: nonce, email: rawEmail)
    }

    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ value: String) -> String {
        AuthTokenCodec.sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    static func sealSuccessor(_ token: String) -> String {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-session-refresh-rotation-receipt".utf8))))
        if let sealed = try? AES.GCM.seal(Data(token.utf8), using: key) {
            return sealed.ciphertext.base64EncodedString()
        }
        return AuthTokenCodec.sha256("sealed:\(token)")
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
              let headerData = AuthTokenCodec.base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return .invalid }
        guard header["alg"] as? String == "HS256" else { return .invalid }
        let key = SymmetricKey(data: Data(secret.utf8))
        let signing = Data("\(parts[0]).\(parts[1])".utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: signing, using: key))
        guard let given = AuthTokenCodec.base64urlDecode(parts[2]), given == expected else { return .invalid }
        guard let payloadData = AuthTokenCodec.base64urlDecode(parts[1]),
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

    static func pkceS256(_ verifier: String) -> String {
        AuthTokenCodec.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func deviceSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dvc_\(encoded)"
    }

    public static let agentCredentialUseDefaultThrottleMs = 60_000
}
