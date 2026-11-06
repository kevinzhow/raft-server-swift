import Foundation
@testable import RaftHTTP

/// These mutable setup APIs exist only in TestSupport. Each closure borrows the
/// owning Mutex for the full change; no whole-state snapshot is written back.
extension EmailLoginDirectory {
    public func configureOAuthForTesting(_ update: (inout OAuthFlowsService.DeploymentConfiguration) -> Void) {
        authProfileStore.state.withLock { update(&$0.configSurface.oauthDeployment) }
    }

    public func configureAuthCoreForTesting(_ update: (inout AuthCoreService.DeploymentConfiguration) -> Void) {
        authProfileStore.state.withLock { update(&$0.configSurface.authCoreDeployment) }
    }

    public func configureNativeNotificationsForTesting(_ update: (inout NativeNotificationsService.DeploymentConfiguration) -> Void) {
        notificationsStore.storage.withLock { update(&$0.nativeDeployment) }
    }

    public func configureMobileEmailForTesting(_ update: (inout MobileAppEmailUnsubscribe.DeploymentConfiguration) -> Void) {
        notificationsStore.storage.withLock { update(&$0.mobileEmailDeployment) }
    }

    public struct AuthSimulationConfiguration: Sendable {
        public var mobileProviderProfile: MobileProviderProfile?
        public var webProviderProfile: MobileProviderProfile?
        public var exchangeNativeAppleCode: (@Sendable (NativeAppleCodeExchange) async -> String?)?
    }

    public func configureAuthSimulationForTesting(_ update: (inout AuthSimulationConfiguration) -> Void) {
        authProfileStore.state.withLock { state in
            var configuration = AuthSimulationConfiguration(
                mobileProviderProfile: state.configSurface.mobileProviderProfile,
                webProviderProfile: state.configSurface.webProviderProfile,
                exchangeNativeAppleCode: state.configSurface.exchangeNativeAppleCode
            )
            update(&configuration)
            state.configSurface.mobileProviderProfile = configuration.mobileProviderProfile
            state.configSurface.webProviderProfile = configuration.webProviderProfile
            state.configSurface.exchangeNativeAppleCode = configuration.exchangeNativeAppleCode
        }
    }

    public func setMobileEmailCancellationForTesting(_ cancel: (@Sendable (String) -> Void)?) {
        notificationsStore.storage.withLock { $0.cancelMobileAppEmail = cancel }
    }

    public func setNativeAttestationVerifierForTesting(_ verifier: (@Sendable (String) -> Bool)?) {
        notificationsStore.storage.withLock { $0.nativeNotificationAttestationVerifier = verifier }
    }

    public func setNativeLiveWriteHookForTesting(_ hook: (@Sendable (Int, Int) async -> Void)?) {
        notificationsStore.storage.withLock { $0.nativeNotificationLiveWriteHook = hook }
    }

    public func setAgentReadUpdatedForTesting(_ hook: (@Sendable (String, String, String, Int) -> Void)?) {
        notificationsStore.storage.withLock { $0.onAgentReadUpdated = hook }
    }
}

extension EmailLoginDirectory {
    public func setFCMPushAvailableForTesting(_ available: Bool) {
        notificationsStore.storage.withLock { $0.fcmPushAvailable = available }
    }
}
