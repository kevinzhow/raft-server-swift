// Test seams for product feedback and the Hands upstream: base URL / app overrides,
// the injected upstream transport, warning sink and route-binding cache.
@testable import RaftHTTP
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {
    public func setHandsFeedbackForTesting(baseURL: String?, appId: String?, appToken: String?, appSlug: String? = nil) {
        lock.lock()
        handsFeedbackBaseURLOverride = baseURL
        handsFeedbackAppIdOverride = appId
        handsFeedbackAppSlugOverride = appSlug
        handsFeedbackAppTokenOverride = appToken
        productFeedbackReporterSessionCache.removeAll()
        productFeedbackRouteBindingSuccesses.removeAll()
        productFeedbackRouteVerifiedCommitments.removeAll()
        lock.unlock()
    }

    public func setHandsFeedbackUpstreamForTesting(_ handler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?) {
        lock.lock(); handsFeedbackUpstreamHandler = handler; lock.unlock()
    }

    /// Installs the SecureString-shaped `HANDS_FEEDBACK_APPS` JSON. Production
    /// reads this from SSM; the port has no AWS client, so the composition root
    /// (or a test) supplies the payload.
    public func setHandsFeedbackAppsForTesting(_ appsJSON: String?) {
        lock.lock()
        handsFeedbackAppsJSON = appsJSON
        productFeedbackReporterSessionCache.removeAll()
        productFeedbackRouteBindingSuccesses.removeAll()
        productFeedbackRouteVerifiedCommitments.removeAll()
        lock.unlock()
    }

    /// Overlays the legacy `HANDS_FEEDBACK_*` environment view for a test.
    public func setHandsFeedbackLegacyEnvironmentForTesting(_ values: [String: String]?) {
        lock.lock()
        handsFeedbackLegacyEnvironment = values
        productFeedbackReporterSessionCache.removeAll()
        productFeedbackRouteBindingSuccesses.removeAll()
        productFeedbackRouteVerifiedCommitments.removeAll()
        lock.unlock()
    }

    /// Operator log sink (upstream uses `console.warn`). Tests install one to
    /// assert the fixed reason codes without reading process output.
    public func setHandsFeedbackWarningSinkForTesting(_ sink: ((String) -> Void)?) {
        lock.lock()
        handsFeedbackWarningSink = sink
        lock.unlock()
    }

    /// Labels committed into `integrationSecretCommitments` by route binding.
    public func productFeedbackRouteCommitmentLabelsForTesting() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(productFeedbackRouteCommitments.keys).sorted()
    }

    public func resetProductFeedbackRouteBindingCacheForTesting() {
        lock.lock()
        productFeedbackRouteBindingSuccesses.removeAll()
        productFeedbackRouteVerifiedCommitments.removeAll()
        productFeedbackRouteCommitments.removeAll()
        lock.unlock()
    }

    public func setHandsConversationForTesting(enabled: Bool, appToken: String?) {
        lock.lock()
        handsConversationSessionEnabled = enabled
        handsConversationAppTokenOverride = appToken
        productFeedbackReporterSessionCache.removeAll()
        lock.unlock()
    }
}
