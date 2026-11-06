import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func archivedNameCollisionProjectsTargetRestoreCapability() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111652"
    let adminId = "11111111-1111-4111-8111-111111111653"
    let ordinaryId = "11111111-1111-4111-8111-111111111654"
    let serverId = "33333333-3333-4333-8333-333333333692"
    for (id, email) in [(ownerId, "collision-owner"), (adminId, "collision-admin"), (ordinaryId, "collision-ordinary")] {
        accounts.addAccount(id: id, email: "\(email)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "collision", name: "Collision", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: ordinaryId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "restore-me", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "restore-me")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: adminId)
    accounts.setChannelHumanRoleForTesting(channelId: channelId, userId: adminId, role: "admin")
    accounts.archiveChannel(channelId: channelId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func collide(_ userId: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                let token = accounts.mintAccessTokenForTesting(userId: userId)
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                let response = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                    request.body = .init(string: "{\"name\":\"restore-me\",\"visibility\":\"public\"}")
                }
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let allowed = try await collide(adminId)
            #expect(allowed.0 == .conflict)
            #expect(allowed.1["canUnarchiveArchivedChannel"] as? Bool == true)

            let denied = try await collide(ordinaryId)
            #expect(denied.0 == .conflict)
            #expect(denied.1["canUnarchiveArchivedChannel"] as? Bool == false)

            accounts.setChannelHumanRoleForTesting(channelId: channelId, userId: adminId, role: "member")
            let stale = try await collide(adminId)
            #expect(stale.0 == .conflict)
            #expect(stale.1["canUnarchiveArchivedChannel"] as? Bool == false)
        }
    }
}
