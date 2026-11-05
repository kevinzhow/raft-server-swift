import HTTPTypes
import Vapor

/// Product-feedback and agent-reminder route surface.
///
/// Lifted verbatim from the `configure(_:services:)` block so the handlers keep
/// their exact method, path, request projection and `routeResponse` call. The
/// collection is not registered here; the application mount decides when it is
/// live.
public struct FeedbackFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
    register(routes: routes)
    }

public func register(routes: any RoutesBuilder) {
        routes.post("api", "app-installation", "agent-reminder-messages") { request -> Response in
            routeResponse(services.emailAccounts.appAgentReminderMessage(
                authorization: request.headers[.authorization],
                body: request.body.string ?? ""
            ))
        }
        routes.post("api", "product-feedback", "tickets", ":ticketId", "close") { request -> Response in
            routeResponse(services.emailAccounts.closeProductFeedbackTicket(
                authorization: request.headers[.authorization],
                ticketId: request.parameters.get("ticketId") ?? "",
                body: request.body.string ?? "{}"
            ))
        }
        routes.post("api", "product-feedback", "tickets", ":ticketId", "comments") { request -> Response in
            routeResponse(services.emailAccounts.replyProductFeedbackTicket(
                authorization: request.headers[.authorization],
                ticketId: request.parameters.get("ticketId") ?? "",
                contentType: request.headers[.contentType] ?? "",
                body: request.body.string ?? ""
            ))
        }
        routes.get("api", "product-feedback", "tickets") { request -> Response in
            routeResponse(services.emailAccounts.productFeedbackTickets(authorization: request.headers[.authorization]))
        }
        routes.post("api", "product-feedback") { request -> Response in
            routeResponse(services.emailAccounts.submitProductFeedback(
                authorization: request.headers[.authorization],
                contentType: request.headers[.contentType] ?? "",
                body: request.body.string ?? "",
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                clientKindHeader: request.headers[HTTPField.Name("X-Raft-Client-Kind")!]
                    ?? request.headers[HTTPField.Name("X-Slock-Client-Kind")!]
                    ?? ""
            ))
        }
    }
}
