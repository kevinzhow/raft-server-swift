import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverInvitesCanBeRevokedByAdmins() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111664"
    let memberId = "11111111-1111-4111-8111-111111111665"
    let serverId = "33333333-3333-4333-8333-333333333686"
    for (id, email) in [
        (ownerId, "invite-owner@slock.test"),
        (memberId, "invite-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "invites", name: "Invites", ownerId: ownerId)
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
            func request(_ method: HTTPRequest.Method, _ path: String, _ bearer: String, body: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                return try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            let owner = try await token("invite-owner@slock.test")
            let member = try await token("invite-member@slock.test")

            let created = try await request(.post, "/api/servers/\(serverId)/invites", owner, body: "{\"email\":\"new-human@slock.test\"}")
            #expect(created.status == .ok)
            let createdBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            let inviteId = createdBody?["id"] as? String ?? ""
            #expect(!inviteId.isEmpty)

            let listed = try await request(.get, "/api/servers/\(serverId)/invites", owner)
            let rows = try JSONSerialization.jsonObject(with: Data((listed.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.map { $0["id"] as? String } == [inviteId])

            #expect(try await request(.delete, "/api/servers/\(serverId)/invites/\(inviteId)", member).status == .forbidden)
            #expect(try await request(.delete, "/api/servers/\(serverId)/invites/\(inviteId)", owner).status == .ok)
            let after = try await request(.get, "/api/servers/\(serverId)/invites", owner)
            #expect((try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [[String: Any]] ?? []).isEmpty)
            #expect(try await request(.delete, "/api/servers/\(serverId)/invites/missing", owner).status == .ok)
        }
    }
}
