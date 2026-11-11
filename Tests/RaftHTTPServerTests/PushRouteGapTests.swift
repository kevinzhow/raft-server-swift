import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func pushJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func pushLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return pushJSON(response)["accessToken"] as? String ?? ""
}

private func pushHeaders(_ token: String, serverId: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return headers
}

private func pushSend(
    _ client: any Client, _ method: HTTPRequest.Method, _ path: String,
    headers: HTTPFields, body: String? = nil
) async throws -> ClientResponse {
    try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func pushFixture() -> (EmailLoginDirectory, String, String, String, String) {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-511111111001"
    let pendingId = "11111111-1111-4111-8111-511111111002"
    let serverId = "33333333-3333-4333-8333-511111111001"
    accounts.addAccount(id: ownerId, email: "push-gap-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: pendingId, email: "push-gap-unverified@slock.test", password: "password123")
    accounts.oauth.addOwnedServer(id: serverId, slug: "push-gap", name: "Push Gap", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: pendingId, role: "member")
    return (accounts, ownerId, pendingId, serverId, "push-gap-owner@slock.test")
}

// MARK: - GET /api/push/vapid-key

/// `routes/push.ts:77-88`: unauthenticated, 503 without a configured key and
/// `{"publicKey":…}` with one.
@Test func pushVapidKeyPublishesTheConfiguredKeyOrTheDisabledContract() async throws {
    let (accounts, _, _, _, _) = pushFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let disabled = try await client.get("/api/push/vapid-key", headers: HTTPFields())
            #expect(disabled.status == .serviceUnavailable)
            #expect(pushJSON(disabled)["error"] as? String == "Push notifications not configured")
        }
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            releaseEnvironment: ["VAPID_PUBLIC_KEY": "BPublicKey-test"],
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let configured = try await client.get("/api/push/vapid-key", headers: HTTPFields())
            #expect(configured.status == .ok)
            #expect(configured.body.string == #"{"publicKey":"BPublicKey-test"}"#)
        }
    }
}

// MARK: - POST /api/push/prompt-events

/// `routes/push.ts:92-139`: requireAuth only (email verification is not
/// required), a closed event set, a required trigger, bounded fields, and an
/// optional `X-Server-Id` retained only for a member.
@Test func pushPromptEventsRecordsOnlyTheClosedEventShape() async throws {
    let (accounts, ownerId, pendingId, serverId, ownerEmail) = pushFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await pushLogin(client, email: ownerEmail)
            let unverified = try await pushLogin(client, email: "push-gap-unverified@slock.test")

            let anonymous = try await pushSend(
                client, .post, "/api/push/prompt-events", headers: HTTPFields(),
                body: #"{"event":"web_push_prompt_shown","trigger":"settings"}"#
            )
            #expect(anonymous.status == .unauthorized)

            let invalid = try await pushSend(
                client, .post, "/api/push/prompt-events", headers: pushHeaders(owner),
                body: #"{"event":"not_an_event","trigger":"settings"}"#
            )
            #expect(invalid.status == .badRequest)
            #expect(pushJSON(invalid)["error"] as? String == "Invalid push prompt event")

            let missingTrigger = try await pushSend(
                client, .post, "/api/push/prompt-events", headers: pushHeaders(owner),
                body: #"{"event":"web_push_prompt_shown"}"#
            )
            #expect(missingTrigger.status == .badRequest)

            let withoutServer = try await pushSend(
                client, .post, "/api/push/prompt-events", headers: pushHeaders(owner),
                body: #"{"event":"web_push_prompt_shown","trigger":"settings"}"#
            )
            #expect(withoutServer.status == .ok)
            #expect(withoutServer.body.string == #"{"ok":true}"#)

            // The same event from an unverified account is accepted: the route
            // is not behind requireVerified.
            let longDetail = String(repeating: "d", count: 200)
            let withServer = try await pushSend(
                client, .post, "/api/push/prompt-events", headers: pushHeaders(unverified, serverId: serverId),
                body: #"{"event":"web_push_native_result","trigger":"activation","result":"granted","permissionBefore":"default","permissionAfter":"granted","detail":"\#(longDetail)"}"#
            )
            #expect(withServer.status == .ok, Comment(rawValue: withServer.body.string ?? ""))

            // A non-member header is dropped rather than rejecting the event.
            let foreignServer = "33333333-3333-4333-8333-511111111099"
            let foreign = try await pushSend(
                client, .post, "/api/push/prompt-events", headers: pushHeaders(owner, serverId: foreignServer),
                body: #"{"event":"web_push_subscription_failed","trigger":"activation"}"#
            )
            #expect(foreign.status == .ok)

            let ownerRows = accounts.pushPromptEvents(userId: ownerId)
            #expect(ownerRows.count == 2)
            #expect(ownerRows.first?.event == "web_push_prompt_shown")
            #expect(ownerRows.first?.trigger == "settings")
            #expect(ownerRows.first?.serverId == nil)
            #expect(ownerRows.last?.event == "web_push_subscription_failed")
            #expect(ownerRows.last?.serverId == nil)

            let unverifiedRows = accounts.pushPromptEvents(userId: pendingId)
            #expect(unverifiedRows.count == 1)
            #expect(unverifiedRows.first?.serverId == serverId)
            #expect(unverifiedRows.first?.result == "granted")
            #expect(unverifiedRows.first?.permissionBefore == "default")
            #expect(unverifiedRows.first?.permissionAfter == "granted")
            #expect(unverifiedRows.first?.detail?.count == 128)
        }
    }
}

// MARK: - DELETE /api/push/subscribe

/// `routes/push.ts:182-208`: auth + verified, `{"endpoint"}` required, and a
/// repeat removal is the same `{"ok":true}`. No push-enabled gate.
@Test func pushDeleteSubscribeRemovesTheStoredEndpointIdempotently() async throws {
    let (accounts, ownerId, _, _, ownerEmail) = pushFixture()
    let endpoint = "https://fcm.googleapis.com/fcm/send/delete-gap"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await pushLogin(client, email: ownerEmail)
            let unverified = try await pushLogin(client, email: "push-gap-unverified@slock.test")

            accounts.recordWebPushSubscriptionForTesting(userId: ownerId, endpoint: endpoint)

            let anonymous = try await pushSend(
                client, .delete, "/api/push/subscribe", headers: HTTPFields(),
                body: #"{"endpoint":"\#(endpoint)"}"#
            )
            #expect(anonymous.status == .unauthorized)

            let unverifiedResponse = try await pushSend(
                client, .delete, "/api/push/subscribe", headers: pushHeaders(unverified),
                body: #"{"endpoint":"\#(endpoint)"}"#
            )
            #expect(unverifiedResponse.status == .forbidden)

            let missing = try await pushSend(
                client, .delete, "/api/push/subscribe", headers: pushHeaders(owner), body: "{}"
            )
            #expect(missing.status == .badRequest)
            #expect(pushJSON(missing)["error"] as? String == "Missing endpoint")

            let removed = try await pushSend(
                client, .delete, "/api/push/subscribe", headers: pushHeaders(owner),
                body: #"{"endpoint":"\#(endpoint)"}"#
            )
            #expect(removed.status == .ok)
            #expect(removed.body.string == #"{"ok":true}"#)
            #expect(accounts.webPushEndpoints(userId: ownerId).isEmpty)

            let repeated = try await pushSend(
                client, .delete, "/api/push/subscribe", headers: pushHeaders(owner),
                body: #"{"endpoint":"\#(endpoint)"}"#
            )
            #expect(repeated.status == .ok)
            #expect(repeated.body.string == #"{"ok":true}"#)
        }
    }
}

// MARK: - POST /api/push/test

/// `routes/push.ts:349-397`: verified, and the disabled contract is 503.
@Test func pushTestAnswersTheDisabledContract() async throws {
    let (accounts, _, _, _, ownerEmail) = pushFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await pushLogin(client, email: ownerEmail)
            let unverified = try await pushLogin(client, email: "push-gap-unverified@slock.test")

            let disabled = try await pushSend(
                client, .post, "/api/push/test", headers: pushHeaders(owner)
            )
            #expect(disabled.status == .serviceUnavailable)
            #expect(pushJSON(disabled)["error"] as? String == "Push notifications not configured")

            let unverifiedResponse = try await pushSend(
                client, .post, "/api/push/test", headers: pushHeaders(unverified)
            )
            #expect(unverifiedResponse.status == .forbidden)
        }
    }
}
