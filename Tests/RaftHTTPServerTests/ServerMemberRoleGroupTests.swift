import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct MemberRoleFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let secondOwnerId: String
    let adminId: String
    let memberId: String
    let tokens: [String: String]
}

private func makeMemberRoleFixture(suffix: String) async throws -> MemberRoleFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 160_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 160_000 + number)
    let secondOwnerId = String(format: "11111111-1111-4111-8111-%012d", 170_000 + number)
    let adminId = String(format: "11111111-1111-4111-8111-%012d", 180_000 + number)
    let memberId = String(format: "11111111-1111-4111-8111-%012d", 190_000 + number)
    let users: [(String, String, String)] = [
        (ownerId, "role-owner-\(suffix)@slock.test", "owner"),
        (secondOwnerId, "role-second-\(suffix)@slock.test", "owner"),
        (adminId, "role-admin-\(suffix)@slock.test", "admin"),
        (memberId, "role-member-\(suffix)@slock.test", "member"),
    ]
    for (id, email, role) in users {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" && id == ownerId {
            accounts.oauth.addOwnedServer(id: serverId, slug: "role-\(suffix)", name: "Role Server", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    return MemberRoleFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        secondOwnerId: secondOwnerId,
        adminId: adminId,
        memberId: memberId,
        tokens: [:]
    )
}

private func roleLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func roleHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var fields = HTTPFields()
    fields[.authorization] = "Bearer \(token)"
    fields[.contentType] = "application/json"
    fields[HTTPField.Name("X-Server-Id")!] = serverId
    return fields
}

@Test func serverMemberRoleGroupPreservesOwnersAndGatesAdminChanges() async throws {
    let fixture = try await makeMemberRoleFixture(suffix: "821")
    let events = MemberGroupEvents()
    fixture.accounts.realtimeRelay.install { room, event, payload in
        events.append(room: room, event: event, payload: payload)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await roleLogin(client, email: "role-owner-821@slock.test")
            let admin = try await roleLogin(client, email: "role-admin-821@slock.test")
            func patch(_ token: String, _ target: String, _ role: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: roleHeaders(token, fixture.serverId), to: "/api/servers/\(fixture.serverId)/members/\(target)") { request in
                    request.body = .init(string: "{\"role\":\"\(role)\"}")
                }
            }
            func remove(_ token: String, _ target: String) async throws -> ClientResponse {
                try await client.send(.delete, headers: roleHeaders(token, fixture.serverId), to: "/api/servers/\(fixture.serverId)/members/\(target)")
            }
            func leave(_ token: String) async throws -> ClientResponse {
                try await client.send(.post, headers: roleHeaders(token, fixture.serverId), to: "/api/servers/\(fixture.serverId)/leave") { request in
                    request.body = .init(string: "{}")
                }
            }

            #expect(try await patch(admin, fixture.memberId, "owner").status == .forbidden)
            #expect(try await patch(owner, fixture.memberId, "owner").status == .ok)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.memberId) == "owner")
            #expect(events.events.last?.room == "server:\(fixture.serverId)")
            #expect(events.events.last?.event == "server:member-updated")
            let updatedPayload = events.events.last?.payload.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            #expect(updatedPayload?["userId"] as? String == fixture.memberId)
            #expect(updatedPayload?["previousRole"] as? String == "member")
            #expect(updatedPayload?["role"] as? String == "owner")
            #expect(try await patch(owner, fixture.memberId, "member").status == .ok)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.memberId) == "member")
            #expect(try await patch(owner, fixture.ownerId, "member").status == .badRequest)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.ownerId) == "owner")

            #expect(try await remove(admin, fixture.memberId).status == .ok)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.memberId) == nil)
            #expect(events.events.suffix(2).map(\.event) == ["server:member-removed", "server:membership-removed"])
            #expect(events.events[events.events.count - 2].room == "server:\(fixture.serverId)")
            #expect(events.events[events.events.count - 1].room == "user:\(fixture.memberId)")

            var profileHeaders = roleHeaders(owner, fixture.serverId)
            profileHeaders[.contentType] = "application/json"
            let profile = try await client.get(
                URI(string: "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)/profile"),
                headers: profileHeaders
            )
            #expect(profile.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((profile.body.string ?? "").utf8)) as? [String: Any])?["membershipStatus"] as? String == "removed")

            #expect(try await remove(admin, fixture.secondOwnerId).status == .forbidden)
            #expect(try await remove(owner, fixture.secondOwnerId).status == .ok)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.secondOwnerId) == nil)

            #expect(try await leave(owner).status == .badRequest)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.ownerId) == "owner")

            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.secondOwnerId, role: "owner")
            #expect(try await leave(owner).status == .ok)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.ownerId) == nil)
            #expect(fixture.accounts.oauth.memberRole(serverId: fixture.serverId, userId: fixture.secondOwnerId) == "owner")

            #expect(try await leave(admin).status == .ok)
            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.memberId, role: "member")
            #expect(try await leave(try await roleLogin(client, email: "role-member-821@slock.test")).status == .ok)
        }
    }
}


private final class MemberGroupEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []

    func append(room: String, event: String, payload: String?) {
        lock.lock()
        storage.append((room, event, payload))
        lock.unlock()
    }

    var events: [(room: String, event: String, payload: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Test func serverMachineMutationsBroadcastMachineUpdated() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111112821"
    let serverId = "33333333-3333-4333-8333-333333335821"
    accounts.addAccount(id: ownerId, email: "machine-broadcast-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-broadcast", name: "Machine Broadcast", ownerId: ownerId)
    let events = MemberGroupEvents()
    accounts.realtimeRelay.install { room, event, payload in
        events.append(room: room, event: event, payload: payload)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await roleLogin(client, email: "machine-broadcast-owner@slock.test")
            let created = try await client.send(.post, headers: roleHeaders(owner, serverId), to: "/api/servers/\(serverId)/machines") { request in
                request.body = .init(string: "{\"name\":\"socket-machine\"}")
            }
            #expect(created.status == .ok)
            let body = (try? JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8))) as? [String: Any]
            let machineId = (body?["machine"] as? [String: Any])?["id"] as? String ?? ""
            #expect(!machineId.isEmpty)

            let renamed = try await client.send(.patch, headers: roleHeaders(owner, serverId), to: "/api/servers/\(serverId)/machines/\(machineId)") { request in
                request.body = .init(string: "{\"description\":\"renamed machine\"}")
            }
            #expect(renamed.status == .ok)
            let removed = try await client.send(.delete, headers: roleHeaders(owner, serverId), to: "/api/servers/\(serverId)/machines/\(machineId)")
            #expect(removed.status == .ok)

            #expect(events.events.map(\.room) == Array(repeating: "server:\(serverId)", count: 3))
            #expect(events.events.map(\.event) == Array(repeating: "machine:updated", count: 3))
            for event in events.events {
                let payload = event.payload.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                #expect(payload?["serverId"] as? String == serverId)
                #expect(payload?["machineId"] as? String == machineId)
            }
        }
    }
}
