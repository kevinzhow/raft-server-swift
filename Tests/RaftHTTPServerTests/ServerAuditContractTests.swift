import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func memberGraphIsUnavailableWhenTheHumanDirectoryIsHidden() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111684"
    let memberId = "11111111-1111-4111-8111-111111111685"
    let serverId = "33333333-3333-4333-8333-333333333696"
    for (id, email, role) in [
        (ownerId, "graph-hidden-owner@slock.test", "owner"),
        (memberId, "graph-hidden-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "graph-hidden", name: "Graph Hidden", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)

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
            func graph(_ bearer: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.get("/api/servers/\(serverId)/member-graph", headers: headers)
            }
            let memberToken = try await token("graph-hidden-member@slock.test")
            let ownerToken = try await token("graph-hidden-owner@slock.test")
            #expect(try await graph(memberToken).status == .forbidden)
            #expect(try await graph(ownerToken).status == .ok)
        }
    }
}

@Test func unreadSummaryIsCrossServerWithoutTheServerHeader() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111686"
    let peerId = "11111111-1111-4111-8111-111111111687"
    let serverA = "33333333-3333-4333-8333-333333333697"
    let serverB = "33333333-3333-4333-8333-333333333698"
    accounts.addAccount(id: ownerId, email: "summary-cross@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "summary-cross-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    for serverId in [serverA, serverB] {
        accounts.oauth.addOwnedServer(id: serverId, slug: "summary-\(serverId.suffix(4))", name: "Summary", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
        let channel = accounts.oauth.createChannel(serverId: serverId, name: "summary-room", creatorUserId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "summary-room")
        _ = accounts.oauth.createMessageRecord(channelId: channel, content: "unread", senderId: peerId)
    }

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
                request.body = .init(string: "{\"email\":\"summary-cross@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            let response = try await client.get("/api/servers/unread-summary", headers: headers)
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "private, no-store")
            let rows = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(Set(rows.compactMap { $0["serverId"] as? String }) == Set([serverA, serverB]))
            #expect(rows.allSatisfy { $0["unreadCount"] as? Int == 1 })
        }
    }
}

@Test func sidebarOrderRequiresTheMatchingServerHeader() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111688"
    let serverId = "33333333-3333-4333-8333-333333333699"
    let otherServerId = "33333333-3333-4333-8333-333333333700"
    accounts.addAccount(id: ownerId, email: "sidebar-header@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "sidebar-header", name: "Sidebar Header", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "sidebar-header-other", name: "Sidebar Header Other", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"sidebar-header@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var missing = HTTPFields()
            missing[.authorization] = "Bearer \(token)"
            #expect(try await client.get("/api/servers/\(serverId)/sidebar-order", headers: missing).status == .badRequest)
            var mismatch = missing
            mismatch[HTTPField.Name("X-Server-Id")!] = otherServerId
            #expect(try await client.get("/api/servers/\(serverId)/sidebar-order", headers: mismatch).status == .badRequest)
            var match = missing
            match[HTTPField.Name("X-Server-Id")!] = serverId
            #expect(try await client.get("/api/servers/\(serverId)/sidebar-order", headers: match).status == .ok)
            var patchHeaders = match
            patchHeaders[.contentType] = "application/json"
            let patch = try await client.send(.patch, headers: patchHeaders, to: "/api/servers/\(serverId)/sidebar-order") { request in
                request.body = .init(string: "{\"channelSortMode\":\"recent\"}")
            }
            #expect(patch.status == .ok)
        }
    }
}
