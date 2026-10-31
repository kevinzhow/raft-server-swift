import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func externalDiagnosticsRefusesMembersAndManagedAgents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111617"
    let memberId = "11111111-1111-4111-8111-111111111618"
    let serverId = "33333333-3333-4333-8333-333333333663"
    accounts.addAccount(id: ownerId, email: "diagnostics-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "diagnostics-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "diagnostics", name: "Diagnostics", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let external = accounts.oauth.createAgent(serverId: serverId, name: "diag-external", creatorUserId: ownerId, runtime: "external")
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "diag-managed", creatorUserId: ownerId)
    let missing = UUID().uuidString.lowercased()

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
            let ownerToken = try await login("diagnostics-owner@slock.test")
            let memberToken = try await login("diagnostics-member@slock.test")
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/agents/\(external)/external-diagnostics").status == .forbidden)
            let managedResponse = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(managed)/external-diagnostics")
            #expect(managedResponse.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((managedResponse.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "agent_not_external")
            #expect(try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(missing)/external-diagnostics").status == .notFound)
            #expect(try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(external)/external-diagnostics").status == .ok)
        }
    }
}
