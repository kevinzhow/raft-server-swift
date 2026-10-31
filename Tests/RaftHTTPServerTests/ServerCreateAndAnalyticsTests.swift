import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverCreateEnforcesTheSlugMinimumAndAnalyticsFollowsRole() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111406"
    let adminId = "11111111-1111-4111-8111-111111111407"
    let memberId = "11111111-1111-4111-8111-111111111408"
    let serverId = "33333333-3333-4333-8333-333333333538"
    for (id, email) in [
        (ownerId, "create-owner@slock.test"),
        (adminId, "create-admin@slock.test"),
        (memberId, "create-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "analytics-role", name: "Analytics Role", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            let ownerToken = try await login("create-owner@slock.test")
            let adminToken = try await login("create-admin@slock.test")
            let memberToken = try await login("create-member@slock.test")
            var createHeaders = HTTPFields()
            createHeaders[.authorization] = "Bearer \(ownerToken)"
            createHeaders[.contentType] = "application/json"

            let tooShort = try await client.send(.post, headers: createHeaders, to: "/api/servers") { request in
                request.body = .init(string: "{\"name\":\"Server abcd\",\"slug\":\"abcd\"}")
            }
            #expect(tooShort.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((tooShort.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Slug must be at least 5 characters")
            #expect(accounts.oauth.serverIdForSlug("abcd") == nil)

            let created = try await client.send(.post, headers: createHeaders, to: "/api/servers") { request in
                request.body = .init(string: "{\"name\":\"Server abcde\",\"slug\":\"abcde\"}")
            }
            #expect(created.status == .ok)
            let createdBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            #expect(createdBody?["slug"] as? String == "abcde")
            let newServerId = createdBody?["id"] as? String ?? ""
            #expect(accounts.oauth.memberRole(serverId: newServerId, userId: ownerId) == "owner")

            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func settings(_ token: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/product-analytics-settings")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            let ownerView = try await settings(ownerToken)
            #expect(ownerView["productAnalyticsEnabled"] as? Bool == true)
            #expect(ownerView["canManageProductAnalytics"] as? Bool == true)
            let memberView = try await settings(memberToken)
            #expect(memberView["canManageProductAnalytics"] as? Bool == false)

            let memberPatch = try await client.send(.patch, headers: headers(memberToken), to: "/api/servers/\(serverId)/product-analytics-settings") { request in
                request.body = .init(string: "{\"productAnalyticsEnabled\":false}")
            }
            #expect(memberPatch.status == .forbidden)

            let invalid = try await client.send(.patch, headers: headers(ownerToken), to: "/api/servers/\(serverId)/product-analytics-settings") { request in
                request.body = .init(string: "{\"productAnalyticsEnabled\":\"no\"}")
            }
            #expect(invalid.status == .badRequest)

            let adminPatch = try await client.send(.patch, headers: headers(adminToken), to: "/api/servers/\(serverId)/product-analytics-settings") { request in
                request.body = .init(string: "{\"productAnalyticsEnabled\":false}")
            }
            #expect(adminPatch.status == .ok)
            let adminView = try await settings(adminToken)
            #expect(adminView["productAnalyticsEnabled"] as? Bool == false)
        }
    }
}
