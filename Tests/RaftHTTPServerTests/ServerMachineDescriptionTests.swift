import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct MachineDescriptionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let otherServerId: String
    let ownerId: String
    let ownerEmail: String
    let adminEmail: String
    let memberId: String
    let memberEmail: String
}

private func makeMachineDescriptionFixture(suffix: String) -> MachineDescriptionFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 800_000 + number)
    let otherServerId = String(format: "33333333-3333-4333-8333-%012d", 810_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 700_000 + number)
    let adminId = String(format: "11111111-1111-4111-8111-%012d", 710_000 + number)
    let memberId = String(format: "11111111-1111-4111-8111-%012d", 720_000 + number)
    let ownerEmail = "machine-owner-\(suffix)@slock.test"
    let adminEmail = "machine-admin-\(suffix)@slock.test"
    let memberEmail = "machine-member-\(suffix)@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (adminId, adminEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-desc-\(suffix)", name: "Machine Description", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "machine-other-\(suffix)", name: "Other Machine", ownerId: ownerId)
    return MachineDescriptionFixture(
        accounts: accounts,
        serverId: serverId,
        otherServerId: otherServerId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        adminEmail: adminEmail,
        memberId: memberId,
        memberEmail: memberEmail
    )
}

private func machineLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func machineHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func machineObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func machineDescriptionUpdatesAreTrimmedProjectedAndPermissionGated() async throws {
    let fixture = makeMachineDescriptionFixture(suffix: "911")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await machineLogin(client, email: fixture.ownerEmail)
            let admin = try await machineLogin(client, email: fixture.adminEmail)
            let member = try await machineLogin(client, email: fixture.memberEmail)
            let ownerHeaders = machineHeaders(owner, fixture.serverId)

            let created = try await client.send(.post, headers: ownerHeaders, to: "/api/servers/\(fixture.serverId)/machines") { request in
                request.body = .init(string: "{\"name\":\"described-machine\"}")
            }
            #expect(created.status == .ok)
            let createdBody = try machineObject(created)
            let machineId = try #require((createdBody["machine"] as? [String: Any])?["id"] as? String)

            func patch(_ token: String, _ serverId: String, machineId: String, description: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: machineHeaders(token, serverId), to: "/api/servers/\(serverId)/machines/\(machineId)") { request in
                    request.body = .init(string: "{\"description\":\"\(description)\"}")
                }
            }

            let updated = try await patch(owner, fixture.serverId, machineId: machineId, description: "  Runs the staging smoke tests  ")
            #expect(updated.status == .ok)
            let updatedBody = try machineObject(updated)
            #expect(updatedBody["name"] as? String == "described-machine")
            #expect(updatedBody["description"] as? String == "Runs the staging smoke tests")

            let list = try await client.get("/api/servers/\(fixture.serverId)/machines", headers: ownerHeaders)
            #expect(list.status == .ok)
            let rows = try machineObject(list)["machines"] as? [[String: Any]] ?? []
            #expect(rows.first { $0["id"] as? String == machineId }?["description"] as? String == "Runs the staging smoke tests")

            let cleared = try await patch(owner, fixture.serverId, machineId: machineId, description: "   ")
            #expect(cleared.status == .ok)
            #expect(try machineObject(cleared)["description"] is NSNull)

            let adminUpdated = try await patch(admin, fixture.serverId, machineId: machineId, description: "admin edit")
            #expect(adminUpdated.status == .ok)
            #expect(try machineObject(adminUpdated)["description"] as? String == "admin edit")

            let denied = try await patch(member, fixture.serverId, machineId: machineId, description: "member edit")
            #expect(denied.status == .forbidden)
            #expect(try machineObject(denied)["error"] as? String == "Forbidden")

            let crossServer = try await patch(owner, fixture.otherServerId, machineId: machineId, description: "cross server")
            #expect(crossServer.status == .notFound)

            let otherList = try await client.get("/api/servers/\(fixture.otherServerId)/machines", headers: machineHeaders(owner, fixture.otherServerId))
            #expect(otherList.status == .ok)
            #expect((try machineObject(otherList)["machines"] as? [[String: Any]] ?? []).isEmpty)

            let memberOwned = fixture.accounts.registerMachine(serverId: fixture.serverId, userId: fixture.memberId, name: "member-owned")
            let memberUpdated = try await patch(member, fixture.serverId, machineId: memberOwned, description: "builder keeps its own machine")
            #expect(memberUpdated.status == .ok)
            #expect(try machineObject(memberUpdated)["description"] as? String == "builder keeps its own machine")
        }
    }
}
