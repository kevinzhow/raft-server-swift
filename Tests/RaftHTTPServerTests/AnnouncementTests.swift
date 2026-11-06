import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func activeAnnouncementIsOldestUnreadAndDismissalPersists() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111455"
    accounts.addAccount(id: userId, email: "announcement@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let first = accounts.addAnnouncementForTesting(title: "First", pages: ["page one"], startsAt: firstDate)
    let second = accounts.addAnnouncementForTesting(title: "Second", pages: ["body1", "body2"], startsAt: firstDate.addingTimeInterval(1))

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
                request.body = .init(string: "{\"email\":\"announcement@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            func active(_ query: String = "") async throws -> ClientResponse {
                try await client.send(.get, headers: headers, to: URI(string: "/api/announcements/active\(query)"))
            }
            func ids(_ response: ClientResponse) throws -> [String] {
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["announcements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }

            let initial = try await active()
            #expect(initial.status == .ok)
            #expect(try ids(initial) == [first])
            let initialBody = try JSONSerialization.jsonObject(with: Data((initial.body.string ?? "").utf8)) as? [String: Any]
            #expect((initialBody?["announcements"] as? [[String: Any]])?.first?["pages"] is [Any])

            let advanced = try await active("?after=\(first)")
            #expect(try ids(advanced) == [second])
            #expect(try await active("?after=not-a-uuid").status == .badRequest)

            let dismissed = try await client.send(.post, headers: headers, to: "/api/announcements/\(first)/dismiss")
            #expect(dismissed.status == .ok)
            #expect(try ids(try await active()) == [second])
            #expect(try await client.send(.post, headers: headers, to: "/api/announcements/\(UUID().uuidString.lowercased())/dismiss").status == .notFound)
            #expect(try await client.send(.get, headers: HTTPFields(), to: "/api/announcements/active").status == .unauthorized)
        }
    }
}

@Test func draftsNeverSurfaceAndExpiringTheNewestFallsThroughToOlderUnread() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111642"
    accounts.addAccount(id: userId, email: "announcement-draft@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let base = Date(timeIntervalSince1970: 1_700_100_000)
    let live = accounts.addAnnouncementForTesting(title: "Live", pages: ["live body"], startsAt: base)
    _ = accounts.addAnnouncementForTesting(title: "Draft", pages: ["draft body"], startsAt: base.addingTimeInterval(1), status: "draft")
    let scheduled = accounts.addAnnouncementForTesting(
        title: "Scheduled", pages: ["scheduled body"], startsAt: base.addingTimeInterval(2), status: "scheduled"
    )
    _ = accounts.addAnnouncementForTesting(
        title: "Expiring", pages: ["expiring body"], startsAt: base.addingTimeInterval(-10),
        expiresAt: base.addingTimeInterval(60), status: "published", publishedAt: base.addingTimeInterval(-10)
    )
    _ = live
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"announcement-draft@slock.test\",\"password\":\"password123\"}")
            }
            let loginBody = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8))) as? [String: Any]
            let token = loginBody?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            func ids(_ path: String) async throws -> [String] {
                let response = try await client.get(URI(string: path), headers: headers)
                let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
                return (body?["announcements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            let first = try await ids("/api/announcements/active")
            #expect(first.count == 1, "drafts and future scheduled rows never surface")
            #expect(first.first != scheduled)
            let afterFirst = try await ids("/api/announcements/active?after=\(first.first ?? "")")
            #expect(!afterFirst.contains(live), "only the oldest unread is served")
        }
    }
}

private func announcementLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
    return body?["accessToken"] as? String ?? ""
}

@Test func targetedAnnouncementsStayInsideTheirServerAndNeverEchoAudience() async throws {
    let accounts = EmailLoginDirectory()
    let memberId = "11111111-1111-4111-8111-111111111646"
    let outsiderId = "11111111-1111-4111-8111-111111111647"
    let serverId = "33333333-3333-4333-8333-333333333686"
    accounts.addAccount(id: memberId, email: "ann-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.addAccount(id: outsiderId, email: "ann-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "ann-context", name: "Announcement Context", ownerId: memberId)
    let targeted = accounts.addAnnouncementForTesting(
        title: "Members only", pages: ["for the server"], startsAt: Date(timeIntervalSince1970: 1_700_200_000)
    )
    accounts.setAnnouncementAudienceForTesting(id: targeted, serverIds: [serverId])

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let memberToken = try await announcementLogin(client, email: "ann-member@slock.test")
            let outsiderToken = try await announcementLogin(client, email: "ann-outsider@slock.test")
            func active(_ token: String, _ query: String = "") async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                let response = try await client.get(URI(string: "/api/announcements/active\(query)"), headers: headers)
                let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response.status, body)
            }

            #expect(try await active(memberToken, "?server_id=bad").status == .badRequest)
            #expect(try await active(memberToken, "?server_id=\(serverId)&server_id=\(serverId)").status == .badRequest)
            // Unscoped requests only see untargeted announcements.
            #expect(((try await active(memberToken).body["announcements"] as? [[String: Any]]) ?? []).isEmpty)
            #expect(((try await active(outsiderToken, "?server_id=\(serverId)").body["announcements"] as? [[String: Any]]) ?? []).isEmpty)
            let scoped = try await active(memberToken, "?server_id=\(serverId)")
            let rows = (scoped.body["announcements"] as? [[String: Any]]) ?? []
            #expect(rows.map { $0["id"] as? String } == [targeted])
            #expect(rows.first?["audience"] == nil, "the audience is never echoed")

            // An outsider dismissing inside the target server learns nothing.
            let denied = try await client.send(.post, headers: {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(outsiderToken)"
                return headers
            }(), to: URI(string: "/api/announcements/\(targeted)/dismiss?server_id=\(serverId)"))
            #expect(denied.status == .notFound)
        }
    }
}

@Test func dismissalsArePerUserAndRepublishingSurfacesANewRow() async throws {
    let accounts = EmailLoginDirectory()
    let firstId = "11111111-1111-4111-8111-111111111648"
    let secondId = "11111111-1111-4111-8111-111111111649"
    for (id, email) in [(firstId, "ann-first@slock.test"), (secondId, "ann-second@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    let base = Date(timeIntervalSince1970: 1_700_300_000)
    let first = accounts.addAnnouncementForTesting(title: "First", pages: ["one"], startsAt: base)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let firstToken = try await announcementLogin(client, email: "ann-first@slock.test")
            let secondToken = try await announcementLogin(client, email: "ann-second@slock.test")
            func ids(_ token: String) async throws -> [String] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                let response = try await client.get(URI(string: "/api/announcements/active"), headers: headers)
                let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
                return (body?["announcements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            var dismissHeaders = HTTPFields()
            dismissHeaders[.authorization] = "Bearer \(firstToken)"
            let dismissed = try await client.send(.post, headers: dismissHeaders, to: URI(string: "/api/announcements/\(first)/dismiss"))
            #expect(dismissed.status == .ok)
            #expect(try await ids(firstToken).isEmpty, "the dismissing user no longer sees it")
            #expect(try await ids(secondToken) == [first], "another user's dismissal is unaffected")

            // Publishing a fresh announcement surfaces a new row.
            let second = accounts.addAnnouncementForTesting(title: "Second", pages: ["two"], startsAt: base.addingTimeInterval(60))
            #expect(try await ids(firstToken) == [second])
        }
    }
}

@Test func announcementPublishAndAdminRoutesAreNotExposed() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111650"
    accounts.addAccount(id: userId, email: "ann-admin@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let token = try await announcementLogin(client, email: "ann-admin@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            for (method, path) in [
                (HTTPRequest.Method.post, "/api/announcements"),
                (HTTPRequest.Method.post, "/api/announcements/active"),
                (HTTPRequest.Method.get, "/api/admin/announcements"),
                (HTTPRequest.Method.post, "/api/admin/announcements"),
            ] {
                let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: "{}")
                }
                #expect(response.status == .notFound, "\(method) \(path) must not be exposed")
            }
        }
    }
}
