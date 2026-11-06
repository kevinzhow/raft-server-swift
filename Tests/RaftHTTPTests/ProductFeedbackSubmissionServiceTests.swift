import Foundation
import Testing
@testable import RaftHTTP
import TestSupport

/// The submission service's own contracts: the exact legacy error bytes, the
/// onboarding opt-out short-circuit (one store append, none when opted out) and
/// the authorization-before-configuration order. The HTTP route tests lock the
/// wire status/header projection.

private let unusedRouteEnvironment = FeedbackRouteEnvironment(
    baseURL: "",
    appSlug: "",
    appId: "",
    clientKey: "",
    appToken: "",
    conversationToken: "",
    credentialRevision: "",
    reporterIntegrationId: "",
    reporterIdSecret: "",
    routeSubjectKeyId: "v1",
    routeSubjectRoot: "",
    routeCommitmentScope: "",
    cursorSecret: "",
    conversationSessionEnabled: false,
    isMultiApp: false
)

private func dependencies(
    account: @escaping @Sendable (String) -> Account?,
    userId: @escaping @Sendable (String?) -> String?,
    serverAnalyticsAllowed: @escaping @Sendable (String) -> Bool? = { _ in true },
    appendProductEvent: @escaping @Sendable (RecordedProductEvent) -> Void = { _ in },
    configuration: @escaping @Sendable () -> ProductFeedbackRelayConfiguration = {
        ProductFeedbackRelayConfiguration(environment: [:], appsJSON: nil, configured: true)
    }
) -> ProductFeedbackSubmissionDependencies {
    ProductFeedbackSubmissionDependencies(
        account: account,
        userId: userId,
        resolveAttribution: { _, _ in nil },
        multiAppEnabled: { _ in false },
        configuration: configuration,
        multiRouteEnvironment: { _, _, _ in unusedRouteEnvironment },
        legacyRouteEnvironment: { _ in unusedRouteEnvironment },
        ensureRouteBinding: { userId, _ in userId },
        send: { _ in (0, [:], Data()) },
        warn: { _ in },
        appendProductEvent: appendProductEvent,
        serverAnalyticsAllowed: serverAnalyticsAllowed,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        makeUUID: { "00000000-0000-4000-8000-000000000000" }
    )
}

@Test func productFeedbackErrorBodyKeepsTheLegacyKeyOrderAndEscaping() {
    #expect(
        ProductFeedbackSubmissionError.integrationUnavailableForUpstream(status: 403, error: "a/b\tc")
            .errorBody?.render()
            == #"{"error":"Feedback integration is temporarily unavailable","code":"feedback_integration_unavailable","upstream_status":403,"upstream_error":"a/b\tc"}"#
    )
    #expect(
        ProductFeedbackSubmissionError.integrationUnavailableForUpstream(status: 401, error: "x\ny")
            .errorBody?.render()
            == #"{"error":"Feedback integration is temporarily unavailable","code":"feedback_integration_unavailable","upstream_status":401,"upstream_error":"x\ny"}"#
    )
    #expect(
        ProductFeedbackSubmissionError.unauthorized.errorBody?.render()
            == #"{"error":"Unauthorized"}"#
    )
    #expect(
        ProductFeedbackSubmissionError.rateLimited(retryAfter: "60").errorBody?.render()
            == #"{"error":"Feedback is rate limited","code":"feedback_rate_limited"}"#
    )
    #expect(ProductFeedbackSubmissionError.accountUnverified.status == 403)
    #expect(
        ProductFeedbackSubmissionError.rateLimited(retryAfter: "60").errorHeaders
            == .exact([
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "no-store",
                "Retry-After": "60",
            ])
    )
    #expect(ProductFeedbackSubmissionError.invalidSubmission.errorHeaders == .standard())
}

@Test func onboardingWizardOptOutReturnsTheAckWithoutAppending() throws {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001107101"
    let serverId = "33333333-3333-4333-8333-000001107101"
    directory.addAccount(id: userId, email: "service-optout@feedback.test", password: "password123")
    directory.setShareUsageData(userId: userId, value: false)
    let store = ProductEventStore()
    let service = ProductFeedbackSubmissionService(dependencies: dependencies(
        account: { directory.authProfileStore.account(userId: $0) },
        userId: { _ in userId },
        appendProductEvent: { store.append($0) }
    ))

    let ack = try service.recordOnboardingWizard(
        authorization: "Bearer token",
        serverId: serverId,
        body: ProductEventOnboardingWizardRequest(
            eventType: "onboarding_wizard.step_shown",
            metadata: ["step_id": .string("create-agent")]
        )
    )
    #expect(ack == NoContentResponse())
    #expect(store.productEvents(subjectId: serverId).isEmpty)
}

@Test func onboardingWizardAppendsOneSanitizedRow() throws {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001107102"
    let serverId = "33333333-3333-4333-8333-000001107102"
    directory.addAccount(id: userId, email: "service-record@feedback.test", password: "password123")
    directory.setShareUsageData(userId: userId, value: true)
    let store = ProductEventStore()
    let service = ProductFeedbackSubmissionService(dependencies: dependencies(
        account: { directory.authProfileStore.account(userId: $0) },
        userId: { _ in userId },
        appendProductEvent: { store.append($0) }
    ))

    _ = try service.recordOnboardingWizard(
        authorization: "Bearer token",
        serverId: serverId,
        body: ProductEventOnboardingWizardRequest(
            eventType: "onboarding_wizard.primary_clicked",
            idempotencyKey: "onboarding-service-test",
            metadata: [
                "step_id": .string("referral-source"),
                "wizard_version": .string("owner-wizard-v3"),
                "session_id": .string("session-123"),
                "action": .string("submit_referral"),
                "result": .string("twitter_x"),
                "reason": .string("ignored-but-allowed"),
                "latency_ms": .number(123.4),
                "raw_text": .string("must not be stored"),
            ]
        )
    )
    let rows = store.productEvents(subjectId: serverId)
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.subjectType == "onboarding_wizard")
    #expect(row.actorType == "human")
    #expect(row.actorId == userId)
    #expect(row.source == "web")
    #expect(row.idempotencyKey == "onboarding-service-test")
    #expect(
        row.metadataJSON
            == #"{"action":"submit_referral","latency_ms":123,"reason":"ignored-but-allowed","result":"twitter_x","session_id":"session-123","step_id":"referral-source","wizard_version":"owner-wizard-v3"}"#
    )
}

@Test func submitChecksAuthorizationAndVerificationBeforeReadingConfiguration() async throws {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001107103"
    directory.addAccount(id: userId, email: "service-order@feedback.test", password: "password123")
    let reads = Counter()
    let service = ProductFeedbackSubmissionService(dependencies: dependencies(
        account: { directory.authProfileStore.account(userId: $0) },
        userId: { authorization in authorization == "Bearer token" ? userId : nil },
        configuration: {
            reads.increment()
            return ProductFeedbackRelayConfiguration(environment: [:], appsJSON: nil, configured: true)
        }
    ))
    let body = ProductFeedbackSubmissionRequest(
        authorization: nil,
        contentType: "multipart/form-data; boundary=x",
        body: "--x\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\nidea\r\n--x--\r\n",
        serverId: ""
    )
    await #expect(throws: ProductFeedbackSubmissionError.unauthorized) {
        try await service.submit(body)
    }
    #expect(reads.count == 0)

    let unverified = ProductFeedbackSubmissionRequest(
        authorization: "Bearer token",
        contentType: body.contentType,
        body: body.body,
        serverId: ""
    )
    await #expect(throws: ProductFeedbackSubmissionError.accountUnverified) {
        try await service.submit(unverified)
    }
    #expect(reads.count == 0)
}
