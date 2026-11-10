import Foundation
import JWTKit
@testable import RaftHTTP

/// Provider setup and mobile-request facts over the scene's private profile owner.
public struct AuthMobileFixture: Sendable {
    private let profiles: AuthProfileStore

    init(profiles: AuthProfileStore) {
        self.profiles = profiles
    }

    public func setMobileProviderProfile(_ profile: MobileProviderProfile) {
        profiles.state.withLock { $0.configSurface.mobileProviderProfile = profile }
    }

    public func setWebProviderProfile(_ profile: MobileProviderProfile) {
        profiles.state.withLock { $0.configSurface.webProviderProfile = profile }
    }

    public func allowAppleLogin(on platforms: [String]) {
        profiles.state.withLock { owned in
            owned.accountSurface.appleLoginPlatforms.formUnion(platforms)
        }
    }

    public var mobileOAuthRequestCount: Int {
        profiles.state.withLock { $0.accountSurface.mobileRequests.count }
    }

    public func expireMobileOAuthRequest(id: String) {
        profiles.state.withLock { owned in
            owned.accountSurface.mobileRequests[id]?.expiresAt = Date(timeIntervalSinceNow: -1)
        }
    }

    public func oauthRequestStatus(id: String) -> String? {
        profiles.accountState.mobileRequests[id]?.status
    }

    public func oauthRequestReturnUri(id: String) -> String? {
        profiles.accountState.mobileRequests[id]?.returnUri
    }

    public func oauthRequestCodeHash(id: String) -> String? {
        profiles.accountState.mobileRequests[id]?.codeHash
    }

    public func oauthRequestCodeChallenge(id: String) -> String? {
        profiles.accountState.mobileRequests[id]?.codeChallenge
    }

    public func setNativeAppleCodeResponses(
        _ responses: [String: @Sendable () async -> String], clientId: String, clientSecret: String
    ) {
        let trustedJWKS = try! AuthAppleJWTFixture().jwksJSON
        profiles.state.withLock { owned in
            owned.configSurface.oauthDeployment.nativeAppleTrustedJWKS = trustedJWKS
            owned.configSurface.exchangeNativeAppleCode = { request in
                guard request.clientId == clientId, request.clientSecret == clientSecret,
                      request.grantType == "authorization_code", request.redirectUri == nil
                else { return nil }
                return await responses[request.code]?()
            }
        }
    }

    public func oauthRequestExpiresAt(id: String) -> Date? {
        profiles.accountState.mobileRequests[id]?.expiresAt
    }

    public func oauthRequestProviderEmail(id: String) -> String? {
        profiles.accountState.mobileRequests[id]?.profileEmail
    }

    public func oauthRequestProviderUserId(id: String) -> String? {
        profiles.accountState.mobileRequests[id]?.profileUserId
    }
}

/// Immutable, public synthetic material used only by explicit test setup.
public enum AuthJWTFixture {
    public static let socialSigningSecret = "synthetic-JWT-social-signing-key-for-tests-71"
}

/// Preserve Apple's boolean and string forms on the signed wire. In particular,
/// a string "true" fixture must not be silently converted into a JSON boolean.
public enum AuthAppleEmailVerificationClaim: Codable, Sendable, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral {
    case boolean(Bool)
    case string(String)

    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(stringLiteral value: String) { self = .string(value) }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else { self = .string(try value.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .boolean(let boolean): try value.encode(boolean)
        case .string(let string): try value.encode(string)
        }
    }
}

/// A signer input that retains the raw email_verified representation. Production
/// verifies these tokens as JWTKit.AppleIdentityToken, never as this fixture type.
private struct AuthAppleFixturePayload: JWTPayload {
    let iss: IssuerClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    let sub: SubjectClaim
    let nonce: String
    let email: String?
    let email_verified: AuthAppleEmailVerificationClaim

    func verify(using algorithm: some JWTAlgorithm) throws {
        guard algorithm.name == "RS256", iss.value == "https://appleid.apple.com" else {
            throw JWTError.claimVerificationFailure(failedClaim: iss, reason: "Invalid synthetic Apple issuer")
        }
        try exp.verifyNotExpired()
    }
}

/// Real RSA signatures minted by JWTKit. This published upstream test key is
/// synthetic; it supplies no production authority or cached credential proof.
public struct AuthAppleJWTFixture: Sendable {
    private let key: Insecure.RSA.PrivateKey
    public let jwksJSON: String

    public init() throws {
        // JWTKit 5.8.0 Tests/JWTKitTests/RSATests.swift, public test fixture.
        let pem = """
        -----BEGIN PRIVATE KEY-----
        MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDL8W1D9w5zHpmD
        JqpTngIRJ+Sm21e42cRnTudhdejzKUiJQWkHSvQV5yC/+0iEXUsUJYEdSyrKhJFD
        PT+IFGdjIiwb7IX+rUreWXlD/YYBL3/byMG4kYoO4oiPp2A+WvfeyLpuN549OXhk
        7o5kXEZjKfjHTfmnAbCMoYW5BEpiHQC3HAeJZ5EiwAn8HZn5UY6lxJcf7H9hR83x
        D0W7IZTNyxUu4aLNuihFIxJKgP/L/y95Y6ddZsyyHQopM43/7JOYBwufa07MWaxi
        AdBdq1bR/ZeOt2aZaXhV+J6QUoUO8Z6fG6b2cQmvMgk4ybqoeciLII0DfFsyqavu
        ip4hRr59AgMBAAECggEAUIw994XwMw922hG/W98gOd5jtHMVJnD73UGQqTGEm+VG
        PM+Ux8iWtr/ec3Svo3elW4OkhwlVET9ikAf0u64zVzf769ty4K9YzpDQEEZlUrqL
        6SZVPKxetppKDVKx9G7BT0BAQZ+947h7EIIXwxOeyTOeijkFzSwhqqlwwy4qoqzV
        FTQS20QHE62hxzwuS5HBqw8ds183qAg9NbzR0Cp4za9qTiBB6C8KEcLqeatO+q+d
        VCDsJcAMZOvW14N6BozKgbQ/WXZQ/3kNUPBndZLzzqaILFNmB1Zf2DVVJ9gU7+EK
        xOac60StIfG81NllCTBrmRVq8yitNqwmutHMlxrIkQKBgQDvp39MkEHtNunFGkI5
        R8IB5BZjtx5OdRBKkmPasmNU8U0XoQAJUKY/9piIpCtRi87tMXv8WWmlbULi66pu
        4BnMIisw78xlIWRZTSizFrkFcEoVgEnbZBtSrOg/J5PAcjLEGCQoAdmMXAekR2/m
        htv7FPijHPNUjyIFLaxwjl9izwKBgQDZ2mQeKNRHjIb5ZBzB0ZCvUy2y4+kaLrhZ
        +CWMN1flL4dd1KuZKvCEfHY9kWOjqw6XneN4yT0aPmbBft4fihiiNW0Sm8i+fSpy
        g0klw2HJl49wnwctBpRgTdMKGo9n14OGeu0xKOAy7I4j1tKrUXiRWnP9R583Ti7c
        w7YHgdHM8wKBgEV147SaPzF08A6bzMPzY2zO4hpmsdcFoQIsKdryR04QXkrR9EO+
        52C0pYM9Kf0Jq6Ed7ZS3iaJT58YDjjNyqqd648/cQP6yzfYAIiK+HERSRnay5zU6
        b5zn1qyvWOi3cLVbVedumdJPvjtEJU/ImKvOaT5FntVMYwzjLw60hTsLAoGAZJnt
        UeAY51GFovUQMpDL96q5l7qXknewuhtVe4KzHCrun+3tsDWcDBJNp/DTymjbvDg1
        KzoC9XOLkB8+A+KJrZ5uWAGImi7Cw07NIJsxNR7AJonJjolTS4Wkxy2su49SNW/e
        yKzPm7SRjwtNDb/5pWXX2kaQx8Fa8qeOD7lrYPECgYAwQ6o0vYmr+L1tOZZgMVv9
        Jusa8beVUH5hyduJjmxbYOtFTkggAozdx7rs4BgyRsmDlV48cEmcVf/7IH4gMJLb
        O+bbERwCYUChe+piANhnwfwDHzbRd8mmQus54P06X7bWu6Rmi7gbQGVN/Z6VhbIm
        D2cOo0w4bk/3yb01xz1MEw==
        -----END PRIVATE KEY-----
        """
        key = try Insecure.RSA.PrivateKey(pem: pem)
        let components = try key.publicKey.getKeyPrimitives()
        func base64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let jwk = JWK.rsa(.rs256, identifier: "synthetic-apple-rsa-71",
                          modulus: base64(components.modulus), exponent: base64(components.publicExponent))
        jwksJSON = String(decoding: try JSONEncoder().encode(JWKS(keys: [jwk])), as: UTF8.self)
    }

    public func token(subject: String, nonce: String, email: String? = nil,
                      emailVerified: AuthAppleEmailVerificationClaim = true, audience: String = "build.raft.app",
                      issuer: String = "https://appleid.apple.com",
                      expiresAt: Date = Date().addingTimeInterval(300)) async throws -> String {
        let keys = await JWTKeyCollection().add(rsa: key, digestAlgorithm: .sha256, kid: "synthetic-apple-rsa-71")
        return try await keys.sign(AuthAppleFixturePayload(iss: .init(value: issuer), aud: .init(value: [audience]),
            exp: .init(value: expiresAt), iat: .init(value: Date()), sub: .init(value: subject),
            nonce: nonce, email: email, email_verified: emailVerified), kid: "synthetic-apple-rsa-71")
    }
}
