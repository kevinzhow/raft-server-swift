import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentMigrationStatusIsPrivateToCreatorAndAdmins() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111614"
    let memberId = "11111111-1111-4111-8111-111111111615"
    let serverId = "33333333-3333-4333-8333-333333333661"
    accounts.addAccount(id: ownerId, email: "migration-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "migration-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "migration", name: "Migration", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "migration-agent", creatorUserId: ownerId)

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
            let ownerToken = try await login("migration-owner@slock.test")
            let memberToken = try await login("migration-member@slock.test")
            let ownerStatus = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(agent)/migration")
            #expect(ownerStatus.status == .ok)
            let ownerBody = try JSONSerialization.jsonObject(with: Data((ownerStatus.body.string ?? "").utf8)) as? [String: Any]
            #expect(ownerBody?["migration"] == nil || ownerBody?["migration"] is NSNull)
            let memberStatus = try await client.send(.get, headers: headers(memberToken), to: "/api/agents/\(agent)/migration")
            #expect(memberStatus.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((memberStatus.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "not_supported")
        }
    }
}
