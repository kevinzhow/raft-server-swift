import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentWorkspaceFilesRequireAdminAndSameServer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111572"
    let memberId = "11111111-1111-4111-8111-111111111573"
    let closedId = "11111111-1111-4111-8111-111111111574"
    let serverId = "33333333-3333-4333-8333-333333333636"
    let otherServerId = "33333333-3333-4333-8333-333333333637"
    for (id, email) in [
        (ownerId, "workspace-owner@slock.test"),
        (memberId, "workspace-member@slock.test"),
        (closedId, "workspace-closed@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "workspace", name: "Workspace", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "workspace-other", name: "Workspace Other", ownerId: closedId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "workspace-agent")

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
            func headers(_ token: String, _ server: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = server
                return fields
            }
            let ownerToken = try await login("workspace-owner@slock.test")
            let memberToken = try await login("workspace-member@slock.test")
            let closedToken = try await login("workspace-closed@slock.test")
            // Node agents.ts returns 409 machine_unassigned before any RPC for
            // this real unassigned fixture. Accepted owner/creator/admin workspace
            // replies are asserted by postgresPublishedInventoryAndMachineQueries.
            let unassigned = try await client.send(.get, headers: headers(ownerToken, serverId), to: "/api/agents/\(agent)/workspace-files")
            #expect(unassigned.status == .conflict)
            let body = try JSONSerialization.jsonObject(with: Data((unassigned.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "machine_unassigned")
            #expect(try await client.send(.get, headers: headers(memberToken, serverId), to: "/api/agents/\(agent)/workspace-files").status == .forbidden)
            #expect(try await client.send(.get, headers: headers(memberToken, serverId), to: "/api/agents/\(agent)/workspace-files/read?path=MEMORY.md").status == .forbidden)
            #expect(try await client.send(.get, headers: headers(closedToken, otherServerId), to: "/api/agents/\(agent)/workspace-files").status == .notFound)
        }
    }
}
