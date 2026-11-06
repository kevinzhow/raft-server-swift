import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AttachFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001096001"
    let ownerId = "11111111-1111-4111-8111-000001096001"
    let strangerId = "11111111-1111-4111-8111-000001096002"
    let slug = "attach-co"

    init() {
        for (id, email) in [(ownerId, "attach-owner"), (strangerId, "attach-stranger")] {
            accounts.addAccount(id: id, email: "\(email)@attach.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Attach Co", ownerId: ownerId)
    }

    func headers(_ userId: String? = nil) -> HTTPFields {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        if let userId { headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))" }
        return headers
    }

    func attach(_ client: any Client, userId: String?, body: String) async throws -> ClientResponse {
        try await client.send(.post, headers: headers(userId), to: URI(string: "/api/computer/attach")) { request in
            request.body = .init(string: body)
        }
    }
}

private func statusBody(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func computerAttachGateAuthSlugAndCloak() async throws {
    let fixture = AttachFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            fixture.accounts.setComputerAttachEnabledForTesting(false)
            let gated = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverSlug\":\"\(fixture.slug)\"}")
            #expect(gated.status == .notFound)
            fixture.accounts.setComputerAttachEnabledForTesting(nil)

            let defaultOn = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverSlug\":\"missing-slug\"}")
            #expect(defaultOn.status == .forbidden)

            let unauthenticated = try await fixture.attach(client, userId: nil, body: "{\"serverSlug\":\"\(fixture.slug)\"}")
            #expect(unauthenticated.status == .unauthorized)

            let legacyBody = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverId\":\"\(fixture.serverId)\",\"name\":\"raft-computer\"}")
            #expect(legacyBody.status == .badRequest)
            #expect(statusBody(legacyBody)["code"] as? String == "server_slug_required")

            let nonMember = try await fixture.attach(client, userId: fixture.strangerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"raft-computer\"}")
            #expect(nonMember.status == .forbidden)
            #expect(statusBody(nonMember)["code"] as? String == "not_authorized")
            let ghost = try await fixture.attach(client, userId: fixture.strangerId, body: "{\"serverSlug\":\"ghost-slug\",\"name\":\"raft-computer\"}")
            #expect(ghost.status == .forbidden)
            #expect(statusBody(ghost)["code"] as? String == "not_authorized")

            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.strangerId, role: "member")
            let plainMember = try await fixture.attach(client, userId: fixture.strangerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"member-box\"}")
            #expect(plainMember.status == .forbidden)
            #expect(statusBody(plainMember)["code"] as? String == "requires_admin")
            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.strangerId, role: "admin")
            let admin = try await fixture.attach(client, userId: fixture.strangerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"admin-box\"}")
            #expect(admin.status == .created)

            let byUUID = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverSlug\":\"\(fixture.serverId)\",\"name\":\"uuid-box\"}")
            #expect(byUUID.status == .forbidden)
            #expect(statusBody(byUUID)["code"] as? String == "not_authorized")
        }
    }
}

@Test func computerAttachIssuesScopedKeysCollidesAndLinksMachine() async throws {
    let fixture = AttachFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let first = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"raft-computer\"}")
            #expect(first.status == .created)
            let firstBody = statusBody(first)
            let apiKey = try #require(firstBody["apiKey"] as? String)
            #expect(apiKey.hasPrefix("sk_computer_"))
            let serverMachineId = try #require(firstBody["serverMachineId"] as? String)
            #expect(firstBody["serverId"] as? String == fixture.serverId)
            #expect(firstBody["serverSlug"] as? String == fixture.slug)
            #expect(firstBody["resumed"] as? Bool == false)
            let computers = fixture.accounts.computersForTesting(serverId: fixture.serverId)
            #expect(computers.count == 1)
            #expect(computers[0].id == serverMachineId)
            #expect(computers[0].machineId.isEmpty == false)
            #expect(fixture.accounts.machineExistsForTesting(machineId: computers[0].machineId))

            let second = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"raft-computer\"}")
            #expect(second.status == .conflict)
            #expect(statusBody(second)["code"] as? String == "COMPUTER_NAME_COLLISION")
            let after = fixture.accounts.computersForTesting(serverId: fixture.serverId)
            #expect(after.count == 1)
            #expect(after[0].machineId == computers[0].machineId)
        }
    }
}

@Test func computerAttachNameScopeIsPerUserAndRevokeSurfaceIsUnregistered() async throws {
    let fixture = AttachFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let ownerFirst = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"Build-Mac\"}")
            #expect(ownerFirst.status == .created)
            let ownerMachine = statusBody(ownerFirst)["serverMachineId"] as? String

            fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: fixture.strangerId, role: "admin")
            let crossUser = try await fixture.attach(client, userId: fixture.strangerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"Build-Mac\"}")
            #expect(crossUser.status == .created)
            #expect(statusBody(crossUser)["resumed"] as? Bool == false)
            #expect((statusBody(crossUser)["serverMachineId"] as? String) != ownerMachine)

            let attached = try await fixture.attach(client, userId: fixture.ownerId, body: "{\"serverSlug\":\"\(fixture.slug)\",\"name\":\"Revoke-Mac\"}")
            let attachedBody = statusBody(attached)
            let apiKey = try #require(attachedBody["apiKey"] as? String)
            let machineId = try #require(attachedBody["serverMachineId"] as? String)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(apiKey)"
            headers[.contentType] = "application/json"
            let revoke = try await client.send(.post, headers: headers, to: URI(string: "/internal/computer/attachment/revoke")) { request in
                request.body = .init(string: "{\"serverMachineId\":\"\(machineId)\"}")
            }
            #expect(revoke.status == .unauthorized)
            #expect(statusBody(revoke)["code"] as? String == "auth_policy_unregistered_path")
            #expect(fixture.accounts.computersForTesting(serverId: fixture.serverId).first { $0.id == machineId }?.revoked == false)
        }
    }
}
