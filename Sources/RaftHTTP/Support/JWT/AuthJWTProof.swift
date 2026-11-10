import Crypto
import Foundation
import JWTKit

/// A configured root key is separated by purpose with Crypto's HKDF. This value
/// is request-local: no global mutable signer, environment read or proof cache.
enum JWTProofRole: String {
    case social = "raft/social-auth-state/v1"
    case nativeApple = "raft/native-apple-request/v1"
}

enum JWTProofError: DomainError, Sendable {
    case unavailable
    var status: UInt { 503 }
    var errorMessage: String { "Sign-in temporarily unavailable" }
}

private enum JWTClaimFailure: Error { case invalid }

private struct SocialStatePayload: JWTPayload {
    let provider: String
    let mode: String
    let nonce: String
    let kind: String
    let mobileRequestId: String
    let desktopNonce: String?
    let returnTo: String?
    let linkUserId: String?
    let linkOnConflict: Bool?
    let iss: IssuerClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim

    init(_ state: SocialAuthState) {
        provider = state.provider; mode = state.mode; nonce = state.nonce; kind = state.kind
        mobileRequestId = state.mobileRequestId; desktopNonce = state.desktopNonce
        returnTo = state.returnTo; linkUserId = state.linkUserId
        linkOnConflict = state.linkOnConflict ? true : nil
        iss = "slock-social-auth"; aud = "social-auth-state"
        exp = .init(value: Date().addingTimeInterval(600))
    }

    func verify(using algorithm: some JWTAlgorithm) throws {
        guard algorithm.name == "HS256", iss.value == "slock-social-auth",
              !provider.isEmpty, !nonce.isEmpty, mode == "login" || mode == "link",
              kind == "web" || kind == "mobile" else { throw JWTClaimFailure.invalid }
        try aud.verifyIntendedAudience(includes: "social-auth-state")
        try exp.verifyNotExpired()
    }

    var state: SocialAuthState {
        SocialAuthState(provider: provider, mode: mode, nonce: nonce, kind: kind,
            mobileRequestId: mobileRequestId, desktopNonce: desktopNonce,
            returnTo: returnTo, linkUserId: linkUserId, linkOnConflict: linkOnConflict ?? false)
    }
}

private struct NativeRequestPayload: JWTPayload {
    let kind: String
    let requestId: String
    let mode: String
    let codeChallenge: String
    let userId: String?
    let iss: IssuerClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim

    func verify(using algorithm: some JWTAlgorithm) throws {
        guard algorithm.name == "HS256", kind == "native_apple_ios",
              iss.value == "slock-native-apple-auth", !requestId.isEmpty,
              mode == "login" || mode == "link",
              codeChallenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil,
              userId == nil || userId?.isEmpty == false else { throw JWTClaimFailure.invalid }
        try aud.verifyIntendedAudience(includes: "native-apple-auth-request")
        // Expiration is checked with ExpirationClaim after signature and all
        // other claims, so only authentic expired requests get the Node 410.
    }
}

extension AuthTokenCodec {
    private static func jwtKeys(secret: String, role: JWTProofRole) async throws -> JWTKeyCollection {
        guard secret.utf8.count >= 32 else { throw JWTProofError.unavailable }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data(), info: Data(role.rawValue.utf8), outputByteCount: 32)
        return await JWTKeyCollection().add(hmac: HMACKey(key: derived), digestAlgorithm: .sha256)
    }

    private static func checkJWTHeader<P: JWTPayload>(_ token: String, as: P.Type, algorithm: String) throws -> JWTHeader {
        guard token.utf8.count <= 16_384 else { throw JWTClaimFailure.invalid }
        let header = try DefaultJWTParser().parse(Data(token.utf8), as: P.self).header
        guard header.alg == algorithm else { throw JWTClaimFailure.invalid }
        return header
    }

    public static func signSocialAuthState(_ state: SocialAuthState, secret: String) async throws -> String {
        do {
            let keys = try await jwtKeys(secret: secret, role: .social)
            return try await keys.sign(SocialStatePayload(state))
        } catch { throw JWTProofError.unavailable }
    }

    public static func verifySocialAuthState(_ token: String, secret: String) async -> SocialAuthState? {
        do {
            let header = try checkJWTHeader(token, as: SocialStatePayload.self, algorithm: "HS256")
            guard header.kid == nil else { return nil }
            let keys = try await jwtKeys(secret: secret, role: .social)
            return try await keys.verify(token, as: SocialStatePayload.self).state
        } catch { return nil }
    }

    public static func signNativeAppleRequestToken(secret: String, requestId: String, mode: String,
        codeChallenge: String, expiresAt: Date, userId: String? = nil) async throws -> String {
        do {
            let keys = try await jwtKeys(secret: secret, role: .nativeApple)
            let payload = NativeRequestPayload(kind: "native_apple_ios", requestId: requestId, mode: mode,
                codeChallenge: codeChallenge, userId: userId, iss: "slock-native-apple-auth",
                aud: "native-apple-auth-request", exp: .init(value: expiresAt))
            return try await keys.sign(payload)
        } catch { throw JWTProofError.unavailable }
    }

    static func verifyNativeAppleRequestToken(_ token: String, secret: String) async -> NativeAppleRequestToken {
        do {
            let header = try checkJWTHeader(token, as: NativeRequestPayload.self, algorithm: "HS256")
            guard header.kid == nil else { return .invalid }
            let keys = try await jwtKeys(secret: secret, role: .nativeApple)
            let payload = try await keys.verify(token, as: NativeRequestPayload.self)
            do { try payload.exp.verifyNotExpired() } catch { return .expired }
            return .valid(NativeAppleRequestClaims(requestId: payload.requestId, mode: payload.mode,
                codeChallenge: payload.codeChallenge, userId: payload.userId))
        } catch { return .invalid }
    }

    /// Only boot/operator-provided public keys are authoritative. Embedded keys,
    /// certificate URLs and unconfigured trust never supply a signing authority.
    static func verifyAppleIdentity(_ token: String, clientId: String, trustedJWKS: String?) async -> AppleIdentityClaims? {
        do {
            guard !clientId.isEmpty, let trustedJWKS, trustedJWKS.utf8.count <= 65_536 else { return nil }
            let header = try checkJWTHeader(token, as: AppleIdentityToken.self, algorithm: "RS256")
            guard let kid = header.kid, !kid.isEmpty else { return nil }
            let set = try JSONDecoder().decode(JWKS.self, from: Data(trustedJWKS.utf8))
            guard set.keys.count <= 16 else { return nil }
            let matching = set.keys.filter { $0.keyIdentifier?.string == kid }
            guard matching.count == 1, let key = matching.first, key.keyType == .rsa, key.algorithm == .rs256,
                  key.privateExponent == nil, key.prime1 == nil, key.prime2 == nil,
                  let modulus = key.modulus, modulus.utf8.count <= 1_400,
                  let exponent = key.exponent, exponent.utf8.count <= 16 else { return nil }
            let rsa = try Insecure.RSA.PublicKey(modulus: modulus, exponent: exponent)
            let keys = await JWTKeyCollection().add(rsa: rsa, digestAlgorithm: .sha256, kid: .init(string: kid))
            let proof = try await keys.verify(token, as: AppleIdentityToken.self, expectedAudience: clientId)
            guard !proof.subject.value.isEmpty, let nonce = proof.nonce, !nonce.isEmpty else { return nil }
            let email = proof.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !email.isEmpty, proof.emailVerified?.value != true { return nil }
            return AppleIdentityClaims(subject: proof.subject.value, nonce: nonce, email: email.isEmpty ? nil : email)
        } catch { return nil }
    }
}
