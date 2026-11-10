import Foundation

extension FeedbackStore {
    /// Durable State fields: reminder ledger/surfaces, reporter sessions, binding
    /// successes/commitments/verified commitments, and every locator row.
    ///
    /// Excluded and preserved by restore: handsFeedbackAppsJSON,
    /// handsFeedbackLegacyEnvironment, handsFeedbackUpstreamHandler,
    /// handsConversationAppTokenOverride, handsFeedbackBaseURLOverride,
    /// handsFeedbackAppIdOverride, handsFeedbackAppSlugOverride,
    /// handsFeedbackAppTokenOverride, handsFeedbackConfigured,
    /// marketplaceReviewerOverride. These are live process/transport configuration,
    /// not owned upstream submission, ticket or conversation rows.
    ///
    /// Capture only durable references under the owner lock. Record conversion
    /// and JSON encoding execute outside that lock. The caller coordinates any
    /// consistent snapshot across multiple owners.
    func exportPersistenceData() throws -> Data {
        let captured = storage.withLock { PFFeedbackBusiness($0) }
        return try ProductFeedbackPersistenceFormat.encode(
            PFFeedbackSnapshot(captured), owner: "raft.feedback"
        )
    }

    /// Decode every required table/row key, version, Date and binary value before
    /// touching this instance. Replace only durable fields in one owner borrow;
    /// no transport callback, configuration reset or network operation occurs.
    func restorePersistenceData(_ data: Data) throws {
        let decoded = try ProductFeedbackPersistenceFormat.decode(
            PFFeedbackSnapshot.self, from: data, owner: "raft.feedback"
        )
        let restored = decoded.restored()
        storage.withLock { current in
            current.appAgentReminderLedger = restored.appAgentReminderLedger
            current.agentReminderSurfaceChannels = restored.agentReminderSurfaceChannels
            current.productFeedbackReporterSessionCache = restored.productFeedbackReporterSessionCache
            current.productFeedbackRouteBindingSuccesses = restored.productFeedbackRouteBindingSuccesses
            current.productFeedbackRouteCommitments = restored.productFeedbackRouteCommitments
            current.productFeedbackRouteVerifiedCommitments = restored.productFeedbackRouteVerifiedCommitments
            current.feedbackLocatorRecords = restored.feedbackLocatorRecords
        }
    }
}

/// The capture contains only the seven durable fields, not callbacks or configs.
private struct PFFeedbackBusiness: Sendable {
    let appAgentReminderLedger: [String: String]
    let agentReminderSurfaceChannels: [String: String]
    let productFeedbackReporterSessionCache: [String: (token: String, expiresAt: Date)]
    let productFeedbackRouteBindingSuccesses: [String: Date]
    let productFeedbackRouteCommitments: [String: Data]
    let productFeedbackRouteVerifiedCommitments: Set<String>
    let feedbackLocatorRecords: [FeedbackLocatorRecord]

    init(_ state: FeedbackStore.State) {
        appAgentReminderLedger = state.appAgentReminderLedger
        agentReminderSurfaceChannels = state.agentReminderSurfaceChannels
        productFeedbackReporterSessionCache = state.productFeedbackReporterSessionCache
        productFeedbackRouteBindingSuccesses = state.productFeedbackRouteBindingSuccesses
        productFeedbackRouteCommitments = state.productFeedbackRouteCommitments
        productFeedbackRouteVerifiedCommitments = state.productFeedbackRouteVerifiedCommitments
        feedbackLocatorRecords = state.feedbackLocatorRecords
    }

    init(_ snapshot: PFFeedbackSnapshot) {
        appAgentReminderLedger = snapshot.appAgentReminderLedger
        agentReminderSurfaceChannels = snapshot.agentReminderSurfaceChannels
        productFeedbackReporterSessionCache = snapshot.productFeedbackReporterSessionCache.mapValues {
            (token: $0.token, expiresAt: $0.expiresAt.value)
        }
        productFeedbackRouteBindingSuccesses = snapshot.productFeedbackRouteBindingSuccesses.mapValues(\.value)
        productFeedbackRouteCommitments = snapshot.productFeedbackRouteCommitments
        productFeedbackRouteVerifiedCommitments = Set(snapshot.productFeedbackRouteVerifiedCommitments)
        feedbackLocatorRecords = snapshot.feedbackLocatorRecords.map { $0.restored() }
    }
}

private struct PFFeedbackSnapshot: Codable, Sendable {
    let appAgentReminderLedger: [String: String]
    let agentReminderSurfaceChannels: [String: String]
    let productFeedbackReporterSessionCache: [String: PFReporterSession]
    let productFeedbackRouteBindingSuccesses: [String: ProductFeedbackPersistenceDate]
    let productFeedbackRouteCommitments: [String: Data]
    let productFeedbackRouteVerifiedCommitments: [String]
    let feedbackLocatorRecords: [PFLocator]

    init(_ state: PFFeedbackBusiness) {
        appAgentReminderLedger = state.appAgentReminderLedger
        agentReminderSurfaceChannels = state.agentReminderSurfaceChannels
        productFeedbackReporterSessionCache = state.productFeedbackReporterSessionCache.mapValues {
            PFReporterSession(token: $0.token, expiresAt: ProductFeedbackPersistenceDate($0.expiresAt))
        }
        productFeedbackRouteBindingSuccesses = state.productFeedbackRouteBindingSuccesses.mapValues(ProductFeedbackPersistenceDate.init)
        productFeedbackRouteCommitments = state.productFeedbackRouteCommitments
        productFeedbackRouteVerifiedCommitments = state.productFeedbackRouteVerifiedCommitments.sorted()
        feedbackLocatorRecords = state.feedbackLocatorRecords.map(PFLocator.init)
    }

    func restored() -> PFFeedbackBusiness {
        PFFeedbackBusiness(self)
    }
}

private struct PFReporterSession: Codable, Sendable {
    let token: String
    let expiresAt: ProductFeedbackPersistenceDate
}

/// Explicit conversion avoids adding a global Codable conformance to the record.
private struct PFLocator: Codable, Sendable {
    let serverId: String
    let producerAgentId: String
    let reportId: String
    let receiptId: String
    let capturedAt: ProductFeedbackPersistenceDate
    let runtime: String
    let nativeStatus: String
    let nativeLookupMethod: String
    let nativeLocatorKind: String
    let hasServedExact: Bool
    let servedExactSha256: [String]
    let routeBasis: ProductFeedbackPersistenceNullable<String>
    let routeTarget: ProductFeedbackPersistenceNullable<String>
    let payloadSha256: String
    let createdAt: ProductFeedbackPersistenceDate

    init(_ record: FeedbackLocatorRecord) {
        serverId = record.serverId
        producerAgentId = record.producerAgentId
        reportId = record.reportId
        receiptId = record.receiptId
        capturedAt = ProductFeedbackPersistenceDate(record.capturedAt)
        runtime = record.runtime
        nativeStatus = record.nativeStatus
        nativeLookupMethod = record.nativeLookupMethod
        nativeLocatorKind = record.nativeLocatorKind
        hasServedExact = record.hasServedExact
        servedExactSha256 = record.servedExactSha256
        routeBasis = ProductFeedbackPersistenceNullable(record.routeBasis)
        routeTarget = ProductFeedbackPersistenceNullable(record.routeTarget)
        payloadSha256 = record.payloadSha256
        createdAt = ProductFeedbackPersistenceDate(record.createdAt)
    }

    func restored() -> FeedbackLocatorRecord {
        FeedbackLocatorRecord(
            serverId: serverId,
            producerAgentId: producerAgentId,
            reportId: reportId,
            receiptId: receiptId,
            capturedAt: capturedAt.value,
            runtime: runtime,
            nativeStatus: nativeStatus,
            nativeLookupMethod: nativeLookupMethod,
            nativeLocatorKind: nativeLocatorKind,
            hasServedExact: hasServedExact,
            servedExactSha256: servedExactSha256,
            routeBasis: routeBasis.value,
            routeTarget: routeTarget.value,
            payloadSha256: payloadSha256,
            createdAt: createdAt.value
        )
    }
}
