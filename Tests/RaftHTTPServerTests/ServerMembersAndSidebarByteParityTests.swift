import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-level locks for the server-member, sidebar, labs and task-metric
/// surface: the published member order, the `Content-Length`/`Content-Type`
/// header set, the two distinct 401 envelopes, and the raw-body fallback the
/// retired handlers accepted without a JSON `Content-Type`.
@Test func serverMemberAndSidebarSurfacePublishesTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001150001"
    let memberId = "11111111-1111-4111-8111-000001150002"
    let serverId = "33333333-3333-4333-8333-000001150001"
    accounts.addAccount(id: ownerId, email: "byte-members-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "byte-members-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "byte-members", name: "Byte Members", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
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

            func assertStandardHeaders(_ response: ClientResponse, body expected: String) {
                #expect(response.headers[.contentType] == "application/json; charset=utf-8")
                #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                #expect(response.headers[.contentLength] == String(Data(expected.utf8).count))
                #expect(response.body.string == expected)
            }

            // `PATCH /api/servers/:id/members/:memberId`: `ok` before `changed`.
            let rolePatch = try await client.send(
                .patch,
                headers: headers,
                to: "/api/servers/\(serverId)/members/\(memberId)"
            ) { request in
                request.body = .init(string: "{\"role\":\"admin\"}")
            }
            #expect(rolePatch.status == .ok)
            assertStandardHeaders(rolePatch, body: "{\"ok\":true,\"changed\":true}")

            // The member-route 401 keeps `code: auth_required` and `no-store`.
            let anonymousRole = try await client.send(
                .patch,
                headers: HTTPFields(),
                to: "/api/servers/\(serverId)/members/\(memberId)"
            ) { request in
                request.body = .init(string: "{\"role\":\"member\"}")
            }
            #expect(anonymousRole.status == .unauthorized)
            #expect(anonymousRole.body.string
                == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            #expect(anonymousRole.headers[HTTPField.Name("Cache-Control")!] == "no-store")

            // `GET /labs`: catalog order and the two hidden definitions omitted.
            let labs = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/labs")
            #expect(labs.status == .ok)
            assertStandardHeaders(
                labs,
                body: "{\"accessEnabled\":false,\"version\":0,\"canManageAccess\":true,\"canManageEnrollments\":true,\"labs\":[{\"labKey\":\"open_lab\",\"name\":\"Open Lab\",\"description\":\"Available\",\"state\":\"open\",\"enrolled\":false,\"effective\":false,\"updatedAt\":null},{\"labKey\":\"paused_lab\",\"name\":\"Paused Lab\",\"description\":\"Paused\",\"state\":\"paused\",\"enrolled\":false,\"effective\":false,\"updatedAt\":null}]}"
            )

            // The labs scope refusal publishes `code` after `error`.
            var wrongScope = headers
            wrongScope[HTTPField.Name("X-Server-Id")!] = "33333333-3333-4333-8333-000001159999"
            let scope = try await client.send(.get, headers: wrongScope, to: "/api/servers/\(serverId)/labs")
            #expect(scope.status == .forbidden)
            assertStandardHeaders(
                scope,
                body: "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}"
            )

            // `GET /sidebar-order`: the complete published member order.
            let sidebar = try await client.send(
                .get,
                headers: headers,
                to: "/api/servers/\(serverId)/sidebar-order"
            )
            #expect(sidebar.status == .ok)
            assertStandardHeaders(
                sidebar,
                body: "{\"channelOrder\":[],\"agentOrder\":[],\"dmOrder\":[],\"pinned\":[],\"pinnedChannelIds\":[],\"pinnedAgentIds\":[],\"pinnedOrder\":[],\"pinnedVersion\":0,\"hiddenDmIds\":[],\"channelSortMode\":\"manual\",\"jointChannelSortMode\":\"manual\",\"dmSortMode\":\"manual\",\"pinnedSortMode\":\"manual\",\"channelPanelTabOrder\":[\"chat\"],\"agentPanelTabOrder\":[\"activity\",\"profile\"],\"customSections\":[],\"sectionOrder\":[\"system:pinned\",\"system:joint\",\"system:channels\",\"system:dms\"],\"sectionPlacements\":[],\"sectionsVersion\":0}"
            )

            // The sidebar 401 is the bare `Unauthorized` envelope.
            var scopeOnly = HTTPFields()
            scopeOnly[HTTPField.Name("X-Server-Id")!] = serverId
            let anonymousSidebar = try await client.send(
                .get,
                headers: scopeOnly,
                to: "/api/servers/\(serverId)/sidebar-order"
            )
            #expect(anonymousSidebar.status == .unauthorized)
            assertStandardHeaders(anonymousSidebar, body: "{\"error\":\"Unauthorized\"}")

            // `DELETE /members/:memberId` and `DELETE /:id` answer `{"ok":true}`.
            let removed = try await client.send(
                .delete,
                headers: headers,
                to: "/api/servers/\(serverId)/members/\(memberId)"
            )
            #expect(removed.status == .ok)
            assertStandardHeaders(removed, body: "{\"ok\":true}")

            let deleted = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)")
            #expect(deleted.status == .ok)
            assertStandardHeaders(deleted, body: "{\"ok\":true}")
            // A second delete is the idempotent `{"ok":true}` before auth.
            let deletedAgain = try await client.send(
                .delete,
                headers: HTTPFields(),
                to: "/api/servers/\(serverId)"
            )
            #expect(deletedAgain.status == .ok)
            #expect(deletedAgain.body.string == "{\"ok\":true}")
        }
    }
}

/// The sidebar and member-role handlers accepted a JSON body without a
/// `Content-Type`; the typed routes keep that raw decode fallback.
@Test func serverMemberAndSidebarRoutesAcceptAJsonBodyWithoutAContentType() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001150003"
    let memberId = "11111111-1111-4111-8111-000001150004"
    let serverId = "33333333-3333-4333-8333-000001150002"
    accounts.addAccount(id: ownerId, email: "byte-members-owner2@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "byte-members-member2@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "byte-members-2", name: "Byte Members 2", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
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

            let sidebar = try await client.send(
                .patch,
                headers: headers,
                to: "/api/servers/\(serverId)/sidebar-order"
            ) { request in
                request.body = .init(string: "{\"channelSortMode\":\"recent\"}")
            }
            #expect(sidebar.status == .ok, Comment(rawValue: sidebar.body.string ?? ""))
            #expect(sidebar.body.string?.contains("\"channelSortMode\":\"recent\"") == true)

            let rolePatch = try await client.send(
                .patch,
                headers: headers,
                to: "/api/servers/\(serverId)/members/\(memberId)"
            ) { request in
                request.body = .init(string: "{\"role\":\"admin\"}")
            }
            #expect(rolePatch.status == .ok, Comment(rawValue: rolePatch.body.string ?? ""))
            #expect(rolePatch.body.string == "{\"ok\":true,\"changed\":true}")

            let labsAccess = try await client.send(
                .patch,
                headers: headers,
                to: "/api/servers/\(serverId)/labs/access"
            ) { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":0}")
            }
            #expect(labsAccess.status == .ok, Comment(rawValue: labsAccess.body.string ?? ""))
            #expect(labsAccess.body.string?.hasPrefix("{\"applied\":true,\"accessEnabled\":true,\"version\":1,\"labs\":[") == true)
        }
    }
}

/// The two task aggregate surfaces keep their published member order and the
/// retired `number(_:)` scalar text (an integral value has no `.0`).
@Test func taskAggregateMetricsPublishTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001150005"
    let serverId = "33333333-3333-4333-8333-000001150003"
    accounts.addAccount(id: ownerId, email: "byte-metrics-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "byte-metrics", name: "Byte Metrics", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "metrics", creatorUserId: ownerId)
    let iso = ISO8601DateFormatter()
    func date(_ text: String) -> Date { iso.date(from: text) ?? Date() }
    accounts.addTaskSnapshot(
        channelId: channelId,
        title: "Review",
        status: "in_review",
        createdAt: date("2026-07-01T00:00:00Z"),
        updatedAt: date("2026-08-09T00:00:00Z")
    )
    accounts.addTaskSnapshot(
        channelId: channelId,
        title: "Done",
        status: "done",
        createdAt: date("2026-07-02T00:00:00Z"),
        updatedAt: date("2026-07-03T00:00:00Z"),
        completedAt: date("2026-07-03T00:00:00Z")
    )
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

            let snapshot = try await client.send(
                .get,
                headers: headers,
                to: "/api/tasks/server/snapshot-metrics"
            )
            #expect(snapshot.status == .ok)
            #expect(snapshot.body.string
                == "{\"total\":2,\"inReview\":1,\"done\":1,\"durationSamples\":1,\"medianHours\":24,\"p90Hours\":24,\"firstCreatedAt\":\"2026-07-01T00:00:00.000Z\",\"latestUpdatedAt\":\"2026-08-09T00:00:00.000Z\"}")
            #expect(snapshot.headers[.contentLength]
                == String(Data((snapshot.body.string ?? "").utf8).count))

            accounts.addCompletedTask(
                channelId: channelId,
                title: "Current",
                createdAt: date("2026-10-10T00:00:00Z"),
                completedAt: date("2026-10-11T00:00:00Z")
            )
            let query = "from=2026-10-04T00:00:00Z&midpoint=2026-10-11T00:00:00Z&to=2026-10-18T00:00:00Z"
            let period = try await client.send(
                .get,
                headers: headers,
                to: "/api/tasks/server/period-metrics?\(query)"
            )
            #expect(period.status == .ok)
            #expect(period.body.string
                == "{\"current\":{\"completed\":1,\"durationSamples\":1,\"meanHours\":24,\"medianHours\":24},\"previous\":{\"completed\":0,\"durationSamples\":0,\"meanHours\":0,\"medianHours\":0}}")
        }
    }
}
