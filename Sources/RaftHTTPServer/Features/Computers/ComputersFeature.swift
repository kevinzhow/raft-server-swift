import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// The three `api/computer/**` routes, split out of `NotificationsFeature` to
/// match upstream `routes/computers.ts`.
///
/// `adopt-legacy` and `attach` answer the same `routeResponse` mapping, and
/// `legacy-machines` keeps the `serverSlug` / `includeAll=1` query projection.
public struct ComputersFeature: RouteCollection, Sendable {
    public let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let computers = routes.grouped("api", "computer")

        computers.post("adopt-legacy") { request async throws -> Response in
            let body = await jsonRequestBody(ComputerAdoptLegacyRequest.self, request) ?? ComputerAdoptLegacyRequest()
            return try await respond(status: 201) {
                try services.emailAccounts.computersFleet.adoptLegacyComputer(
                    authorization: request.headers[.authorization],
                    request: body
                )
            }
        }
        computers.post("attach") { request async throws -> Response in
            let body = await jsonRequestBody(ComputerAttachRequest.self, request) ?? ComputerAttachRequest()
            return try await respond(status: 201) {
                try services.emailAccounts.computersFleet.attachComputer(
                    authorization: request.headers[.authorization],
                    request: body
                )
            }
        }
        computers.get("legacy-machines") { request async throws -> Response in
            try await respond {
                try services.emailAccounts.computersFleet.legacyMachines(
                    authorization: request.headers[.authorization],
                    serverSlug: desktopQuery(request.url.query, "serverSlug"),
                    includeAll: desktopQuery(request.url.query, "includeAll") == "1"
                )
            }
        }
    }
}
