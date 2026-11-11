import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverCreationEnforcesSlugMinimumOnlyForNewServers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111676"
    accounts.addAccount(id: ownerId, email: "slug-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"slug-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            func create(_ slug: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/api/servers") { request in
                    request.body = .init(string: "{\"name\":\"Server \(slug)\",\"slug\":\"\(slug)\"}")
                }
            }
            let short = try await create("abcd")
            #expect(short.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((short.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Slug must be at least 5 characters")
            let ok = try await create("abcde")
            #expect(ok.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((ok.body.string ?? "").utf8)) as? [String: Any])?["slug"] as? String == "abcde")
        }
    }
}

@Test func removedMemberAddRouteStaysUnmounted() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111677"
    let targetId = "11111111-1111-4111-8111-111111111678"
    let serverId = "33333333-3333-4333-8333-333333333692"
    for (id, email) in [
        (ownerId, "member-add-owner@slock.test"),
        (targetId, "member-add-target@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "member-add", name: "Member Add", ownerId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"member-add-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/members") { request in
                request.body = .init(string: "{\"userId\":\"\(targetId)\",\"role\":\"member\"}")
            }
            #expect(response.status == .notFound)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: targetId) == nil)
        }
    }
}

@Test func productAnalyticsSettingsSplitReadAndWriteAuthority() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111679"
    let adminId = "11111111-1111-4111-8111-111111111680"
    let memberId = "11111111-1111-4111-8111-111111111681"
    let serverId = "33333333-3333-4333-8333-333333333693"
    for (id, email, role) in [
        (ownerId, "analytics-owner@slock.test", "owner"),
        (adminId, "analytics-admin@slock.test", "admin"),
        (memberId, "analytics-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "analytics", name: "Analytics", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func request(_ method: HTTPRequest.Method, _ bearer: String, body: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                if body != nil { headers[.contentType] = "application/json" }
                return try await client.send(method, headers: headers, to: "/api/servers/\(serverId)/product-analytics-settings") { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            let owner = try await token("analytics-owner@slock.test")
            let admin = try await token("analytics-admin@slock.test")
            let member = try await token("analytics-member@slock.test")

            let ownerRead = try await request(.get, owner)
            #expect((try JSONSerialization.jsonObject(with: Data((ownerRead.body.string ?? "").utf8)) as? [String: Any])?["canManageProductAnalytics"] as? Bool == true)
            let memberRead = try await request(.get, member)
            #expect((try JSONSerialization.jsonObject(with: Data((memberRead.body.string ?? "").utf8)) as? [String: Any])?["canManageProductAnalytics"] as? Bool == false)
            #expect(try await request(.patch, member, body: "{\"productAnalyticsEnabled\":false}").status == .forbidden)
            #expect(try await request(.patch, owner, body: "{\"productAnalyticsEnabled\":\"no\"}").status == .badRequest)
            let patched = try await request(.patch, admin, body: "{\"productAnalyticsEnabled\":false}")
            #expect(patched.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((patched.body.string ?? "").utf8)) as? [String: Any])?["productAnalyticsEnabled"] as? Bool == false)
        }
    }
}

@Test func serverScopedRoutesRejectMissingOrMismatchedHeader() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111682"
    let outsiderId = "11111111-1111-4111-8111-111111111683"
    let serverA = "33333333-3333-4333-8333-333333333694"
    let serverB = "33333333-3333-4333-8333-333333333695"
    accounts.addAccount(id: userId, email: "scope-user@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addAccount(id: outsiderId, email: "scope-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "scope-a", name: "Scope A", ownerId: userId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "scope-b", name: "Scope B", ownerId: userId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"scope-user@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverA
            let mismatch = try await client.get("/api/servers/\(serverB)/members", headers: headers)
            #expect(mismatch.status == .badRequest)
            var missing = HTTPFields()
            missing[.authorization] = "Bearer \(token)"
            let missingResponse = try await client.get("/api/servers/\(serverA)/members", headers: missing)
            #expect(missingResponse.status == .badRequest)
            var match = HTTPFields()
            match[.authorization] = "Bearer \(token)"
            match[HTTPField.Name("X-Server-Id")!] = serverA
            #expect(try await client.get("/api/servers/\(serverA)/members", headers: match).status == .ok)

            var outsiderLoginHeaders = HTTPFields()
            outsiderLoginHeaders[.contentType] = "application/json"
            let outsiderLogin = try await client.send(.post, headers: outsiderLoginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"scope-outsider@slock.test\",\"password\":\"password123\"}")
            }
            let outsiderToken = (try JSONSerialization.jsonObject(with: Data((outsiderLogin.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var outsiderHeaders = HTTPFields()
            outsiderHeaders[.authorization] = "Bearer \(outsiderToken)"
            outsiderHeaders[HTTPField.Name("X-Server-Id")!] = serverA
            #expect(try await client.get("/api/servers/\(serverA)", headers: outsiderHeaders).status == .forbidden)
        }
    }
}
