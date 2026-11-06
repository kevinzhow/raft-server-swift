import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `GET api/reminders`, split out of `NotificationsFeature` to match upstream
/// `routes/reminders.ts`.
public struct RemindersFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let reminders = routes.grouped("api", "reminders")

        reminders.get { request -> Response in
            routeResponse(services.emailAccounts.listReminders(
                authorization: request.headers[.authorization],
                serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                ownerAgentId: desktopQuery(request.url.query, "ownerAgentId")
            ))
        }
    }
}
