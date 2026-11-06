import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Product-feedback submissions (`POST /api/feedback` and the async relay).
/// Migrated verbatim from the production methods at the top of `EmailLogin+TestSeams.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ProductFeedbackSubmissionService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
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
        let appsJSON = handsFeedbackAppsJSON
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
        let (environment, appsJSON) = feedbackLocked { (feedbackLegacyEnvironmentLocked(), handsFeedbackAppsJSON) }
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
}
