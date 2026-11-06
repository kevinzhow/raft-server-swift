import Foundation

extension AuthProfileStore {
    var oauthDeploymentConfiguration: OAuthFlowsService.DeploymentConfiguration {
        state.withLock { $0.configSurface.oauthDeployment }
    }

    func setOAuthDeployment(_ configuration: OAuthFlowsService.DeploymentConfiguration) {
        state.withLock { $0.configSurface.oauthDeployment = configuration }
    }

    var authCoreDeploymentConfiguration: AuthCoreService.DeploymentConfiguration {
        state.withLock { $0.configSurface.authCoreDeployment }
    }

    func setAuthCoreDeployment(_ configuration: AuthCoreService.DeploymentConfiguration) {
        state.withLock { $0.configSurface.authCoreDeployment = configuration }
    }
}
