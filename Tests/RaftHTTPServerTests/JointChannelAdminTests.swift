import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func jointChannelAdminMetadataRolesAndCapabilities() async throws {
    let accounts = EmailLoginDirectory()
    let hostServerId = "33333333-3333-4333-8333-000001114001"
    let peerServerId = "33333333-3333-4333-8333-000001114002"
    let hostOwner = "11111111-1111-4111-8111-000001114001"
    let hostMember = "11111111-1111-4111-8111-000001114002"
    let hostOther = "11111111-1111-4111-8111-000001114003"
    let peerOwner = "11111111-1111-4111-8111-000001114004"
    let peerMember = "11111111-1111-4111-8111-000001114005"
    for (id, name) in [(hostOwner, "host-owner"), (hostMember, "host-member"), (hostOther, "host-other"), (peerOwner, "peer-owner"), (peerMember, "peer-member")] {
        accounts.addAccount(id: id, email: "\(name)@joint-admin.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: hostServerId, slug: "jca-host", name: "JCA Host", ownerId: hostOwner)
    accounts.oauth.addOwnedServer(id: peerServerId, slug: "jca-peer", name: "JCA Peer", ownerId: peerOwner)
    accounts.oauth.addMember(serverId: hostServerId, userId: hostMember, role: "member")
    accounts.oauth.addMember(serverId: hostServerId, userId: hostOther, role: "member")
    accounts.oauth.addMember(serverId: peerServerId, userId: peerMember, role: "member")
    let canonical = accounts.oauth.createChannel(serverId: hostServerId, name: "jca-storage", creatorUserId: hostOwner)
    let hostProjection = accounts.oauth.createChannel(serverId: hostServerId, name: "jca-room", creatorUserId: hostOwner, type: "joint")
    let peerProjection = accounts.oauth.createChannel(serverId: peerServerId, name: "jca-room", creatorUserId: peerOwner, type: "joint")
    for user in [hostOwner, hostMember, hostOther] { accounts.oauth.addChannelHuman(channelId: hostProjection, userId: user) }
    for user in [peerOwner, peerMember] { accounts.oauth.addChannelHuman(channelId: peerProjection, userId: user) }
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: canonical, serverId: hostServerId)
    accounts.addJointChannelProjection(localChannelId: peerProjection, canonicalChannelId: canonical, serverId: peerServerId)
    accounts.addPostableChannel(serverId: hostServerId, channelId: hostProjection, memberId: hostOwner, kind: "joint", name: "jca-room")
    accounts.addPostableChannel(serverId: hostServerId, channelId: hostProjection, memberId: hostMember, kind: "joint", name: "jca-room")
    accounts.addPostableChannel(serverId: hostServerId, channelId: hostProjection, memberId: hostOther, kind: "joint", name: "jca-room")
    accounts.addPostableChannel(serverId: peerServerId, channelId: peerProjection, memberId: peerOwner, kind: "joint", name: "jca-room")
    let hostOwnerToken = accounts.mintAccessTokenForTesting(userId: hostOwner)
    let hostMemberToken = accounts.mintAccessTokenForTesting(userId: hostMember)
    let hostOtherToken = accounts.mintAccessTokenForTesting(userId: hostOther)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func request(_ method: String, _ path: String, token: String, body: String? = nil) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = hostServerId
                headers[.contentType] = "application/json"
                let response = try await client.send(method == "PATCH" ? .patch : method == "DELETE" ? .delete : method == "POST" ? .post : .get, headers: headers, to: URI(string: path)) { req in
                    if let body { req.body = .init(string: body) }
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let plain = try await request("PATCH", "/api/channels/\(hostProjection)", token: hostMemberToken, body: "{\"description\":\"nope\"}")
            #expect(plain.0.status == .forbidden)

            let promote = try await request("PATCH", "/api/channels/\(hostProjection)/members/user/\(hostMember)/role", token: hostOwnerToken, body: "{\"role\":\"admin\"}")
            #expect(promote.0.status == .ok)

            let renamed = try await request("PATCH", "/api/channels/\(hostProjection)", token: hostMemberToken, body: "{\"name\":\"jca-renamed\",\"description\":\"set by admin\"}")
            #expect(renamed.0.status == .ok)
            #expect(accounts.oauth.channelInfo(id: hostProjection)?.name == "jca-renamed")
            #expect(accounts.oauth.channelInfo(id: peerProjection)?.name == "jca-renamed")
            #expect(accounts.oauth.channelInfo(id: peerProjection)?.description == "set by admin")

            let visibility = try await request("PATCH", "/api/channels/\(hostProjection)", token: hostMemberToken, body: "{\"visibility\":\"private\"}")
            #expect(visibility.0.status == .forbidden)

            let archive = try await request("POST", "/api/channels/\(hostProjection)/archive", token: hostMemberToken)
            #expect(archive.0.status == .forbidden)
            #expect(accounts.oauth.channelArchivedAt(id: hostProjection) == nil)

            let remove = try await request("DELETE", "/api/channels/\(hostProjection)/members/user/\(hostOther)", token: hostMemberToken)
            #expect(remove.0.status == .forbidden)

            let promoteLocal = try await request("PATCH", "/api/channels/\(hostProjection)/members/user/\(hostOther)/role", token: hostMemberToken, body: "{\"role\":\"admin\"}")
            #expect(promoteLocal.0.status == .ok)
            let promotePeer = try await request("PATCH", "/api/channels/\(hostProjection)/members/user/\(peerMember)/role", token: hostMemberToken, body: "{\"role\":\"admin\"}")
            #expect(promotePeer.0.status != .ok)

            let roster = try await request("GET", "/api/channels/\(hostProjection)/members", token: hostOwnerToken)
            #expect(roster.0.status == .ok)
            let humans = roster.1["humans"] as? [[String: Any]] ?? []
            let byId = Dictionary(uniqueKeysWithValues: humans.compactMap { human -> (String, [String: Any])? in
                guard let id = human["id"] as? String else { return nil }
                return (id, human)
            })
            #expect(byId[hostMember]?["canChangeChannelRole"] as? Bool == true)
            #expect(byId[peerMember]?["canChangeChannelRole"] as? Bool == false)

            let list = try await request("GET", "/api/channels", token: hostMemberToken)
            #expect(list.0.status == .ok)
            let listBody = (try? JSONSerialization.jsonObject(with: Data((list.0.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            let row = listBody.first { $0["id"] as? String == hostProjection }
            let caps = row?["channelCapabilities"] as? [String: Any] ?? [:]
            #expect(caps["editChannelMetadata"] as? Bool == true)
            #expect(caps["changeChannelMemberRoles"] as? Bool == true)
            #expect(caps["archiveChannels"] as? Bool == false)
            #expect(caps["removeChannelMembers"] as? Bool == false)
            #expect(caps["manageGuestAccess"] as? Bool == false)
        }
    }
}
