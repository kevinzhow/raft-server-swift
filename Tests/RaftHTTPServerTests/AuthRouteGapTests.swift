import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func authGapJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func authGapLogin(_ client: any Client, email: String, password: String = "password123") async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"\(password)\"}")
    }
    return authGapJSON(response)["accessToken"] as? String ?? ""
}

private func authGapPost(
    _ client: any Client, path: String, body: String, token: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

// MARK: - POST /api/auth/forgot-password

/// `routes/auth.ts:1751-1771`: only a missing/empty email is 400; every other
/// address answers the same acceptance message, including one that has no
/// account. `requestPasswordReset` mints one 1-hour token and replaces any
/// older one (`services/userService.ts:1168-1199`).
@Test func forgotPasswordIsNonRevealingAndRedeemsARealToken() async throws {
    let accounts = EmailLoginDirectory()
    let knownId = "11111111-1111-4111-8111-311111111001"
    accounts.addAccount(id: knownId, email: "forgot-known@slock.test", password: "password123")
    accounts.markEmailVerified(userId: knownId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let missing = try await authGapPost(
                client, path: "/api/auth/forgot-password", body: "{}"
            )
            #expect(missing.status == .badRequest)
            #expect(authGapJSON(missing)["error"] as? String == "Email is required")

            // The acceptance body is byte-identical for a known and an unknown
            // address, so the route cannot be used to enumerate accounts.
            let known = try await authGapPost(
                client, path: "/api/auth/forgot-password",
                body: #"{"email":"forgot-known@slock.test"}"#
            )
            #expect(known.status == .ok)
            #expect(
                known.body.string
                    == #"{"ok":true,"message":"If an account exists with that email, a reset link has been sent."}"#
            )

            let unknown = try await authGapPost(
                client, path: "/api/auth/forgot-password",
                body: #"{"email":"nobody-here@slock.test"}"#
            )
            #expect(unknown.status == .ok)
            #expect(unknown.body.string == known.body.string)

            // A real reset token is accepted by the published reset route.
            accounts.addPasswordResetTokenForTesting(
                userId: knownId, token: "forgot-gap-token",
                expiresAt: Date().addingTimeInterval(600)
            )
            let reset = try await authGapPost(
                client, path: "/api/auth/reset-password",
                body: #"{"token":"forgot-gap-token","password":"new-password-123"}"#
            )
            #expect(reset.status == .ok)
            #expect(reset.body.string == #"{"ok":true}"#)
            #expect(try await authGapLogin(client, email: "forgot-known@slock.test", password: "new-password-123") != "")

            // An expired token is the published 400 and writes no credential.
            accounts.addPasswordResetTokenForTesting(
                userId: knownId, token: "forgot-expired-token",
                expiresAt: Date().addingTimeInterval(-1)
            )
            let expired = try await authGapPost(
                client, path: "/api/auth/reset-password",
                body: #"{"token":"forgot-expired-token","password":"another-password-123"}"#
            )
            #expect(expired.status == .badRequest)
            #expect(authGapJSON(expired)["error"] as? String == "Invalid or expired reset token")
        }
    }
}

/// Upstream mounts a 5-per-hour-per-IP limiter before the route
/// (`app.ts:332-344`); the sixth request is 429 with the published message.
@Test func forgotPasswordRateLimitsFiveRequestsPerIpHour() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(
        id: "11111111-1111-4111-8111-311111111002",
        email: "forgot-limit@slock.test", password: "password123"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            for index in 0..<5 {
                let accepted = try await authGapPost(
                    client, path: "/api/auth/forgot-password",
                    body: #"{"email":"forgot-limit@slock.test"}"#
                )
                #expect(accepted.status == .ok, Comment(rawValue: "request \(index) \(accepted.body.string ?? "")"))
            }
            let limited = try await authGapPost(
                client, path: "/api/auth/forgot-password",
                body: #"{"email":"forgot-limit@slock.test"}"#
            )
            #expect(limited.status == .tooManyRequests)
            #expect(
                authGapJSON(limited)["error"] as? String
                    == "Too many password reset requests. Please try again later."
            )
            #expect(limited.headers[HTTPField.Name("RateLimit-Limit")!] == "5")
        }
    }
}

// MARK: - GET /api/auth/me/username-available

/// `routes/auth.ts:1463-1483`: behind requireAuth, trimmed `?name=`; invalid
/// names answer `invalid`, the reserved/placeholder rules answer `reserved`,
/// uniqueness answers `taken`, and a free name omits reason/message.
@Test func usernameAvailabilityMirrorsCompleteProfileValidation() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-311111111003"
    let takenId = "11111111-1111-4111-8111-311111111004"
    accounts.addAccount(id: userId, email: "username-check@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addAccount(id: takenId, email: "taken-handle@slock.test", password: "password123")
    accounts.setAccountProfileForTesting(id: takenId, name: "chosen-handle")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await authGapLogin(client, email: "username-check@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"

            let anonymous = try await client.get("/api/auth/me/username-available?name=fresh-handle", headers: HTTPFields())
            #expect(anonymous.status == .unauthorized)

            func check(_ query: String) async throws -> ClientResponse {
                try await client.get(URI(string: "/api/auth/me/username-available?name=\(query)"), headers: headers)
            }

            let empty = try await check("")
            #expect(empty.status == .ok)
            #expect(authGapJSON(empty)["available"] as? Bool == false)
            #expect(authGapJSON(empty)["reason"] as? String == "invalid")
            #expect(authGapJSON(empty)["message"] as? String == "Username is required")

            let short = try await check("abcd")
            #expect(authGapJSON(short)["message"] as? String == "Username must be at least 5 characters")

            let pattern = try await check("1nope")
            #expect(authGapJSON(pattern)["message"] as? String
                == "Username must start with a letter and can only contain letters, numbers, hyphens, and underscores")

            let reserved = try await check("human")
            #expect(authGapJSON(reserved)["reason"] as? String == "reserved")
            #expect(authGapJSON(reserved)["message"] as? String == "This username is reserved. Choose another name.")

            let taken = try await check("chosen-handle")
            #expect(authGapJSON(taken)["available"] as? Bool == false)
            #expect(authGapJSON(taken)["reason"] as? String == "taken")
            #expect(authGapJSON(taken)["message"] as? String == "This username is already taken.")

            let free = try await check("fresh-handle")
            #expect(free.status == .ok)
            #expect(free.body.string == #"{"available":true}"#)
        }
    }
}
