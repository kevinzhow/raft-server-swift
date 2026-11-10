import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverSettingsAreOwnerAdminOnlyWhileSelfStateAndMachinesStayScoped() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111258"
    let adminId = "11111111-1111-4111-8111-111111111259"
    let memberId = "11111111-1111-4111-8111-111111111260"
    let guestId = "11111111-1111-4111-8111-111111111261"
    let serverId = "33333333-3333-4333-8333-333333333450"
    let emails = [
        ownerId: "rbac-owner@slock.test",
        adminId: "rbac-admin@slock.test",
        memberId: "rbac-member@slock.test",
        guestId: "rbac-guest@slock.test",
    ]
    for (id, email) in emails {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "rbac-settings", name: "RBAC Settings", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let guestMachine = accounts.registerMachine(serverId: serverId, userId: guestId, name: "Guest-owned machine")
    let ownerMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Owner-owned machine")

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
            let tokens: [String: String] = [
                "owner": try await login(emails[ownerId]!),
                "admin": try await login(emails[adminId]!),
                "member": try await login(emails[memberId]!),
                "guest": try await login(emails[guestId]!),
            ]

            for role in ["owner", "admin"] {
                let response = try await client.send(.get, headers: headers(tokens[role]!), to: "/api/servers/\(serverId)/settings")
                #expect(response.status == .ok)
            }
            for role in ["member", "guest"] {
                let settings = try await client.send(.get, headers: headers(tokens[role]!), to: "/api/servers/\(serverId)/settings")
                #expect(settings.status == .forbidden)
                let notifications = try await client.send(.get, headers: headers(tokens[role]!), to: "/api/servers/\(serverId)/notification-settings")
                #expect(notifications.status == .ok)
            }
            let onboarding = try await client.send(.get, headers: headers(tokens["member"]!), to: "/api/servers/\(serverId)/onboarding-settings")
            #expect(onboarding.status == .ok)

            for role in ["owner", "admin", "member"] {
                let response = try await client.send(.get, headers: headers(tokens[role]!), to: "/api/servers/\(serverId)/machines")
                #expect(response.status == .ok)
            }
            let guestList = try await client.send(.get, headers: headers(tokens["guest"]!), to: "/api/servers/\(serverId)/machines")
            #expect(guestList.status == .forbidden)

            let ownPatch = try await client.send(.patch, headers: headers(tokens["guest"]!), to: "/api/servers/\(serverId)/machines/\(guestMachine)") { request in
                request.body = .init(string: "{\"description\":\"still managed by its exact registrant\"}")
            }
            #expect(ownPatch.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((ownPatch.body.string ?? "").utf8)) as? [String: Any])?["description"] as? String == "still managed by its exact registrant")

            let foreignPatch = try await client.send(.patch, headers: headers(tokens["guest"]!), to: "/api/servers/\(serverId)/machines/\(ownerMachine)") { request in
                request.body = .init(string: "{\"description\":\"must not widen from one Machine to the collection\"}")
            }
            #expect(foreignPatch.status == .forbidden)
        }
    }
}
