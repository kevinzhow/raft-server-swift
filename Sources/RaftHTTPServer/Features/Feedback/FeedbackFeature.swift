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
            // Typed bodies go through the DTO; anything that does not decode
            // keeps the raw-body path so the existing validator owns the reply.
            let body: String
            if let typed = try? await request.content.decode(AppAgentReminderMessageRequest.self) {
                body = FeedbackJSONCoding.string(typed)
            } else {
                body = try await request.bodyText()
            }
            return routeResponse(services.emailAccounts.appAgentReminderMessage(
                authorization: request.headers[.authorization],
                body: body
            ))
        }
        tickets.post(":ticketId", "close") { request async throws -> Response in
            let body: String
            if let typed = try? await request.content.decode(FeedbackTicketCloseRequest.self) {
                body = FeedbackJSONCoding.string(typed)
            } else {
                body = try await request.bodyText(default: "{}")
            }
            return routeResponse(await services.emailAccounts.closeProductFeedbackTicketAsync(
                authorization: request.headers[.authorization],
                ticketId: request.parameters.get("ticketId") ?? "",
                body: body,
                clientKindHeader: request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            ))
        }
        tickets.post(":ticketId", "comments") { request async throws -> Response in
            routeResponse(await services.emailAccounts.replyProductFeedbackTicketAsync(
                authorization: request.headers[.authorization],
                ticketId: request.parameters.get("ticketId") ?? "",
                contentType: request.headers[.contentType] ?? "",
                body: try await request.bodyText(),
                clientKindHeader: request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            ))
        }
        tickets.get { request async throws -> Response in
            routeResponse(await services.emailAccounts.productFeedbackTicketsAsync(
                authorization: request.headers[.authorization],
                clientKindHeader: request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? "",
                cursor: try? request.query.get(String.self, at: "cursor")
            ))
        }
        tickets.get(":ticketId") { request async throws -> Response in
            routeResponse(await services.emailAccounts.productFeedbackTicketAsync(
                authorization: request.headers[.authorization],
                ticketId: request.parameters.get("ticketId") ?? "",
                clientKindHeader: request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? "",
                commentCursor: try? request.query.get(String.self, at: "comment_cursor")
            ))
        }
        tickets.get(":ticketId", "attachments", ":attachmentId") { request async throws -> Response in
            routeResponse(await services.emailAccounts.productFeedbackAttachmentAsync(
                authorization: request.headers[.authorization],
                ticketId: request.parameters.get("ticketId") ?? "",
                attachmentId: request.parameters.get("attachmentId") ?? "",
                clientKindHeader: request.headers[HTTPField.Name("X-Raft-Client-Kind")!] ?? ""
            ))
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
