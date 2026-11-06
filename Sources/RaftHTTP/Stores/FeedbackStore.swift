import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        // Injectable Hands feedback transport configuration that used to live
        // inline on `EmailLoginDirectory`.
        var handsFeedbackUpstreamHandler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))? = nil
        var handsConversationAppTokenOverride: String? = nil
        var handsFeedbackBaseURLOverride: String? = nil
        var handsFeedbackAppIdOverride: String? = nil
        var handsFeedbackAppSlugOverride: String? = nil
        var handsFeedbackAppTokenOverride: String? = nil
        var handsFeedbackConfigured = false
        var marketplaceReviewerOverride: Set<String>? = nil
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

    /// The outcome of one locator insert. The receipt belongs to the stored row
    /// so a replay answers the original id.
    enum FeedbackLocatorInsertOutcome: Equatable {
        case inserted
        case duplicate(receiptId: String)
        case conflict
    }

    /// The `(server, report)` identity lookup, the digest comparison and the
    /// append are one critical section: two concurrent first reports for the
    /// same identity cannot both be inserted.
    func insertFeedbackLocator(_ record: FeedbackLocatorRecord) -> FeedbackLocatorInsertOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage.feedbackLocatorRecords.first(where: {
            $0.serverId == record.serverId && $0.reportId == record.reportId
        }) {
            return existing.payloadSha256 == record.payloadSha256
                ? .duplicate(receiptId: existing.receiptId)
                : .conflict
        }
        storage.feedbackLocatorRecords.append(record)
        return .inserted
    }

    /// One locked snapshot of a server's rows; filtering and paging stay in the
    /// service and cannot interleave with an insert.
    func feedbackLocatorSnapshot(serverId: String) -> [FeedbackLocatorRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.feedbackLocatorRecords.filter { $0.serverId == serverId }
    }

    var handsFeedbackAppsJSON: String? {
        get { state.handsFeedbackAppsJSON }
        set { state.handsFeedbackAppsJSON = newValue }
    }

    var handsFeedbackLegacyEnvironment: [String: String]? {
        get { state.handsFeedbackLegacyEnvironment }
        set { state.handsFeedbackLegacyEnvironment = newValue }
    }

    // MARK: - Injected Hands feedback transport configuration

    var handsFeedbackUpstreamHandler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))? {
        get { state.handsFeedbackUpstreamHandler }
        set { state.handsFeedbackUpstreamHandler = newValue }
    }

    var handsConversationAppTokenOverride: String? {
        get { state.handsConversationAppTokenOverride }
        set { state.handsConversationAppTokenOverride = newValue }
    }

    var handsFeedbackBaseURLOverride: String? {
        get { state.handsFeedbackBaseURLOverride }
        set { state.handsFeedbackBaseURLOverride = newValue }
    }

    var handsFeedbackAppIdOverride: String? {
        get { state.handsFeedbackAppIdOverride }
        set { state.handsFeedbackAppIdOverride = newValue }
    }

    var handsFeedbackAppSlugOverride: String? {
        get { state.handsFeedbackAppSlugOverride }
        set { state.handsFeedbackAppSlugOverride = newValue }
    }

    var handsFeedbackAppTokenOverride: String? {
        get { state.handsFeedbackAppTokenOverride }
        set { state.handsFeedbackAppTokenOverride = newValue }
    }

    var handsFeedbackConfigured: Bool {
        get { state.handsFeedbackConfigured }
        set { state.handsFeedbackConfigured = newValue }
    }

    var marketplaceReviewerOverride: Set<String>? {
        get { state.marketplaceReviewerOverride }
        set { state.marketplaceReviewerOverride = newValue }
    }
}
