import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentPrivateSurfacesAllowCreatorAndAdminsOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111575"
    let creatorId = "11111111-1111-4111-8111-111111111576"
    let adminId = "11111111-1111-4111-8111-111111111577"
    let viewerId = "11111111-1111-4111-8111-111111111578"
    let serverId = "33333333-3333-4333-8333-333333333638"
    for (id, email) in [
        (ownerId, "private-surface-owner@slock.test"),
        (creatorId, "private-surface-creator@slock.test"),
        (adminId, "private-surface-admin@slock.test"),
        (viewerId, "private-surface-viewer@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "private-surface", name: "Private Surface", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: creatorId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: viewerId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "private-surface-agent", creatorUserId: creatorId)

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
            let ownerToken = try await login("private-surface-owner@slock.test")
            let creatorToken = try await login("private-surface-creator@slock.test")
            let adminToken = try await login("private-surface-admin@slock.test")
            let viewerToken = try await login("private-surface-viewer@slock.test")
            let routes = [
                "/api/agents/\(agent)/activity",
                "/api/agents/\(agent)/activity-log",
                "/api/agents/\(agent)/activity-summaries",
                "/api/agents/\(agent)/workspace-files",
                "/api/agents/\(agent)/skills",
                "/api/agents/\(agent)/agent-dms",
                "/api/agents/\(agent)/channels",
            ]
            for route in routes {
                let uri = URI(string: route)
                #expect(try await client.send(.get, headers: headers(viewerToken), to: uri).status == .forbidden)
                for token in [creatorToken, adminToken, ownerToken] {
                    let response = try await client.send(.get, headers: headers(token), to: uri)
                    if route.hasSuffix("/workspace-files") {
                        // Node agents.ts rejects an unassigned workspace with 409.
                        // This is authority-before-refusal coverage; accepted owner,
                        // creator and admin RPC reads live in the real PG/NIO scene
                        // postgresPublishedInventoryAndMachineQueries.
                        #expect(response.status == .conflict)
                        let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                        #expect(body?["code"] as? String == "machine_unassigned")
                    } else {
                        let status = response.status.code
                        #expect(status == 200 || status == 503)
                    }
                }
            }
        }
    }
}
