import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func machineWorkspacesAreScopedToTheServerAndItsAgents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111648"
    let memberId = "11111111-1111-4111-8111-111111111649"
    let serverId = "33333333-3333-4333-8333-333333333679"
    let otherServerId = "33333333-3333-4333-8333-333333333680"
    for (id, email) in [
        (ownerId, "workspace-owner@slock.test"),
        (memberId, "workspace-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "workspaces", name: "Workspaces", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "workspaces-other", name: "Workspaces Other", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "workspace-machine")
    let otherMachine = accounts.registerMachine(serverId: otherServerId, userId: ownerId, name: "other-machine")

    let live = accounts.oauth.createAgent(serverId: serverId, name: "a-live")
    accounts.addServerAgent(serverId: serverId, id: live, name: "a-live", avatarUrl: nil, status: "active")
    accounts.setAgentMachineForTesting(agentId: live, machineId: machine)
    let deleted = accounts.oauth.createAgent(serverId: serverId, name: "a-gone")
    accounts.addServerAgent(serverId: serverId, id: deleted, name: "a-gone", avatarUrl: nil, status: "inactive")
    accounts.setAgentMachineForTesting(agentId: deleted, machineId: machine)
    accounts.oauth.deleteAgent(id: deleted)
    let other = accounts.oauth.createAgent(serverId: otherServerId, name: "b-live")
    accounts.addServerAgent(serverId: otherServerId, id: other, name: "b-live", avatarUrl: nil, status: "active")
    accounts.setAgentMachineForTesting(agentId: other, machineId: otherMachine)

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
            func workspaces(_ bearer: String, _ machineId: String = machine) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                return try await client.get("/api/servers/\(serverId)/machines/\(machineId)/workspaces", headers: headers)
            }
            let owner = try await token("workspace-owner@slock.test")
            let member = try await token("workspace-member@slock.test")

            #expect(try await workspaces(member).status == .forbidden)
            let response = try await workspaces(owner)
            #expect(response.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.count == 2)
            #expect(Set(rows.compactMap { $0["directoryName"] as? String }) == Set([live, deleted]))
            #expect(rows.first { $0["directoryName"] as? String == live }?["status"] as? String == "active")
            #expect(rows.first { $0["directoryName"] as? String == deleted }?["status"] as? String == "deleted")
            #expect(rows.first { $0["directoryName"] as? String == deleted }?["agentName"] as? String == "a-gone")
            #expect(!rows.contains { $0["directoryName"] as? String == other })
            #expect(try await workspaces(owner, otherMachine).status == .notFound)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(owner)"
            let foreignDelete = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)/machines/\(machine)/workspaces/\(other)")
            #expect(foreignDelete.status == .notFound)
            let ownDelete = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)/machines/\(machine)/workspaces/\(deleted)")
            #expect(ownDelete.status == .ok)
            let after = try await workspaces(owner)
            let afterRows = try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(afterRows.compactMap { $0["directoryName"] as? String } == [live])
        }
    }
}
