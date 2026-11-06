import HTTPTypes
import RaftHTTP
import Vapor

/// Product-feedback and agent-reminder route surface.
///
/// Lifted verbatim from the `configure(_:services:)` block so the handlers keep
/// their exact method, path, request projection and `routeResponse` call. The
/// collection is not registered here; the application mount decides when it is
/// live.
///
/// Every feedback route calls the async `…Async` entry point: the upstream
/// Hands transport no longer parks a thread on a semaphore, so the closures are
/// `async throws` and run on Vapor's concurrency pool.
public struct FeedbackFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let api = routes.grouped("api")
        let feedback = api.grouped("product-feedback")
        let tickets = feedback.grouped("tickets")

        api.post("app-installation", "agent-reminder-messages") { request async throws -> Response in
            let body = await jsonRequestBody(LenientJSONObjectRequest.self, request)
            return try await respond {
                try services.emailAccounts.managedMCPOAuth.appAgentReminderMessage(
                    authorization: request.headers[.authorization],
                    body: body
                )
            }
        }
        tickets.post(":ticketId", "close") { request async throws -> Response in
            let body = await jsonRequestBody(FeedbackTicketCloseRequest.self, request)
            let clientKind = request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            return try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await services.emailAccounts.feedbackMultiApp.closeTicket(
                    authorization: request.headers[.authorization],
                    ticketId: request.parameters.get("ticketId") ?? "",
                    request: body,
                    clientKindHeader: clientKind
                )
            }
        }
        tickets.post(":ticketId", "comments") { request async throws -> Response in
            let reply = FeedbackTicketReplyRequest(
                contentType: request.headers[.contentType] ?? "",
                body: try await request.bodyText()
            )
            let clientKind = request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            return try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await services.emailAccounts.feedbackMultiApp.replyTicket(
                    authorization: request.headers[.authorization],
                    ticketId: request.parameters.get("ticketId") ?? "",
                    request: reply,
                    clientKindHeader: clientKind
                )
            }
        }
        tickets.get { request async throws -> Response in
            let clientKind = request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            let cursor = try? request.query.get(String.self, at: "cursor")
            return try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await services.emailAccounts.feedbackMultiApp.tickets(
                    authorization: request.headers[.authorization],
                    clientKindHeader: clientKind,
                    cursor: cursor
                )
            }
        }
        tickets.get(":ticketId") { request async throws -> Response in
            let clientKind = request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            let commentCursor = try? request.query.get(String.self, at: "comment_cursor")
            return try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await services.emailAccounts.feedbackMultiApp.ticket(
                    authorization: request.headers[.authorization],
                    ticketId: request.parameters.get("ticketId") ?? "",
                    clientKindHeader: clientKind,
                    commentCursor: commentCursor
                )
            }
        }
        tickets.get(":ticketId", "attachments", ":attachmentId") { request async throws -> Response in
            let clientKind = request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            return try await respond(status: { $0.status }, headers: { $0.headers }) {
                try await services.emailAccounts.feedbackMultiApp.attachment(
                    authorization: request.headers[.authorization],
                    ticketId: request.parameters.get("ticketId") ?? "",
                    attachmentId: request.parameters.get("attachmentId") ?? "",
                    clientKindHeader: clientKind
                )
            }
        }
        feedback.post { request async throws -> Response in
            let submission = ProductFeedbackSubmissionRequest(
                authorization: request.headers[.authorization],
                contentType: request.headers[.contentType] ?? "",
                body: try await request.bodyText(),
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientKindHeader: request.headers[HTTPField.Name("X-Raft-Client-Kind")!]
                    ?? request.headers[HTTPField.Name("X-Slock-Client-Kind")!]
                    ?? ""
            )
            return try await respond(
                status: 201,
                headers: { receipt in
                    .exact([
                        "Content-Type": AppFallback.jsonContentType,
                        "Cache-Control": "no-store",
                        "Server-Timing": receipt.serverTiming,
                    ])
                }
            ) {
                try await services.emailAccounts.productFeedbackSubmissions.submit(submission)
            }
        }
    }
}
