// Test seams for product feedback and the Hands upstream: base URL / app overrides,
// the injected upstream transport, warning sink and route-binding cache.
@testable import RaftHTTP
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {
    public func setHandsFeedbackForTesting(baseURL: String?, appId: String?, appToken: String?, appSlug: String? = nil) {
        feedbackStore.handsFeedbackBaseURLOverride = baseURL
        feedbackStore.handsFeedbackAppIdOverride = appId
        feedbackStore.handsFeedbackAppSlugOverride = appSlug
        feedbackStore.handsFeedbackAppTokenOverride = appToken
        feedbackStore.clearRouteBindingCache(includingReporterSessions: true)
    }

    public func setHandsFeedbackUpstreamForTesting(_ handler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?) {
        feedbackStore.handsFeedbackUpstreamHandler = handler
    }

    /// Installs the SecureString-shaped `HANDS_FEEDBACK_APPS` JSON. Production
    /// reads this from SSM; the port has no AWS client, so the composition root
    /// (or a test) supplies the payload.
    public func setHandsFeedbackAppsForTesting(_ appsJSON: String?) {
        feedbackStore.handsFeedbackAppsJSON = appsJSON
        feedbackStore.clearRouteBindingCache(includingReporterSessions: true)
    }

    /// Overlays the legacy `HANDS_FEEDBACK_*` environment view for a test.
    public func setHandsFeedbackLegacyEnvironmentForTesting(_ values: [String: String]?) {
        feedbackStore.handsFeedbackLegacyEnvironment = values
        feedbackStore.clearRouteBindingCache(includingReporterSessions: true)
    }

    /// Operator log sink (upstream uses `console.warn`). Tests install one to
    /// assert the fixed reason codes without reading process output.
    public func setHandsFeedbackWarningSinkForTesting(_ sink: ((String) -> Void)?) {
        authProfileStore.handsFeedbackWarningSink = sink
    }

    /// Labels committed into `integrationSecretCommitments` by route binding.
    public func productFeedbackRouteCommitmentLabelsForTesting() -> [String] {
        feedbackStore.routeCommitmentLabels()
    }

    public func resetProductFeedbackRouteBindingCacheForTesting() {
        feedbackStore.clearRouteBindingCache(includingCommitments: true)
    }

    public func setHandsConversationForTesting(enabled: Bool, appToken: String?) {
        authProfileStore.handsConversationSessionEnabled = enabled
        feedbackStore.handsConversationAppTokenOverride = appToken
        feedbackStore.clearReporterSessions()
    }
}
