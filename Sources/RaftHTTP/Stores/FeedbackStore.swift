import Foundation
import Synchronization
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
final class FeedbackStore: Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State: Sendable {
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
        var handsFeedbackUpstreamHandler: (@Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data))? = nil
        var handsConversationAppTokenOverride: String? = nil
        var handsFeedbackBaseURLOverride: String? = nil
        var handsFeedbackAppIdOverride: String? = nil
        var handsFeedbackAppSlugOverride: String? = nil
        var handsFeedbackAppTokenOverride: String? = nil
        var handsFeedbackConfigured = false
        var marketplaceReviewerOverride: Set<String>? = nil
    }

    private let storage = Mutex(State())

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    var appAgentReminderLedger: [String: String] {
        get { storage.withLock { $0.appAgentReminderLedger } }
        set { storage.withLock { $0.appAgentReminderLedger = newValue } }
    }

    var agentReminderSurfaceChannels: [String: String] {
        get { storage.withLock { $0.agentReminderSurfaceChannels } }
        set { storage.withLock { $0.agentReminderSurfaceChannels = newValue } }
    }

    var productFeedbackRouteVerifiedCommitments: Set<String> {
        get { storage.withLock { $0.productFeedbackRouteVerifiedCommitments } }
        set { storage.withLock { $0.productFeedbackRouteVerifiedCommitments = newValue } }
    }

    var feedbackLocatorRecords: [FeedbackLocatorRecord] {
        get { storage.withLock { $0.feedbackLocatorRecords } }
        set { storage.withLock { $0.feedbackLocatorRecords = newValue } }
    }

    /// The outcome of one locator insert. The receipt belongs to the stored row
    /// so a replay answers the original id.
    enum FeedbackLocatorInsertOutcome: Equatable, Sendable {
        case inserted
        case duplicate(receiptId: String)
        case conflict
    }

    /// The `(server, report)` identity lookup, the digest comparison and the
    /// append are one critical section: two concurrent first reports for the
    /// same identity cannot both be inserted.
    func insertFeedbackLocator(_ record: FeedbackLocatorRecord) -> FeedbackLocatorInsertOutcome {
        return storage.withLock { storage in
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
    }

    /// One locked snapshot of a server's rows; filtering and paging stay in the
    /// service and cannot interleave with an insert.
    func feedbackLocatorSnapshot(serverId: String) -> [FeedbackLocatorRecord] {
        return storage.withLock { storage in
            return storage.feedbackLocatorRecords.filter { $0.serverId == serverId }
        }
    }

    var handsFeedbackAppsJSON: String? {
        get { storage.withLock { $0.handsFeedbackAppsJSON } }
        set { storage.withLock { $0.handsFeedbackAppsJSON = newValue } }
    }

    var handsFeedbackLegacyEnvironment: [String: String]? {
        get { storage.withLock { $0.handsFeedbackLegacyEnvironment } }
        set { storage.withLock { $0.handsFeedbackLegacyEnvironment = newValue } }
    }

    // MARK: - Injected Hands feedback transport configuration

    var handsFeedbackUpstreamHandler: (@Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data))? {
        get { storage.withLock { $0.handsFeedbackUpstreamHandler } }
        set { storage.withLock { $0.handsFeedbackUpstreamHandler = newValue } }
    }

    var handsConversationAppTokenOverride: String? {
        get { storage.withLock { $0.handsConversationAppTokenOverride } }
        set { storage.withLock { $0.handsConversationAppTokenOverride = newValue } }
    }

    var handsFeedbackBaseURLOverride: String? {
        get { storage.withLock { $0.handsFeedbackBaseURLOverride } }
        set { storage.withLock { $0.handsFeedbackBaseURLOverride = newValue } }
    }

    var handsFeedbackAppIdOverride: String? {
        get { storage.withLock { $0.handsFeedbackAppIdOverride } }
        set { storage.withLock { $0.handsFeedbackAppIdOverride = newValue } }
    }

    var handsFeedbackAppSlugOverride: String? {
        get { storage.withLock { $0.handsFeedbackAppSlugOverride } }
        set { storage.withLock { $0.handsFeedbackAppSlugOverride = newValue } }
    }

    var handsFeedbackAppTokenOverride: String? {
        get { storage.withLock { $0.handsFeedbackAppTokenOverride } }
        set { storage.withLock { $0.handsFeedbackAppTokenOverride = newValue } }
    }

    var handsFeedbackConfigured: Bool {
        get { storage.withLock { $0.handsFeedbackConfigured } }
        set { storage.withLock { $0.handsFeedbackConfigured = newValue } }
    }

    var marketplaceReviewerOverride: Set<String>? {
        get { storage.withLock { $0.marketplaceReviewerOverride } }
        set { storage.withLock { $0.marketplaceReviewerOverride = newValue } }
    }

    // MARK: - Hands feedback configuration

    /// The merged `HANDS_FEEDBACK_*` view: the process environment plus the
    /// injectable overlay and per-key overrides this store owns.
    ///
    /// The legacy `FeedbackService.legacyEnvironmentLocked` merged the same
    /// keys; reading them here gives the merge one critical section and keeps
    /// the submission path off the directory lock. `conversationSessionEnabled`
    /// is a test seam that lives in `AuthProfileStore`, so the caller passes it
    /// in rather than this store reaching across a lock.
    func handsFeedbackEnvironment(
        base: [String: String],
        conversationSessionEnabled: Bool?
    ) -> [String: String] {
        return storage.withLock { storage in
            return Self.mergedEnvironment(
                storage,
                base: base,
                conversationSessionEnabled: conversationSessionEnabled
            )
        }
    }

    /// One atomic read of the three configuration facts the submission path
    /// consumes together: the merged environment, the multi-app apps payload
    /// and the configured flag.
    func handsFeedbackSubmissionConfiguration(
        base: [String: String],
        conversationSessionEnabled: Bool?
    ) -> (environment: [String: String], appsJSON: String?, configured: Bool) {
        return storage.withLock { storage in
            return (
                Self.mergedEnvironment(
                    storage,
                    base: base,
                    conversationSessionEnabled: conversationSessionEnabled
                ),
                storage.handsFeedbackAppsJSON,
                storage.handsFeedbackConfigured
            )
        }
    }

    private static func mergedEnvironment(
        _ state: State,
        base: [String: String],
        conversationSessionEnabled: Bool?
    ) -> [String: String] {
        var environment = base
        if let overlay = state.handsFeedbackLegacyEnvironment {
            for (key, value) in overlay { environment[key] = value }
        }
        if let value = state.handsFeedbackBaseURLOverride {
            environment["HANDS_FEEDBACK_BASE_URL"] = value
        }
        if let value = state.handsFeedbackAppIdOverride {
            environment["HANDS_FEEDBACK_APP_ID"] = value
        }
        if let value = state.handsFeedbackAppSlugOverride {
            environment["HANDS_FEEDBACK_APP_SLUG"] = value
        }
        if let value = state.handsFeedbackAppTokenOverride {
            environment["HANDS_FEEDBACK_APP_TOKEN"] = value
        }
        if let value = conversationSessionEnabled {
            environment["HANDS_FEEDBACK_CONVERSATION_SESSION_ENABLED"] = value ? "true" : "false"
        }
        if let value = state.handsConversationAppTokenOverride {
            environment["HANDS_FEEDBACK_CONVERSATION_APP_TOKEN"] = value
        }
        return environment
    }
}

// MARK: - Managed MCP lifecycle: app reminder ledger sections

extension FeedbackStore {
    /// The message an installation already recorded for the idempotency key.
    func appAgentReminderMessageId(ledgerKey: String) -> String? {
        return storage.withLock { storage in
            return storage.appAgentReminderLedger[ledgerKey]
        }
    }

    /// The agent's reminders DM channel id, when one was created.
    func agentReminderSurfaceChannelId(agentId: String) -> String? {
        return storage.withLock { storage in
            return storage.agentReminderSurfaceChannels[agentId]
        }
    }

    /// Forgets the reminders surface when it still points at `channelId` (it
    /// was soft-deleted), so the next write creates a fresh one.
    func clearAgentReminderSurface(agentId: String, ifChannelId channelId: String) {
        storage.withLock { storage -> Void in
            if storage.agentReminderSurfaceChannels[agentId] == channelId {
                storage.agentReminderSurfaceChannels.removeValue(forKey: agentId)
            }
        }
    }

    func setAgentReminderSurface(agentId: String, channelId: String) {
        storage.withLock { storage -> Void in
            storage.agentReminderSurfaceChannels[agentId] = channelId
        }
    }

    /// Records the delivered reminder for the idempotency key.
    func recordAppAgentReminder(ledgerKey: String, messageId: String) {
        storage.withLock { storage -> Void in
            storage.appAgentReminderLedger[ledgerKey] = messageId
        }
    }
}

// MARK: - Hands route binding and reporter sessions

extension FeedbackStore {
    /// The outcome of one route-binding cache probe.
    enum RouteBindingCheck: Equatable, Sendable {
        /// A different root commitment is already recorded for the label.
        case commitmentMismatch
        /// A live success for the cache key is cached.
        case cached
        /// Nothing cached: the caller must bind upstream.
        case miss
    }

    /// The commitment compare-or-insert and the cached-success lookup are one
    /// critical section, so two concurrent first requests cannot both record
    /// different commitments for the same label.
    func checkRouteBinding(
        commitmentLabel: String,
        commitment: Data,
        cacheKey: String,
        now: Date
    ) -> RouteBindingCheck {
        return storage.withLock { storage in
            if let existing = storage.productFeedbackRouteCommitments[commitmentLabel] {
                if existing != commitment { return .commitmentMismatch }
            } else {
                storage.productFeedbackRouteCommitments[commitmentLabel] = commitment
            }
            if let expiresAt = storage.productFeedbackRouteBindingSuccesses[cacheKey], expiresAt > now {
                return .cached
            }
            return .miss
        }
    }

    func recordRouteBindingSuccess(cacheKey: String, expiresAt: Date) {
        storage.withLock { storage -> Void in
            storage.productFeedbackRouteBindingSuccesses[cacheKey] = expiresAt
        }
    }

    /// The cached reporter session token that stays valid past `validAfter`.
    func cachedReporterSession(cacheKey: String, validAfter: Date) -> String? {
        return storage.withLock { storage in
            guard let cached = storage.productFeedbackReporterSessionCache[cacheKey],
                  cached.expiresAt > validAfter
            else { return nil }
            return cached.token
        }
    }

    func storeReporterSession(cacheKey: String, token: String, expiresAt: Date) {
        storage.withLock { storage -> Void in
            storage.productFeedbackReporterSessionCache[cacheKey] = (token, expiresAt)
        }
    }

    /// Drops the cached route-binding successes and verified commitments; the
    /// recorded commitments survive unless `includingCommitments` is set.
    func clearRouteBindingCache(includingCommitments: Bool = false, includingReporterSessions: Bool = false) {
        storage.withLock { storage -> Void in
            storage.productFeedbackRouteBindingSuccesses.removeAll()
            storage.productFeedbackRouteVerifiedCommitments.removeAll()
            if includingCommitments { storage.productFeedbackRouteCommitments.removeAll() }
            if includingReporterSessions { storage.productFeedbackReporterSessionCache.removeAll() }
        }
    }

    func clearReporterSessions() {
        storage.withLock { storage -> Void in
            storage.productFeedbackReporterSessionCache.removeAll()
        }
    }

    /// Labels committed by route binding, sorted.
    func routeCommitmentLabels() -> [String] {
        return storage.withLock { storage in
            return storage.productFeedbackRouteCommitments.keys.sorted()
        }
    }
}
