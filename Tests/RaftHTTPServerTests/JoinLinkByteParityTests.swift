import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-level locks for the join-link surface: the published member order and
/// the `Content-Length`/`Content-Type` header set, plus the raw-body fallback
/// the retired handler accepted without a JSON `Content-Type`.
@Test func joinLinkInviteInfoPublishesTheLegacyBytesAndHeaders() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001140001"
    let serverId = "33333333-3333-4333-8333-000001140001"
    accounts.addAccount(id: ownerId, email: "byte-parity-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "byte-parity", name: "Byte Parity", ownerId: ownerId)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let created = try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/join-links") { request in
                request.body = .init(string: "{}")
            }
            #expect(created.status == .ok)
            let tokenValue = (try JSONSerialization.jsonObject(
                with: Data((created.body.string ?? "").utf8)
            ) as? [String: Any])?["token"] as? String ?? ""
            #expect(!tokenValue.isEmpty)

            let info = try await client.get(URI(string: "/api/auth/invite-info?token=\(tokenValue)"))
            #expect(info.status == .ok)
            // Exact upstream invite-info order: serverId, serverName,
            // serverSlug, humanSeatLimitReached, humanSeatLimitMessage,
            // memberCount, agentCount, insideCountsHidden, agreement.
            let expected = "{\"serverId\":\"\(serverId)\",\"serverName\":\"Byte Parity\",\"serverSlug\":\"byte-parity\",\"humanSeatLimitReached\":false,\"humanSeatLimitMessage\":null,\"memberCount\":1,\"agentCount\":0,\"insideCountsHidden\":false,\"agreement\":null}"
            #expect(info.body.string == expected)
            #expect(info.headers[.contentType] == "application/json; charset=utf-8")
            #expect(info.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(info.headers[.contentLength] == String(Data(expected.utf8).count))
        }
    }
}

/// A JSON body sent without a `Content-Type` still creates the link, because
/// the retired handler read the raw bytes and the typed route keeps that
/// fallback.
@Test func joinLinkCreateAcceptsAJsonBodyWithoutAContentType() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001140002"
    let serverId = "33333333-3333-4333-8333-000001140002"
    accounts.addAccount(id: ownerId, email: "byte-parity-owner2@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "byte-parity-2", name: "Byte Parity 2", ownerId: ownerId)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let created = try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/join-links") { request in
                request.body = .init(string: "{\"maxUses\":2}")
            }
            #expect(created.status == .ok, Comment(rawValue: created.body.string ?? ""))
            let body = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            #expect((body?["maxUses"] as? Int) == 2)
            #expect((body?["token"] as? String)?.isEmpty == false)
        }
    }
}

/// The unauthenticated list reply keeps both the published body order and the
/// `Cache-Control: no-store` header the retired `PublicVisits.authRequired`
/// helper set.
@Test func joinLinkListUnauthenticatedKeepsTheExactErrorEnvelope() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001140003"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let anonymous = try await client.get(URI(string: "/api/servers/\(serverId)/join-links"))
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body.string == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            #expect(anonymous.headers[HTTPField.Name("Cache-Control")!] == "no-store")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer not-a-token"
            let expired = try await client.get(URI(string: "/api/servers/\(serverId)/join-links"), headers: headers)
            #expect(expired.status == .unauthorized)
            #expect(expired.body.string == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            #expect(expired.headers[HTTPField.Name("Cache-Control")!] == "no-store")
        }
    }
}
