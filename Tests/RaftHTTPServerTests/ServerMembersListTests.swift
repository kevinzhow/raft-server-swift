import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func memberListHidesOtherEmailsFromPlainMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111351"
    let adminId = "11111111-1111-4111-8111-111111111352"
    let memberId = "11111111-1111-4111-8111-111111111353"
    let otherId = "11111111-1111-4111-8111-111111111354"
    let serverId = "33333333-3333-4333-8333-333333333506"
    for (id, email) in [
        (ownerId, "list-owner@slock.test"),
        (adminId, "list-admin@slock.test"),
        (memberId, "list-member@slock.test"),
        (otherId, "list-other@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "members-list", name: "Members List", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")

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
            let ownerToken = try await login("list-owner@slock.test")
            let adminToken = try await login("list-admin@slock.test")
            let memberToken = try await login("list-member@slock.test")

            let ownerView = try await list(ownerToken)
            #expect(ownerView.count == 4)
            #expect(ownerView.allSatisfy { ($0["email"] as? String)?.isEmpty == false })
            #expect(try await list(adminToken).allSatisfy { ($0["email"] as? String)?.isEmpty == false })

            let memberView = try await list(memberToken)
            for row in memberView {
                if row["userId"] as? String == memberId {
                    #expect(row["email"] as? String == "list-member@slock.test")
                } else {
                    #expect(row["email"] == nil || row["email"] is NSNull)
                }
            }
            let serialized = String(data: try JSONSerialization.data(withJSONObject: memberView), encoding: .utf8) ?? ""
            #expect(!serialized.contains("list-owner@slock.test"))
            #expect(!serialized.contains("list-admin@slock.test"))
            #expect(!serialized.contains("list-other@slock.test"))
        }
    }
}
