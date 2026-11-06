import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Product-feedback ticket surface (`/api/product-feedback/tickets…`).
///
/// The synchronous entry points stay for the extracted route tests that mount
/// synchronous closures; the `…Async` twins are what `FeedbackFeature` calls.
/// Both share the same validation, routing and reply mapping through
/// `FeedbackService`, which owns the transport and the route-binding plumbing.
struct FeedbackMultiAppService {
    let directory: EmailLoginDirectory

    init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    private var feedback: FeedbackService { FeedbackService(directory: directory) }

    // MARK: - Ticket list

    /// `GET /api/product-feedback/tickets`.
    func tickets(
        authorization: String?,
        clientKindHeader: String = "",
        cursor: String? = nil
    ) -> HTTPReply {
        let service = feedback
        let listStartedAt = Date()
        guard let userId = directory.sessionUserId(authorization: authorization) else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let verified = service.locked { directory.accounts.values.first { $0.id == userId }?.emailVerified == true }
        guard verified else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Email verification required\",\"code\":\"account_unverified\"}")
        }
        let source: String
        do {
            source = try EmailLoginDirectory.feedbackSource(clientKindHeader)
        } catch {
            return service.sourceInvalidReply()
        }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
        }
        let conversationToken = environment.conversationToken.isEmpty
            ? environment.appToken
            : environment.conversationToken
        guard !environment.baseURL.isEmpty, !conversationToken.isEmpty else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\"}")
        }
        let reporterId: String
        do {
            reporterId = try service.ensureRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try service.bearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var handsCursor: String?
        if let cursor, !cursor.isEmpty {
            guard !environment.cursorSecret.isEmpty else { return service.sourceInvalidReply() }
            do {
                handsCursor = try EmailLoginDirectory.feedbackDecodeCursor(
                    cursor,
                    route: "ticket_list",
                    userId: userId,
                    ticketId: nil,
                    cursorKey: environment.cursorSecret
                )
            } catch {
                return service.sourceInvalidReply()
            }
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback?limit=50"
        if let handsCursor {
            path += "&cursor=" + EmailLoginDirectory.feedbackPercentEncoded(handsCursor)
        }
        let (status, headers, body) = service.handsRequest(
            environment: environment,
            method: "GET",
            path: path,
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return service.conversationReply(status: status, upstreamHeaders: headers, body: body)
        }
        var replyBody = String(decoding: body, as: UTF8.self)
        if !environment.cursorSecret.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let next = object["next_cursor"] as? String, !next.isEmpty,
           let encoded = EmailLoginDirectory.feedbackEncodeCursor(
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
        return service.jsonReply(
            status: 200,
            body: replyBody,
            elapsed: listStartedAt,
            upstreamHeaders: headers
        )
    }

    /// `GET /api/product-feedback/tickets` for the Vapor route closure.
    func ticketsAsync(
        authorization: String?,
        clientKindHeader: String = "",
        cursor: String? = nil
    ) async -> HTTPReply {
        let service = feedback
        let listStartedAt = Date()
        guard let userId = directory.sessionUserId(authorization: authorization) else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let verified = service.locked { directory.accounts.values.first { $0.id == userId }?.emailVerified == true }
        guard verified else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Email verification required\",\"code\":\"account_unverified\"}")
        }
        let source: String
        do {
            source = try EmailLoginDirectory.feedbackSource(clientKindHeader)
        } catch {
            return service.sourceInvalidReply()
        }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
        }
        let conversationToken = environment.conversationToken.isEmpty
            ? environment.appToken
            : environment.conversationToken
        guard !environment.baseURL.isEmpty, !conversationToken.isEmpty else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\"}")
        }
        let reporterId: String
        do {
            reporterId = try await service.ensureRouteBindingAsync(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try await service.bearerAsync(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var handsCursor: String?
        if let cursor, !cursor.isEmpty {
            guard !environment.cursorSecret.isEmpty else { return service.sourceInvalidReply() }
            do {
                handsCursor = try EmailLoginDirectory.feedbackDecodeCursor(
                    cursor,
                    route: "ticket_list",
                    userId: userId,
                    ticketId: nil,
                    cursorKey: environment.cursorSecret
                )
            } catch {
                return service.sourceInvalidReply()
            }
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback?limit=50"
        if let handsCursor {
            path += "&cursor=" + EmailLoginDirectory.feedbackPercentEncoded(handsCursor)
        }
        let (status, headers, body) = await service.handsRequestAsync(
            environment: environment,
            method: "GET",
            path: path,
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return service.conversationReply(status: status, upstreamHeaders: headers, body: body)
        }
        var replyBody = String(decoding: body, as: UTF8.self)
        if !environment.cursorSecret.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let next = object["next_cursor"] as? String, !next.isEmpty,
           let encoded = EmailLoginDirectory.feedbackEncodeCursor(
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
        return service.jsonReply(
            status: 200,
            body: replyBody,
            elapsed: listStartedAt,
            upstreamHeaders: headers
        )
    }

    // MARK: - Close

    /// `POST /api/product-feedback/tickets/:ticketId/close`.
    func closeTicket(
        authorization: String?,
        ticketId: String,
        body: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        let service = feedback
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        let reason = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["reason"] as? String
        guard reason == "completed" || reason == "no_longer_needed" else {
            return EmailLoginDirectory.json(400, "{\"error\":\"Feedback close reason is invalid\",\"code\":\"feedback_invalid\"}")
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try service.ensureRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try service.bearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, upstreamBody) = service.handsRequest(
            environment: environment,
            method: "POST",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/close",
            bearer: bearer,
            reporterId: reporterId,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
        return service.conversationReply(status: status, upstreamHeaders: headers, body: upstreamBody)
    }

    /// `POST /api/product-feedback/tickets/:ticketId/close` for Vapor.
    func closeTicketAsync(
        authorization: String?,
        ticketId: String,
        body: String,
        clientKindHeader: String = ""
    ) async -> HTTPReply {
        let service = feedback
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        let reason = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["reason"] as? String
        guard reason == "completed" || reason == "no_longer_needed" else {
            return EmailLoginDirectory.json(400, "{\"error\":\"Feedback close reason is invalid\",\"code\":\"feedback_invalid\"}")
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try await service.ensureRouteBindingAsync(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try await service.bearerAsync(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, upstreamBody) = await service.handsRequestAsync(
            environment: environment,
            method: "POST",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/close",
            bearer: bearer,
            reporterId: reporterId,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
        return service.conversationReply(status: status, upstreamHeaders: headers, body: upstreamBody)
    }

    // MARK: - Reply

    /// `POST /api/product-feedback/tickets/:ticketId/comments`.
    func replyTicket(
        authorization: String?,
        ticketId: String,
        contentType: String,
        body: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        let service = feedback
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        for part in body.components(separatedBy: "Content-Disposition: form-data") {
            guard part.contains("filename=\"") else { continue }
            let lower = part.lowercased()
            let allowed = lower.contains("content-type: image/png") || lower.contains("content-type: image/jpeg")
                || lower.contains("content-type: image/webp") || lower.contains("content-type: image/gif")
            if !allowed {
                return EmailLoginDirectory.json(400, "{\"error\":\"Only image attachments are supported\",\"code\":\"feedback_attachment_type_invalid\"}")
            }
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try service.ensureRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try service.bearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, upstreamBody) = service.handsRequest(
            environment: environment,
            method: "POST",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/comments",
            bearer: bearer,
            reporterId: reporterId,
            headers: ["Content-Type": contentType],
            body: Data(body.utf8)
        )
        return service.conversationReply(status: status, upstreamHeaders: headers, body: upstreamBody)
    }

    /// `POST /api/product-feedback/tickets/:ticketId/comments` for Vapor.
    func replyTicketAsync(
        authorization: String?,
        ticketId: String,
        contentType: String,
        body: String,
        clientKindHeader: String = ""
    ) async -> HTTPReply {
        let service = feedback
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        for part in body.components(separatedBy: "Content-Disposition: form-data") {
            guard part.contains("filename=\"") else { continue }
            let lower = part.lowercased()
            let allowed = lower.contains("content-type: image/png") || lower.contains("content-type: image/jpeg")
                || lower.contains("content-type: image/webp") || lower.contains("content-type: image/gif")
            if !allowed {
                return EmailLoginDirectory.json(400, "{\"error\":\"Only image attachments are supported\",\"code\":\"feedback_attachment_type_invalid\"}")
            }
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try await service.ensureRouteBindingAsync(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try await service.bearerAsync(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, upstreamBody) = await service.handsRequestAsync(
            environment: environment,
            method: "POST",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/comments",
            bearer: bearer,
            reporterId: reporterId,
            headers: ["Content-Type": contentType],
            body: Data(body.utf8)
        )
        return service.conversationReply(status: status, upstreamHeaders: headers, body: upstreamBody)
    }

    // MARK: - Ticket detail

    /// `GET /api/product-feedback/tickets/:ticketId`.
    func ticket(
        authorization: String?,
        ticketId: String,
        clientKindHeader: String = "",
        commentLimit: Int = 50,
        commentCursor: String? = nil
    ) -> HTTPReply {
        let service = feedback
        let startedAt = Date()
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        guard commentLimit >= 1, commentLimit <= 100 else {
            return EmailLoginDirectory.json(400, "{\"error\":\"Invalid feedback request\",\"code\":\"feedback_invalid\"}")
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try service.ensureRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try service.bearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var handsCursor: String?
        if let commentCursor, !commentCursor.isEmpty {
            guard !environment.cursorSecret.isEmpty else { return service.sourceInvalidReply() }
            do {
                handsCursor = try EmailLoginDirectory.feedbackDecodeCursor(
                    commentCursor,
                    route: "ticket_comments",
                    userId: userId,
                    ticketId: ticketId,
                    cursorKey: environment.cursorSecret
                )
            } catch {
                return service.sourceInvalidReply()
            }
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)?comment_limit=\(commentLimit)"
        if let handsCursor {
            path += "&comment_cursor=" + EmailLoginDirectory.feedbackPercentEncoded(handsCursor)
        }
        let (status, headers, body) = service.handsRequest(
            environment: environment,
            method: "GET",
            path: path,
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return service.conversationReply(status: status, upstreamHeaders: headers, body: body)
        }
        var replyBody = String(decoding: body, as: UTF8.self)
        if !environment.cursorSecret.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let next = object["next_comment_cursor"] as? String, !next.isEmpty,
           let encoded = EmailLoginDirectory.feedbackEncodeCursor(
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
        return service.jsonReply(status: 200, body: replyBody, elapsed: startedAt, upstreamHeaders: headers)
    }

    /// `GET /api/product-feedback/tickets/:ticketId` for Vapor.
    func ticketAsync(
        authorization: String?,
        ticketId: String,
        clientKindHeader: String = "",
        commentLimit: Int = 50,
        commentCursor: String? = nil
    ) async -> HTTPReply {
        let service = feedback
        let startedAt = Date()
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        guard commentLimit >= 1, commentLimit <= 100 else {
            return EmailLoginDirectory.json(400, "{\"error\":\"Invalid feedback request\",\"code\":\"feedback_invalid\"}")
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try await service.ensureRouteBindingAsync(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try await service.bearerAsync(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        var handsCursor: String?
        if let commentCursor, !commentCursor.isEmpty {
            guard !environment.cursorSecret.isEmpty else { return service.sourceInvalidReply() }
            do {
                handsCursor = try EmailLoginDirectory.feedbackDecodeCursor(
                    commentCursor,
                    route: "ticket_comments",
                    userId: userId,
                    ticketId: ticketId,
                    cursorKey: environment.cursorSecret
                )
            } catch {
                return service.sourceInvalidReply()
            }
        }
        var path = "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)?comment_limit=\(commentLimit)"
        if let handsCursor {
            path += "&comment_cursor=" + EmailLoginDirectory.feedbackPercentEncoded(handsCursor)
        }
        let (status, headers, body) = await service.handsRequestAsync(
            environment: environment,
            method: "GET",
            path: path,
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return service.conversationReply(status: status, upstreamHeaders: headers, body: body)
        }
        var replyBody = String(decoding: body, as: UTF8.self)
        if !environment.cursorSecret.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let next = object["next_comment_cursor"] as? String, !next.isEmpty,
           let encoded = EmailLoginDirectory.feedbackEncodeCursor(
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
        return service.jsonReply(status: 200, body: replyBody, elapsed: startedAt, upstreamHeaders: headers)
    }

    // MARK: - Attachment

    /// `GET /api/product-feedback/tickets/:ticketId/attachments/:attachmentId`.
    func attachment(
        authorization: String?,
        ticketId: String,
        attachmentId: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        let service = feedback
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId),
              EmailLoginDirectory.feedbackCanonicalUUID(attachmentId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try service.ensureRouteBinding(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try service.bearer(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, body) = service.handsRequest(
            environment: environment,
            method: "GET",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/attachments/\(attachmentId)",
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return service.conversationReply(status: status, upstreamHeaders: headers, body: body)
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

    /// `GET /api/product-feedback/tickets/:ticketId/attachments/:attachmentId`
    /// for Vapor.
    func attachmentAsync(
        authorization: String?,
        ticketId: String,
        attachmentId: String,
        clientKindHeader: String = ""
    ) async -> HTTPReply {
        let service = feedback
        if let rejected = service.conversationRejectedReply(authorization: authorization) { return rejected }
        let userId = directory.sessionUserId(authorization: authorization)!
        guard EmailLoginDirectory.feedbackCanonicalUUID(ticketId),
              EmailLoginDirectory.feedbackCanonicalUUID(attachmentId) else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")
        }
        let source: String
        do { source = try EmailLoginDirectory.feedbackSource(clientKindHeader) } catch { return service.sourceInvalidReply() }
        let environment: FeedbackRouteEnvironment
        do {
            environment = try service.routeEnvironment(source: source, userId: userId)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let reporterId: String
        do {
            reporterId = try await service.ensureRouteBindingAsync(userId: userId, environment: environment)
        } catch let failure as FeedbackRouteFailure {
            return service.availabilityReply(failure)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let bearer: String
        do {
            bearer = try await service.bearerAsync(userId: userId, reporterId: reporterId, environment: environment)
        } catch {
            return EmailLoginDirectory.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_service_unavailable\"}")
        }
        let (status, headers, body) = await service.handsRequestAsync(
            environment: environment,
            method: "GET",
            path: "/api/apps/\(environment.appId)/reporter-feedback/\(ticketId)/attachments/\(attachmentId)",
            bearer: bearer,
            reporterId: reporterId
        )
        guard status == 200 else {
            return service.conversationReply(status: status, upstreamHeaders: headers, body: body)
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

// MARK: - Directory entry points

extension EmailLoginDirectory {
    public func productFeedbackTickets(
        authorization: String?,
        clientKindHeader: String = "",
        cursor: String? = nil
    ) -> HTTPReply {
        FeedbackMultiAppService(directory: self).tickets(
            authorization: authorization,
            clientKindHeader: clientKindHeader,
            cursor: cursor
        )
    }

    public func closeProductFeedbackTicket(
        authorization: String?,
        ticketId: String,
        body: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        FeedbackMultiAppService(directory: self).closeTicket(
            authorization: authorization,
            ticketId: ticketId,
            body: body,
            clientKindHeader: clientKindHeader
        )
    }

    public func replyProductFeedbackTicket(
        authorization: String?,
        ticketId: String,
        contentType: String,
        body: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        FeedbackMultiAppService(directory: self).replyTicket(
            authorization: authorization,
            ticketId: ticketId,
            contentType: contentType,
            body: body,
            clientKindHeader: clientKindHeader
        )
    }

    /// `GET /api/product-feedback/tickets/:ticketId`.
    public func productFeedbackTicket(
        authorization: String?,
        ticketId: String,
        clientKindHeader: String = "",
        commentLimit: Int = 50,
        commentCursor: String? = nil
    ) -> HTTPReply {
        FeedbackMultiAppService(directory: self).ticket(
            authorization: authorization,
            ticketId: ticketId,
            clientKindHeader: clientKindHeader,
            commentLimit: commentLimit,
            commentCursor: commentCursor
        )
    }

    /// `GET /api/product-feedback/tickets/:ticketId/attachments/:attachmentId`.
    public func productFeedbackAttachment(
        authorization: String?,
        ticketId: String,
        attachmentId: String,
        clientKindHeader: String = ""
    ) -> HTTPReply {
        FeedbackMultiAppService(directory: self).attachment(
            authorization: authorization,
            ticketId: ticketId,
            attachmentId: attachmentId,
            clientKindHeader: clientKindHeader
        )
    }

    /// `GET /api/product-feedback/tickets` for the Vapor route closure.
    public func productFeedbackTicketsAsync(
        authorization: String?,
        clientKindHeader: String = "",
        cursor: String? = nil
    ) async -> HTTPReply {
        await FeedbackMultiAppService(directory: self).ticketsAsync(
            authorization: authorization,
            clientKindHeader: clientKindHeader,
            cursor: cursor
        )
    }

    /// `POST /api/product-feedback/tickets/:ticketId/close` for the Vapor route closure.
    public func closeProductFeedbackTicketAsync(
        authorization: String?,
        ticketId: String,
        body: String,
        clientKindHeader: String = ""
    ) async -> HTTPReply {
        await FeedbackMultiAppService(directory: self).closeTicketAsync(
            authorization: authorization,
            ticketId: ticketId,
            body: body,
            clientKindHeader: clientKindHeader
        )
    }

    /// `POST /api/product-feedback/tickets/:ticketId/comments` for the Vapor route closure.
    public func replyProductFeedbackTicketAsync(
        authorization: String?,
        ticketId: String,
        contentType: String,
        body: String,
        clientKindHeader: String = ""
    ) async -> HTTPReply {
        await FeedbackMultiAppService(directory: self).replyTicketAsync(
            authorization: authorization,
            ticketId: ticketId,
            contentType: contentType,
            body: body,
            clientKindHeader: clientKindHeader
        )
    }

    /// `GET /api/product-feedback/tickets/:ticketId` for the Vapor route closure.
    public func productFeedbackTicketAsync(
        authorization: String?,
        ticketId: String,
        clientKindHeader: String = "",
        commentLimit: Int = 50,
        commentCursor: String? = nil
    ) async -> HTTPReply {
        await FeedbackMultiAppService(directory: self).ticketAsync(
            authorization: authorization,
            ticketId: ticketId,
            clientKindHeader: clientKindHeader,
            commentLimit: commentLimit,
            commentCursor: commentCursor
        )
    }

    /// `GET /api/product-feedback/tickets/:ticketId/attachments/:attachmentId`
    /// for the Vapor route closure.
    public func productFeedbackAttachmentAsync(
        authorization: String?,
        ticketId: String,
        attachmentId: String,
        clientKindHeader: String = ""
    ) async -> HTTPReply {
        await FeedbackMultiAppService(directory: self).attachmentAsync(
            authorization: authorization,
            ticketId: ticketId,
            attachmentId: attachmentId,
            clientKindHeader: clientKindHeader
        )
    }
}
