import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func billingJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func billingLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return billingJSON(response)["accessToken"] as? String ?? ""
}

private func billingHeaders(_ token: String, _ serverId: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return headers
}

private func billingPost(
    _ client: any Client, _ path: String, headers: HTTPFields, body: String = "{}"
) async throws -> ClientResponse {
    try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

// MARK: - GET /api/billing/subscription

/// `routes/billing.ts:229-248` with `isStripeConfigured()` false: the summary
/// still answers 200 and projects the real retained server plan, member count
/// and upload quota; owners may manage, admins may only read, members are 403.
@Test func billingSummaryProjectsTheRetainedFreePlanAndPermissions() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-411111111001"
    let adminId = "11111111-1111-4111-8111-411111111002"
    let memberId = "11111111-1111-4111-8111-411111111003"
    let serverId = "33333333-3333-4333-8333-411111111001"
    for (id, email) in [
        (ownerId, "billing-owner@slock.test"),
        (adminId, "billing-admin@slock.test"),
        (memberId, "billing-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "billing-free", name: "Billing Free", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    let trialStart = try #require(ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z"))
    let trialEnd = try #require(ISO8601DateFormatter().date(from: "2026-06-23T12:00:00Z"))
    let now = Date()
    let trialActive = now >= trialStart && now < trialEnd
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let parts = calendar.dateComponents([.year, .month], from: now)
    let month = String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await billingLogin(client, email: "billing-owner@slock.test")
            let admin = try await billingLogin(client, email: "billing-admin@slock.test")
            let member = try await billingLogin(client, email: "billing-member@slock.test")

            let ownerResponse = try await client.get(
                "/api/billing/subscription", headers: billingHeaders(owner, serverId)
            )
            #expect(ownerResponse.status == .ok)
            let body = billingJSON(ownerResponse)
            #expect(body["plan"] as? String == "free")
            #expect(body["displayName"] as? String == "Free")
            #expect(body["serverPlan"] as? String == "free")
            #expect(body["source"] as? String == "server")
            #expect(body["stripeConfigured"] as? Bool == false)
            #expect(body["price"] is NSNull)
            #expect(body["subscription"] is NSNull)

            let capacity = body["capacity"] as? [String: Any] ?? [:]
            #expect(capacity["maxHumans"] as? Int == -1)
            #expect(capacity["maxAgents"] as? Int == -1)
            #expect(capacity["maxUniversalSeats"] as? Int == -1)

            let usage = body["usage"] as? [String: Any] ?? [:]
            #expect(usage["humans"] as? Int == 3)
            #expect(usage["agents"] as? Int == 0)
            #expect((usage["universalSeats"] as? NSNumber)?.doubleValue == 3)

            let provisioned = body["provisioned"] as? [String: Any] ?? [:]
            #expect(provisioned["humans"] as? Int == 3)
            #expect(provisioned["agents"] as? Int == 0)
            #expect(provisioned["proPackQuantity"] as? Int == 0)
            #expect(provisioned["trialFreePackQuantity"] as? Int == 0)
            #expect(provisioned["firstPackTrialEndsAt"] is NSNull)

            let quota = body["fileUploadQuota"] as? [String: Any] ?? [:]
            #expect(quota["month"] as? String == month)
            #expect(quota["plan"] as? String == "free")
            #expect(quota["limited"] as? Bool == true)
            #expect(quota["enforced"] as? Bool == !trialActive)
            #expect(quota["limitBytes"] as? Int == 100 * 1024 * 1024)
            #expect(quota["usedBytes"] as? Int == 0)
            #expect(quota["remainingBytes"] as? Int == 100 * 1024 * 1024)

            #expect((body["permissions"] as? [String: Any])?["canReadBillingSummary"] as? Bool == true)
            #expect((body["permissions"] as? [String: Any])?["canManageBilling"] as? Bool == true)

            let adminResponse = try await client.get(
                "/api/billing/subscription", headers: billingHeaders(admin, serverId)
            )
            #expect(adminResponse.status == .ok)
            #expect((billingJSON(adminResponse)["permissions"] as? [String: Any])?["canManageBilling"] as? Bool == false)

            let memberResponse = try await client.get(
                "/api/billing/subscription", headers: billingHeaders(member, serverId)
            )
            #expect(memberResponse.status == .forbidden)
            #expect(billingJSON(memberResponse)["error"] as? String == "Only server owners and admins can view billing")

            let missingServer = try await client.get(
                "/api/billing/subscription", headers: billingHeaders(owner)
            )
            #expect(missingServer.status == .badRequest)
            #expect(billingJSON(missingServer)["error"] as? String == "Missing X-Server-Id header")

            let anonymous = try await client.get("/api/billing/subscription", headers: HTTPFields())
            #expect(anonymous.status == .unauthorized)
        }
    }
}

// MARK: - Mutating routes when billing is disabled

/// `routes/billing.ts` checks `isStripeConfigured()` before the role or body
/// check, so every mutating route answers the same 503 for an owner, an admin
/// or a member.
@Test func billingMutatingRoutesAnswerTheDisabledContract() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-411111111011"
    let memberId = "11111111-1111-4111-8111-411111111012"
    let serverId = "33333333-3333-4333-8333-411111111011"
    for (id, email) in [
        (ownerId, "billing-disabled-owner@slock.test"),
        (memberId, "billing-disabled-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "billing-disabled", name: "Billing Disabled", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await billingLogin(client, email: "billing-disabled-owner@slock.test")
            let member = try await billingLogin(client, email: "billing-disabled-member@slock.test")

            let paths = [
                "/api/billing/checkout",
                "/api/billing/cancel",
                "/api/billing/portal",
                "/api/billing/seat-pack-quantity",
                "/api/billing/seat-pack-quantity/preview",
                "/api/billing/pack-quantity",
                "/api/billing/pack-quantity/preview",
            ]
            for path in paths {
                for token in [owner, member] {
                    let response = try await billingPost(
                        client, path, headers: billingHeaders(token, serverId),
                        body: #"{"successUrl":"http://127.0.0.1:4173/billing/success","cancelUrl":"http://127.0.0.1:4173/billing/cancel","returnUrl":"http://127.0.0.1:4173/billing"}"#
                    )
                    #expect(response.status == .serviceUnavailable, Comment(rawValue: "\(path) \(response.status)"))
                    #expect(billingJSON(response)["error"] as? String == "Billing is not configured")
                }
            }
        }
    }
}

// MARK: - GET /api/billing/hosted-runtime-usage

/// `routes/billing.ts:250-334`: reader-only, and with no hosted runtime the
/// route answers the typed 404 that hides the Plan card. It is not Stripe gated.
@Test func hostedRuntimeUsageRefusesReadersWithoutHostedProvision() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-411111111021"
    let memberId = "11111111-1111-4111-8111-411111111022"
    let serverId = "33333333-3333-4333-8333-411111111021"
    for (id, email) in [
        (ownerId, "hosted-spend-owner@slock.test"),
        (memberId, "hosted-spend-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "hosted-spend", name: "Hosted Spend", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await billingLogin(client, email: "hosted-spend-owner@slock.test")
            let member = try await billingLogin(client, email: "hosted-spend-member@slock.test")

            let ownerResponse = try await client.get(
                "/api/billing/hosted-runtime-usage", headers: billingHeaders(owner, serverId)
            )
            #expect(ownerResponse.status == .notFound)
            #expect(billingJSON(ownerResponse)["error"] as? String == "This server has no cloud agents")
            #expect(billingJSON(ownerResponse)["code"] as? String == "hosted_runtime_spend_not_enabled")

            let memberResponse = try await client.get(
                "/api/billing/hosted-runtime-usage", headers: billingHeaders(member, serverId)
            )
            #expect(memberResponse.status == .forbidden)
            #expect(billingJSON(memberResponse)["code"] as? String == "hosted_runtime_spend_forbidden")
        }
    }
}
