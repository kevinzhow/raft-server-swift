import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/api/raftbench/...` routes.
///
/// Upstream registers this family in every deployment and refuses non-pilot
/// servers inside the handler. The port keeps that published refusal (403
/// `raftbench_server_not_allowed`) after the same auth/member/body ordering;
/// the synthetic-analysis engine itself stays out (D19).
public struct RaftBenchFeature: RouteCollection, Sendable {
    private let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let raftbench = routes.grouped("api", "raftbench")
        let service = services.emailAccounts.raftBench(environment: services.releaseEnvironment)

        raftbench.get("agents") { request async throws -> Response in
            try await respond { () throws -> OkResponse in
                try service.authorize(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
                try service.refuseUnlessEnrolled(serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "")
            }
        }
        raftbench.post("agents") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond { () throws -> OkResponse in
                try service.authorize(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
                try service.validateAgentSettings(body)
                try service.refuseUnlessEnrolled(serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "")
            }
        }
        raftbench.put("assignment") { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond { () throws -> OkResponse in
                try service.authorize(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
                try service.validateAssignment(body)
                try service.refuseUnlessEnrolled(serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "")
            }
        }
        raftbench.get { request async throws -> Response in
            try await respond { () throws -> OkResponse in
                try service.authorize(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
                try service.validateDashboardPage(desktopQuery(request.url.query, "page"))
                try service.refuseUnlessEnrolled(serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "")
            }
        }
        raftbench.put { request async throws -> Response in
            let body = try await request.bodyText()
            return try await respond { () throws -> OkResponse in
                try service.authorize(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
                try service.validateConfigure(body)
                try service.refuseUnlessEnrolled(serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "")
            }
        }
    }
}
