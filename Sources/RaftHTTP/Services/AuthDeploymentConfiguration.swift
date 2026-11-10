import Foundation

extension OAuthFlowsService {
    public struct DeploymentConfiguration: Sendable, Equatable {
        public var configuredSocialAuthProviders: Set<String>
        public var appleClientId: String
        public var nativeAppleClientId: String
        public var nativeAppleClientSecret: String
        public var nativeAppleStateSecret: String
        public var socialAuthStateSecret: String
        public var nativeAppleTrustedJWKS: String?
        public var serverURL: String
        public var appURL: String
        public var mobileOAuthReturnURI: String?
        public var mobileOAuthAllowedReturnURIs: String?

        public init(
            configuredSocialAuthProviders: Set<String> = [],
            appleClientId: String = "",
            nativeAppleClientId: String = "",
            nativeAppleClientSecret: String = "",
            nativeAppleStateSecret: String = "",
            socialAuthStateSecret: String = "",
            nativeAppleTrustedJWKS: String? = nil,
            serverURL: String = "http://localhost:3001",
            appURL: String = "http://localhost:3000",
            mobileOAuthReturnURI: String? = nil,
            mobileOAuthAllowedReturnURIs: String? = nil
        ) {
            self.configuredSocialAuthProviders = configuredSocialAuthProviders
            self.appleClientId = appleClientId
            self.nativeAppleClientId = nativeAppleClientId
            self.nativeAppleClientSecret = nativeAppleClientSecret
            self.nativeAppleStateSecret = nativeAppleStateSecret
            self.socialAuthStateSecret = socialAuthStateSecret
            self.nativeAppleTrustedJWKS = nativeAppleTrustedJWKS
            self.serverURL = serverURL
            self.appURL = appURL
            self.mobileOAuthReturnURI = mobileOAuthReturnURI
            self.mobileOAuthAllowedReturnURIs = mobileOAuthAllowedReturnURIs
        }
    }

    public var deploymentConfiguration: DeploymentConfiguration { store.profiles.oauthDeploymentConfiguration }

    public func configureDeployment(_ configuration: DeploymentConfiguration) {
        store.profiles.setOAuthDeployment(configuration)
    }
}

extension AuthCoreService {
    public struct DeploymentConfiguration: Sendable, Equatable {
        public var releaseBranch: String?
        public var deviceLoginGate: String?

        public init(
            releaseBranch: String? = nil,
            deviceLoginGate: String? = nil
        ) {
            self.releaseBranch = releaseBranch
            self.deviceLoginGate = deviceLoginGate
        }
    }

    public var deploymentConfiguration: DeploymentConfiguration { store.authCoreDeploymentConfiguration }

    public func configureDeployment(_ configuration: DeploymentConfiguration) {
        store.setAuthCoreDeployment(configuration)
    }
}

extension MobileAppEmailUnsubscribe {
    public struct DeploymentConfiguration: Sendable, Equatable {
        public var secret: String

        public init(
            secret: String = "test-jwt-secret"
        ) {
            self.secret = secret
        }
    }

    public var deploymentConfiguration: DeploymentConfiguration { notifications.mobileEmailDeploymentConfiguration }

    public func configureDeployment(_ configuration: DeploymentConfiguration) {
        notifications.setMobileEmailDeployment(configuration)
    }
}
