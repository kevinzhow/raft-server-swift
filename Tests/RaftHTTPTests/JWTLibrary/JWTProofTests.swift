import Foundation
import Testing
@testable import RaftHTTP

@Test func jwtLibraryExpiredNativeRequestRequiresAnAuthenticSignature() async throws {
    let secret = "synthetic-native-expiration-signing-key-71"
    let token = try await AuthTokenCodec.signNativeAppleRequestToken(secret: secret, requestId: "synthetic-request",
        mode: "login", codeChallenge: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(-60))
    if case .expired = await AuthTokenCodec.verifyNativeAppleRequestToken(token, secret: secret) {} else {
        Issue.record("Authentic expired requests retain the published expiration classification")
    }
    let parts = token.split(separator: ".")
    let forged = "\(parts[0]).\(parts[1]).Ym9ndXM"
    if case .invalid = await AuthTokenCodec.verifyNativeAppleRequestToken(forged, secret: secret) {} else {
        Issue.record("Unauthenticated expiration must not receive a trusted-claim classification")
    }
    if case .invalid = await AuthTokenCodec.verifyNativeAppleRequestToken(token,
        secret: "synthetic-unrelated-configured-key-71") {} else { Issue.record("Wrong authority must fail closed") }
}

@Test func jwtLibrarySocialProofRejectsMissingAuthorityAndCannotServeAsNativeCapability() async throws {
    let secret = "synthetic-social-capability-signing-key-71"
    let state = SocialAuthState(provider: "google", mode: "login", nonce: "synthetic-nonce", kind: "web", mobileRequestId: "", desktopNonce: nil)
    let signed = try await AuthTokenCodec.signSocialAuthState(state, secret: secret)
    #expect(await AuthTokenCodec.verifySocialAuthState(signed, secret: secret) == state)
    #expect(await AuthTokenCodec.verifySocialAuthState(signed, secret: "") == nil)
    if case .invalid = await AuthTokenCodec.verifyNativeAppleRequestToken(signed, secret: secret) {} else {
        Issue.record("A social state must not become a native Apple request capability")
    }
    await #expect(throws: JWTProofError.unavailable) {
        try await AuthTokenCodec.signSocialAuthState(state, secret: "short")
    }
}
