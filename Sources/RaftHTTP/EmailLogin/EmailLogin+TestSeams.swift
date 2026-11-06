import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {

    // MARK: Seams shared with existing tests

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

    public func submitProductFeedback(authorization: String?, contentType: String, body: String, serverId: String = "", clientKindHeader: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let feedbackStartedAt = Date()
        lock.lock()
        let verified = accounts.values.first { $0.id == userId }?.emailVerified == true
        lock.unlock()
        guard verified else {
            return Self.json(403, "{\"error\":\"Email verification required\",\"code\":\"account_unverified\"}")
        }
        guard let fields = Self.multipartFields(body: body, contentType: contentType),
              let submissionId = fields["submission_id"],
              submissionId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil,
              let type = fields["type"], ["idea", "problem"].contains(type),
              let message = fields["message"], !message.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
        }
        if let rawMetadata = fields["metadata"], !rawMetadata.isEmpty {
            guard let metadata = (try? JSONSerialization.jsonObject(with: Data(rawMetadata.utf8))) as? [String: Any] else {
                return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
            }
            let nativeKinds = ["ios", "android", "macos", "windows", "linux"]
            if let clientKind = metadata["client_kind"] as? String, nativeKinds.contains(clientKind) {
                let platform = metadata["platform"] as? String ?? ""
                if platform != clientKind || metadata["browser"] != nil {
                    return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
                }
            }
            if let metadataKind = metadata["client_kind"] as? String,
               !Self.productFeedbackSources.contains(metadataKind) {
                return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
            }
        }
        var metadataObject: [String: Any] = [:]
        if let rawMetadata = fields["metadata"],
           let parsed = (try? JSONSerialization.jsonObject(with: Data(rawMetadata.utf8))) as? [String: Any] {
            metadataObject = parsed
        }
        if let reportId = fields["feedback_report_id"], !reportId.isEmpty {
            guard reportId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
                return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
            }
            metadataObject["feedback_report_id"] = reportId.lowercased()
            metadataObject["surface"] = "agent.report_issue"
        }
        let trustedClientKind: String
        do {
            trustedClientKind = try Self.feedbackSource(clientKindHeader)
        } catch {
            return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
        }
        if let metadataKind = metadataObject["client_kind"] as? String, metadataKind != trustedClientKind {
            return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
        }
        let clientKind = metadataObject["client_kind"] as? String
        if let clientKind, Self.productFeedbackSources.contains(clientKind), clientKind != "web" {
            var forwarded: [String: Any] = [
                "client_kind": clientKind,
                "platform": metadataObject["platform"] as? String ?? clientKind,
                "product_type": clientKind,
                "feedback_type": type,
                "contact_consent": fields["may_contact"] == "true",
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
        if ServerScope.isUUID(serverId),
           let profile = oauth.serverProfile(id: serverId),
           oauth.memberRole(serverId: serverId, userId: userId) != nil,
           !profile.slug.isEmpty {
            lock.lock()
            let handle = accounts.values.first { $0.id == userId }?.name ?? ""
            lock.unlock()
            metadataObject["reporter_attribution"] = [
                "v": 1,
                "server_id": serverId,
                "server_slug": profile.slug,
                "user_id": userId,
                "handle": handle,
            ]
        }
        lock.lock()
        let environment = feedbackLegacyEnvironmentLocked()
        let appsJSON = handsFeedbackAppsJSONForTesting
        lock.unlock()
        guard handsFeedbackConfigured || environment["HANDS_FEEDBACK_BASE_URL"] != nil else {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_not_configured\"}")
        }
        let multiEnabled = evaluateFeatureFlagKey(
            key: Self.productFeedbackMultiAppFlag,
            userId: userId,
            serverId: nil,
            platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        ).enabled
        let routeEnvironment: FeedbackRouteEnvironment
        if multiEnabled {
            do {
                routeEnvironment = try Self.feedbackMultiRouteEnvironment(
                    source: trustedClientKind,
                    appsJSON: appsJSON,
                    environment: environment
                )
            } catch let failure as FeedbackRouteFailure {
                return feedbackAvailabilityReply(failure)
            } catch {
                return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
            }
        } else {
            routeEnvironment = Self.feedbackLegacyRouteEnvironment(environment)
        }
        let reporterId: String
        do {
            reporterId = try ensureFeedbackRouteBinding(userId: userId, environment: routeEnvironment)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var presignedJSON: String?
        if let rawDiagnostics = fields["diagnostics"], !rawDiagnostics.isEmpty {
            guard let native = clientKind, ["android", "ios", "ohos"].contains(native),
                  let diagnostics = Self.validatedFeedbackDiagnostics(rawDiagnostics, appId: routeEnvironment.appId)
            else {
                return Self.json(400, "{\"error\":\"Invalid feedback diagnostics\",\"code\":\"feedback_diagnostics_invalid\"}")
            }
            presignedJSON = "[\("\(diagnostics)")]"
        }
        let appSlug = routeEnvironment.appSlug.isEmpty ? routeEnvironment.appId : routeEnvironment.appSlug
        guard !routeEnvironment.baseURL.isEmpty, !appSlug.isEmpty else {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_not_configured\"}")
        }
        let boundary = "raft-boundary-\(UUID().uuidString.lowercased())"
        var multipart = Data()
        func appendField(_ name: String, _ value: String) {
            multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("type", type)
        appendField("message", message)
        appendField("submission_id", submissionId)
        appendField("metadata", Self.serializeJSON(metadataObject))
        if let contact = fields["may_contact"] { appendField("may_contact", contact) }
        if let presignedJSON { appendField("presigned", presignedJSON) }
        multipart.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "\(routeEnvironment.baseURL)/public/v2/apps/\(appSlug)/feedback")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let bearerToken = routeEnvironment.appToken.isEmpty ? environment["HANDS_FEEDBACK_APP_TOKEN"] ?? "" : routeEnvironment.appToken
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if !routeEnvironment.clientKey.isEmpty {
            request.setValue(routeEnvironment.clientKey, forHTTPHeaderField: "X-Hands-Client-Key")
        }
        if !routeEnvironment.reporterIdSecret.isEmpty {
            request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        }
        request.httpBody = multipart
        let (upstreamStatus, upstreamHeaders, upstreamBody) = handsFeedbackSend(request)
        return feedbackSubmissionReply(
            upstreamStatus: upstreamStatus,
            upstreamHeaders: upstreamHeaders,
            upstreamBody: upstreamBody,
            presignedJSON: presignedJSON,
            feedbackStartedAt: feedbackStartedAt
        )
    }

    /// Shared upstream-outcome mapping for the synchronous and async submission
    /// entry points.
    func feedbackSubmissionReply(
        upstreamStatus: Int,
        upstreamHeaders: [String: String],
        upstreamBody: Data,
        presignedJSON: String?,
        feedbackStartedAt: Date
    ) -> HTTPReply {
        let upstreamJSON = (try? JSONSerialization.jsonObject(with: upstreamBody)) as? [String: Any] ?? [:]
        let upstreamCode = upstreamJSON["code"] as? String
        if upstreamStatus == 201 || upstreamStatus == 200 {
            let id = upstreamJSON["id"] as? String ?? UUID().uuidString.lowercased()
            let status = upstreamJSON["status"] as? String ?? "open"
            let body = FeedbackJSONCoding.string(FeedbackSubmissionResponse(id: id, status: status))
            var headers: [String: String] = [
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "no-store",
                "Content-Length": String(body.utf8.count),
            ]
            headers["Server-Timing"] = Self.feedbackTimingHeader(
                elapsedMs: Date().timeIntervalSince(feedbackStartedAt) * 1000,
                upstreamHeaders: upstreamHeaders
            )
            return HTTPReply(status: 201, headers: headers, body: body)
        }
        if upstreamStatus == 409 {
            return feedbackErrorReply(409, error: "This submission was already sent", code: "feedback_submission_conflict")
        }
        if upstreamStatus == 400, presignedJSON != nil,
           let upstreamCode, ["presigned_invalid", "presigned_not_found", "presigned_size_mismatch"].contains(upstreamCode) {
            return feedbackErrorReply(400, error: "The diagnostics upload was rejected", code: "feedback_diagnostics_rejected")
        }
        if upstreamStatus == 400 {
            return feedbackErrorReply(400, error: "Invalid feedback submission", code: "feedback_invalid")
        }
        if upstreamStatus == 401 || upstreamStatus == 403 {
            let upstreamError = Self.feedbackUpstreamError(upstreamJSON["error"] as? String)
            return Self.json(503, "{\"error\":\"Feedback integration is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\",\"upstream_status\":\(upstreamStatus),\"upstream_error\":\(jsonString(upstreamError))}")
        }
        if upstreamStatus == 413 {
            return feedbackErrorReply(413, error: "Feedback attachment is too large", code: "feedback_attachment_too_large")
        }
        if upstreamStatus == 429 {
            let retryAfter = upstreamHeaders.first { $0.key.lowercased() == "retry-after" }?.value ?? "60"
            return HTTPReply(status: 429, headers: ["Content-Type": AppFallback.jsonContentType, "Cache-Control": "no-store", "Retry-After": retryAfter], body: FeedbackJSONCoding.string(FeedbackErrorResponse(error: "Feedback is rate limited", code: "feedback_rate_limited")))
        }
        return feedbackErrorReply(503, error: "Feedback service is temporarily unavailable", code: "feedback_service_unavailable")
    }

    /// Async twin of `submitProductFeedback` used by `FeedbackFeature`.
    public func submitProductFeedbackAsync(authorization: String?, contentType: String, body: String, serverId: String = "", clientKindHeader: String = "") async -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let feedbackStartedAt = Date()
        let verified = feedbackLocked { accounts.values.first { $0.id == userId }?.emailVerified == true }
        guard verified else {
            return Self.json(403, "{\"error\":\"Email verification required\",\"code\":\"account_unverified\"}")
        }
        guard let fields = Self.multipartFields(body: body, contentType: contentType),
              let submissionId = fields["submission_id"],
              submissionId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil,
              let type = fields["type"], ["idea", "problem"].contains(type),
              let message = fields["message"], !message.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
        }
        if let rawMetadata = fields["metadata"], !rawMetadata.isEmpty {
            guard let metadata = (try? JSONSerialization.jsonObject(with: Data(rawMetadata.utf8))) as? [String: Any] else {
                return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
            }
            let nativeKinds = ["ios", "android", "macos", "windows", "linux"]
            if let clientKind = metadata["client_kind"] as? String, nativeKinds.contains(clientKind) {
                let platform = metadata["platform"] as? String ?? ""
                if platform != clientKind || metadata["browser"] != nil {
                    return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
                }
            }
            if let metadataKind = metadata["client_kind"] as? String,
               !Self.productFeedbackSources.contains(metadataKind) {
                return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
            }
        }
        var metadataObject: [String: Any] = [:]
        if let rawMetadata = fields["metadata"],
           let parsed = (try? JSONSerialization.jsonObject(with: Data(rawMetadata.utf8))) as? [String: Any] {
            metadataObject = parsed
        }
        if let reportId = fields["feedback_report_id"], !reportId.isEmpty {
            guard reportId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
                return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
            }
            metadataObject["feedback_report_id"] = reportId.lowercased()
            metadataObject["surface"] = "agent.report_issue"
        }
        let trustedClientKind: String
        do {
            trustedClientKind = try Self.feedbackSource(clientKindHeader)
        } catch {
            return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
        }
        if let metadataKind = metadataObject["client_kind"] as? String, metadataKind != trustedClientKind {
            return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
        }
        let clientKind = metadataObject["client_kind"] as? String
        if let clientKind, Self.productFeedbackSources.contains(clientKind), clientKind != "web" {
            var forwarded: [String: Any] = [
                "client_kind": clientKind,
                "platform": metadataObject["platform"] as? String ?? clientKind,
                "product_type": clientKind,
                "feedback_type": type,
                "contact_consent": fields["may_contact"] == "true",
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
        if ServerScope.isUUID(serverId),
           let profile = oauth.serverProfile(id: serverId),
           oauth.memberRole(serverId: serverId, userId: userId) != nil,
           !profile.slug.isEmpty {
            let handle = feedbackLocked { accounts.values.first { $0.id == userId }?.name ?? "" }
            metadataObject["reporter_attribution"] = [
                "v": 1,
                "server_id": serverId,
                "server_slug": profile.slug,
                "user_id": userId,
                "handle": handle,
            ]
        }
        let (environment, appsJSON) = feedbackLocked { (feedbackLegacyEnvironmentLocked(), handsFeedbackAppsJSONForTesting) }
        guard handsFeedbackConfigured || environment["HANDS_FEEDBACK_BASE_URL"] != nil else {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_not_configured\"}")
        }
        let multiEnabled = evaluateFeatureFlagKey(
            key: Self.productFeedbackMultiAppFlag,
            userId: userId,
            serverId: nil,
            platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        ).enabled
        let routeEnvironment: FeedbackRouteEnvironment
        if multiEnabled {
            do {
                routeEnvironment = try Self.feedbackMultiRouteEnvironment(
                    source: trustedClientKind,
                    appsJSON: appsJSON,
                    environment: environment
                )
            } catch let failure as FeedbackRouteFailure {
                return feedbackAvailabilityReply(failure)
            } catch {
                return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
            }
        } else {
            routeEnvironment = Self.feedbackLegacyRouteEnvironment(environment)
        }
        let reporterId: String
        do {
            reporterId = try await ensureFeedbackRouteBindingAsync(userId: userId, environment: routeEnvironment)
        } catch let failure as FeedbackRouteFailure {
            return feedbackAvailabilityReply(failure)
        } catch {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var presignedJSON: String?
        if let rawDiagnostics = fields["diagnostics"], !rawDiagnostics.isEmpty {
            guard let native = clientKind, ["android", "ios", "ohos"].contains(native),
                  let diagnostics = Self.validatedFeedbackDiagnostics(rawDiagnostics, appId: routeEnvironment.appId)
            else {
                return Self.json(400, "{\"error\":\"Invalid feedback diagnostics\",\"code\":\"feedback_diagnostics_invalid\"}")
            }
            presignedJSON = "[\("\(diagnostics)")]"
        }
        let appSlug = routeEnvironment.appSlug.isEmpty ? routeEnvironment.appId : routeEnvironment.appSlug
        guard !routeEnvironment.baseURL.isEmpty, !appSlug.isEmpty else {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_not_configured\"}")
        }
        let boundary = "raft-boundary-\(UUID().uuidString.lowercased())"
        var multipart = Data()
        func appendField(_ name: String, _ value: String) {
            multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("type", type)
        appendField("message", message)
        appendField("submission_id", submissionId)
        appendField("metadata", Self.serializeJSON(metadataObject))
        if let contact = fields["may_contact"] { appendField("may_contact", contact) }
        if let presignedJSON { appendField("presigned", presignedJSON) }
        multipart.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "\(routeEnvironment.baseURL)/public/v2/apps/\(appSlug)/feedback")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let bearerToken = routeEnvironment.appToken.isEmpty ? environment["HANDS_FEEDBACK_APP_TOKEN"] ?? "" : routeEnvironment.appToken
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if !routeEnvironment.clientKey.isEmpty {
            request.setValue(routeEnvironment.clientKey, forHTTPHeaderField: "X-Hands-Client-Key")
        }
        if !routeEnvironment.reporterIdSecret.isEmpty {
            request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        }
        request.httpBody = multipart
        let (upstreamStatus, upstreamHeaders, upstreamBody) = await handsFeedbackSendAsync(request)
        return feedbackSubmissionReply(
            upstreamStatus: upstreamStatus,
            upstreamHeaders: upstreamHeaders,
            upstreamBody: upstreamBody,
            presignedJSON: presignedJSON,
            feedbackStartedAt: feedbackStartedAt
        )
    }



    /// `POST /api/product-events/onboarding-wizard`.
    public func recordOnboardingWizard(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let serverEnabled = oauth.serverAnalyticsAllowed(id: serverId), serverEnabled else {
            return Self.json(204, "")
        }
        lock.lock()
        let shareUsageData = accounts.values.first(where: { $0.id == userId })?.shareUsageData
        lock.unlock()
        if shareUsageData == false {
            return Self.json(204, "")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let eventType = object["eventType"] as? String, !eventType.isEmpty,
              let rawMetadata = object["metadata"] as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid product event\"}")
        }
        let stepId = rawMetadata["step_id"] as? String ?? ""
        if eventType == "onboarding_wizard.step_shown", stepId == "enable-notifications" {
            return Self.json(400, "{\"error\":\"Only tracked onboarding wizard steps are accepted\"}")
        }
        let allowedKeys = ["step_id", "wizard_version", "session_id", "action", "result", "reason"]
        var sanitized: [String: Any] = [:]
        for key in allowedKeys {
            if let value = rawMetadata[key] as? String { sanitized[key] = value }
        }
        if let latency = rawMetadata["latency_ms"] as? Double {
            sanitized["latency_ms"] = Int(latency)
        } else if let latency = rawMetadata["latency_ms"] as? Int {
            sanitized["latency_ms"] = latency
        }
        let metadataJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) {
            metadataJSON = String(decoding: data, as: UTF8.self)
        } else {
            metadataJSON = "{}"
        }
        let record = RecordedProductEvent(
            subjectType: "onboarding_wizard",
            subjectId: serverId,
            eventType: eventType,
            actorType: "human",
            actorId: userId,
            source: "web",
            idempotencyKey: object["idempotencyKey"] as? String,
            metadataJSON: metadataJSON
        )
        productEventStore.append(record)
        return Self.json(204, "")
    }

    func authorize(_ authorization: String?) -> Auth {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .rejected(Self.missingAuthorization)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let id = accessTokens[token]
        let family = accessTokenFamilies[token]
        let familyRevoked = family.map { revokedFamilies.contains($0) } ?? false
        lock.unlock()
        guard let id, !familyRevoked else { return .rejected(Self.invalidToken) }
        return .user(id)
    }


    /// Shipped UI catalogs only. Region tags collapse inside `en` and `zh-cn`; `zh-TW` and `fr` do not.
    static func normalizeDisplayLocale(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        if value == "zh-cn" || value == "zh" || value == "zh-hans" || value == "zh-hans-cn" { return "zh-cn" }
        return nil
    }



    static let reservedAgentNames: Set<String> = [
        "all", "human", "humans", "agent", "agents", "here", "idle", "busy", "system", "reminders",
    ]

    /// Final handles stay unclaimed until profile setup. The stored name is `pending_` plus 20 hex characters.
    static func pendingHandle(taken: Set<String>) -> String {
        for _ in 0..<10 {
            let handle = "pending_\(randomHex(10))"
            if !taken.contains(handle) { return handle }
        }
        return "pending_\(randomHex(10))"
    }

    static func slugifyUserName(_ seed: String) -> String {
        let lowered = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var normalized = ""
        for scalar in lowered.unicodeScalars {
            let value = scalar.value
            let allowed = (value >= 97 && value <= 122) || (value >= 48 && value <= 57) || value == 95 || value == 45
            normalized.append(allowed ? Character(scalar) : "-")
        }
        normalized = trimHyphens(normalized)
        let prefixed = normalized.first?.isLetter == true ? normalized : "user-\(normalized)"
        var compact = ""
        var previousHyphen = false
        for character in prefixed {
            if character == "-" {
                if previousHyphen { continue }
                previousHyphen = true
            } else {
                previousHyphen = false
            }
            compact.append(character)
        }
        compact = trimHyphens(compact)
        let fallback = compact.isEmpty ? "user-account" : compact
        return fallback.count >= 5 ? fallback : "\(fallback)-user"
    }

    static func availableUserName(seed: String, taken: Set<String>) -> String {
        let base = slugifyUserName(seed)
        if !taken.contains(base) { return base }
        for suffix in 1..<100 {
            let candidate = "\(base)-\(suffix + 1)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(base)-\(randomHex(2))"
    }



    /// `dm:@reminders` names an agent's private reminder conversation, so the handle is reserved.
    static func isReservedAgentName(_ name: String) -> Bool {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("@") { normalized.removeFirst() }
        return reservedAgentNames.contains(normalized.lowercased())
    }


    static let maxProfileAvatarBytes = 5 * 1024 * 1024

    public static func sha256Hex(_ value: String) -> String {
        sha256(value)
    }





    static func refreshAttempt(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^arf_[0-9a-f]{16}$/) != nil else { return nil }
        return trimmed
    }

    static func refreshInstallation(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^ari_[0-9a-f]{32}$/) != nil else { return nil }
        return trimmed
    }

    public static func signSocialAuthState(_ state: SocialAuthState) -> String {
        let header = base64url(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        var payload: [String: Any] = [
            "provider": state.provider,
            "mode": state.mode,
            "nonce": state.nonce,
            "kind": state.kind,
            "mobileRequestId": state.mobileRequestId,
            "iss": "slock-social-auth",
            "aud": "social-auth-state",
            "exp": Int(Date().timeIntervalSince1970) + 600,
        ]
        if let desktopNonce = state.desktopNonce {
            payload["desktopNonce"] = desktopNonce
        }
        if let returnTo = state.returnTo {
            payload["returnTo"] = returnTo
        }
        if let linkUserId = state.linkUserId {
            payload["linkUserId"] = linkUserId
        }
        if state.linkOnConflict {
            payload["linkOnConflict"] = true
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = base64url(encoded)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: stateKey))
        return "\(header).\(body).\(base64url(mac))"
    }

    public static func verifySocialAuthState(_ token: String) -> SocialAuthState? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3 else { return nil }
        let signing = Data("\(parts[0]).\(parts[1])".utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: signing, using: stateKey))
        guard let given = base64urlDecode(parts[2]), given == expected else { return nil }
        guard let payload = base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let provider = object["provider"] as? String,
              let mode = object["mode"] as? String,
              let nonce = object["nonce"] as? String,
              let kind = object["kind"] as? String,
              let requestId = object["mobileRequestId"] as? String,
              (object["iss"] as? String) == "slock-social-auth",
              (object["aud"] as? String) == "social-auth-state"
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        return SocialAuthState(
            provider: provider,
            mode: mode,
            nonce: nonce,
            kind: kind,
            mobileRequestId: requestId,
            desktopNonce: object["desktopNonce"] as? String,
            returnTo: object["returnTo"] as? String,
            linkUserId: object["linkUserId"] as? String,
            linkOnConflict: object["linkOnConflict"] as? Bool ?? false
        )
    }

    static let stateKey = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-social-auth-state".utf8))))











    func verifyMobileAppEmailUnsubscribeToken(_ token: String) -> (userId: String, locale: String)? {
        guard !token.isEmpty, token.count <= 512 else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let expected = Self.mobileAppUnsubscribeSignature(payload: parts[0], secret: mobileAppEmailUnsubscribeSecret)
        guard parts[1] == expected else { return nil }
        guard let data = Self.base64urlDecode(parts[0]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted().joined(separator: ",") == "locale,sub,typ,v"
        else { return nil }
        let version = (object["v"] as? NSNumber)?.intValue ?? (object["v"] as? Int)
        guard version == 1,
              (object["typ"] as? String) == "mobile-app-email-unsubscribe",
              let userId = object["sub"] as? String,
              Self.isMobileUnsubscribeUserId(userId),
              let locale = object["locale"] as? String,
              locale == "en" || locale == "zh-cn"
        else { return nil }
        return (userId, locale)
    }

    /// `GET /api/email/mobile-app/unsubscribe`. A valid token shows the confirmation page and writes nothing.
    public func mobileAppEmailUnsubscribePage(token: String?) -> HTTPReply {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token) else {
            return Self.mobileAppUnsubscribeInvalid()
        }
        let copy = Self.mobileAppUnsubscribeCopy(identity.locale)
        let action = "/api/email/mobile-app/unsubscribe?token=\(Self.urlQuery(token))&source=visible"
        let body = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.confirmationHeading)</h1><p style=\"margin:0 0 20px;line-height:1.5;\">\(copy.confirmationBody)</p><form method=\"post\" action=\"\(action)\"><input type=\"hidden\" name=\"List-Unsubscribe\" value=\"One-Click\"><button type=\"submit\" style=\"cursor:pointer;padding:10px 16px;border:2px solid #141111;border-radius:8px;background:#fe7da8;color:#141111;font:inherit;font-weight:700;box-shadow:2px 2px 0 #141111;\">\(copy.submit)</button></form>"
        return Self.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.confirmationTitle, body: body)
    }

    /// `POST /api/email/mobile-app/unsubscribe`. One-click is an empty 200. A visible submit is the success page.
    public func mobileAppEmailUnsubscribeSubmit(token: String?, source: String?, body: String) -> HTTPReply {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token),
              Self.formField(body, "List-Unsubscribe") == "One-Click"
        else { return Self.mobileAppUnsubscribeInvalid() }
        recordMobileAppEmailOptOut(userId: identity.userId)
        let copy = Self.mobileAppUnsubscribeCopy(identity.locale)
        if source == "visible" {
            let page = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.successHeading)</h1><p style=\"margin:0;line-height:1.5;\">\(copy.successBody)</p>"
            return Self.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.successTitle, body: page)
        }
        return Self.text(200, "")
    }

    func recordMobileAppEmailOptOut(userId: String) {
        lock.lock()
        guard let account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return
        }
        let email = Self.normalize(account.email)
        guard !email.isEmpty else {
            lock.unlock()
            return
        }
        let audienceId = "mobile-app-lifecycle"
        mobileAppEmailContactsByKey["\(audienceId)\n\(email)"] = MobileAppEmailContact(
            userId: userId,
            email: email,
            audienceId: audienceId,
            status: "unsubscribed",
            optedOutAt: Date()
        )
        let emailIds = storedMobileAppEmailJourneys.compactMap { row -> String? in
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  !emailId.isEmpty,
                  row.userId == userId || Self.normalize(row.email) == email
            else { return nil }
            return emailId
        }
        let cancel = cancelMobileAppEmail
        lock.unlock()
        for emailId in emailIds {
            cancel?(emailId)
        }
        guard !emailIds.isEmpty else { return }
        lock.lock()
        let canceledAt = Date()
        for index in storedMobileAppEmailJourneys.indices {
            let row = storedMobileAppEmailJourneys[index]
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  emailIds.contains(emailId),
                  row.userId == userId || Self.normalize(row.email) == email
            else { continue }
            storedMobileAppEmailJourneys[index].day1Status = "skipped"
            storedMobileAppEmailJourneys[index].suppressedReason = "unsubscribed"
            storedMobileAppEmailJourneys[index].canceledAt = canceledAt
        }
        lock.unlock()
    }











    static let appleNotConfigured = json(404, "{\"code\":\"provider_not_configured\",\"error\":\"Apple sign-in is not configured\"}")
    static let nativeAppleInvalidRequest = json(400, "{\"code\":\"invalid_request\",\"error\":\"Native Apple sign-in requires the iOS platform and app environment\"}")
    static let nativeAppleInvalidCredential = json(400, "{\"code\":\"native_apple_invalid_credential\",\"error\":\"Apple sign-in credential was invalid\"}")
    static let nativeAppleAuthRequired = json(401, "{\"code\":\"auth_required\",\"error\":\"Apple account linking requires authentication\"}")
    static let nativeAppleLinkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Apple account linking does not match the authenticated user\"}")
    static let nativeAppleRequestExpired = json(410, "{\"code\":\"native_apple_request_expired\",\"error\":\"Apple sign-in request expired\"}")
    static let nativeAppleRequestConsumed = json(410, "{\"code\":\"native_apple_request_consumed\",\"error\":\"Apple sign-in request was already used\"}")




    func nativeAppleAvailable() -> Bool {
        lock.lock()
        let configured = !nativeAppleClientId.isEmpty && !nativeAppleClientSecret.isEmpty
        let gate = appleLoginPlatforms.contains("mobile")
        lock.unlock()
        return configured && gate
    }

    public static func signNativeAppleRequestToken(secret: String, requestId: String, mode: String, codeChallenge: String, expiresAt: Date, userId: String? = nil) -> String {
        let header = base64url(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        var payload: [String: Any] = [
            "kind": "native_apple_ios",
            "requestId": requestId,
            "mode": mode,
            "codeChallenge": codeChallenge,
            "iss": "slock-native-apple-auth",
            "aud": "native-apple-auth-request",
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
        if let userId { payload["userId"] = userId }
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = base64url(encoded)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: key))
        return "\(header).\(body).\(base64url(mac))"
    }


    func parseAppleIdentity(_ token: String) -> AppleIdentityClaims? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = Self.base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let payloadData = Self.base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              object["iss"] as? String == "https://appleid.apple.com",
              object["aud"] as? String == nativeAppleClientId,
              let subject = object["sub"] as? String, !subject.isEmpty,
              let nonce = object["nonce"] as? String, !nonce.isEmpty
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        let rawEmail = (object["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if rawEmail.isEmpty {
            return AppleIdentityClaims(subject: subject, nonce: nonce, email: nil)
        }
        let verified: Bool
        if let flag = object["email_verified"] as? Bool {
            verified = flag
        } else if let flag = object["email_verified"] as? String {
            verified = flag == "true"
        } else {
            verified = false
        }
        guard verified else { return nil }
        return AppleIdentityClaims(subject: subject, nonce: nonce, email: rawEmail)
    }

    func mobileAppleAvailable() -> Bool {
        lock.lock()
        let configured = configuredSocialAuthProviders.contains("apple")
        let allowed = appleLoginPlatforms.contains("mobile")
        lock.unlock()
        return configured && allowed
    }

    func webProviderAvailable(_ provider: String) -> Bool {
        lock.lock()
        let configured = configuredSocialAuthProviders.contains(provider)
        let allowed = appleLoginPlatforms.contains("web")
        lock.unlock()
        guard configured else { return false }
        if provider == "apple" { return allowed }
        return true
    }

    func webAuthorizationURL(provider: String, state: String, nonce: String) -> String {
        guard provider == "apple" else {
            return Self.authorizationURL(provider: provider, state: state)
        }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appleClientId),
            URLQueryItem(name: "redirect_uri", value: "\(base)/api/auth/apple/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        return components.string ?? ""
    }

    func stateCookie(provider: String, nonce: String) -> String {
        let encoded = nonce.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nonce
        var parts = [
            "slock_\(provider)_oauth_nonce=\(encoded)",
            "Path=/api/auth/\(provider)/callback",
            "Max-Age=600",
            "HttpOnly",
            "SameSite=\(provider == "apple" ? "None" : "Lax")",
        ]
        if provider == "apple" || serverURL.hasPrefix("https://") {
            parts.append("Secure")
        }
        return parts.joined(separator: "; ")
    }








}

/// One stored agent runtime profile row: the machine it runs on plus any
/// pending migration release state. The delete-machine path treats these as
/// the authority on which Computers may still be removed.
public struct AgentRuntimeProfileFact: Sendable, Equatable {
    public var agentId: String
    public var machineId: String
    public var baselineMachineId: String?
    public var pendingBeforeMachineId: String?
    public var pendingAfterMachineId: String?
    public var migrationStatus: String?
    public var pendingKind: String?
    public var pendingReleaseNotesUrl: String?

    public init(
        agentId: String,
        machineId: String,
        baselineMachineId: String? = nil,
        pendingBeforeMachineId: String? = nil,
        pendingAfterMachineId: String? = nil,
        migrationStatus: String? = nil,
        pendingKind: String? = nil,
        pendingReleaseNotesUrl: String? = nil
    ) {
        self.agentId = agentId
        self.machineId = machineId
        self.baselineMachineId = baselineMachineId
        self.pendingBeforeMachineId = pendingBeforeMachineId
        self.pendingAfterMachineId = pendingAfterMachineId
        self.migrationStatus = migrationStatus
        self.pendingKind = pendingKind
        self.pendingReleaseNotesUrl = pendingReleaseNotesUrl
    }
}

/// Outcome of a target-side agent start attempt during migration arrival.
public enum MachineMigrationAgentStartOutcome: Sendable, Equatable {
    /// The daemon accepted the launch; the migration completes.
    case dispatched
    /// A gate (for example a held wake lock) suppressed the launch; the
    /// migration stays in `starting` so the arrival callback can retry.
    case skipped(String)
}

/// Outcome of an agent start dispatch (for example a resume-all prompt).
public enum AgentStartDispatchOutcome: Sendable, Equatable {
    /// The daemon accepted the start and will run the agent.
    case dispatched
    /// A gate (for example a held wake lock) suppressed the start.
    case skipped(String)
}

/// Outcome of the Built-in model catalog check for a target Computer.
public enum BuiltinModelCatalogResult: Sendable, Equatable {
    case supported
    case modelAbsent
    case catalogUnavailable
}

/// Result of one machine-backed agent surface read.
public enum AgentSurfaceResult: Sendable, Equatable {
    case ok(String)
    case machineUnassigned
    case machineOffline
    case machineTimeout
}

/// A code-shaped source-archive failure reported by the source Computer.
public struct MachineMigrationArchiveFailure: Error, Sendable, Equatable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// Test-observable mirror of the in-memory machine migration row.
public struct MachineMigrationStateSnapshot: Sendable, Equatable {
    public var state: String
    public var revision: Int
    public var agentId: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var transportGeneration: String
    public var flippedAt: Date?
    public var arrivedAt: Date?
    public var completedAt: Date?
    public var updatedAt: Date
    public var failureReason: String?
    public var transportErrorCode: String?
    public var transportErrorMessage: String?
    public var autoStartFailureStage: String?
    public var autoStartFailureCode: String?
    public var sourceWorkspaceArchivedAt: Date?
    public var sourceWorkspaceArchiveAttempts: Int
    public var sourceWorkspaceArchiveLastError: String?
    public var sourceWorkspaceArchiveRetryAt: Date?
    public var sourceWorkspaceArchiveAbandonedAt: Date?
    public var cancelDisposition: String?
    public var cancelSourceAck: String?
    public var cancelTargetAck: String?
    public var cancelSourceAckAt: Date?
    public var cancelTargetAckAt: Date?
    public var canceledAt: Date?
    public var transportTeardownAt: Date?
}

/// One agent migration row. Terminal rows stay behind as history after the
/// source Computer is deleted.
public struct AgentMigrationFact: Sendable, Equatable {
    public var agentId: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var state: String

    public init(agentId: String, sourceMachineId: String, targetMachineId: String, state: String) {
        self.agentId = agentId
        self.sourceMachineId = sourceMachineId
        self.targetMachineId = targetMachineId
        self.state = state
    }
}

/// One probed runtime model with its optional reasoning metadata.
public struct RuntimeModelProbeModel: Sendable, Equatable {
    public var id: String
    public var label: String
    public var supportedReasoningEfforts: [String]?
    public var defaultReasoningEffort: String?

    public init(
        id: String,
        label: String,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.label = label
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

/// The Computer's answer to a runtime model probe.
public enum RuntimeModelProbeOutcome: Sendable, Equatable {
    case live(models: [RuntimeModelProbeModel], default: String?)
    case models(models: [RuntimeModelProbeModel], default: String?)
    case missingConfig
    case noModels
    case unsupported
    case error(code: String, retryable: Bool)
    case failed
}

/// One agent (runner) thread follow row.
public struct AgentThreadFollowRecord: Sendable, Equatable {
    public var serverId: String
    public var agentId: String
    public var threadChannelId: String
    public var parentMessageId: String
    public var followedAt: Date
    public var reason: String
    public var doneAt: Date?
    public var unfollowedAt: Date?

    public init(
        serverId: String,
        agentId: String,
        threadChannelId: String,
        parentMessageId: String,
        followedAt: Date,
        reason: String,
        doneAt: Date? = nil,
        unfollowedAt: Date? = nil
    ) {
        self.serverId = serverId
        self.agentId = agentId
        self.threadChannelId = threadChannelId
        self.parentMessageId = parentMessageId
        self.followedAt = followedAt
        self.reason = reason
        self.doneAt = doneAt
        self.unfollowedAt = unfollowedAt
    }
}

/// One agent login into a server integration service.
public struct AgentIntegrationLoginRecord: Sendable, Equatable {
    public var serverId: String
    public var agentId: String
    public var clientId: String
    public var scopes: [String]
    public var loggedInAt: Date

    public init(serverId: String, agentId: String, clientId: String, scopes: [String], loggedInAt: Date) {
        self.serverId = serverId
        self.agentId = agentId
        self.clientId = clientId
        self.scopes = scopes
        self.loggedInAt = loggedInAt
    }
}

/// One attachment comment row.
public struct AttachmentCommentRecord: Sendable, Equatable {
    public var id: String
    public var attachmentId: String
    public var content: String
    public var anchorJSON: String?
    public var senderId: String
    public var senderType: String
    public var createdAt: Date
    public var threadChannelId: String?
    public var hostMessageId: String?
    public var hostChannelId: String?

    public init(
        id: String,
        attachmentId: String,
        content: String,
        anchorJSON: String?,
        senderId: String,
        senderType: String,
        createdAt: Date,
        threadChannelId: String? = nil,
        hostMessageId: String? = nil,
        hostChannelId: String? = nil
    ) {
        self.id = id
        self.attachmentId = attachmentId
        self.content = content
        self.anchorJSON = anchorJSON
        self.senderId = senderId
        self.senderType = senderType
        self.createdAt = createdAt
        self.threadChannelId = threadChannelId
        self.hostMessageId = hostMessageId
        self.hostChannelId = hostChannelId
    }
}

// MARK: - Store-backed test seams

/// `EmailLogin.swift` keeps no `ForTesting` storage: each of these accessors
/// forwards to a domain store whose property carries the production name.
extension EmailLoginDirectory {
    /// Forces the next session issuance to fail so the pending link rolls back.
    public var failNextSessionIssuanceForTesting: Bool {
        get { authProfileStore.failNextSessionIssuance }
        set { authProfileStore.failNextSessionIssuance = newValue }
    }

    var handsConversationSessionEnabledForTesting: Bool? {
        get { authProfileStore.handsConversationSessionEnabled }
        set { authProfileStore.handsConversationSessionEnabled = newValue }
    }

    var handsFeedbackWarningSinkForTesting: ((String) -> Void)? {
        get { authProfileStore.handsFeedbackWarningSink }
        set { authProfileStore.handsFeedbackWarningSink = newValue }
    }

    var experimentalSurfacesDisabledForTesting: Bool? {
        get { authProfileStore.experimentalSurfacesDisabledOverride }
        set { authProfileStore.experimentalSurfacesDisabledOverride = newValue }
    }

    var inboxResiduesForTesting: Set<String> {
        get { messagesAndThreadsStore.inboxResidues }
        set { messagesAndThreadsStore.inboxResidues = newValue }
    }

    var userChannelReadCursorsForTesting: [String: Int] {
        get { messagesAndThreadsStore.userChannelReadCursors }
        set { messagesAndThreadsStore.userChannelReadCursors = newValue }
    }

    var agentInboxAvailableForTesting: Bool? {
        get { agentsRuntimeStore.agentInboxAvailable }
        set { agentsRuntimeStore.agentInboxAvailable = newValue }
    }

    var machineBroadcastPoliciesForTesting: [String: String] {
        get { machinesAndComputersStore.machineBroadcastPolicies }
        set { machinesAndComputersStore.machineBroadcastPolicies = newValue }
    }

    var machineModelSeenCapabilityForTesting: Set<String> {
        get { machinesAndComputersStore.machineModelSeenCapability }
        set { machinesAndComputersStore.machineModelSeenCapability = newValue }
    }

    var latestComputerReleaseForTesting: (version: String, notesJSON: String)? {
        get { machinesAndComputersStore.latestComputerRelease }
        set { machinesAndComputersStore.latestComputerRelease = newValue }
    }

    var handsFeedbackAppsJSONForTesting: String? {
        get { feedbackStore.handsFeedbackAppsJSON }
        set { feedbackStore.handsFeedbackAppsJSON = newValue }
    }

    var handsFeedbackLegacyEnvironmentForTesting: [String: String]? {
        get { feedbackStore.handsFeedbackLegacyEnvironment }
        set { feedbackStore.handsFeedbackLegacyEnvironment = newValue }
    }
}
