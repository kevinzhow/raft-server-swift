import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverMemberListGuardsTheHeaderAndHidesOtherEmails() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111484"
    let memberId = "11111111-1111-4111-8111-111111111485"
    let outsiderId = "11111111-1111-4111-8111-111111111486"
    let serverId = "33333333-3333-4333-8333-333333333587"
    for (id, email) in [
        (ownerId, "members-owner@slock.test"),
        (memberId, "members-member@slock.test"),
        (outsiderId, "members-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "members-visibility", name: "Members Visibility", ownerId: ownerId)
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
            func headers(_ token: String, server: String? = serverId) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                if let server { fields[HTTPField.Name("X-Server-Id")!] = server }
                return fields
            }
            let ownerToken = try await login("members-owner@slock.test")
            let memberToken = try await login("members-member@slock.test")
            let outsiderToken = try await login("members-outsider@slock.test")

            func rows(_ response: ClientResponse) throws -> [String: [String: Any]] {
                let list = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
                return Dictionary(uniqueKeysWithValues: list.compactMap { row -> (String, [String: Any])? in
                    guard let id = row["userId"] as? String else { return nil }
                    return (id, row)
                })
            }

            let ownerView = try await client.send(.get, headers: headers(ownerToken), to: "/api/servers/\(serverId)/members")
            #expect(ownerView.status == .ok)
            let ownerRows = try rows(ownerView)
            #expect(ownerRows[ownerId]?["email"] as? String == "members-owner@slock.test")
            #expect(ownerRows[memberId]?["email"] as? String == "members-member@slock.test")

            let memberView = try await client.send(.get, headers: headers(memberToken), to: "/api/servers/\(serverId)/members")
            #expect(memberView.status == .ok)
            let memberRows = try rows(memberView)
            #expect(memberRows[memberId]?["email"] as? String == "members-member@slock.test")
            #expect(memberRows[ownerId]?["email"] == nil || memberRows[ownerId]?["email"] is NSNull)

            #expect(try await client.send(.get, headers: headers(memberToken, server: nil), to: "/api/servers/\(serverId)/members").status == .badRequest)
            #expect(try await client.send(.get, headers: headers(memberToken, server: UUID().uuidString.lowercased()), to: "/api/servers/\(serverId)/members").status == .badRequest)
            #expect(try await client.send(.get, headers: headers(outsiderToken), to: "/api/servers/\(serverId)/members").status == .forbidden)
        }
    }
}
