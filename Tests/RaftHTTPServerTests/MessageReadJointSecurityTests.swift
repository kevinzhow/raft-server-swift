import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

// Supplemental joint-projection acceptance; the initial four read-family
// regressions were frozen before Source authoring in tests-first.patch.
@Test func jointMessageReadsRequireAnActiveLocalProjectionAndDenyRegisteredGuests() async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased(), guest = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased(), storageServer = UUID().uuidString.lowercased()
    for (id, email) in [(owner, "joint-read-owner@example.test"), (guest, "joint-read-guest@example.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: server, slug: "joint-read-local", name: "Local", ownerId: owner)
    accounts.oauth.addOwnedServer(id: storageServer, slug: "joint-read-storage", name: "Storage", ownerId: owner)
    accounts.oauth.addMember(serverId: server, userId: guest, role: "guest")
    accounts.createFeatureFlagForTesting(key: "server_guest_v0")
    accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [server])
    let local = accounts.oauth.createChannel(serverId: server, name: "joint-local", creatorUserId: owner, type: "joint")
    let canonical = accounts.oauth.createChannel(serverId: storageServer, name: "joint-storage", creatorUserId: owner)
    accounts.addPostableChannel(serverId: server, channelId: local, memberId: owner, kind: "joint", name: "joint-local")
    accounts.addPostableChannel(serverId: storageServer, channelId: canonical, memberId: owner, name: "joint-storage")
    accounts.oauth.addChannelHuman(channelId: local, userId: owner)
    accounts.oauth.addChannelHuman(channelId: local, userId: guest)
    accounts.setChannelGuestVisibleForTesting(channelId: local, visible: true)
    accounts.addJointChannelProjection(localChannelId: local, canonicalChannelId: canonical, serverId: server)
    let message = accounts.addHumanMessageForTesting(channelId: canonical, senderId: owner, content: "joint-private-read-sentinel")
    func headers(_ user: String) -> HTTPFields {
        var headers = HTTPFields(); headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: user))"
        headers[HTTPField.Name("X-Server-Id")!] = server
        return headers
    }
    let paths = ["/api/messages/channel/\(local)", "/api/messages/sync?channel_id=\(local)",
                 "/api/messages/context/\(message)?channelId=\(local)", "/api/messages/search?q=joint-private&channelId=\(local)"]
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            for path in paths {
                let permitted = try await client.get(URI(string: path), headers: headers(owner))
                #expect(permitted.status == .ok)
                // Scoped search must still filter by its requested local scope;
                // canonical storage never grants a different server's authority.
                if !path.contains("search") { #expect((permitted.body.string ?? "").contains("joint-private-read-sentinel")) }
                let denied = try await client.get(URI(string: path), headers: headers(guest))
                #expect(denied.status == .notFound)
                #expect(!(denied.body.string ?? "").contains("joint-private-read-sentinel"))
            }
            accounts.setJointProjectionStatusForTesting(localChannelId: local, serverId: server, status: "inactive")
            for path in paths {
                let denied = try await client.get(URI(string: path), headers: headers(owner))
                #expect(denied.status == .notFound)
                #expect(!(denied.body.string ?? "").contains("joint-private-read-sentinel"))
            }
        }
    }
}
