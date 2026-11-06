import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func hiddenHumanDirectoryShowsOnlySelfToPlainMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111355"
    let memberId = "11111111-1111-4111-8111-111111111356"
    let otherId = "11111111-1111-4111-8111-111111111357"
    let serverId = "33333333-3333-4333-8333-333333333507"
    for (id, email) in [
        (ownerId, "hide-directory-owner@slock.test"),
        (memberId, "hide-directory-member@slock.test"),
        (otherId, "hide-directory-other@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "hide-directory", name: "Hide Directory", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)

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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func list(_ token: String) async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/members")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            }
            let memberToken = try await login("hide-directory-member@slock.test")
            let ownerToken = try await login("hide-directory-owner@slock.test")

            let memberView = try await list(memberToken)
            #expect(memberView.compactMap { $0["userId"] as? String } == [memberId])
            let serialized = String(data: try JSONSerialization.data(withJSONObject: memberView), encoding: .utf8) ?? ""
            #expect(!serialized.contains("hide-directory-owner"))
            #expect(!serialized.contains("hide-directory-other"))

            let ownerView = try await list(ownerToken)
            #expect(Set(ownerView.compactMap { $0["userId"] as? String }) == [ownerId, memberId, otherId])
        }
    }
}

@Test func hiddenDirectoryClosesTheMemberGraphToPlainMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111397"
    let memberId = "11111111-1111-4111-8111-111111111398"
    let otherId = "11111111-1111-4111-8111-111111111399"
    let serverId = "33333333-3333-4333-8333-333333333533"
    for (id, email) in [
        (ownerId, "graph-hidden-owner@slock.test"),
        (memberId, "graph-hidden-member@slock.test"),
        (otherId, "graph-hidden-other@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "graph-hidden", name: "Graph Hidden", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)

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
            func headers(_ token: String, server: String = serverId) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = server
                return fields
            }
            let ownerToken = try await login("graph-hidden-owner@slock.test")
            let memberToken = try await login("graph-hidden-member@slock.test")

            let memberGraph = try await client.send(.get, headers: headers(memberToken), to: "/api/servers/\(serverId)/member-graph")
            #expect(memberGraph.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((memberGraph.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Member graph is not available")

            let ownerGraph = try await client.send(.get, headers: headers(ownerToken), to: "/api/servers/\(serverId)/member-graph")
            #expect(ownerGraph.status == .ok)
            let humans = (try JSONSerialization.jsonObject(with: Data((ownerGraph.body.string ?? "").utf8)) as? [String: Any])?["humans"] as? [[String: Any]] ?? []
            #expect(Set(humans.compactMap { $0["id"] as? String }) == [ownerId, memberId, otherId])

            let mismatched = try await client.send(.get, headers: headers(ownerToken, server: UUID().uuidString.lowercased()), to: "/api/servers/\(serverId)/member-graph")
            #expect(mismatched.status == .badRequest)
        }
    }
}
