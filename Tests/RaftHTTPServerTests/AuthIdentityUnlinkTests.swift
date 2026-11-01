import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct IdentityFixture {
    let accounts: EmailLoginDirectory
    let passwordUserId: String
    let passwordUserEmail: String
    let passwordlessUserId: String
    let passwordlessUserEmail: String
    let legacyUserId: String
    let legacyUserEmail: String
    let multiUserId: String
    let concurrentUserId: String
    let unrelatedUserId: String
}

private func makeIdentityFixture(suffix: String) -> IdentityFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let base = 800_000 + number
    let passwordUserId = String(format: "11111111-1111-4111-8111-%012d", base)
    let passwordlessUserId = String(format: "11111111-1111-4111-8111-%012d", base + 1)
    let legacyUserId = String(format: "11111111-1111-4111-8111-%012d", base + 2)
    let multiUserId = String(format: "11111111-1111-4111-8111-%012d", base + 3)
    let concurrentUserId = String(format: "11111111-1111-4111-8111-%012d", base + 4)
    let unrelatedUserId = String(format: "11111111-1111-4111-8111-%012d", base + 5)
    let passwordUserEmail = "password-owner-\(suffix)@example.com"
    let passwordlessUserEmail = "social-only-\(suffix)@example.com"
    let legacyUserEmail = "legacy-password-social-\(suffix)@example.com"

    accounts.addAccount(id: passwordUserId, email: passwordUserEmail, password: "password123")
    accounts.addAuthIdentityForTesting(userId: passwordUserId, provider: "apple", providerEmail: "apple@example.com")

    accounts.addAccount(
        id: passwordlessUserId,
        email: passwordlessUserEmail,
        password: "social-placeholder-\(UUID().uuidString)",
        passwordCredentialEstablished: false
    )
    accounts.addAuthIdentityForTesting(userId: passwordlessUserId, provider: "github", providerEmail: "github@example.com")

    accounts.addAccount(
        id: legacyUserId,
        email: legacyUserEmail,
        password: "password123",
        passwordCredentialEstablished: false
    )
    accounts.addAuthIdentityForTesting(userId: legacyUserId, provider: "github", providerEmail: "github@example.com")

    accounts.addAccount(
        id: multiUserId,
        email: "multi-social-\(suffix)@example.com",
        password: "placeholder-\(UUID().uuidString)",
        passwordCredentialEstablished: false
    )
    accounts.addAuthIdentityForTesting(userId: multiUserId, provider: "google", providerEmail: "google@example.com")
    accounts.addAuthIdentityForTesting(userId: multiUserId, provider: "github", providerEmail: "github@example.com")

    accounts.addAccount(
        id: concurrentUserId,
        email: "concurrent-social-\(suffix)@example.com",
        password: "placeholder-\(UUID().uuidString)",
        passwordCredentialEstablished: false
    )
    accounts.addAuthIdentityForTesting(userId: concurrentUserId, provider: "google", providerEmail: "google@example.com")
    accounts.addAuthIdentityForTesting(userId: concurrentUserId, provider: "github", providerEmail: "github@example.com")

    accounts.addAccount(id: unrelatedUserId, email: "unrelated-\(suffix)@example.com", password: "password123")

    return IdentityFixture(
        accounts: accounts,
        passwordUserId: passwordUserId,
        passwordUserEmail: passwordUserEmail,
        passwordlessUserId: passwordlessUserId,
        passwordlessUserEmail: passwordlessUserEmail,
        legacyUserId: legacyUserId,
        legacyUserEmail: legacyUserEmail,
        multiUserId: multiUserId,
        concurrentUserId: concurrentUserId,
        unrelatedUserId: unrelatedUserId
    )
}

private func identityToken(_ accounts: EmailLoginDirectory, _ userId: String) -> String {
    accounts.mintAccessTokenForTesting(userId: userId)
}

private func identityHeaders(_ token: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    return headers
}

private func identityObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func identityLogin(_ client: any Client, email: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
}

@Test func identityUnlinkKeepsOneLoginMethodAndIsOwnerBound() async throws {
    let fixture = makeIdentityFixture(suffix: "921")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let unauthenticated = try await client.send(.delete, headers: HTTPFields(), to: "/api/auth/identities/apple")
            #expect(unauthenticated.status == .unauthorized)

            let passwordlessToken = identityToken(fixture.accounts, fixture.passwordlessUserId)
            let methodsBefore = try await client.get("/api/auth/identities", headers: identityHeaders(passwordlessToken))
            #expect(methodsBefore.status == .ok)
            #expect(try identityObject(methodsBefore) as NSDictionary == [
                "identities": [["provider": "github", "providerEmail": "github@example.com"]],
                "passwordConfigured": false,
            ] as NSDictionary)

            #expect(try await identityLogin(client, email: fixture.passwordlessUserEmail).status == .unauthorized)
            #expect(try await identityLogin(client, email: fixture.legacyUserEmail).status == .ok)
            #expect(fixture.accounts.passwordCredentialEstablished(userId: fixture.legacyUserId))

            let blocked = try await client.send(.delete, headers: identityHeaders(passwordlessToken), to: "/api/auth/identities/github")
            #expect(blocked.status == .conflict)
            #expect(try identityObject(blocked) as NSDictionary == [
                "code": "PASSWORD_CREDENTIAL_REQUIRED",
                "error": "Set a password before disconnecting your final sign-in account.",
            ] as NSDictionary)
            #expect(fixture.accounts.authIdentityCount(userId: fixture.passwordlessUserId) == 1)

            let multiToken = identityToken(fixture.accounts, fixture.multiUserId)
            let firstOfTwo = try await client.send(.delete, headers: identityHeaders(multiToken), to: "/api/auth/identities/google")
            #expect(firstOfTwo.status == .ok)
            #expect(try identityObject(firstOfTwo) as NSDictionary == [
                "unlinked": true,
                "identities": [["provider": "github", "providerEmail": "github@example.com"]],
                "passwordConfigured": false,
            ] as NSDictionary)
            let secondOfTwo = try await client.send(.delete, headers: identityHeaders(multiToken), to: "/api/auth/identities/github")
            #expect(secondOfTwo.status == .conflict)

            let concurrentToken = identityToken(fixture.accounts, fixture.concurrentUserId)
            async let google = client.send(.delete, headers: identityHeaders(concurrentToken), to: "/api/auth/identities/google")
            async let github = client.send(.delete, headers: identityHeaders(concurrentToken), to: "/api/auth/identities/github")
            let (googleResponse, githubResponse) = try await (google, github)
            #expect([googleResponse.status.code, githubResponse.status.code].sorted() == [200, 409])
            #expect(fixture.accounts.authIdentityCount(userId: fixture.concurrentUserId) == 1)

            let unrelatedToken = identityToken(fixture.accounts, fixture.unrelatedUserId)
            let unrelated = try await client.send(.delete, headers: identityHeaders(unrelatedToken), to: "/api/auth/identities/apple")
            #expect(unrelated.status == .ok)
            #expect(try identityObject(unrelated) as NSDictionary == [
                "unlinked": false,
                "identities": [],
                "passwordConfigured": true,
            ] as NSDictionary)
            #expect(fixture.accounts.authIdentityCount(userId: fixture.passwordUserId) == 1)

            let passwordToken = identityToken(fixture.accounts, fixture.passwordUserId)
            let unlinked = try await client.send(.delete, headers: identityHeaders(passwordToken), to: "/api/auth/identities/apple")
            #expect(unlinked.status == .ok)
            #expect(try identityObject(unlinked) as NSDictionary == [
                "unlinked": true,
                "identities": [],
                "passwordConfigured": true,
            ] as NSDictionary)
            let replay = try await client.send(.delete, headers: identityHeaders(passwordToken), to: "/api/auth/identities/apple")
            #expect(replay.status == .ok)
            #expect(try identityObject(replay) as NSDictionary == [
                "unlinked": false,
                "identities": [],
                "passwordConfigured": true,
            ] as NSDictionary)
        }
    }
}

@Test func verifiedPasswordResetEstablishesTheCredentialForFinalUnlink() async throws {
    let fixture = makeIdentityFixture(suffix: "922")
    let accounts = fixture.accounts
    accounts.addAccount(
        id: "11111111-1111-4111-8111-111111111930",
        email: "password-setup-922@example.com",
        password: "placeholder-\(UUID().uuidString)",
        passwordCredentialEstablished: false
    )
    let userId = "11111111-1111-4111-8111-111111111930"
    accounts.addAuthIdentityForTesting(userId: userId, provider: "google", providerEmail: "google@example.com")
    accounts.addPasswordResetTokenForTesting(userId: userId, token: "verified-password-setup-token", expiresAt: Date().addingTimeInterval(60))

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let reset = try await client.send(.post, headers: headers, to: "/api/auth/reset-password") { request in
                request.body = .init(string: "{\"token\":\"verified-password-setup-token\",\"password\":\"new-password-123\"}")
            }
            #expect(reset.status == .ok)

            let token = identityToken(accounts, userId)
            let methods = try await client.get("/api/auth/identities", headers: identityHeaders(token))
            #expect(methods.status == .ok)
            #expect(try identityObject(methods)["passwordConfigured"] as? Bool == true)

            let unlink = try await client.send(.delete, headers: identityHeaders(token), to: "/api/auth/identities/google")
            #expect(unlink.status == .ok)
            #expect(try identityObject(unlink)["unlinked"] as? Bool == true)
        }
    }
}
