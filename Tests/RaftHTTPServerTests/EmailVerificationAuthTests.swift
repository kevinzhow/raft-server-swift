import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func jsonObject(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(bodyText(response).utf8))) as? [String: Any] ?? [:]
}

private func sendJSON(
    _ client: any Client,
    _ method: HTTPRequest.Method,
    _ path: String,
    body: String? = nil,
    authorization: String? = nil,
    serverId: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    if body != nil {
        headers[.contentType] = "application/json"
    }
    if let authorization { headers[.authorization] = authorization }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body {
            request.body = .init(string: body)
        }
    }
}

private func postJSON(
    _ client: any Client,
    _ path: String,
    body: String,
    authorization: String? = nil,
    serverId: String? = nil
) async throws -> ClientResponse {
    try await sendJSON(
        client,
        .post,
        path,
        body: body,
        authorization: authorization,
        serverId: serverId
    )
}

private func registrationBody(email: String, extra: String = "") -> String {
    "{\"email\":\"\(email)\",\"password\":\"password123\",\"name\":\"Verifier\",\"acceptTerms\":true,"
        + "\"termsVersion\":\"\(EmailLoginDirectory.termsVersion)\","
        + "\"privacyVersion\":\"\(EmailLoginDirectory.privacyVersion)\"\(extra)}"
}

private func register(
    _ client: any Client,
    email: String,
    extra: String = ""
) async throws -> (response: ClientResponse, token: String, userId: String, emailVerified: Bool?) {
    let response = try await postJSON(client, "/api/auth/register", body: registrationBody(email: email, extra: extra))
    let payload = jsonObject(response)
    let user = payload["user"] as? [String: Any] ?? [:]
    return (
        response,
        payload["accessToken"] as? String ?? "",
        user["id"] as? String ?? "",
        user["emailVerified"] as? Bool
    )
}

private func me(_ client: any Client, token: String) async throws -> (response: ClientResponse, payload: [String: Any]) {
    let response = try await sendJSON(client, .get, "/api/auth/me", authorization: "Bearer \(token)")
    return (response, jsonObject(response))
}

private func makeApp(_ accounts: EmailLoginDirectory) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: accounts
    )
}

@Test func verifyEmailUnlocksHumanMessaging() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-333333333301"
    let channelId = "22222222-2222-4222-8222-222222222201"

    try await withApp { app in
        configure(app, services: makeApp(accounts))
        try await app.testing { client in
            let registered = try await register(client, email: "verify-roundtrip@slock.test")
            #expect(registered.response.status == .ok)
            #expect(!registered.token.isEmpty)
            #expect(!registered.userId.isEmpty)
            #expect(registered.emailVerified == false)

            accounts.addPostableChannel(
                serverId: serverId,
                channelId: channelId,
                memberId: registered.userId,
                name: "verified-roundtrip"
            )

            // `requireVerified` blocks a real human until the token is spent.
            let gated = try await postJSON(
                client,
                "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"before verification\"}",
                authorization: "Bearer \(registered.token)",
                serverId: serverId
            )
            #expect(gated.status == .forbidden)
            #expect(bodyText(gated) == "{\"error\":\"Email verification required\"}")
            #expect(accounts.humanMessageCount == 0)

            let verificationToken = accounts.latestEmailVerificationTokenForTesting(userId: registered.userId)
            #expect(verificationToken != nil)
            #expect(verificationToken?.count == 64)
            #expect(verificationToken?.allSatisfy(\.isHexDigit) == true)

            let verified = try await postJSON(
                client,
                "/api/auth/verify-email",
                body: "{\"token\":\"\(verificationToken ?? "")\"}"
            )
            #expect(verified.status == .ok)
            #expect(bodyText(verified) == "{\"ok\":true}")

            let profile = try await me(client, token: registered.token)
            #expect(profile.response.status == .ok)
            #expect(profile.payload["emailVerified"] as? Bool == true)

            let sent = try await postJSON(
                client,
                "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"after verification\"}",
                authorization: "Bearer \(registered.token)",
                serverId: serverId
            )
            // Upstream `createHumanMessage` answers 200 (`res.json`), not 201.
            #expect(sent.status == .ok)
            #expect(jsonObject(sent)["content"] as? String == "after verification")
            #expect(accounts.humanMessageCount == 1)

            // A consumed token cannot verify a second time.
            let reused = try await postJSON(
                client,
                "/api/auth/verify-email",
                body: "{\"token\":\"\(verificationToken ?? "")\"}"
            )
            #expect(reused.status == .badRequest)
            #expect(bodyText(reused) == "{\"error\":\"Invalid or expired verification token\"}")
        }
    }
}

@Test func verifyEmailRejectsMissingEmptyAndUnknownTokens() async throws {
    let accounts = EmailLoginDirectory()

    try await withApp { app in
        configure(app, services: makeApp(accounts))
        try await app.testing { client in
            for body in ["{}", "", "{\"token\":\"\"}"] {
                let missing = try await postJSON(client, "/api/auth/verify-email", body: body)
                #expect(missing.status == .badRequest)
                #expect(bodyText(missing) == "{\"error\":\"Token is required\"}")
            }

            let unknown = try await postJSON(
                client,
                "/api/auth/verify-email",
                body: "{\"token\":\"not-a-real-verification-token\"}"
            )
            #expect(unknown.status == .badRequest)
            #expect(bodyText(unknown) == "{\"error\":\"Invalid or expired verification token\"}")
        }
    }
}

@Test func resendVerificationRequiresAuthRejectsVerifiedAndEnforcesCooldown() async throws {
    let accounts = EmailLoginDirectory()

    try await withApp { app in
        configure(app, services: makeApp(accounts))
        try await app.testing { client in
            let anonymous = try await postJSON(client, "/api/auth/resend-verification", body: "{}")
            #expect(anonymous.status == .unauthorized)
            #expect(bodyText(anonymous) == "{\"error\":\"Missing or invalid Authorization header\"}")

            let invalidSession = try await postJSON(
                client,
                "/api/auth/resend-verification",
                body: "{}",
                authorization: "Bearer not-a-session"
            )
            #expect(invalidSession.status == .unauthorized)
            #expect(bodyText(invalidSession) == "{\"error\":\"Invalid or expired token\"}")

            let registered = try await register(client, email: "resend-verification@slock.test")
            #expect(registered.response.status == .ok)

            // Registration already issued one token seconds ago.
            let cooling = try await postJSON(
                client,
                "/api/auth/resend-verification",
                body: "{}",
                authorization: "Bearer \(registered.token)"
            )
            #expect(cooling.status == .tooManyRequests)
            #expect(bodyText(cooling) == "{\"error\":\"Please wait before requesting another verification email.\"}")

            let verificationToken = accounts.latestEmailVerificationTokenForTesting(userId: registered.userId)
            #expect(verificationToken != nil)
            let verified = try await postJSON(
                client,
                "/api/auth/verify-email",
                body: "{\"token\":\"\(verificationToken ?? "")\"}"
            )
            #expect(verified.status == .ok)

            let alreadyVerified = try await postJSON(
                client,
                "/api/auth/resend-verification",
                body: "{}",
                authorization: "Bearer \(registered.token)"
            )
            #expect(alreadyVerified.status == .badRequest)
            #expect(bodyText(alreadyVerified) == "{\"error\":\"Email is already verified\"}")

            // An unauthenticated resend never mutates the token ledger.
            let before = accounts.latestEmailVerificationTokenForTesting(userId: registered.userId)
            _ = try await postJSON(client, "/api/auth/resend-verification", body: "{}")
            #expect(accounts.latestEmailVerificationTokenForTesting(userId: registered.userId) == before)
        }
    }
}

@Test func registerAutoVerifiesOnlyWhenBothE2EGatesAreSet() async throws {
    unsetenv("SLOCK_E2E_AUTO_VERIFY_EMAIL")
    defer { unsetenv("SLOCK_E2E_AUTO_VERIFY_EMAIL") }
    let accounts = EmailLoginDirectory()

    try await withApp { app in
        configure(app, services: makeApp(accounts))
        try await app.testing { client in
            // Per-request opt-in alone is not enough.
            let flagOnly = try await register(
                client,
                email: "auto-verify-flag-only@slock.test",
                extra: ",\"__e2eAutoVerify\":true"
            )
            #expect(flagOnly.response.status == .ok)
            #expect(flagOnly.emailVerified == false)
            #expect(try await me(client, token: flagOnly.token).payload["emailVerified"] as? Bool == false)
            #expect(accounts.isEmailVerified(userId: flagOnly.userId) == false)

            setenv("SLOCK_E2E_AUTO_VERIFY_EMAIL", "1", 1)

            // The environment flag alone is not enough either.
            let envOnly = try await register(client, email: "auto-verify-env-only@slock.test")
            #expect(envOnly.response.status == .ok)
            #expect(envOnly.emailVerified == false)
            #expect(accounts.isEmailVerified(userId: envOnly.userId) == false)

            // Both gates set: the ephemeral E2E user is verified immediately.
            let both = try await register(
                client,
                email: "auto-verify-both@slock.test",
                extra: ",\"__e2eAutoVerify\":true"
            )
            #expect(both.response.status == .ok)
            #expect(both.emailVerified == true)
            let profile = try await me(client, token: both.token)
            #expect(profile.payload["emailVerified"] as? Bool == true)
            #expect(accounts.isEmailVerified(userId: both.userId) == true)
        }
    }
}
