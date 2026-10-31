import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverRenameAndHiddenDirectoryAreOwnerAdminOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111367"
    let adminId = "11111111-1111-4111-8111-111111111368"
    let memberId = "11111111-1111-4111-8111-111111111369"
    let serverId = "33333333-3333-4333-8333-333333333516"
    for (id, email) in [
        (ownerId, "rename-owner@slock.test"),
        (adminId, "rename-admin@slock.test"),
        (memberId, "rename-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "patch-profile", name: "Patch Profile", ownerId: ownerId)
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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func patch(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/servers/\(serverId)") { request in
                    request.body = .init(string: body)
                }
            }
            let ownerToken = try await login("rename-owner@slock.test")
            let adminToken = try await login("rename-admin@slock.test")
            let memberToken = try await login("rename-member@slock.test")

            let ownerRes = try await patch(ownerToken, "{\"name\":\"Renamed by Owner\",\"hideHumansFromMembers\":true}")
            #expect(ownerRes.status == .ok)
            let ownerBody = try JSONSerialization.jsonObject(with: Data((ownerRes.body.string ?? "").utf8)) as? [String: Any]
            #expect(ownerBody?["name"] as? String == "Renamed by Owner")
            #expect(ownerBody?["hideHumansFromMembers"] as? Bool == true)

            let adminRes = try await patch(adminToken, "{\"name\":\"Renamed by Admin\",\"hideHumansFromMembers\":false}")
            #expect(adminRes.status == .ok)
            let adminBody = try JSONSerialization.jsonObject(with: Data((adminRes.body.string ?? "").utf8)) as? [String: Any]
            #expect(adminBody?["name"] as? String == "Renamed by Admin")
            #expect(adminBody?["hideHumansFromMembers"] as? Bool == false)

            #expect(try await patch(memberToken, "{\"hideHumansFromMembers\":true}").status == .forbidden)
            #expect(try await patch(ownerToken, "{\"name\":\"   \"}").status == .badRequest)
            #expect(try await patch(ownerToken, "{\"hideHumansFromMembers\":\"yes\"}").status == .badRequest)
        }
    }
}
