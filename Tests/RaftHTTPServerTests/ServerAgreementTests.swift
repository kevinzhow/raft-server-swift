import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agreementEditsCreateNewActiveVersionsAndCapTheBody() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111307"
    let adminId = "11111111-1111-4111-8111-111111111308"
    let memberId = "11111111-1111-4111-8111-111111111309"
    let serverId = "33333333-3333-4333-8333-333333333482"
    for (id, email) in [
        (ownerId, "agreement-owner@slock.test"),
        (adminId, "agreement-admin@slock.test"),
        (memberId, "agreement-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "agreement", name: "Agreement Server", ownerId: ownerId)
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
            let ownerToken = try await login("agreement-owner@slock.test")
            let adminToken = try await login("agreement-admin@slock.test")
            let memberToken = try await login("agreement-member@slock.test")
            func put(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.put, headers: headers(token), to: "/api/servers/\(serverId)/agreement") { request in
                    request.body = .init(string: body)
                }
            }

            let denied = try await put(memberToken, "{\"enabled\":true,\"title\":\"Rules\",\"bodyMarkdown\":\"Be kind.\"}")
            #expect(denied.status == .forbidden)
            let deniedBody = try JSONSerialization.jsonObject(with: Data((denied.body.string ?? "").utf8)) as? [String: Any]
            #expect(deniedBody?["error"] as? String == "Only server owners and admins can manage the pre-join agreement")

            let first = try await put(adminToken, "{\"enabled\":true,\"title\":\"Rules v1\",\"bodyMarkdown\":\"Be kind.\"}")
            #expect(first.status == .ok)
            let firstBody = try JSONSerialization.jsonObject(with: Data((first.body.string ?? "").utf8)) as? [String: Any]
            let firstAgreement = firstBody?["agreement"] as? [String: Any]
            let firstId = firstAgreement?["id"] as? String ?? ""
            #expect(firstAgreement?["version"] as? Int == 1)

            let read = try await client.send(.get, headers: headers(adminToken), to: "/api/servers/\(serverId)/agreement")
            #expect(read.status == .ok)
            let readBody = try JSONSerialization.jsonObject(with: Data((read.body.string ?? "").utf8)) as? [String: Any]
            #expect((readBody?["agreement"] as? [String: Any])?["id"] as? String == firstId)

            let second = try await put(ownerToken, "{\"enabled\":true,\"title\":\"Rules v2\",\"bodyMarkdown\":\"Be kind.\\nNo spam.\"}")
            #expect(second.status == .ok)
            let secondBody = try JSONSerialization.jsonObject(with: Data((second.body.string ?? "").utf8)) as? [String: Any]
            let secondAgreement = secondBody?["agreement"] as? [String: Any]
            #expect(secondAgreement?["version"] as? Int == 2)
            #expect(secondAgreement?["id"] as? String != firstId)
            #expect(accounts.oauth.serverAgreementVersions(serverId: serverId).filter { $0.enabled }.count == 1)

            let longBody = String(repeating: "A", count: 5000)
            let accepted = try await put(ownerToken, "{\"enabled\":true,\"title\":\"Rules\",\"bodyMarkdown\":\"\(longBody)\"}")
            #expect(accepted.status == .ok)
            let over = String(repeating: "A", count: 5001)
            let rejected = try await put(ownerToken, "{\"enabled\":true,\"title\":\"Rules\",\"bodyMarkdown\":\"\(over)\"}")
            #expect(rejected.status == .badRequest)
            let rejectedBody = try JSONSerialization.jsonObject(with: Data((rejected.body.string ?? "").utf8)) as? [String: Any]
            #expect(rejectedBody?["error"] as? String == "Agreement body must be 5000 characters or fewer")
        }
    }
}
