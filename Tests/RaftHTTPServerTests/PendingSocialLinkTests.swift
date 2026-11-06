import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func passwordLoginCompletesAPendingSocialLinkOnceAndRefusesMismatches() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001083001"
    let otherId = "11111111-1111-4111-8111-000001083002"
    accounts.addAccount(id: existingId, email: "existing@pending-link.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.addAccount(id: otherId, email: "other@pending-link.test", password: "password123")
    accounts.markEmailVerified(userId: otherId)
    let token = accounts.issuePendingSocialLinkForTesting(
        provider: "google", providerUserId: "google-sub-1304", email: "existing@pending-link.test",
        returnTo: "/s/home"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String, _ password: String, _ pending: String?) async throws -> (HTTPResponse.Status, [String: Any]) {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                var payload: [String: Any] = ["email": email, "password": password]
                if let pending { payload["pendingLinkToken"] = pending }
                let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: body)
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let wrongPassword = try await login("existing@pending-link.test", "nope", token)
            #expect(wrongPassword.0 == .unauthorized)
            #expect(wrongPassword.1["code"] as? String == "AUTH_INVALID_CREDENTIALS")

            let wrongAccount = try await login("other@pending-link.test", "password123", token)
            #expect(wrongAccount.0 == .forbidden)
            #expect(wrongAccount.1["code"] as? String == "pending_link_account_mismatch")
            #expect(accounts.linkedProviderUserIds(userId: otherId, provider: "google").isEmpty)

            let signedIn = try await login("existing@pending-link.test", "password123", token)
            #expect(signedIn.0 == .ok)
            #expect(signedIn.1["linkedProvider"] as? String == "google")
            #expect(accounts.linkedProviderUserIds(userId: existingId, provider: "google") == ["google-sub-1304"])

            let replay = try await login("existing@pending-link.test", "password123", token)
            #expect(replay.0 == .gone)
            #expect(replay.1["code"] as? String == "pending_link_expired")
        }
    }
}

@Test func cancelAndExpiryDropThePendingLinkWithoutIssuingASession() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001083011"
    accounts.addAccount(id: userId, email: "cancel@pending-link.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let cancelled = accounts.issuePendingSocialLinkForTesting(
        provider: "google", providerUserId: "google-cancel", email: "cancel@pending-link.test"
    )
    let expired = accounts.issuePendingSocialLinkForTesting(
        provider: "google", providerUserId: "google-expired", email: "cancel@pending-link.test",
        expiresAt: Date().addingTimeInterval(-1)
    )
    let sessionsBefore = accounts.sessionCount

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            for _ in 0..<2 {
                let cancel = try await client.send(.post, headers: headers, to: "/api/auth/pending-link/cancel") { request in
                    request.body = .init(string: "{\"pendingLinkToken\":\"\(cancelled)\"}")
                }
                #expect(cancel.status == .noContent)
            }
            func login(_ token: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"cancel@pending-link.test\",\"password\":\"password123\",\"pendingLinkToken\":\"\(token)\"}")
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            #expect((try await login(cancelled)).0 == .gone)
            #expect((try await login(expired)).0 == .gone)
        }
    }
    #expect(accounts.sessionCount == sessionsBefore)
    #expect(accounts.linkedProviderUserIds(userId: userId, provider: "google").isEmpty)
}
