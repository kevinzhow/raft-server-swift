import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private let leakMarkers = [
    "invalid input syntax for type uuid",
    "Failed query",
    "params:",
    "23505",
    "23503",
    "42P01",
    "22P02",
    "internal_server_error",
]

private func assertNoLeak(_ body: String) {
    let lowered = body.lowercased()
    for marker in leakMarkers {
        #expect(lowered.contains(marker.lowercased()) == false)
    }
    #expect(body.range(of: #"(?i)\b(select|insert|update|delete)\b[\s\S]*\bfrom\b\s+"[a-z_]+""#, options: .regularExpression) == nil)
}

private func serverScopeFixture() -> (accounts: EmailLoginDirectory, token: String) {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111651"
    accounts.addAccount(id: userId, email: "server-scope-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    // This helper opens an actual session on this Root's authProfileStore.
    return (accounts, accounts.mintAccessTokenForTesting(userId: userId))
}

private func assertServerScopeReply(_ response: ClientResponse, status: HTTPResponse.Status, body: String) {
    #expect(response.status == status)
    #expect(bodyText(response) == body)
    #expect(response.headers[.contentLength] == String(body.utf8.count))
    #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
    #expect(response.headers[.cacheControl] == "private, no-store")
    assertNoLeak(bodyText(response))
}

@Test func malformedServerIdIsAClean404() async throws {
    let fixture = serverScopeFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            // Preserve the original invalid-Bearer request at the complete mount.
            let response = try await client.get("/api/servers/not-a-uuid/members", headers: [
                .authorization: "Bearer token",
                HTTPField.Name("X-Server-Id")!: "not-a-uuid",
            ])
            assertServerScopeReply(response, status: .unauthorized,
                body: "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            let anonymous = try await client.get("/api/servers/not-a-uuid/members", headers: [
                HTTPField.Name("X-Server-Id")!: "not-a-uuid",
            ])
            assertServerScopeReply(anonymous, status: .unauthorized,
                body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")

            // Only authentication differs; retain the malformed URL and header.
            let authenticated = try await client.get("/api/servers/not-a-uuid/members", headers: [
                .authorization: "Bearer \(fixture.token)",
                HTTPField.Name("X-Server-Id")!: "not-a-uuid",
            ])
            assertServerScopeReply(authenticated, status: .notFound, body: "{\"error\":\"Server not found\"}")
        }
    }
}

@Test func mismatchedServerHeaderStaysATyped4xx() async throws {
    let fixture = serverScopeFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let mismatched = try await client.get("/api/servers/path-value/members", headers: [
                .authorization: "Bearer token",
                HTTPField.Name("X-Server-Id")!: "header-value",
            ])
            assertServerScopeReply(mismatched, status: .unauthorized,
                body: "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            let authenticatedMalformed = try await client.get("/api/servers/path-value/members", headers: [
                .authorization: "Bearer \(fixture.token)",
                HTTPField.Name("X-Server-Id")!: "header-value",
            ])
            assertServerScopeReply(authenticatedMalformed, status: .notFound, body: "{\"error\":\"Server not found\"}")

            let pathId = "11111111-1111-4111-8111-111111111111"
            let headerId = "22222222-2222-4222-8222-222222222222"
            let typed = try await client.get("/api/servers/\(pathId)/members", headers: [
                .authorization: "Bearer token",
                HTTPField.Name("X-Server-Id")!: headerId,
            ])
            assertServerScopeReply(typed, status: .unauthorized,
                body: "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            let anonymous = try await client.get("/api/servers/\(pathId)/members", headers: [
                HTTPField.Name("X-Server-Id")!: headerId,
            ])
            assertServerScopeReply(anonymous, status: .unauthorized,
                body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            let authenticated = try await client.get("/api/servers/\(pathId)/members", headers: [
                .authorization: "Bearer \(fixture.token)",
                HTTPField.Name("X-Server-Id")!: headerId,
            ])
            assertServerScopeReply(authenticated, status: .badRequest,
                body: "{\"error\":\"X-Server-Id must match server id in URL\"}")
        }
    }
}
