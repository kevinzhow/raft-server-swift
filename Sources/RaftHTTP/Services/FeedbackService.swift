import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asynchronous transport for the upstream Hands product-feedback API plus the
/// shared configuration, route-binding and conversation plumbing.
///
/// The feedback handlers run on Vapor's concurrency pool. `URLSession` is
/// bridged with `withCheckedContinuation` so a request never parks a worker
/// thread on a semaphore; the 12 s ceiling is enforced by the request timeout
/// and a watchdog task that resumes the continuation exactly once.
///
/// The directory owns the feedback ledger and the injected transport slot; the
/// public `…Async` ticket entry points live in `FeedbackMultiAppService`.
public struct FeedbackService: Sendable {
    public typealias UpstreamResponse = (status: Int, headers: [String: String], body: Data)
    public typealias InjectedTransport = (URLRequest) -> UpstreamResponse

    /// Mirrors the old `semaphore.wait(timeout: .now() + 12)` ceiling.
    public static let requestTimeout: TimeInterval = 12

    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// Sends `request` upstream.
    ///
    /// When a test seam is installed (`injected`), it answers synchronously and
    /// no `URLSession` work is scheduled. Otherwise the request is executed
    /// asynchronously; transport failures and the timeout produce the same
    /// zero status the synchronous implementation reported.
    public func sendUpstreamRequest(
        _ request: URLRequest,
        injected: InjectedTransport? = nil
    ) async -> UpstreamResponse {
        if let injected {
            return injected(request)
        }
        var prepared = request
        if prepared.timeoutInterval <= 0 || prepared.timeoutInterval > Self.requestTimeout {
            prepared.timeoutInterval = Self.requestTimeout
        }

        return await withCheckedContinuation { continuation in
            let box = UpstreamContinuationBox(continuation: continuation)
            let taskBox = DataTaskBox()
            let task = URLSession.shared.dataTask(with: prepared) { data, response, _ in
                var status = 0
                var headers: [String: String] = [:]
                if let http = response as? HTTPURLResponse {
                    status = http.statusCode
                    for (key, value) in http.allHeaderFields {
                        headers[String(describing: key)] = String(describing: value)
                    }
                }
                box.resume((status, headers, data ?? Data()))
            }
            taskBox.task = task
            // Install the watchdog before starting the task so a very fast
            // response can still cancel it.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Self.requestTimeout))
                if box.resume((0, [:], Data())) {
                    taskBox.task?.cancel()
                }
            }
            box.install(timeoutTask: watchdog)
            task.resume()
        }
    }

    // MARK: - Transport seams

    /// Synchronous compatibility entry point for the extracted route tests.
    ///
    /// Production feedback routes call `sendAsync`; this overload exists because
    /// a few test helpers still mount synchronous route closures. It never parks
    /// a thread on `URLSession`: an injected seam answers immediately, and a
    /// caller without a seam gets the same zero status the timed-out transport
    /// used to produce.
    func send(_ request: URLRequest) -> UpstreamResponse {
        let injected = locked { directory.handsFeedbackUpstreamHandler }
        if let injected { return injected(request) }
        return (0, [:], Data())
    }

    /// Async transport used by every production feedback route.
    func sendAsync(_ request: URLRequest) async -> UpstreamResponse {
        let injected = locked { directory.handsFeedbackUpstreamHandler }
        return await sendUpstreamRequest(request, injected: injected)
    }

    /// `NSLock.lock()`/`unlock()` are `noasync`; async entry points run their
    /// critical sections through this synchronous scoped helper instead.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return try body()
    }

    // MARK: - Warning sink

    func warn(_ message: String) {
        let sink = locked { directory.handsFeedbackWarningSink }
        if let sink {
            sink(message)
        } else {
            print(message)
        }
    }

    // MARK: - Configuration resolution

    func legacyEnvironmentLocked() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let overlay = directory.handsFeedbackLegacyEnvironment {
            for (key, value) in overlay { environment[key] = value }
        }
        if let handsFeedbackBaseURLOverride = directory.handsFeedbackBaseURLOverride {
            environment["HANDS_FEEDBACK_BASE_URL"] = handsFeedbackBaseURLOverride
        }
        if let handsFeedbackAppIdOverride = directory.handsFeedbackAppIdOverride {
            environment["HANDS_FEEDBACK_APP_ID"] = handsFeedbackAppIdOverride
        }
        if let handsFeedbackAppSlugOverride = directory.handsFeedbackAppSlugOverride {
            environment["HANDS_FEEDBACK_APP_SLUG"] = handsFeedbackAppSlugOverride
        }
        if let handsFeedbackAppTokenOverride = directory.handsFeedbackAppTokenOverride {
            environment["HANDS_FEEDBACK_APP_TOKEN"] = handsFeedbackAppTokenOverride
        }
        if let handsConversationSessionEnabled = directory.handsConversationSessionEnabled {
            environment["HANDS_FEEDBACK_CONVERSATION_SESSION_ENABLED"] = handsConversationSessionEnabled ? "true" : "false"
        }
        if let handsConversationAppTokenOverride = directory.handsConversationAppTokenOverride {
            environment["HANDS_FEEDBACK_CONVERSATION_APP_TOKEN"] = handsConversationAppTokenOverride
        }
        return environment
    }

    func routeEnvironment(source: String, userId: String) throws -> FeedbackRouteEnvironment {
        guard EmailLoginDirectory.productFeedbackSources.contains(source) else {
            throw FeedbackRouteFailure.invalidSource
        }
        directory.lock.lock()
        let environment = legacyEnvironmentLocked()
        let appsJSON = directory.handsFeedbackAppsJSON
        directory.lock.unlock()
        let multiEnabled = directory.evaluateFeatureFlagKey(
            key: EmailLoginDirectory.productFeedbackMultiAppFlag,
            userId: userId,
            serverId: nil,
            platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        ).enabled
        if !multiEnabled { return EmailLoginDirectory.feedbackLegacyRouteEnvironment(environment) }
        return try EmailLoginDirectory.feedbackMultiRouteEnvironment(
            source: source,
            appsJSON: appsJSON,
            environment: environment
        )
    }

    // MARK: - Reporter id

    func reporterId(userId: String) -> String {
        let secret = directory.handsFeedbackBaseURLOverride
            ?? ProcessInfo.processInfo.environment["HANDS_FEEDBACK_REPORTER_ID_SECRET"]
            ?? "reporter-id-secret"
        let digest = SHA256.hash(data: Data("\(userId):\(secret)".utf8))
        return EmailLoginDirectory.feedbackBase64URL(Data(digest))
    }

    // MARK: - Route binding

    /// `ensureProductFeedbackRouteBinding`: reporter id, root commitment and one
    /// `PUT .../reporter-feedback/route-subject`, cached for five minutes.
    func ensureRouteBinding(
        userId: String,
        environment: FeedbackRouteEnvironment
    ) throws -> String {
        let fallbackReporterId = environment.reporterIdSecret.isEmpty
            ? reporterId(userId: userId)
            : EmailLoginDirectory.feedbackReporterId(userId: userId, secret: environment.reporterIdSecret)
        guard let config = try EmailLoginDirectory.feedbackRouteConfig(environment) else { return fallbackReporterId }
        let reporterId = EmailLoginDirectory.feedbackReporterId(userId: userId, secret: config.reporterIdSecret)
        let rootBytes = EmailLoginDirectory.feedbackRouteRootBytes(config.root) ?? Data()
        let commitment = Data(SHA256.hash(data: Data(config.commitmentLabel.utf8) + Data([0]) + rootBytes))
        directory.lock.lock()
        if let existing = directory.productFeedbackRouteCommitments[config.commitmentLabel] {
            if existing != commitment {
                directory.lock.unlock()
                throw FeedbackRouteFailure.routeBinding(reason: "root_commitment_mismatch")
            }
        } else {
            directory.productFeedbackRouteCommitments[config.commitmentLabel] = commitment
        }
        let now = Date()
        let cacheKey = "\(config.appId)|\(config.credentialRevision)|\(config.commitmentLabel)|\(reporterId)"
        if let cached = directory.productFeedbackRouteBindingSuccesses[cacheKey], cached > now {
            directory.lock.unlock()
            return reporterId
        }
        directory.lock.unlock()
        guard let subject = EmailLoginDirectory.feedbackRouteSubject(config: config, userId: userId, reporterId: reporterId) else {
            throw FeedbackRouteFailure.routeBinding(reason: "route_subject_invalid")
        }
        var request = URLRequest(url: URL(string: "\(config.baseURL)/api/apps/\(config.appId)/reporter-feedback/route-subject")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 4
        request.setValue("Bearer \(config.appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        request.httpBody = Data("{\"route_subject\":\(jsonString(subject))}".utf8)
        func bindingReason(_ status: Int) -> String {
            status == 0 ? "request_failed" : "hands_status_\(status)"
        }
        func submitBinding() -> (Int, [String: String], Data) {
            send(request)
        }
        var (status, _, body) = submitBinding()
        if status == 0 || (500...599).contains(status) {
            (status, _, body) = submitBinding()
        }
        guard status == 200 || status == 201 else {
            throw FeedbackRouteFailure.routeBinding(reason: bindingReason(status))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              Set(object.keys) == ["changed", "subject_version"],
              let changed = object["changed"] as? Bool,
              object["subject_version"] as? String == "v1",
              (status == 201) == changed
        else {
            throw FeedbackRouteFailure.routeBinding(reason: "hands_unexpected_body")
        }
        locked { directory.productFeedbackRouteBindingSuccesses[cacheKey] = Date().addingTimeInterval(300) }
        return reporterId
    }

    /// Async twin of `ensureRouteBinding` for the Vapor route closures.
    func ensureRouteBindingAsync(
        userId: String,
        environment: FeedbackRouteEnvironment
    ) async throws -> String {
        let fallbackReporterId = environment.reporterIdSecret.isEmpty
            ? reporterId(userId: userId)
            : EmailLoginDirectory.feedbackReporterId(userId: userId, secret: environment.reporterIdSecret)
        guard let config = try EmailLoginDirectory.feedbackRouteConfig(environment) else { return fallbackReporterId }
        let reporterId = EmailLoginDirectory.feedbackReporterId(userId: userId, secret: config.reporterIdSecret)
        let rootBytes = EmailLoginDirectory.feedbackRouteRootBytes(config.root) ?? Data()
        let commitment = Data(SHA256.hash(data: Data(config.commitmentLabel.utf8) + Data([0]) + rootBytes))
        let now = Date()
        let cacheKey = "\(config.appId)|\(config.credentialRevision)|\(config.commitmentLabel)|\(reporterId)"
        let cachedBinding: Bool = try locked {
            if let existing = directory.productFeedbackRouteCommitments[config.commitmentLabel] {
                if existing != commitment {
                    throw FeedbackRouteFailure.routeBinding(reason: "root_commitment_mismatch")
                }
            } else {
                directory.productFeedbackRouteCommitments[config.commitmentLabel] = commitment
            }
            if let cached = directory.productFeedbackRouteBindingSuccesses[cacheKey], cached > now {
                return true
            }
            return false
        }
        if cachedBinding { return reporterId }
        guard let subject = EmailLoginDirectory.feedbackRouteSubject(config: config, userId: userId, reporterId: reporterId) else {
            throw FeedbackRouteFailure.routeBinding(reason: "route_subject_invalid")
        }
        var request = URLRequest(url: URL(string: "\(config.baseURL)/api/apps/\(config.appId)/reporter-feedback/route-subject")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 4
        request.setValue("Bearer \(config.appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        request.httpBody = Data("{\"route_subject\":\(jsonString(subject))}".utf8)
        func bindingReason(_ status: Int) -> String {
            status == 0 ? "request_failed" : "hands_status_\(status)"
        }
        var (status, _, body) = await sendAsync(request)
        if status == 0 || (500...599).contains(status) {
            (status, _, body) = await sendAsync(request)
        }
        guard status == 200 || status == 201 else {
            throw FeedbackRouteFailure.routeBinding(reason: bindingReason(status))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              Set(object.keys) == ["changed", "subject_version"],
              let changed = object["changed"] as? Bool,
              object["subject_version"] as? String == "v1",
              (status == 201) == changed
        else {
            throw FeedbackRouteFailure.routeBinding(reason: "hands_unexpected_body")
        }
        locked { directory.productFeedbackRouteBindingSuccesses[cacheKey] = Date().addingTimeInterval(300) }
        return reporterId
    }

    // MARK: - Reporter session / bearer

    func bearer(
        userId: String,
        reporterId: String,
        environment: FeedbackRouteEnvironment
    ) throws -> String {
        let conversationToken = environment.conversationToken.isEmpty
            ? environment.appToken
            : environment.conversationToken
        guard !environment.baseURL.isEmpty, !conversationToken.isEmpty else {
            throw FeedbackRouteFailure.configuration
        }
        guard environment.conversationSessionEnabled else {
            return conversationToken
        }
        let cacheKey = "\(environment.appId)|\(environment.credentialRevision)|\(userId)"
        directory.lock.lock()
        if let cached = directory.productFeedbackReporterSessionCache[cacheKey],
           cached.expiresAt > Date().addingTimeInterval(5) {
            directory.lock.unlock()
            return cached.token
        }
        directory.lock.unlock()
        var request = URLRequest(url: URL(string: "\(environment.baseURL)/api/apps/\(environment.appId)/reporter-feedback/session")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(conversationToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        request.httpBody = Data("{\"scopes\":[\"feedback:comment\",\"feedback:read\"]}".utf8)
        let (status, _, body) = send(request)
        guard status == 200 || status == 201,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let token = object["session_token"] as? String, !token.isEmpty
        else {
            throw FeedbackRouteFailure.configuration
        }
        let expires = (object["expires_at"] as? NSNumber)?.doubleValue ?? Date().addingTimeInterval(30).timeIntervalSince1970
        directory.lock.lock()
        directory.productFeedbackReporterSessionCache[cacheKey] = (token, Date(timeIntervalSince1970: expires))
        directory.lock.unlock()
        return token
    }

    /// Async twin of `bearer`.
    func bearerAsync(
        userId: String,
        reporterId: String,
        environment: FeedbackRouteEnvironment
    ) async throws -> String {
        let conversationToken = environment.conversationToken.isEmpty
            ? environment.appToken
            : environment.conversationToken
        guard !environment.baseURL.isEmpty, !conversationToken.isEmpty else {
            throw FeedbackRouteFailure.configuration
        }
        guard environment.conversationSessionEnabled else {
            return conversationToken
        }
        let cacheKey = "\(environment.appId)|\(environment.credentialRevision)|\(userId)"
        let cachedToken: String? = locked {
            if let cached = directory.productFeedbackReporterSessionCache[cacheKey],
               cached.expiresAt > Date().addingTimeInterval(5) {
                return cached.token
            }
            return nil
        }
        if let cachedToken { return cachedToken }
        var request = URLRequest(url: URL(string: "\(environment.baseURL)/api/apps/\(environment.appId)/reporter-feedback/session")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(conversationToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        request.httpBody = Data("{\"scopes\":[\"feedback:comment\",\"feedback:read\"]}".utf8)
        let (status, _, body) = await sendAsync(request)
        guard status == 200 || status == 201,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let token = object["session_token"] as? String, !token.isEmpty
        else {
            throw FeedbackRouteFailure.configuration
        }
        let expires = (object["expires_at"] as? NSNumber)?.doubleValue ?? Date().addingTimeInterval(30).timeIntervalSince1970
        locked { directory.productFeedbackReporterSessionCache[cacheKey] = (token, Date(timeIntervalSince1970: expires)) }
        return token
    }

    // MARK: - Conversation plumbing

    func handsRequest(
        environment: FeedbackRouteEnvironment,
        method: String,
        path: String,
        bearer: String,
        reporterId: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> (status: Int, headers: [String: String], body: Data) {
        var request = URLRequest(url: URL(string: "\(environment.baseURL)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        return send(request)
    }

    /// Async twin of `handsRequest`.
    func handsRequestAsync(
        environment: FeedbackRouteEnvironment,
        method: String,
        path: String,
        bearer: String,
        reporterId: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async -> (status: Int, headers: [String: String], body: Data) {
        var request = URLRequest(url: URL(string: "\(environment.baseURL)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        return await sendAsync(request)
    }

    // MARK: - Reply mapping

    /// Error reply built from the canonical `FeedbackErrorResponse` DTO.
    func errorReply(
        _ status: Int,
        error: String,
        code: String,
        headers: [String: String] = [:]
    ) -> HTTPReply {
        let body = FeedbackJSONCoding.string(FeedbackErrorResponse(error: error, code: code))
        if headers.isEmpty {
            return EmailLoginDirectory.json(status, body)
        }
        return EmailLoginDirectory.jsonWithHeaders(status, body, headers: headers)
    }

    func jsonReply(
        status: Int,
        body: String,
        elapsed: Date? = nil,
        upstreamHeaders: [String: String] = [:],
        retryAfter: String? = nil
    ) -> HTTPReply {
        var headers: [String: String] = [
            "Content-Type": AppFallback.jsonContentType,
            "Cache-Control": "no-store",
            "Content-Length": String(body.utf8.count),
        ]
        if let elapsed {
            headers["Server-Timing"] = EmailLoginDirectory.feedbackTimingHeader(
                elapsedMs: Date().timeIntervalSince(elapsed) * 1000,
                upstreamHeaders: upstreamHeaders
            )
        }
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return HTTPReply(status: status, headers: headers, body: body)
    }

    /// `sendConversationError` + upstream outcome mapping for conversation calls.
    func conversationReply(
        status: Int,
        upstreamHeaders: [String: String],
        body: Data,
        elapsed: Date? = nil
    ) -> HTTPReply {
        switch status {
        case 200, 201:
            return jsonReply(
                status: status,
                body: String(decoding: body, as: UTF8.self),
                elapsed: elapsed,
                upstreamHeaders: upstreamHeaders
            )
        case 400:
            return errorReply(400, error: "Invalid feedback request", code: "feedback_invalid")
        case 404:
            return errorReply(404, error: "Feedback ticket not found", code: "feedback_not_found")
        case 409:
            return errorReply(409, error: "This comment retry does not match the original submission", code: "feedback_comment_conflict")
        case 429:
            let retryAfter = upstreamHeaders.first { $0.key.lowercased() == "retry-after" }?.value ?? "60"
            return errorReply(
                429,
                error: "Too many feedback requests. Please try again later.",
                code: "feedback_rate_limited",
                headers: ["Retry-After": retryAfter]
            )
        case 401, 403:
            return errorReply(503, error: "Feedback service is temporarily unavailable", code: "feedback_integration_unavailable")
        default:
            return errorReply(503, error: "Feedback service is temporarily unavailable", code: "feedback_service_unavailable")
        }
    }

    func sourceInvalidReply() -> HTTPReply {
        errorReply(400, error: "Invalid feedback request", code: "feedback_invalid")
    }

    func availabilityReply(_ failure: FeedbackRouteFailure) -> HTTPReply {
        switch failure {
        case .invalidSource:
            return sourceInvalidReply()
        case .sourceUnavailable(let source, let reason):
            warn("[product-feedback] source unavailable (\(source): \(reason))")
            return errorReply(503, error: "Feedback service is temporarily unavailable", code: "feedback_integration_unavailable")
        case .routeBinding(let reason):
            warn("[product-feedback] route binding failed (\(reason))")
            return errorReply(
                503,
                error: "Feedback service is temporarily unavailable",
                code: "feedback_integration_unavailable",
                headers: ["Retry-After": "5"]
            )
        case .configuration:
            return errorReply(503, error: "Feedback service is temporarily unavailable", code: "feedback_integration_unavailable")
        }
    }

    /// Verifies the caller's session without producing a reply for a valid one.
    func conversationRejectedReply(authorization: String?) -> HTTPReply? {
        guard let userId = directory.sessionUserId(authorization: authorization) else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let verified = locked { directory.accounts.values.first { $0.id == userId }?.emailVerified == true }
        guard verified else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Email verification required\",\"code\":\"account_unverified\"}")
        }
        return nil
    }
}

// MARK: - Directory entry points
//
// The directory keeps the published method names and the static constants the
// rest of the module references; every body delegates to `FeedbackService`.

extension EmailLoginDirectory {
    /// Feature flag key from `productFeedbackApps.ts`.
    public static let productFeedbackMultiAppFlag = "product_feedback_multi_app"

    /// Trusted client sources; anything else is an invalid request.
    static let productFeedbackSources: Set<String> = ["web", "ios", "android", "ohos"]

    static let productFeedbackLegacyCommitmentLabel = "hands-feedback-route-subject:v1"
    static let productFeedbackMultiCommitmentLabel = "hands-feedback-route-subject:multi:v1"

    static let feedbackTimingNames: Set<String> = [
        "hands_auth", "hands_preflight", "hands_commit", "hands_postcommit",
        "hands_list", "hands_session_mint", "hands_session_verify",
    ]

    func feedbackWarn(_ message: String) {
        FeedbackService(directory: self).warn(message)
    }

    func handsFeedbackSend(_ request: URLRequest) -> (Int, [String: String], Data) {
        FeedbackService(directory: self).send(request)
    }

    func feedbackLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func handsFeedbackSendAsync(_ request: URLRequest) async -> (Int, [String: String], Data) {
        await FeedbackService(directory: self).sendAsync(request)
    }

    func feedbackLegacyEnvironmentLocked() -> [String: String] {
        FeedbackService(directory: self).legacyEnvironmentLocked()
    }

    func feedbackRouteEnvironment(source: String, userId: String) throws -> FeedbackRouteEnvironment {
        try FeedbackService(directory: self).routeEnvironment(source: source, userId: userId)
    }

    func ensureFeedbackRouteBinding(
        userId: String,
        environment: FeedbackRouteEnvironment
    ) throws -> String {
        try FeedbackService(directory: self).ensureRouteBinding(userId: userId, environment: environment)
    }

    /// Async twin of `ensureFeedbackRouteBinding` for the Vapor route closures.
    func ensureFeedbackRouteBindingAsync(
        userId: String,
        environment: FeedbackRouteEnvironment
    ) async throws -> String {
        try await FeedbackService(directory: self).ensureRouteBindingAsync(userId: userId, environment: environment)
    }

    func feedbackBearer(
        userId: String,
        reporterId: String,
        environment: FeedbackRouteEnvironment
    ) throws -> String {
        try FeedbackService(directory: self).bearer(userId: userId, reporterId: reporterId, environment: environment)
    }

    /// Async twin of `feedbackBearer`.
    func feedbackBearerAsync(
        userId: String,
        reporterId: String,
        environment: FeedbackRouteEnvironment
    ) async throws -> String {
        try await FeedbackService(directory: self).bearerAsync(userId: userId, reporterId: reporterId, environment: environment)
    }

    func feedbackHandsRequest(
        environment: FeedbackRouteEnvironment,
        method: String,
        path: String,
        bearer: String,
        reporterId: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> (status: Int, headers: [String: String], body: Data) {
        FeedbackService(directory: self).handsRequest(
            environment: environment,
            method: method,
            path: path,
            bearer: bearer,
            reporterId: reporterId,
            headers: headers,
            body: body
        )
    }

    /// Async twin of `feedbackHandsRequest`.
    func feedbackHandsRequestAsync(
        environment: FeedbackRouteEnvironment,
        method: String,
        path: String,
        bearer: String,
        reporterId: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async -> (status: Int, headers: [String: String], body: Data) {
        await FeedbackService(directory: self).handsRequestAsync(
            environment: environment,
            method: method,
            path: path,
            bearer: bearer,
            reporterId: reporterId,
            headers: headers,
            body: body
        )
    }

    /// Error reply built from the canonical `FeedbackErrorResponse` DTO.
    func feedbackErrorReply(
        _ status: Int,
        error: String,
        code: String,
        headers: [String: String] = [:]
    ) -> HTTPReply {
        FeedbackService(directory: self).errorReply(status, error: error, code: code, headers: headers)
    }

    func feedbackJSONReply(
        status: Int,
        body: String,
        elapsed: Date? = nil,
        upstreamHeaders: [String: String] = [:],
        retryAfter: String? = nil
    ) -> HTTPReply {
        FeedbackService(directory: self).jsonReply(
            status: status,
            body: body,
            elapsed: elapsed,
            upstreamHeaders: upstreamHeaders,
            retryAfter: retryAfter
        )
    }

    /// `sendConversationError` + upstream outcome mapping for conversation calls.
    func feedbackConversationReply(
        status: Int,
        upstreamHeaders: [String: String],
        body: Data,
        elapsed: Date? = nil
    ) -> HTTPReply {
        FeedbackService(directory: self).conversationReply(
            status: status,
            upstreamHeaders: upstreamHeaders,
            body: body,
            elapsed: elapsed
        )
    }

    func feedbackSourceInvalidReply() -> HTTPReply {
        FeedbackService(directory: self).sourceInvalidReply()
    }

    func feedbackAvailabilityReply(_ failure: FeedbackRouteFailure) -> HTTPReply {
        FeedbackService(directory: self).availabilityReply(failure)
    }

    func handsReporterId(_ userId: String) -> String {
        FeedbackService(directory: self).reporterId(userId: userId)
    }

    func feedbackConversationRejectedReply(authorization: String?) -> HTTPReply? {
        FeedbackService(directory: self).conversationRejectedReply(authorization: authorization)
    }
}

/// Resumes a continuation at most once: the data task and the timeout watchdog
/// race, and whichever finishes first wins. The loser's asynchronous work is
/// cancelled as soon as the winner resumes.
private final class UpstreamContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var timeoutTask: Task<Void, Never>?
    private let continuation: CheckedContinuation<FeedbackService.UpstreamResponse, Never>

    init(continuation: CheckedContinuation<FeedbackService.UpstreamResponse, Never>) {
        self.continuation = continuation
    }

    func install(timeoutTask: Task<Void, Never>) {
        lock.lock()
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    /// Returns `true` when this call performed the resume.
    @discardableResult
    func resume(_ result: FeedbackService.UpstreamResponse) -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        resumed = true
        let watchdog = timeoutTask
        timeoutTask = nil
        lock.unlock()
        watchdog?.cancel()
        continuation.resume(returning: result)
        return true
    }
}

/// Keeps the in-flight task reachable from the timeout watchdog without
/// crossing an actor boundary with a mutable reference.
private final class DataTaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
}
