import Foundation
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
        _ responses: [String: @Sendable () -> String], clientId: String, clientSecret: String
    ) {
        profiles.state.withLock { owned in
            owned.configSurface.exchangeNativeAppleCode = { request in
                guard request.clientId == clientId, request.clientSecret == clientSecret,
                      request.grantType == "authorization_code", request.redirectUri == nil
                else { return nil }
                return responses[request.code]?()
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
