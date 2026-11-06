import Foundation

/// Product-feedback ticket surface (`/api/product-feedback/tickets…`).
///
/// The service owns the whole handler body the directory extension carried:
/// authorization order, request validation, Hands app selection, route binding,
/// the reporter bearer, the upstream relay and the cursor re-wrapping. It returns
/// a `FeedbackHandsReply` (the relayed body with its status and header policy)
/// or throws a typed `FeedbackMultiAppError`; it never builds a wire response.
///
/// The Hands transport, route binding and reporter session still live in the
/// not-yet-migrated `FeedbackService` (shared with the submission service), so
/// they enter through closures in `FeedbackMultiAppDependencies`, wired in the
/// directory accessor. The service holds no state of its own.
public struct FeedbackMultiAppService: Sendable {
    let dependencies: FeedbackMultiAppDependencies

    init(dependencies: FeedbackMultiAppDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - GET /api/product-feedback/tickets

    public func tickets(
        authorization: String?,
        clientKindHeader: String = "",
        cursor: String? = nil
    ) async throws -> FeedbackHandsReply {
        let startedAt = dependencies.now()
        let userId = try authenticate(authorization)
        let source = try resolveSource(clientKindHeader)
        let environment = try routeEnvironment(source: source, userId: userId)
        let conversationToken = environment.conversationToken.isEmpty
            ? environment.appToken
            : environment.conversationToken
        guard !environment.baseURL.isEmpty, !conversationToken.isEmpty else {
            throw FeedbackMultiAppError.routeNotFound
        }
        let reporterId = try await bind(userId: userId, environment: environment)
        let bearer = try await mintBearer(userId: userId, reporterId: reporterId, environment: environment)
        var handsCursor: String?
        if let cursor, !cursor.isEmpty {
            handsCursor = try decodeCursor(
                cursor,
                route: "ticket_list",
                userId: userId,
                ticketId: nil,
                environment: environment
            )
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback?limit=50"
        if let handsCursor {
            path += "&cursor=" + EmailLoginDirectory.feedbackPercentEncoded(handsCursor)
        }
        let upstream = await dependencies.handsRequest(
            environment, "GET", path, bearer, reporterId, [:], nil
        )
        guard upstream.status == 200 else {
            return try outcome(upstream)
        }
        return pageReply(
            upstream,
            member: "next_cursor",
            route: "ticket_list",
            userId: userId,
            ticketId: nil,
            environment: environment,
            startedAt: startedAt
        )
    }

    // MARK: - POST /api/product-feedback/tickets/:ticketId/close

    /// `request` is nil when the body did not decode; the reason check then
    /// answers the published `400`.
    public func closeTicket(
        authorization: String?,
        ticketId: String,
        request: FeedbackTicketCloseRequest?,
        clientKindHeader: String = ""
    ) async throws -> FeedbackHandsReply {
        let userId = try authenticate(authorization)
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            throw FeedbackMultiAppError.ticketNotFound
        }
        guard let request, request.reason == "completed" || request.reason == "no_longer_needed" else {
            throw FeedbackMultiAppError.closeReasonInvalid
        }
        let source = try resolveSource(clientKindHeader)
        let environment = try routeEnvironment(source: source, userId: userId)
        let reporterId = try await bind(userId: userId, environment: environment)
        let bearer = try await mintBearer(userId: userId, reporterId: reporterId, environment: environment)
        let upstream = await dependencies.handsRequest(
            environment,
            "POST",
            "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/close",
            bearer,
            reporterId,
            ["Content-Type": "application/json"],
            Data(FeedbackJSONCoding.string(request).utf8)
        )
        return try outcome(upstream)
    }

    // MARK: - POST /api/product-feedback/tickets/:ticketId/comments

    public func replyTicket(
        authorization: String?,
        ticketId: String,
        request: FeedbackTicketReplyRequest,
        clientKindHeader: String = ""
    ) async throws -> FeedbackHandsReply {
        let userId = try authenticate(authorization)
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            throw FeedbackMultiAppError.ticketNotFound
        }
        for part in request.body.components(separatedBy: "Content-Disposition: form-data") {
            guard part.contains("filename=\"") else { continue }
            let lower = part.lowercased()
            let allowed = lower.contains("content-type: image/png") || lower.contains("content-type: image/jpeg")
                || lower.contains("content-type: image/webp") || lower.contains("content-type: image/gif")
            if !allowed { throw FeedbackMultiAppError.attachmentTypeInvalid }
        }
        let source = try resolveSource(clientKindHeader)
        let environment = try routeEnvironment(source: source, userId: userId)
        let reporterId = try await bind(userId: userId, environment: environment)
        let bearer = try await mintBearer(userId: userId, reporterId: reporterId, environment: environment)
        let upstream = await dependencies.handsRequest(
            environment,
            "POST",
            "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/comments",
            bearer,
            reporterId,
            ["Content-Type": request.contentType],
            Data(request.body.utf8)
        )
        return try outcome(upstream)
    }

    // MARK: - GET /api/product-feedback/tickets/:ticketId

    public func ticket(
        authorization: String?,
        ticketId: String,
        clientKindHeader: String = "",
        commentLimit: Int = 50,
        commentCursor: String? = nil
    ) async throws -> FeedbackHandsReply {
        let startedAt = dependencies.now()
        let userId = try authenticate(authorization)
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            throw FeedbackMultiAppError.ticketNotFound
        }
        guard commentLimit >= 1, commentLimit <= 100 else {
            throw FeedbackMultiAppError.invalidRequest
        }
        let source = try resolveSource(clientKindHeader)
        let environment = try routeEnvironment(source: source, userId: userId)
        let reporterId = try await bind(userId: userId, environment: environment)
        let bearer = try await mintBearer(userId: userId, reporterId: reporterId, environment: environment)
        var handsCursor: String?
        if let commentCursor, !commentCursor.isEmpty {
            handsCursor = try decodeCursor(
                commentCursor,
                route: "ticket_comments",
                userId: userId,
                ticketId: ticketId,
                environment: environment
            )
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)?comment_limit=\(commentLimit)"
        if let handsCursor {
            path += "&comment_cursor=" + EmailLoginDirectory.feedbackPercentEncoded(handsCursor)
        }
        let upstream = await dependencies.handsRequest(
            environment, "GET", path, bearer, reporterId, [:], nil
        )
        guard upstream.status == 200 else {
            return try outcome(upstream)
        }
        return pageReply(
            upstream,
            member: "next_comment_cursor",
            route: "ticket_comments",
            userId: userId,
            ticketId: ticketId,
            environment: environment,
            startedAt: startedAt
        )
    }

    // MARK: - GET /api/product-feedback/tickets/:ticketId/attachments/:attachmentId

    public func attachment(
        authorization: String?,
        ticketId: String,
        attachmentId: String,
        clientKindHeader: String = ""
    ) async throws -> FeedbackHandsReply {
        let userId = try authenticate(authorization)
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId),
              EmailLoginDirectory.feedbackCanonicalUUID(attachmentId) else {
            throw FeedbackMultiAppError.ticketNotFound
        }
        let source = try resolveSource(clientKindHeader)
        let environment = try routeEnvironment(source: source, userId: userId)
        let reporterId = try await bind(userId: userId, environment: environment)
        let bearer = try await mintBearer(userId: userId, reporterId: reporterId, environment: environment)
        let upstream = await dependencies.handsRequest(
            environment,
            "GET",
            "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/attachments/\(attachmentId)",
            bearer,
            reporterId,
            [:],
            nil
        )
        guard upstream.status == 200 else {
            return try outcome(upstream)
        }
        return FeedbackHandsReply.attachment(body: upstream.body, upstreamHeaders: upstream.headers)
    }

    // MARK: - Shared steps

    /// A verified session: `401` without a live token, `403` until the email is
    /// verified.
    private func authenticate(_ authorization: String?) throws -> String {
        guard let userId = dependencies.userId(authorization) else {
            throw FeedbackMultiAppError.unauthorized
        }
        guard dependencies.emailVerified(userId) else {
            throw FeedbackMultiAppError.accountUnverified
        }
        return userId
    }

    private func resolveSource(_ clientKindHeader: String) throws -> String {
        do {
            return try EmailLoginDirectory.feedbackSource(clientKindHeader)
        } catch {
            throw FeedbackMultiAppError.invalidRequest
        }
    }

    private func routeEnvironment(source: String, userId: String) throws -> FeedbackRouteEnvironment {
        do {
            return try dependencies.routeEnvironment(source, userId)
        } catch let failure as FeedbackRouteFailure {
            throw availabilityError(failure)
        } catch {
            throw FeedbackMultiAppError.integrationUnavailable
        }
    }

    private func bind(userId: String, environment: FeedbackRouteEnvironment) async throws -> String {
        do {
            return try await dependencies.ensureRouteBinding(userId, environment)
        } catch let failure as FeedbackRouteFailure {
            throw availabilityError(failure)
        } catch {
            throw FeedbackMultiAppError.serviceUnavailable
        }
    }

    /// Any failure minting the reporter bearer, including a configuration
    /// failure, answers the generic availability error.
    private func mintBearer(
        userId: String,
        reporterId: String,
        environment: FeedbackRouteEnvironment
    ) async throws -> String {
        do {
            return try await dependencies.bearer(userId, reporterId, environment)
        } catch {
            throw FeedbackMultiAppError.serviceUnavailable
        }
    }

    private func decodeCursor(
        _ cursor: String,
        route: String,
        userId: String,
        ticketId: String?,
        environment: FeedbackRouteEnvironment
    ) throws -> String {
        guard !environment.cursorSecret.isEmpty else { throw FeedbackMultiAppError.invalidRequest }
        do {
            return try EmailLoginDirectory.feedbackDecodeCursor(
                cursor,
                route: route,
                userId: userId,
                ticketId: ticketId,
                cursorKey: environment.cursorSecret
            )
        } catch {
            throw FeedbackMultiAppError.invalidRequest
        }
    }

    /// Typed projection of a Hands route failure, including the warning the
    /// legacy availability reply wrote before choosing the status.
    private func availabilityError(_ failure: FeedbackRouteFailure) -> FeedbackMultiAppError {
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

    /// The upstream outcome of a conversation call: `200`/`201` are relayed, the
    /// rest map to the published feedback errors.
    private func outcome(
        _ upstream: (status: Int, headers: [String: String], body: Data)
    ) throws -> FeedbackHandsReply {
        switch upstream.status {
        case 200, 201:
            return FeedbackHandsReply.relayed(status: UInt(upstream.status), body: upstream.body)
        case 400:
            throw FeedbackMultiAppError.invalidRequest
        case 404:
            throw FeedbackMultiAppError.ticketNotFound
        case 409:
            throw FeedbackMultiAppError.commentConflict
        case 429:
            let retryAfter = upstream.headers.first { $0.key.lowercased() == "retry-after" }?.value ?? "60"
            throw FeedbackMultiAppError.rateLimited(retryAfter: retryAfter)
        case 401, 403:
            throw FeedbackMultiAppError.integrationUnavailable
        default:
            throw FeedbackMultiAppError.serviceUnavailable
        }
    }

    /// A `200` list/detail page: the cursor member is re-wrapped for the caller
    /// when the app has a cursor secret, and `Server-Timing` is added.
    private func pageReply(
        _ upstream: (status: Int, headers: [String: String], body: Data),
        member: String,
        route: String,
        userId: String,
        ticketId: String?,
        environment: FeedbackRouteEnvironment,
        startedAt: Date
    ) -> FeedbackHandsReply {
        var body = String(decoding: upstream.body, as: UTF8.self)
        if !environment.cursorSecret.isEmpty,
           let rewritten = FeedbackCursorRewrite.rewrite(body: upstream.body, member: member, wrap: { next in
               EmailLoginDirectory.feedbackEncodeCursor(
                   route: route,
                   userId: userId,
                   ticketId: ticketId,
                   handsCursor: next,
                   cursorKey: environment.cursorSecret
               )
           }) {
            body = rewritten
        }
        let elapsedMs = dependencies.now().timeIntervalSince(startedAt) * 1000
        return FeedbackHandsReply.timed(
            body: body,
            serverTiming: EmailLoginDirectory.feedbackTimingHeader(
                elapsedMs: elapsedMs,
                upstreamHeaders: upstream.headers
            )
        )
    }
}

// MARK: - Errors

/// One domain failure for the ticket routes. Every case names the published
/// status, body and header set; the feature layer only projects it.
public enum FeedbackMultiAppError: DomainError, Equatable {
    case unauthorized
    case accountUnverified
    case invalidRequest
    case closeReasonInvalid
    case attachmentTypeInvalid
    case ticketNotFound
    /// `{"error":"Not found"}`: the list route when the app has no credentials.
    case routeNotFound
    case commentConflict
    case rateLimited(retryAfter: String)
    case integrationUnavailable
    case integrationUnavailableRetryable(retryAfter: String)
    case serviceUnavailable

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .accountUnverified:
            403
        case .invalidRequest, .closeReasonInvalid, .attachmentTypeInvalid:
            400
        case .ticketNotFound, .routeNotFound:
            404
        case .commentConflict:
            409
        case .rateLimited:
            429
        case .integrationUnavailable, .integrationUnavailableRetryable, .serviceUnavailable:
            503
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .accountUnverified:
            "Email verification required"
        case .invalidRequest:
            "Invalid feedback request"
        case .closeReasonInvalid:
            "Feedback close reason is invalid"
        case .attachmentTypeInvalid:
            "Only image attachments are supported"
        case .ticketNotFound:
            "Feedback ticket not found"
        case .routeNotFound:
            "Not found"
        case .commentConflict:
            "This comment retry does not match the original submission"
        case .rateLimited:
            "Too many feedback requests. Please try again later."
        case .integrationUnavailable, .integrationUnavailableRetryable, .serviceUnavailable:
            "Feedback service is temporarily unavailable"
        }
    }

    public var errorCode: String? {
        switch self {
        case .unauthorized, .routeNotFound:
            nil
        case .accountUnverified:
            "account_unverified"
        case .invalidRequest, .closeReasonInvalid:
            "feedback_invalid"
        case .attachmentTypeInvalid:
            "feedback_attachment_type_invalid"
        case .ticketNotFound:
            "feedback_not_found"
        case .commentConflict:
            "feedback_comment_conflict"
        case .rateLimited:
            "feedback_rate_limited"
        case .integrationUnavailable, .integrationUnavailableRetryable:
            "feedback_integration_unavailable"
        case .serviceUnavailable:
            "feedback_service_unavailable"
        }
    }

    /// The retryable failures publish `Retry-After` and no robots tag; every
    /// other failure keeps the standard JSON header set.
    public var errorHeaders: ResponseHeaders {
        switch self {
        case .rateLimited(let retryAfter), .integrationUnavailableRetryable(let retryAfter):
            .exact([
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "no-store",
                "Retry-After": retryAfter,
            ])
        default:
            .standard()
        }
    }
}

// MARK: - Dependencies

/// Everything the ticket service reads from domains that have not migrated yet.
///
/// The session lookup, the account row, the Hands app selection, the route
/// binding, the reporter bearer and the transport enter as closures at the
/// composition root, so a unit test can drive the service with fakes.
struct FeedbackMultiAppDependencies: Sendable {
    typealias Upstream = (status: Int, headers: [String: String], body: Data)

    var userId: @Sendable (_ authorization: String?) -> String?
    var emailVerified: @Sendable (_ userId: String) -> Bool
    var routeEnvironment: @Sendable (_ source: String, _ userId: String) throws -> FeedbackRouteEnvironment
    var ensureRouteBinding: @Sendable (
        _ userId: String,
        _ environment: FeedbackRouteEnvironment
    ) async throws -> String
    var bearer: @Sendable (
        _ userId: String,
        _ reporterId: String,
        _ environment: FeedbackRouteEnvironment
    ) async throws -> String
    var handsRequest: @Sendable (
        _ environment: FeedbackRouteEnvironment,
        _ method: String,
        _ path: String,
        _ bearer: String,
        _ reporterId: String,
        _ headers: [String: String],
        _ body: Data?
    ) async -> Upstream
    var warn: @Sendable (_ message: String) -> Void
    var now: @Sendable () -> Date

    init(
        userId: @escaping @Sendable (String?) -> String?,
        emailVerified: @escaping @Sendable (String) -> Bool,
        routeEnvironment: @escaping @Sendable (String, String) throws -> FeedbackRouteEnvironment,
        ensureRouteBinding: @escaping @Sendable (String, FeedbackRouteEnvironment) async throws -> String,
        bearer: @escaping @Sendable (String, String, FeedbackRouteEnvironment) async throws -> String,
        handsRequest: @escaping @Sendable (
            FeedbackRouteEnvironment, String, String, String, String, [String: String], Data?
        ) async -> Upstream,
        warn: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.userId = userId
        self.emailVerified = emailVerified
        self.routeEnvironment = routeEnvironment
        self.ensureRouteBinding = ensureRouteBinding
        self.bearer = bearer
        self.handsRequest = handsRequest
        self.warn = warn
        self.now = now
    }
}
