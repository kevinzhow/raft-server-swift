import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func usageLimitAttentionSyncsSeenAndDismissPerRecipient() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111641"
    let adminId = "11111111-1111-4111-8111-111111111642"
    let memberId = "11111111-1111-4111-8111-111111111643"
    let serverId = "33333333-3333-4333-8333-333333333676"
    let otherServerId = "33333333-3333-4333-8333-333333333677"
    for (id, email, role) in [
        (ownerId, "attention-owner@slock.test", "owner"),
        (adminId, "attention-admin@slock.test", "admin"),
        (memberId, "attention-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "attention", name: "Attention", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "attention-other", name: "Attention Other", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Cindy MacBook")
    let otherMachine = accounts.registerMachine(serverId: otherServerId, userId: ownerId, name: "Other Machine")
    accounts.enableUsageLimitAttentionForServer(serverId)
    accounts.enableUsageLimitAttentionForServer(otherServerId)
    let first = accounts.addSystemAttentionIncidentForTesting(
        serverId: serverId,
        machineId: machine,
        affectedAgentIds: ["agent-a", "agent-b"],
        activatedAt: Date(timeIntervalSince1970: 1_760_169_600)
    )
    let other = accounts.addSystemAttentionIncidentForTesting(
        serverId: otherServerId,
        machineId: otherMachine,
        affectedAgentIds: []
    )

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
            let owner = try await token("attention-owner@slock.test")
            let admin = try await token("attention-admin@slock.test")
            let member = try await token("attention-member@slock.test")

            func request(_ method: HTTPRequest.Method, _ path: String, _ bearer: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                return try await client.send(method, headers: headers, to: URI(string: path))
            }
            func feed(_ bearer: String) async throws -> [String: Any] {
                let response = try await request(.get, "/api/servers/\(serverId)/system-notifications-v2", bearer)
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let initial = try await feed(owner)
            #expect(initial["contractVersion"] as? String == "server-system-attention-v1")
            #expect(initial["snapshotMode"] as? String == "replace")
            #expect(initial["unseenCount"] as? Int == 1)
            let notifications = initial["notifications"] as? [[String: Any]] ?? []
            #expect(notifications.count == 1)
            #expect(notifications.first?["id"] as? String == first)
            #expect(notifications.first?["kind"] as? String == "usage_limit_reached")
            #expect(notifications.first?["severity"] as? String == "warning")
            #expect((notifications.first?["machine"] as? [String: Any])?["name"] as? String == "Cindy MacBook")
            #expect((notifications.first?["affectedAgentIds"] as? [String])?.count == 2)
            #expect(try await feed(admin)["unseenCount"] as? Int == 1)
            #expect((try await feed(member)["notifications"] as? [[String: Any]] ?? []).isEmpty)

            #expect(try await request(.post, "/api/servers/\(serverId)/system-notifications-v2/not-a-uuid/seen", owner).status == .badRequest)
            #expect(try await request(.post, "/api/servers/\(serverId)/system-notifications-v2/\(other)/seen", owner).status == .notFound)
            #expect(try await request(.post, "/api/servers/\(serverId)/system-notifications-v2/\(first)/seen", member).status == .notFound)

            accounts.disableUsageLimitAttentionForServer(serverId)
            #expect((try await feed(owner)["notifications"] as? [[String: Any]] ?? []).isEmpty)
            #expect(try await request(.post, "/api/servers/\(serverId)/system-notifications-v2/\(first)/seen", owner).status == .notFound)
            accounts.enableUsageLimitAttentionForServer(serverId)

            #expect(try await request(.post, "/api/servers/\(serverId)/system-notifications-v2/\(first)/seen", owner).status == .ok)
            #expect(try await feed(owner)["unseenCount"] as? Int == 0)
            #expect(try await feed(admin)["unseenCount"] as? Int == 1)
            #expect(try await request(.post, "/api/servers/\(serverId)/system-notifications-v2/\(first)/dismiss", owner).status == .ok)
            #expect((try await feed(owner)["notifications"] as? [[String: Any]] ?? []).isEmpty)
            #expect((try await feed(admin)["notifications"] as? [[String: Any]] ?? []).count == 1)

            let second = accounts.addSystemAttentionIncidentForTesting(
                serverId: serverId,
                machineId: machine,
                affectedAgentIds: ["agent-c"],
                activatedAt: Date(timeIntervalSince1970: 1_760_173_200)
            )
            let reactivated = try await feed(owner)
            #expect(reactivated["unseenCount"] as? Int == 1)
            #expect((reactivated["notifications"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } == [second])
            _ = other
        }
    }
}
