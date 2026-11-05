import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {

    // MARK: - Product feedback apps, sources and route binding

    /// Feature flag key from `productFeedbackApps.ts`.
    public static let productFeedbackMultiAppFlag = "product_feedback_multi_app"

    /// Trusted client sources; anything else is an invalid request.
    static let productFeedbackSources: Set<String> = ["web", "ios", "android", "ohos"]

    static let productFeedbackLegacyCommitmentLabel = "hands-feedback-route-subject:v1"
    static let productFeedbackMultiCommitmentLabel = "hands-feedback-route-subject:multi:v1"





    // MARK: Public test seams

    /// Installs the SecureString-shaped `HANDS_FEEDBACK_APPS` JSON. Production
    /// reads this from SSM; the port has no AWS client, so the composition root
    /// (or a test) supplies the payload.
    public func setHandsFeedbackAppsForTesting(_ appsJSON: String?) {
        lock.lock()
        handsFeedbackAppsJSONForTesting = appsJSON
        productFeedbackReporterSessionCache.removeAll()
        productFeedbackRouteBindingSuccesses.removeAll()
        productFeedbackRouteVerifiedCommitments.removeAll()
        lock.unlock()
    }

    /// Overlays the legacy `HANDS_FEEDBACK_*` environment view for a test.
    public func setHandsFeedbackLegacyEnvironmentForTesting(_ values: [String: String]?) {
        lock.lock()
        handsFeedbackLegacyEnvironmentForTesting = values
        productFeedbackReporterSessionCache.removeAll()
        productFeedbackRouteBindingSuccesses.removeAll()
        productFeedbackRouteVerifiedCommitments.removeAll()
        lock.unlock()
    }

    /// Operator log sink (upstream uses `console.warn`). Tests install one to
    /// assert the fixed reason codes without reading process output.
    public func setHandsFeedbackWarningSinkForTesting(_ sink: ((String) -> Void)?) {
        lock.lock()
        handsFeedbackWarningSinkForTesting = sink
        lock.unlock()
    }

    /// Labels committed into `integrationSecretCommitments` by route binding.
    public func productFeedbackRouteCommitmentLabelsForTesting() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return productFeedbackRouteCommitments.keys.sorted()
    }

    public func resetProductFeedbackRouteBindingCacheForTesting() {
        lock.lock()
        productFeedbackRouteBindingSuccesses.removeAll()
        productFeedbackRouteVerifiedCommitments.removeAll()
        productFeedbackRouteCommitments.removeAll()
        lock.unlock()
    }

    // MARK: Configuration resolution

    func feedbackWarn(_ message: String) {
        lock.lock()
        let sink = handsFeedbackWarningSinkForTesting
        lock.unlock()
        if let sink {
            sink(message)
        } else {
            print(message)
        }
    }

    static let feedbackTimingNames: Set<String> = [
        "hands_auth", "hands_preflight", "hands_commit", "hands_postcommit",
        "hands_list", "hands_session_mint", "hands_session_verify",
    ]



    func handsFeedbackSend(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock()
        let injected = handsFeedbackUpstreamHandler
        lock.unlock()
        if let injected { return injected(request) }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var status = 0; var headers: [String: String] = [:]; var body = Data() }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                box.status = http.statusCode
                for (key, value) in http.allHeaderFields {
                    box.headers[String(describing: key)] = String(describing: value)
                }
            }
            box.body = data ?? Data()
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return (box.status, box.headers, box.body)
    }

    func feedbackLegacyEnvironmentLocked() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let overlay = handsFeedbackLegacyEnvironmentForTesting {
            for (key, value) in overlay { environment[key] = value }
        }
        if let handsFeedbackBaseURLOverride { environment["HANDS_FEEDBACK_BASE_URL"] = handsFeedbackBaseURLOverride }
        if let handsFeedbackAppIdOverride { environment["HANDS_FEEDBACK_APP_ID"] = handsFeedbackAppIdOverride }
        if let handsFeedbackAppSlugOverride { environment["HANDS_FEEDBACK_APP_SLUG"] = handsFeedbackAppSlugOverride }
        if let handsFeedbackAppTokenOverride { environment["HANDS_FEEDBACK_APP_TOKEN"] = handsFeedbackAppTokenOverride }
        if let handsConversationSessionEnabledForTesting {
            environment["HANDS_FEEDBACK_CONVERSATION_SESSION_ENABLED"] = handsConversationSessionEnabledForTesting ? "true" : "false"
        }
        if let handsConversationAppTokenOverride {
            environment["HANDS_FEEDBACK_CONVERSATION_APP_TOKEN"] = handsConversationAppTokenOverride
        }
        return environment
    }





    /// Mirrors `productFeedbackUnavailableReason`; fixed codes and field names only.


    func feedbackRouteEnvironment(source: String, userId: String) throws -> FeedbackRouteEnvironment {
        guard Self.productFeedbackSources.contains(source) else { throw FeedbackRouteFailure.invalidSource }
        lock.lock()
        let environment = feedbackLegacyEnvironmentLocked()
        let appsJSON = handsFeedbackAppsJSONForTesting
        lock.unlock()
        let multiEnabled = evaluateFeatureFlagKey(
            key: Self.productFeedbackMultiAppFlag,
            userId: userId,
            serverId: nil,
            platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        ).enabled
        if !multiEnabled { return Self.feedbackLegacyRouteEnvironment(environment) }
        return try Self.feedbackMultiRouteEnvironment(source: source, appsJSON: appsJSON, environment: environment)
    }

    /// Trusted client source; unknown values are invalid before any configuration.

    // MARK: Route binding







    /// `ensureProductFeedbackRouteBinding`: reporter id, root commitment and one
    /// `PUT .../reporter-feedback/route-subject`, cached for five minutes.
    func ensureFeedbackRouteBinding(
        userId: String,
        environment: FeedbackRouteEnvironment
    ) throws -> String {
        let fallbackReporterId = environment.reporterIdSecret.isEmpty
            ? handsReporterId(userId)
            : Self.feedbackReporterId(userId: userId, secret: environment.reporterIdSecret)
        guard let config = try Self.feedbackRouteConfig(environment) else { return fallbackReporterId }
        let reporterId = Self.feedbackReporterId(userId: userId, secret: config.reporterIdSecret)
        let rootBytes = Self.feedbackRouteRootBytes(config.root) ?? Data()
        let commitment = Data(SHA256.hash(data: Data(config.commitmentLabel.utf8) + Data([0]) + rootBytes))
        lock.lock()
        if let existing = productFeedbackRouteCommitments[config.commitmentLabel] {
            if existing != commitment {
                lock.unlock()
                throw FeedbackRouteFailure.routeBinding(reason: "root_commitment_mismatch")
            }
        } else {
            productFeedbackRouteCommitments[config.commitmentLabel] = commitment
        }
        let now = Date()
        let cacheKey = "\(config.appId)|\(config.credentialRevision)|\(config.commitmentLabel)|\(reporterId)"
        if let cached = productFeedbackRouteBindingSuccesses[cacheKey], cached > now {
            lock.unlock()
            return reporterId
        }
        lock.unlock()
        guard let subject = Self.feedbackRouteSubject(config: config, userId: userId, reporterId: reporterId) else {
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
            handsFeedbackSend(request)
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
        lock.lock()
        productFeedbackRouteBindingSuccesses[cacheKey] = Date().addingTimeInterval(300)
        lock.unlock()
        return reporterId
    }

    // MARK: Reporter session / bearer

    func feedbackBearer(
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
        lock.lock()
        if let cached = productFeedbackReporterSessionCache[cacheKey], cached.expiresAt > Date().addingTimeInterval(5) {
            lock.unlock()
            return cached.token
        }
        lock.unlock()
        var request = URLRequest(url: URL(string: "\(environment.baseURL)/api/apps/\(environment.appId)/reporter-feedback/session")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(conversationToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        request.httpBody = Data("{\"scopes\":[\"feedback:comment\",\"feedback:read\"]}".utf8)
        let (status, _, body) = handsFeedbackSend(request)
        guard status == 200 || status == 201,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let token = object["session_token"] as? String, !token.isEmpty
        else {
            throw FeedbackRouteFailure.configuration
        }
        let expires = (object["expires_at"] as? NSNumber)?.doubleValue ?? Date().addingTimeInterval(30).timeIntervalSince1970
        lock.lock()
        productFeedbackReporterSessionCache[cacheKey] = (token, Date(timeIntervalSince1970: expires))
        lock.unlock()
        return token
    }

    // MARK: Cursors




    // MARK: Conversation plumbing

    func feedbackHandsRequest(
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
        return handsFeedbackSend(request)
    }

    func feedbackJSONReply(
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
            headers["Server-Timing"] = Self.feedbackTimingHeader(
                elapsedMs: Date().timeIntervalSince(elapsed) * 1000,
                upstreamHeaders: upstreamHeaders
            )
        }
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return HTTPReply(status: status, headers: headers, body: body)
    }

    /// `sendConversationError` + upstream outcome mapping for conversation calls.
    func feedbackConversationReply(
        status: Int,
        upstreamHeaders: [String: String],
        body: Data,
        elapsed: Date? = nil
    ) -> HTTPReply {
        switch status {
        case 200, 201:
            return feedbackJSONReply(
                status: status,
                body: String(decoding: body, as: UTF8.self),
                elapsed: elapsed,
                upstreamHeaders: upstreamHeaders
            )
        case 400:
            return Self.json(400, "{\"error\":\"Invalid feedback request\",\"code\":\"feedback_invalid\"}")
        case 404:
            return Self.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        case 409:
            return Self.json(409, "{\"error\":\"This comment retry does not match the original submission\",\"code\":\"feedback_comment_conflict\"}")
        case 429:
            let retryAfter = upstreamHeaders.first { $0.key.lowercased() == "retry-after" }?.value ?? "60"
            return Self.jsonWithHeaders(
                429,
                "{\"error\":\"Too many feedback requests. Please try again later.\",\"code\":\"feedback_rate_limited\"}",
                headers: ["Retry-After": retryAfter]
            )
        case 401, 403:
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
        default:
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
    }


    func feedbackSourceInvalidReply() -> HTTPReply {
        Self.json(400, "{\"error\":\"Invalid feedback request\",\"code\":\"feedback_invalid\"}")
    }

    func feedbackAvailabilityReply(_ failure: FeedbackRouteFailure) -> HTTPReply {
        switch failure {
        case .invalidSource:
            return feedbackSourceInvalidReply()
        case .sourceUnavailable(let source, let reason):
            feedbackWarn("[product-feedback] source unavailable (\(source): \(reason))")
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
        case .routeBinding(let reason):
            feedbackWarn("[product-feedback] route binding failed (\(reason))")
            return Self.jsonWithHeaders(
                503,
                "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}",
                headers: ["Retry-After": "5"]
            )
        case .configuration:
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
        }
    }

    public func setHandsConversationForTesting(enabled: Bool, appToken: String?) {
        lock.lock()
        handsConversationSessionEnabledForTesting = enabled
        handsConversationAppTokenOverride = appToken
        productFeedbackReporterSessionCache.removeAll()
        lock.unlock()
    }

    public func productFeedbackTickets(
        authorization: String?,
        clientKindHeader: String = "",
        cursor: String? = nil
    ) -> HTTPReply {
        let listStartedAt = Date()
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let verified = accounts.values.first { $0.id == userId }?.emailVerified == true
        lock.unlock()
        guard verified else {
            return Self.json(403, "{\"error\":\"Email verification required\",\"code\":\"account_unverified\"}")
        }
        let source: String
        do {
            source = try Self.feedbackSource(clientKindHeader)
        } catch {
            return feedbackSourceInvalidReply()
        }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try feedbackRouteEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
        }
        let conversationToken = environment.conversationToken.isEmpty
            ? environment.appToken
            : environment.conversationToken
        guard !environment.baseURL.isEmpty, !conversationToken.isEmpty else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let reporterId: String
        do {
            reporterId = try ensureFeedbackRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try feedbackBearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var handsCursor: String?
        if let cursor, !cursor.isEmpty {
            guard !environment.cursorSecret.isEmpty else { return feedbackSourceInvalidReply() }
            do {
                handsCursor = try Self.feedbackDecodeCursor(
                    cursor,
                    route: "ticket_list",
                    userId: userId,
                    ticketId: nil,
                    cursorKey: environment.cursorSecret
                )
            } catch {
                return feedbackSourceInvalidReply()
            }
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback?limit=50"
        if let handsCursor {
            path += "&cursor=" + Self.feedbackPercentEncoded(handsCursor)
        }
        let (status, headers, body) = feedbackHandsRequest(
            environment: environment,
            method: "GET",
            path: path,
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return feedbackConversationReply(status: status, upstreamHeaders: headers, body: body)
        }
        var replyBody = String(decoding: body, as: UTF8.self)
        if !environment.cursorSecret.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let next = object["next_cursor"] as? String, !next.isEmpty,
           let encoded = Self.feedbackEncodeCursor(
               route: "ticket_list",
               userId: userId,
               ticketId: nil,
               handsCursor: next,
               cursorKey: environment.cursorSecret
           ) {
            var rewritten = object
            rewritten["next_cursor"] = encoded
            if let data = try? JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys]) {
                replyBody = String(decoding: data, as: UTF8.self)
            }
        }
        return feedbackJSONReply(
            status: 200,
            body: replyBody,
            elapsed: listStartedAt,
            upstreamHeaders: headers
        )
    }


    func handsReporterId(_ userId: String) -> String {
        let secret = handsFeedbackBaseURLOverride ?? ProcessInfo.processInfo.environment["HANDS_FEEDBACK_REPORTER_ID_SECRET"] ?? "reporter-id-secret"
        let digest = SHA256.hash(data: Data("\(userId):\(secret)".utf8))
        return Self.feedbackBase64URL(Data(digest))
    }

    func feedbackConversationRejectedReply(authorization: String?) -> HTTPReply? {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let verified = accounts.values.first { $0.id == userId }?.emailVerified == true
        lock.unlock()
        guard verified else {
            return Self.json(403, "{\"error\":\"Email verification required\",\"code\":\"account_unverified\"}")
        }
        return nil
    }

    public func closeProductFeedbackTicket(
        authorization: String?,
        ticketId: String,
        body: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        if let rejected = feedbackConversationRejectedReply(authorization: authorization) { return rejected }
        let userId = sessionUserId(authorization: authorization)!
        guard Self.feedbackCanonicalUUID(ticketId) else {
            return Self.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        let reason = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["reason"] as? String
        guard reason == "completed" || reason == "no_longer_needed" else {
            return Self.json(400, "{\"error\":\"Feedback close reason is invalid\",\"code\":\"feedback_invalid\"}")
        }
        let source: String
        do { source = try Self.feedbackSource(clientKindHeader) } catch { return feedbackSourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try feedbackRouteEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try ensureFeedbackRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try feedbackBearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, upstreamBody) = feedbackHandsRequest(
            environment: environment,
            method: "POST",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/close",
            bearer: bearer,
            reporterId: reporterId,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
        return feedbackConversationReply(status: status, upstreamHeaders: headers, body: upstreamBody)
    }

    public func replyProductFeedbackTicket(
        authorization: String?,
        ticketId: String,
        contentType: String,
        body: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        if let rejected = feedbackConversationRejectedReply(authorization: authorization) { return rejected }
        let userId = sessionUserId(authorization: authorization)!
        guard Self.feedbackCanonicalUUID(ticketId) else {
            return Self.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        for part in body.components(separatedBy: "Content-Disposition: form-data") {
            guard part.contains("filename=\"") else { continue }
            let lower = part.lowercased()
            let allowed = lower.contains("content-type: image/png") || lower.contains("content-type: image/jpeg")
                || lower.contains("content-type: image/webp") || lower.contains("content-type: image/gif")
            if !allowed {
                return Self.json(400, "{\"error\":\"Only image attachments are supported\",\"code\":\"feedback_attachment_type_invalid\"}")
            }
        }
        let source: String
        do { source = try Self.feedbackSource(clientKindHeader) } catch { return feedbackSourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try feedbackRouteEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try ensureFeedbackRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try feedbackBearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, upstreamBody) = feedbackHandsRequest(
            environment: environment,
            method: "POST",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/comments",
            bearer: bearer,
            reporterId: reporterId,
            headers: ["Content-Type": contentType],
            body: Data(body.utf8)
        )
        return feedbackConversationReply(status: status, upstreamHeaders: headers, body: upstreamBody)
    }

    /// `GET /api/product-feedback/tickets/:ticketId`.
    public func productFeedbackTicket(
        authorization: String?,
        ticketId: String,
        clientKindHeader: String = "",
        commentLimit: Int = 50,
        commentCursor: String? = nil
    ) -> HTTPReply {
        let startedAt = Date()
        if let rejected = feedbackConversationRejectedReply(authorization: authorization) { return rejected }
        let userId = sessionUserId(authorization: authorization)!
        guard Self.feedbackCanonicalUUID(ticketId) else {
            return Self.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        guard commentLimit >= 1, commentLimit <= 100 else {
            return Self.json(400, "{\"error\":\"Invalid feedback request\",\"code\":\"feedback_invalid\"}")
        }
        let source: String
        do { source = try Self.feedbackSource(clientKindHeader) } catch { return feedbackSourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try feedbackRouteEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try ensureFeedbackRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try feedbackBearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var handsCursor: String?
        if let commentCursor, !commentCursor.isEmpty {
            guard !environment.cursorSecret.isEmpty else { return feedbackSourceInvalidReply() }
            do {
                handsCursor = try Self.feedbackDecodeCursor(
                    commentCursor,
                    route: "ticket_comments",
                    userId: userId,
                    ticketId: ticketId,
                    cursorKey: environment.cursorSecret
                )
            } catch {
                return feedbackSourceInvalidReply()
            }
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)?comment_limit=\(commentLimit)"
        if let handsCursor {
            path += "&comment_cursor=" + Self.feedbackPercentEncoded(handsCursor)
        }
        let (status, headers, body) = feedbackHandsRequest(
            environment: environment,
            method: "GET",
            path: path,
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return feedbackConversationReply(status: status, upstreamHeaders: headers, body: body)
        }
        var replyBody = String(decoding: body, as: UTF8.self)
        if !environment.cursorSecret.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let next = object["next_comment_cursor"] as? String, !next.isEmpty,
           let encoded = Self.feedbackEncodeCursor(
               route: "ticket_comments",
               userId: userId,
               ticketId: ticketId,
               handsCursor: next,
               cursorKey: environment.cursorSecret
           ) {
            var rewritten = object
            rewritten["next_comment_cursor"] = encoded
            if let data = try? JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys]) {
                replyBody = String(decoding: data, as: UTF8.self)
            }
        }
        return feedbackJSONReply(status: 200, body: replyBody, elapsed: startedAt, upstreamHeaders: headers)
    }

    /// `GET /api/product-feedback/tickets/:ticketId/attachments/:attachmentId`.
    public func productFeedbackAttachment(
        authorization: String?,
        ticketId: String,
        attachmentId: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        if let rejected = feedbackConversationRejectedReply(authorization: authorization) { return rejected }
        let userId = sessionUserId(authorization: authorization)!
        guard Self.feedbackCanonicalUUID(ticketId), Self.feedbackCanonicalUUID(attachmentId) else {
            return Self.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        let source: String
        do { source = try Self.feedbackSource(clientKindHeader) } catch { return feedbackSourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try feedbackRouteEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try ensureFeedbackRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try feedbackBearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, body) = feedbackHandsRequest(
            environment: environment,
            method: "GET",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/attachments/\(attachmentId)",
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return feedbackConversationReply(status: status, upstreamHeaders: headers, body: body)
        }
        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/octet-stream"
        let disposition = headers.first { $0.key.lowercased() == "content-disposition" }?.value
        var responseHeaders: [String: String] = [
            "Content-Type": contentType,
            "Content-Length": String(body.count),
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "private, no-store",
        ]
        if let disposition { responseHeaders["Content-Disposition"] = disposition }
        return HTTPReply(status: 200, headers: responseHeaders, body: String(decoding: body, as: UTF8.self))
    }

}
