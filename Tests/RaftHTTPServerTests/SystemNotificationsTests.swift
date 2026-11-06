import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func systemNotificationFeedUsesViewMachinesAndExcludesComputers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111636"
    let adminId = "11111111-1111-4111-8111-111111111637"
    let memberId = "11111111-1111-4111-8111-111111111638"
    let guestId = "11111111-1111-4111-8111-111111111639"
    let outsiderId = "11111111-1111-4111-8111-111111111640"
    let serverId = "33333333-3333-4333-8333-333333333675"
    for (id, email, role) in [
        (ownerId, "notify-owner@slock.test", "owner"),
        (adminId, "notify-admin@slock.test", "admin"),
        (memberId, "notify-member@slock.test", "member"),
        (guestId, "notify-guest@slock.test", "guest"),
        (outsiderId, "notify-outsider@slock.test", nil),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if let role {
            if role == "owner" {
                accounts.oauth.addOwnedServer(id: serverId, slug: "notify", name: "Notify", ownerId: id)
            } else {
                accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
            }
        }
    }
    let offline = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Offline Daemon")
    let online = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Online Daemon")
    accounts.setMachineOnline(machineId: online, online: true)
    let computer = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Managed Computer")
    accounts.linkComputerForTesting(serverId: serverId, machineId: computer)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "active-offline-agent")
    accounts.addServerAgent(serverId: serverId, id: agent, name: "active-offline-agent", avatarUrl: nil, status: "active")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: offline)

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
            func feed(_ bearer: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                return try await client.get("/api/servers/\(serverId)/system-notifications", headers: headers)
            }

            let owner = try await token("notify-owner@slock.test")
            let admin = try await token("notify-admin@slock.test")
            let member = try await token("notify-member@slock.test")
            let guest = try await token("notify-guest@slock.test")
            let outsider = try await token("notify-outsider@slock.test")

            for bearer in [owner, admin, member] {
                let response = try await feed(bearer)
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                #expect(body?["contractVersion"] as? String == "server-system-notifications-v1")
                #expect(body?["snapshotMode"] as? String == "replace")
                let notifications = body?["notifications"] as? [[String: Any]] ?? []
                #expect(notifications.count == 1)
                #expect(notifications.first?["id"] as? String == "machine-offline:\(offline)")
                #expect(notifications.first?["type"] as? String == "machine.offline")
                #expect(notifications.first?["kind"] as? String == "error")
                let payload = notifications.first?["payload"] as? [String: Any]
                #expect(payload?["activeAgentCount"] as? Int == 1)
                #expect((notifications.first?["action"] as? [String: Any])?["targetId"] as? String == offline)
                #expect(notifications.first?["id"] as? String != "machine-offline:\(computer)")
                #expect(notifications.first?["id"] as? String != "machine-offline:\(online)")
            }

            let guestResponse = try await feed(guest)
            #expect(guestResponse.status == .ok)
            let guestBody = try JSONSerialization.jsonObject(with: Data((guestResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect((guestBody?["notifications"] as? [[String: Any]] ?? []).isEmpty)
            #expect(try await feed(outsider).status == .forbidden)

            accounts.setAgentStatusForTesting(agentId: agent, status: "inactive")
            let idle = try await feed(owner)
            let idleBody = try JSONSerialization.jsonObject(with: Data((idle.body.string ?? "").utf8)) as? [String: Any]
            let idleNotification = (idleBody?["notifications"] as? [[String: Any]] ?? []).first
            #expect(idleNotification?["kind"] as? String == "warning")
            #expect((idleNotification?["payload"] as? [String: Any])?["activeAgentCount"] as? Int == 0)
        }
    }
}
