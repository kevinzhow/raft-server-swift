import Foundation

/// Owns the agent-reminder and product-feedback rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class FeedbackStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var appAgentReminderLedger: [String: String] = [:]
        var agentReminderSurfaceChannels: [String: String] = [:]
        var productFeedbackReporterSessionCache: [String: (token: String, expiresAt: Date)] = [:]
        var productFeedbackRouteBindingSuccesses: [String: Date] = [:]
        var productFeedbackRouteCommitments: [String: Data] = [:]
        var productFeedbackRouteVerifiedCommitments: Set<String> = []
        var feedbackLocatorRecords: [FeedbackLocatorRecord] = []
        var handsFeedbackAppsJSON: String? = nil
        var handsFeedbackLegacyEnvironment: [String: String]? = nil
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var appAgentReminderLedger: [String: String] {
        get { state.appAgentReminderLedger }
        set { state.appAgentReminderLedger = newValue }
    }

    var agentReminderSurfaceChannels: [String: String] {
        get { state.agentReminderSurfaceChannels }
        set { state.agentReminderSurfaceChannels = newValue }
    }

    var productFeedbackReporterSessionCache: [String: (token: String, expiresAt: Date)] {
        get { state.productFeedbackReporterSessionCache }
        set { state.productFeedbackReporterSessionCache = newValue }
    }

    var productFeedbackRouteBindingSuccesses: [String: Date] {
        get { state.productFeedbackRouteBindingSuccesses }
        set { state.productFeedbackRouteBindingSuccesses = newValue }
    }

    var productFeedbackRouteCommitments: [String: Data] {
        get { state.productFeedbackRouteCommitments }
        set { state.productFeedbackRouteCommitments = newValue }
    }

    var productFeedbackRouteVerifiedCommitments: Set<String> {
        get { state.productFeedbackRouteVerifiedCommitments }
        set { state.productFeedbackRouteVerifiedCommitments = newValue }
    }

    var feedbackLocatorRecords: [FeedbackLocatorRecord] {
        get { state.feedbackLocatorRecords }
        set { state.feedbackLocatorRecords = newValue }
    }

    var handsFeedbackAppsJSON: String? {
        get { state.handsFeedbackAppsJSON }
        set { state.handsFeedbackAppsJSON = newValue }
    }

    var handsFeedbackLegacyEnvironment: [String: String]? {
        get { state.handsFeedbackLegacyEnvironment }
        set { state.handsFeedbackLegacyEnvironment = newValue }
    }
}
