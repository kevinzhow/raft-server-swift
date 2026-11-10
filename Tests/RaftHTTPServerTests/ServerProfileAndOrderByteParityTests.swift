import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-level locks for the server profile, switcher order, agreement,
/// translation-settings, member-directory and share-artifact routes: the
/// published member order, complete-mount auth/cache headers and the raw
/// fallbacks accepted by the routed services.
@Test func serverProfileAndOrderSurfacePublishesTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001170001"
    let memberId = "11111111-1111-4111-8111-000001170002"
    let serverA = "33333333-3333-4333-8333-000001170001"
    let serverB = "33333333-3333-4333-8333-000001170002"
    accounts.addAccount(id: ownerId, email: "bytes-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "bytes-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "bytes-a", name: "Bytes A", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "bytes-b", name: "Bytes B", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverA, userId: memberId, role: "member")
    accounts.seedServerSwitcherOrder(userId: ownerId, ids: [serverB, serverA], version: 4)
    accounts.enableComposerResourceReferences(serverId: serverA, enabled: true)
    // The injected provider keeps `translationAvailable` independent of the
    // process environment other tests may touch.
    accounts.setTranslationProviderForTesting("fake")
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let memberToken = accounts.mintAccessTokenForTesting(userId: memberId)

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
            var memberHeaders = headers
            memberHeaders[.authorization] = "Bearer \(memberToken)"
            var scopedHeaders = headers
            scopedHeaders[HTTPField.Name("X-Server-Id")!] = serverA
            var scopedMemberHeaders = memberHeaders
            scopedMemberHeaders[HTTPField.Name("X-Server-Id")!] = serverA

            func assertStandard(_ response: ClientResponse, body expected: String, extra: [String: String] = [:]) {
                #expect(response.headers[.contentType] == "application/json; charset=utf-8")
                #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                #expect(response.headers[.contentLength] == String(Data(expected.utf8).count))
                for (name, value) in extra {
                    #expect(response.headers[HTTPField.Name(name)!] == value)
                }
                #expect(response.body.string == expected)
            }

            // Order: `serverOrder` then `serverOrderVersion`.
            let order = try await client.send(.get, headers: headers, to: "/api/servers/order")
            #expect(order.status == .ok)
            assertStandard(order, body: "{\"serverOrder\":[\"\(serverB)\",\"\(serverA)\"],\"serverOrderVersion\":4}")

            // A patch that changes nothing keeps the version; a swap bumps it.
            let same = try await client.send(.patch, headers: headers, to: "/api/servers/order") { request in
                request.body = .init(string: "{\"serverOrder\":[\"\(serverB)\",\"\(serverA)\"]}")
            }
            assertStandard(same, body: "{\"serverOrder\":[\"\(serverB)\",\"\(serverA)\"],\"serverOrderVersion\":4}")
            let swapped = try await client.send(.patch, headers: headers, to: "/api/servers/order") { request in
                request.body = .init(string: "{\"serverOrder\":[\"\(serverA)\"]}")
            }
            assertStandard(swapped, body: "{\"serverOrder\":[\"\(serverA)\",\"\(serverB)\"],\"serverOrderVersion\":5}")

            // The body is accepted without a JSON Content-Type, and a body
            // without a string array is the published 400.
            var noType = headers
            noType[.contentType] = nil
            let raw = try await client.send(.patch, headers: noType, to: "/api/servers/order") { request in
                request.body = .init(string: "{\"serverOrder\":[\"\(serverB)\"]}")
            }
            assertStandard(raw, body: "{\"serverOrder\":[\"\(serverB)\",\"\(serverA)\"],\"serverOrderVersion\":6}")
            for bad in ["{\"serverOrder\":[1]}", "{}", "[]", "not json"] {
                let refused = try await client.send(.patch, headers: headers, to: "/api/servers/order") { request in
                    request.body = .init(string: bad)
                }
                #expect(refused.status == .badRequest)
                assertStandard(refused, body: "{\"error\":\"Invalid server order\"}")
            }

            // Both anonymous user-scoped reads stop at the same outer auth mount.
            let anonymousSummary = try await client.send(.get, headers: HTTPFields(), to: "/api/servers/unread-summary")
            #expect(anonymousSummary.status == .unauthorized)
            assertStandard(anonymousSummary, body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}", extra: ["Cache-Control": "private, no-store"])
            let anonymousOrder = try await client.send(.get, headers: HTTPFields(), to: "/api/servers/order")
            #expect(anonymousOrder.status == .unauthorized)
            assertStandard(
                anonymousOrder,
                body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}",
                extra: ["Cache-Control": "private, no-store"]
            )

            // Unread summary: `serverId`, `unreadCount`, `serverPushMuted`,
            // `activityUnreadCount`, with the private cache header.
            let memberSummary = try await client.send(.get, headers: memberHeaders, to: "/api/servers/unread-summary")
            #expect(memberSummary.status == .ok)
            assertStandard(
                memberSummary,
                body: "[{\"serverId\":\"\(serverA)\",\"unreadCount\":0,\"serverPushMuted\":false,\"activityUnreadCount\":0}]",
                extra: ["Cache-Control": "private, no-store"]
            )

            // Apps: enabled only where composer references are on.
            let apps = try await client.send(.get, headers: headers, to: "/api/servers/\(serverA)/apps")
            assertStandard(
                apps,
                body: "{\"apps\":[{\"appId\":\"system.cleaner\",\"displayName\":\"Memory Cleaner\"},{\"appId\":\"system.reminder\",\"displayName\":\"Reminder\"}]}"
            )
            let appsOff = try await client.send(.get, headers: headers, to: "/api/servers/\(serverB)/apps")
            #expect(appsOff.status == .notFound)
            assertStandard(appsOff, body: "{\"error\":\"Not found\"}")

            // Translation settings: published order, and the legacy `0`/`1`
            // boolean reading of the raw parser.
            let settings = try await client.send(.get, headers: memberHeaders, to: "/api/servers/\(serverA)/translation-settings")
            assertStandard(
                settings,
                body: "{\"translationEnabled\":false,\"translationAvailable\":true,\"canManageTranslation\":false}"
            )
            let enable = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverA)/translation-settings") { request in
                request.body = .init(string: "{\"translationEnabled\":1}")
            }
            assertStandard(
                enable,
                body: "{\"translationEnabled\":true,\"translationAvailable\":true,\"canManageTranslation\":true}"
            )
            let notBool = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverA)/translation-settings") { request in
                request.body = .init(string: "{\"translationEnabled\":2}")
            }
            #expect(notBool.status == .badRequest)
            assertStandard(notBool, body: "{\"error\":\"translationEnabled must be a boolean\"}")
            let memberPatch = try await client.send(.patch, headers: memberHeaders, to: "/api/servers/\(serverA)/translation-settings") { request in
                request.body = .init(string: "{\"translationEnabled\":true}")
            }
            #expect(memberPatch.status == .forbidden)
            assertStandard(memberPatch, body: "{\"error\":\"Only server owners and admins can update translation settings\"}")

            // Agreement: `null` until written, then the published member order.
            let emptyAgreement = try await client.send(.get, headers: headers, to: "/api/servers/\(serverA)/agreement")
            assertStandard(emptyAgreement, body: "{\"agreement\":null}")
            let put = try await client.send(.put, headers: headers, to: "/api/servers/\(serverA)/agreement") { request in
                request.body = .init(string: "{\"enabled\":true,\"title\":\"Terms/1\",\"bodyMarkdown\":\"be nice\"}")
            }
            #expect(put.status == .ok)
            let putBody = put.body.string ?? ""
            let agreementId = accounts.oauth.activeServerAgreement(serverId: serverA)?.id ?? ""
            #expect(!agreementId.isEmpty)
            assertStandard(
                put,
                body: "{\"agreement\":{\"id\":\"\(agreementId)\",\"version\":\(accounts.oauth.activeServerAgreement(serverId: serverA)?.version ?? -1),\"title\":\"Terms/1\",\"bodyMarkdown\":\"be nice\",\"enabled\":true}}"
            )
            #expect(putBody.contains("Terms/1"))
            let badAgreement = try await client.send(.put, headers: headers, to: "/api/servers/\(serverA)/agreement") { request in
                request.body = .init(string: "{\"enabled\":true,\"title\":\"x\"}")
            }
            #expect(badAgreement.status == .badRequest)
            assertStandard(badAgreement, body: "{\"error\":\"Invalid agreement request\"}")
            let disabled = try await client.send(.put, headers: headers, to: "/api/servers/\(serverA)/agreement") { request in
                request.body = .init(string: "{\"enabled\":false,\"title\":\"x\",\"bodyMarkdown\":\"y\"}")
            }
            assertStandard(disabled, body: "{\"agreement\":null}")

            // Profile patch: the name keeps its slash unescaped, `avatarUrl` is
            // a published `null`, and a wrong type is its own 400.
            let patch = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverA)") { request in
                request.body = .init(string: "{\"name\":\"  Team/Alpha  \",\"hideHumansFromMembers\":true}")
            }
            assertStandard(
                patch,
                body: "{\"id\":\"\(serverA)\",\"name\":\"Team/Alpha\",\"slug\":\"bytes-a\",\"avatarUrl\":null,\"hideHumansFromMembers\":true}"
            )
            let blank = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverA)") { request in
                request.body = .init(string: "{\"name\":\"   \"}")
            }
            #expect(blank.status == .badRequest)
            assertStandard(blank, body: "{\"error\":\"Server name is required\"}")
            let nullName = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverA)") { request in
                request.body = .init(string: "{\"name\":null}")
            }
            assertStandard(nullName, body: "{\"error\":\"Server name is required\"}")
            let badHidden = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverA)") { request in
                request.body = .init(string: "{\"hideHumansFromMembers\":\"yes\"}")
            }
            assertStandard(badHidden, body: "{\"error\":\"hideHumansFromMembers must be a boolean\"}")

            // Member list: the owner sees every email; the hidden directory
            // leaves a plain member only themselves.
            let ownerList = try await client.send(.get, headers: scopedHeaders, to: "/api/servers/\(serverA)/members")
            assertStandard(
                ownerList,
                body: "[{\"userId\":\"\(ownerId)\",\"role\":\"owner\",\"name\":\"bytes-owner\",\"displayName\":\"bytes-owner\",\"email\":\"bytes-owner@slock.test\",\"avatarUrl\":null},{\"userId\":\"\(memberId)\",\"role\":\"member\",\"name\":\"bytes-member\",\"displayName\":\"bytes-member\",\"email\":\"bytes-member@slock.test\",\"avatarUrl\":null}]"
            )
            let memberList = try await client.send(.get, headers: scopedMemberHeaders, to: "/api/servers/\(serverA)/members")
            #expect(memberList.body.string?.contains(ownerId) == false)

            // Avatar upload: member refusal and the published key.
            let denied = try await client.send(.post, headers: memberHeaders, to: "/api/servers/\(serverA)/avatar")
            #expect(denied.status == .forbidden)
            assertStandard(denied, body: "{\"error\":\"Forbidden\"}")
            let avatar = try await client.send(.post, headers: headers, to: "/api/servers/\(serverA)/avatar")
            #expect(avatar.status == .ok)
            let avatarBody = avatar.body.string ?? ""
            #expect(avatarBody.hasPrefix("{\"avatarUrl\":\"/api/avatars/server-\(serverA)/"))
            #expect(avatarBody.hasSuffix(".webp\"}"))
            #expect(avatar.headers[.contentLength] == String(Data(avatarBody.utf8).count))
        }
    }
}
