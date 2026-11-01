import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func joinLinksListUseAndRevoke() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111632"
    let memberId = "11111111-1111-4111-8111-111111111633"
    let outsiderId = "11111111-1111-4111-8111-111111111634"
    let exhaustedId = "11111111-1111-4111-8111-111111111635"
    let serverId = "33333333-3333-4333-8333-333333333674"
    for (id, email) in [
        (ownerId, "join-link-owner@slock.test"),
        (memberId, "join-link-member@slock.test"),
        (outsiderId, "join-link-outsider@slock.test"),
        (exhaustedId, "join-link-exhausted@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "join-link", name: "Join Link", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
            let owner = try await token("join-link-owner@slock.test")
            let member = try await token("join-link-member@slock.test")
            let outsider = try await token("join-link-outsider@slock.test")
            let exhausted = try await token("join-link-exhausted@slock.test")

            func request(_ method: HTTPRequest.Method, _ path: String, _ bearer: String?, body: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                headers[.contentType] = "application/json"
                return try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }

            #expect(try await request(.post, "/api/servers/\(serverId)/join-links", owner, body: "{\"maxUses\":0}").status == .badRequest)
            #expect(try await request(.post, "/api/servers/\(serverId)/join-links", owner, body: "{\"expiresAt\":\"not-a-date\"}").status == .badRequest)

            let created = try await request(.post, "/api/servers/\(serverId)/join-links", owner, body: "{\"maxUses\":1,\"expiresAt\":null}")
            #expect(created.status == .ok)
            let createdBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            let link = createdBody?["link"] as? [String: Any]
            let tokenValue = createdBody?["token"] as? String ?? ""
            let linkId = link?["id"] as? String ?? ""
            #expect(!tokenValue.isEmpty)
            #expect(link?["useCount"] as? Int == 0)
            #expect(link?["maxUses"] as? Int == 1)

            let list = try await request(.get, "/api/servers/\(serverId)/join-links", owner)
            #expect(list.status == .ok)
            let links = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(links.count == 1)
            #expect(links.first?["id"] as? String == linkId)
            #expect(try await request(.get, "/api/servers/\(serverId)/join-links", member).status == .forbidden)
            #expect(try await request(.get, "/api/servers/\(serverId)/join-links", nil).status == .unauthorized)

            #expect(try await request(.get, "/api/auth/invite-info?token=\(tokenValue)", nil).status == .ok)
            let accepted = try await request(.post, "/api/auth/accept-invite", outsider, body: "{\"token\":\"\(tokenValue)\"}")
            #expect(accepted.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: outsiderId) == "member")
            #expect(try await request(.post, "/api/auth/accept-invite", exhausted, body: "{\"token\":\"\(tokenValue)\"}").status == .badRequest)
            let exhaustedList = try await request(.get, "/api/servers/\(serverId)/join-links", owner)
            let exhaustedRows = (try JSONSerialization.jsonObject(with: Data((exhaustedList.body.string ?? "").utf8)) as? [[String: Any]]) ?? []
            #expect(exhaustedRows.isEmpty)

            let second = try await request(.post, "/api/servers/\(serverId)/join-links", owner, body: "{}")
            let secondBody = try JSONSerialization.jsonObject(with: Data((second.body.string ?? "").utf8)) as? [String: Any]
            let secondId = (secondBody?["link"] as? [String: Any])?["id"] as? String ?? ""
            #expect(try await request(.delete, "/api/servers/\(serverId)/join-links/\(secondId)", member).status == .forbidden)
            #expect(try await request(.delete, "/api/servers/\(serverId)/join-links/\(secondId)", owner).status == .ok)
            let revokedList = try await request(.get, "/api/servers/\(serverId)/join-links", owner)
            let revokedRows = (try JSONSerialization.jsonObject(with: Data((revokedList.body.string ?? "").utf8)) as? [[String: Any]]) ?? []
            #expect(revokedRows.isEmpty)
        }
    }
}
