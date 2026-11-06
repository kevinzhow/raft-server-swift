import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftShared

/// Product-feedback submissions (`POST /api/product-feedback`) and the
/// onboarding-wizard product event (`POST /api/product-events/onboarding-wizard`).
///
/// The service owns the whole handler body the legacy
/// directory extension carried: authorization order, multipart and
/// metadata validation, attribution, the Hands route selection, the multipart
/// upload and the upstream-outcome mapping. It returns a `Codable` receipt or
/// throws a typed `ProductFeedbackSubmissionError`; it never builds an
/// wire response, a header set or a JSON string.
///
/// The Hands feedback transport and route binding still live in the
/// not-yet-migrated `FeedbackService`, so they enter through closures in
/// `ProductFeedbackSubmissionDependencies` (wired at the composition root).
public struct ProductFeedbackSubmissionService: Sendable {
    let dependencies: ProductFeedbackSubmissionDependencies

    init(dependencies: ProductFeedbackSubmissionDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - POST /api/product-feedback

    public func submit(_ request: ProductFeedbackSubmissionRequest) async throws -> ProductFeedbackReceipt {
        guard let userId = dependencies.userId(request.authorization) else {
            throw ProductFeedbackSubmissionError.unauthorized
        }
        let feedbackStartedAt = dependencies.now()
        guard dependencies.account(userId)?.emailVerified == true else {
            throw ProductFeedbackSubmissionError.accountUnverified
        }
        guard let fields = EmailLoginDirectory.multipartFields(body: request.body, contentType: request.contentType),
              let submissionId = fields["submission_id"],
              submissionId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil,
              let type = fields["type"], ["idea", "problem"].contains(type),
              let message = fields["message"], !message.isEmpty
        else {
            throw ProductFeedbackSubmissionError.invalidSubmission
        }
        var metadataObject: [String: JSONValue] = [:]
        if let rawMetadata = fields["metadata"], !rawMetadata.isEmpty {
            guard let metadata = Self.metadataObject(rawMetadata) else {
                throw ProductFeedbackSubmissionError.invalidSubmission
            }
            let nativeKinds = ["ios", "android", "macos", "windows", "linux"]
            if let clientKind = metadata.productFeedbackString("client_kind"),
               nativeKinds.contains(clientKind) {
                let platform = metadata.productFeedbackString("platform") ?? ""
                if platform != clientKind || metadata["browser"] != nil {
                    throw ProductFeedbackSubmissionError.invalidSubmission
                }
            }
            if let metadataKind = metadata.productFeedbackString("client_kind"),
               !EmailLoginDirectory.productFeedbackSources.contains(metadataKind) {
                throw ProductFeedbackSubmissionError.invalidSubmission
            }
            metadataObject = metadata
        }
        if let reportId = fields["feedback_report_id"], !reportId.isEmpty {
            guard reportId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
                throw ProductFeedbackSubmissionError.invalidSubmission
            }
            metadataObject["feedback_report_id"] = .string(reportId.lowercased())
            metadataObject["surface"] = .string("agent.report_issue")
        }
        let trustedClientKind: String
        do {
            trustedClientKind = try EmailLoginDirectory.feedbackSource(request.clientKindHeader)
        } catch {
            throw ProductFeedbackSubmissionError.invalidSubmission
        }
        if let metadataKind = metadataObject.productFeedbackString("client_kind"),
           metadataKind != trustedClientKind {
            throw ProductFeedbackSubmissionError.invalidSubmission
        }
        let clientKind = metadataObject.productFeedbackString("client_kind")
        if let clientKind, EmailLoginDirectory.productFeedbackSources.contains(clientKind), clientKind != "web" {
            var forwarded: [String: JSONValue] = [
                "client_kind": .string(clientKind),
                "platform": .string(metadataObject.productFeedbackString("platform") ?? clientKind),
                "product_type": .string(clientKind),
                "feedback_type": .string(type),
                "contact_consent": .bool(fields["may_contact"] == "true"),
            ]
            for key in ["client_version", "locale", "os_version"] {
                if let value = metadataObject[key] { forwarded[key] = value }
            }
            metadataObject = forwarded
        } else {
            for key in ["browser", "viewport", "web_version", "userId", "reporterId", "baseUrl", "appToken"] {
                metadataObject.removeValue(forKey: key)
            }
        }
        if let attribution = dependencies.resolveAttribution(request.serverId, userId) {
            metadataObject["reporter_attribution"] = .object([
                "v": .integer(1),
                "server_id": .string(request.serverId),
                "server_slug": .string(attribution.serverSlug),
                "user_id": .string(userId),
                "handle": .string(attribution.handle),
            ])
        }
        let configuration = dependencies.configuration()
        guard configuration.configured || configuration.environment["HANDS_FEEDBACK_BASE_URL"] != nil else {
            throw ProductFeedbackSubmissionError.notConfigured
        }
        let multiEnabled = dependencies.multiAppEnabled(userId)
        let routeEnvironment: FeedbackRouteEnvironment
        if multiEnabled {
            do {
                routeEnvironment = try dependencies.multiRouteEnvironment(
                    trustedClientKind,
                    configuration.appsJSON,
                    configuration.environment
                )
            } catch let failure as FeedbackRouteFailure {
                throw availabilityError(failure)
            } catch {
                throw ProductFeedbackSubmissionError.integrationUnavailable
            }
        } else {
            routeEnvironment = dependencies.legacyRouteEnvironment(configuration.environment)
        }
        let reporterId: String
        do {
            reporterId = try await dependencies.ensureRouteBinding(userId, routeEnvironment)
        } catch let failure as FeedbackRouteFailure {
            throw availabilityError(failure)
        } catch {
            throw ProductFeedbackSubmissionError.serviceUnavailable
        }
        var presignedJSON: String?
        if let rawDiagnostics = fields["diagnostics"], !rawDiagnostics.isEmpty {
            guard let native = clientKind, ["android", "ios", "ohos"].contains(native),
                  let diagnostics = EmailLoginDirectory.validatedFeedbackDiagnostics(rawDiagnostics, appId: routeEnvironment.appId)
            else {
                throw ProductFeedbackSubmissionError.diagnosticsInvalid
            }
            presignedJSON = "[\("\(diagnostics)")]"
        }
        let appSlug = routeEnvironment.appSlug.isEmpty ? routeEnvironment.appId : routeEnvironment.appSlug
        guard !routeEnvironment.baseURL.isEmpty, !appSlug.isEmpty else {
            throw ProductFeedbackSubmissionError.notConfigured
        }
        let boundary = "raft-boundary-\(dependencies.makeUUID())"
        var multipart = Data()
        func appendField(_ name: String, _ value: String) {
            multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("type", type)
        appendField("message", message)
        appendField("submission_id", submissionId)
        appendField("metadata", ProductFeedbackMetadataJSON.string(metadataObject))
        if let contact = fields["may_contact"] { appendField("may_contact", contact) }
        if let presignedJSON { appendField("presigned", presignedJSON) }
        multipart.append(Data("--\(boundary)--\r\n".utf8))
        var upstreamRequest = URLRequest(url: URL(string: "\(routeEnvironment.baseURL)/public/v2/apps/\(appSlug)/feedback")!)
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.timeoutInterval = 10
        upstreamRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let bearerToken = routeEnvironment.appToken.isEmpty
            ? configuration.environment["HANDS_FEEDBACK_APP_TOKEN"] ?? ""
            : routeEnvironment.appToken
        if !bearerToken.isEmpty {
            upstreamRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if !routeEnvironment.clientKey.isEmpty {
            upstreamRequest.setValue(routeEnvironment.clientKey, forHTTPHeaderField: "X-Hands-Client-Key")
        }
        if !routeEnvironment.reporterIdSecret.isEmpty {
            upstreamRequest.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        }
        upstreamRequest.httpBody = multipart
        let upstream = await dependencies.send(upstreamRequest)
        return try Self.receipt(
            upstreamStatus: upstream.0,
            upstreamHeaders: upstream.1,
            upstreamBody: upstream.2,
            presignedJSON: presignedJSON,
            feedbackStartedAt: feedbackStartedAt,
            now: dependencies.now(),
            makeUUID: dependencies.makeUUID
        )
    }

    // MARK: - POST /api/product-events/onboarding-wizard

    public func recordOnboardingWizard(
        authorization: String?,
        serverId: String,
        body: ProductEventOnboardingWizardRequest
    ) throws -> NoContentResponse {
        guard let userId = dependencies.userId(authorization) else {
            throw ProductFeedbackSubmissionError.unauthorized
        }
        guard let serverEnabled = dependencies.serverAnalyticsAllowed(serverId), serverEnabled else {
            return NoContentResponse()
        }
        guard dependencies.account(userId)?.shareUsageData != false else {
            return NoContentResponse()
        }
        guard let eventType = body.eventType, !eventType.isEmpty,
              let rawMetadata = body.metadata
        else {
            throw ProductFeedbackSubmissionError.invalidProductEvent
        }
        let stepId = rawMetadata.productFeedbackString("step_id") ?? ""
        if eventType == "onboarding_wizard.step_shown", stepId == "enable-notifications" {
            throw ProductFeedbackSubmissionError.untrackedOnboardingStep
        }
        let allowedKeys = ["step_id", "wizard_version", "session_id", "action", "result", "reason"]
        var sanitized: [String: JSONValue] = [:]
        for key in allowedKeys {
            if let value = rawMetadata.productFeedbackString(key) { sanitized[key] = .string(value) }
        }
        if let latency = rawMetadata["latency_ms"] {
            switch latency {
            case .number(let value):
                sanitized["latency_ms"] = .integer(Int64(value))
            case .integer(let value):
                sanitized["latency_ms"] = .integer(value)
            case .bool(let value):
                // The retired NSNumber bridge read a JSON boolean as 1/0.
                sanitized["latency_ms"] = .integer(value ? 1 : 0)
            default:
                break
            }
        }
        dependencies.appendProductEvent(RecordedProductEvent(
            subjectType: "onboarding_wizard",
            subjectId: serverId,
            eventType: eventType,
            actorType: "human",
            actorId: userId,
            source: "web",
            idempotencyKey: body.idempotencyKey,
            metadataJSON: ProductFeedbackMetadataJSON.string(sanitized)
        ))
        return NoContentResponse()
    }

    // MARK: - Upstream outcome mapping

    /// `sendProductFeedback`'s receipt/error mapping, moved verbatim from the
    /// legacy `feedbackSubmissionReply`.
    private static func receipt(
        upstreamStatus: Int,
        upstreamHeaders: [String: String],
        upstreamBody: Data,
        presignedJSON: String?,
        feedbackStartedAt: Date,
        now: Date,
        makeUUID: @Sendable () -> String
    ) throws -> ProductFeedbackReceipt {
        let upstreamJSON = Self.metadataObject(upstreamBody)
        let upstreamCode = upstreamJSON?.productFeedbackString("code")
        if upstreamStatus == 201 || upstreamStatus == 200 {
            let id = upstreamJSON?.productFeedbackString("id") ?? makeUUID()
            let status = upstreamJSON?.productFeedbackString("status") ?? "open"
            return ProductFeedbackReceipt(
                id: id,
                status: status,
                serverTiming: EmailLoginDirectory.feedbackTimingHeader(
                    elapsedMs: now.timeIntervalSince(feedbackStartedAt) * 1000,
                    upstreamHeaders: upstreamHeaders
                )
            )
        }
        if upstreamStatus == 409 {
            throw ProductFeedbackSubmissionError.submissionConflict
        }
        if upstreamStatus == 400, presignedJSON != nil,
           let upstreamCode, ["presigned_invalid", "presigned_not_found", "presigned_size_mismatch"].contains(upstreamCode) {
            throw ProductFeedbackSubmissionError.diagnosticsRejected
        }
        if upstreamStatus == 400 {
            throw ProductFeedbackSubmissionError.invalidSubmission
        }
        if upstreamStatus == 401 || upstreamStatus == 403 {
            throw ProductFeedbackSubmissionError.integrationUnavailableForUpstream(
                status: upstreamStatus,
                error: EmailLoginDirectory.feedbackUpstreamError(upstreamJSON?.productFeedbackString("error"))
            )
        }
        if upstreamStatus == 413 {
            throw ProductFeedbackSubmissionError.attachmentTooLarge
        }
        if upstreamStatus == 429 {
            let retryAfter = upstreamHeaders.first { $0.key.lowercased() == "retry-after" }?.value ?? "60"
            throw ProductFeedbackSubmissionError.rateLimited(retryAfter: retryAfter)
        }
        throw ProductFeedbackSubmissionError.serviceUnavailable
    }

    /// Typed projection of a Hands route failure, including the warn sink the
    /// legacy `feedbackAvailabilityReply` wrote before choosing the status.
    private func availabilityError(_ failure: FeedbackRouteFailure) -> ProductFeedbackSubmissionError {
        switch failure {
        case .invalidSource:
            return .invalidRequest
        case .sourceUnavailable(let source, let reason):
            dependencies.warn("[product-feedback] source unavailable (\(source): \(reason))")
            return .integrationUnavailable
        case .routeBinding(let reason):
            dependencies.warn("[product-feedback] route binding failed (\(reason))")
            return .integrationUnavailableRetryable(retryAfter: "5")
        case .configuration:
            return .integrationUnavailable
        }
    }

    /// The retired raw object read: a JSON object decodes to
    /// `[String: JSONValue]`, anything else reads as absent.
    private static func metadataObject(_ raw: String) -> [String: JSONValue]? {
        Self.metadataObject(Data(raw.utf8))
    }

    private static func metadataObject(_ data: Data) -> [String: JSONValue]? {
        try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}

/// One domain failure for the submission and onboarding-wizard operations.
///
/// Every case names the published status, body and header set. The feature
/// layer only projects it, so the service never builds a wire reply.
public enum ProductFeedbackSubmissionError: OrderedBodyDomainError, Equatable {
    case unauthorized
    case accountUnverified
    case invalidSubmission
    case invalidRequest
    case diagnosticsInvalid
    case diagnosticsRejected
    case submissionConflict
    case attachmentTooLarge
    case rateLimited(retryAfter: String)
    case notConfigured
    case integrationUnavailable
    case integrationUnavailableRetryable(retryAfter: String)
    case integrationUnavailableForUpstream(status: Int, error: String)
    case serviceUnavailable
    case invalidProductEvent
    case untrackedOnboardingStep

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .accountUnverified:
            403
        case .invalidSubmission, .invalidRequest, .diagnosticsInvalid, .diagnosticsRejected,
             .invalidProductEvent, .untrackedOnboardingStep:
            400
        case .submissionConflict:
            409
        case .attachmentTooLarge:
            413
        case .rateLimited:
            429
        case .notConfigured, .integrationUnavailable, .integrationUnavailableRetryable,
             .integrationUnavailableForUpstream, .serviceUnavailable:
            503
        }
    }

    public var bodyJSON: String {
        envelope.bodyJSON
    }

    public var responseHeaders: [String: String] {
        switch self {
        case .rateLimited(let retryAfter), .integrationUnavailableRetryable(let retryAfter):
            return [
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "no-store",
                "Retry-After": retryAfter,
            ]
        default:
            return [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
            ]
        }
    }

    private var envelope: ProductFeedbackErrorEnvelope {
        switch self {
        case .unauthorized:
            ProductFeedbackErrorEnvelope(error: "Unauthorized")
        case .accountUnverified:
            ProductFeedbackErrorEnvelope(error: "Email verification required", code: "account_unverified")
        case .invalidSubmission:
            ProductFeedbackErrorEnvelope(error: "Invalid feedback submission", code: "feedback_invalid")
        case .invalidRequest:
            ProductFeedbackErrorEnvelope(error: "Invalid feedback request", code: "feedback_invalid")
        case .diagnosticsInvalid:
            ProductFeedbackErrorEnvelope(error: "Invalid feedback diagnostics", code: "feedback_diagnostics_invalid")
        case .diagnosticsRejected:
            ProductFeedbackErrorEnvelope(error: "The diagnostics upload was rejected", code: "feedback_diagnostics_rejected")
        case .submissionConflict:
            ProductFeedbackErrorEnvelope(error: "This submission was already sent", code: "feedback_submission_conflict")
        case .attachmentTooLarge:
            ProductFeedbackErrorEnvelope(error: "Feedback attachment is too large", code: "feedback_attachment_too_large")
        case .rateLimited:
            ProductFeedbackErrorEnvelope(error: "Feedback is rate limited", code: "feedback_rate_limited")
        case .notConfigured:
            ProductFeedbackErrorEnvelope(
                error: "Feedback service is temporarily unavailable",
                code: "feedback_not_configured"
            )
        case .integrationUnavailable, .integrationUnavailableRetryable:
            ProductFeedbackErrorEnvelope(
                error: "Feedback service is temporarily unavailable",
                code: "feedback_integration_unavailable"
            )
        case .integrationUnavailableForUpstream(let status, let error):
            ProductFeedbackErrorEnvelope(
                error: "Feedback integration is temporarily unavailable",
                code: "feedback_integration_unavailable",
                upstreamStatus: status,
                upstreamError: error
            )
        case .serviceUnavailable:
            ProductFeedbackErrorEnvelope(
                error: "Feedback service is temporarily unavailable",
                code: "feedback_service_unavailable"
            )
        case .invalidProductEvent:
            ProductFeedbackErrorEnvelope(error: "Invalid product event")
        case .untrackedOnboardingStep:
            ProductFeedbackErrorEnvelope(error: "Only tracked onboarding wizard steps are accepted")
        }
    }
}

// MARK: - Dependencies

/// One atomic snapshot of the Hands feedback configuration rows.
struct ProductFeedbackRelayConfiguration: Sendable {
    var environment: [String: String]
    var appsJSON: String?
    var configured: Bool
}

/// Everything the submission service reads from domains that have not migrated
/// yet.
///
/// The account row, the Hands transport/route-binding plumbing (still owned by
/// `FeedbackService`), the feature-flag decision and product-event storage are
/// injected at the composition root. The service holds no directory state and
/// no directory call site; a unit test can drive it with fakes.
struct ProductFeedbackSubmissionDependencies: Sendable {
    var account: @Sendable (_ userId: String) -> Account?
    var userId: @Sendable (_ authorization: String?) -> String?
    var resolveAttribution: @Sendable (_ serverId: String, _ userId: String) -> ProductFeedbackReporterAttribution?
    var multiAppEnabled: @Sendable (_ userId: String) -> Bool
    var configuration: @Sendable () -> ProductFeedbackRelayConfiguration
    var multiRouteEnvironment: @Sendable (
        _ source: String,
        _ appsJSON: String?,
        _ environment: [String: String]
    ) throws -> FeedbackRouteEnvironment
    var legacyRouteEnvironment: @Sendable (_ environment: [String: String]) -> FeedbackRouteEnvironment
    var ensureRouteBinding: @Sendable (
        _ userId: String,
        _ environment: FeedbackRouteEnvironment
    ) async throws -> String
    var send: @Sendable (_ request: URLRequest) async -> (Int, [String: String], Data)
    var warn: @Sendable (_ message: String) -> Void
    var appendProductEvent: @Sendable (_ event: RecordedProductEvent) -> Void
    var serverAnalyticsAllowed: @Sendable (_ serverId: String) -> Bool?
    var now: @Sendable () -> Date
    var makeUUID: @Sendable () -> String

    init(
        account: @escaping @Sendable (String) -> Account?,
        userId: @escaping @Sendable (String?) -> String?,
        resolveAttribution: @escaping @Sendable (String, String) -> ProductFeedbackReporterAttribution?,
        multiAppEnabled: @escaping @Sendable (String) -> Bool,
        configuration: @escaping @Sendable () -> ProductFeedbackRelayConfiguration,
        multiRouteEnvironment: @escaping @Sendable (String, String?, [String: String]) throws -> FeedbackRouteEnvironment,
        legacyRouteEnvironment: @escaping @Sendable ([String: String]) -> FeedbackRouteEnvironment,
        ensureRouteBinding: @escaping @Sendable (String, FeedbackRouteEnvironment) async throws -> String,
        send: @escaping @Sendable (URLRequest) async -> (Int, [String: String], Data),
        warn: @escaping @Sendable (String) -> Void,
        appendProductEvent: @escaping @Sendable (RecordedProductEvent) -> Void,
        serverAnalyticsAllowed: @escaping @Sendable (String) -> Bool?,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.account = account
        self.userId = userId
        self.resolveAttribution = resolveAttribution
        self.multiAppEnabled = multiAppEnabled
        self.configuration = configuration
        self.multiRouteEnvironment = multiRouteEnvironment
        self.legacyRouteEnvironment = legacyRouteEnvironment
        self.ensureRouteBinding = ensureRouteBinding
        self.send = send
        self.warn = warn
        self.appendProductEvent = appendProductEvent
        self.serverAnalyticsAllowed = serverAnalyticsAllowed
        self.now = now
        self.makeUUID = makeUUID
    }
}
