import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// `/api/billing/...` routes.
///
/// This deployment has no Stripe configuration, so the mutating routes publish
/// the upstream disabled refusal and `subscription` publishes the retained
/// free-server summary. The Web hides the hosted-spend card on the typed 404.
public struct BillingFeature: RouteCollection, Sendable {
    private let services: FallbackServices

    public init(services: FallbackServices) {
        self.services = services
    }

    public func boot(routes: any RoutesBuilder) async throws {
        register(routes: routes)
    }

    public func register(routes: any RoutesBuilder) {
        let billing = routes.grouped("api", "billing")
        let service = services.emailAccounts.billing
        let stripeConfigured = BillingService.stripeConfigured(environment: services.releaseEnvironment)

        billing.get("subscription") { request async throws -> Response in
            try await respond {
                try service.summary(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? "",
                    stripeConfigured: stripeConfigured
                )
            }
        }
        billing.get("hosted-runtime-usage") { request async throws -> Response in
            try await respond { () throws -> OkResponse in
                try service.hostedRuntimeUsage(
                    authorization: request.headers[.authorization],
                    serverId: request.headers[HTTPField.Name("X-Server-Id")!] ?? ""
                )
            }
        }

        // Upstream gates every mutating route on `isStripeConfigured()` before
        // the role or body check (`routes/billing.ts:29-227`).
        billing.post("checkout") { _ async throws -> Response in
            try await respond { () throws -> OkResponse in try service.requireConfiguredProvider() }
        }
        billing.post("cancel") { _ async throws -> Response in
            try await respond { () throws -> OkResponse in try service.requireConfiguredProvider() }
        }
        billing.post("portal") { _ async throws -> Response in
            try await respond { () throws -> OkResponse in try service.requireConfiguredProvider() }
        }
        billing.post("seat-pack-quantity", "preview") { _ async throws -> Response in
            try await respond { () throws -> OkResponse in try service.requireConfiguredProvider() }
        }
        billing.post("seat-pack-quantity") { _ async throws -> Response in
            try await respond { () throws -> OkResponse in try service.requireConfiguredProvider() }
        }
        billing.post("pack-quantity", "preview") { _ async throws -> Response in
            try await respond { () throws -> OkResponse in try service.requireConfiguredProvider() }
        }
        billing.post("pack-quantity") { _ async throws -> Response in
            try await respond { () throws -> OkResponse in try service.requireConfiguredProvider() }
        }
    }
}
