import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

/// A user's uploaded avatar must reach every roster projection the pinned Web
/// reads. `ChatPanel` overlays the channel roster onto the server roster and
/// `MessageItem` renders the message author from that overlay, so a channel
/// roster row without `avatarUrl`/`gravatarHash` makes every human message
/// avatar (the uploader included) fall back to a placeholder.
///
/// Pinned authority: `packages/server/src/services/channelService.ts`
/// `getChannelHumansRawForChannels` publishes id, serverId, serverName,
/// serverSlug, name, displayName, description, avatarUrl, role, serverRole,
/// channelRole and `gravatarHash = sha256(trim(lower(email)))`;
/// `routes/channels.ts` publishes the rows unchanged plus the role projection.
/// `packages/server/src/services/serverService.ts` `getServerMembers` publishes
/// the same account fields for `GET /api/servers/:id/members`.
private let rosterGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
private let rosterPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

private func rosterSHA256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func rosterJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func rosterLogin(_ client: any TestClient, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return try rosterJSON(response)["accessToken"] as? String ?? ""
}

private func rosterUploadAvatar(
    _ client: any TestClient, token: String, bytes: Data, filename: String, mimeType: String
) async throws -> ClientResponse {
    let form = MultipartTestBody(
        fields: [], fileField: "avatar", filename: filename, mimeType: mimeType, bytes: bytes
    )
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = form.contentType
    return try await client.send(.post, headers: headers, to: "/api/auth/me/avatar") { request in
        request.body = .init(data: form.body)
    }
}

private struct RosterFixture {
    let accounts: EmailLoginDirectory
    let serverId = "33333333-3333-4333-8333-333333333677"
    let ownerId = "11111111-1111-4111-8111-111111111651"
    let memberId = "11111111-1111-4111-8111-111111111652"
    let channelId: String
    let memberEmail = "roster-avatar-member@slock.test"

    init() {
        accounts = EmailLoginDirectory()
        accounts.addAccount(id: ownerId, email: "roster-avatar-owner@slock.test", password: "password123")
        accounts.addAccount(id: memberId, email: memberEmail, password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.markEmailVerified(userId: memberId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "roster-avatar", name: "Roster Avatar", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "roster-avatar", creatorUserId: ownerId)
        for id in [ownerId, memberId] {
            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: "roster-avatar")
            accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
        }
        accounts.setAccountProfileForTesting(id: memberId, name: "roster-member", displayName: "Roster Display")
        accounts.setAccountDescriptionForTesting(userId: memberId, description: "Roster description")
    }
}

@Test func channelRosterCarriesTheUploadedUserAvatarAndProfile() async throws {
    let fixture = RosterFixture()
    let expectedGravatar = rosterSHA256(fixture.memberEmail.lowercased())
    let agentAvatarURL = "/api/avatars/\(fixture.serverId)/0123456789abcdef0123456789abcdef.webp"
    let agentId = fixture.accounts.oauth.createAgent(
        serverId: fixture.serverId, name: "roster-agent", displayName: "Roster Agent",
        avatarUrl: agentAvatarURL, creatorUserId: fixture.ownerId, runtime: "codex"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let ownerToken = try await rosterLogin(client, email: "roster-avatar-owner@slock.test")
            let memberToken = try await rosterLogin(client, email: fixture.memberEmail)

            let uploaded = try await rosterUploadAvatar(
                client, token: memberToken, bytes: rosterGIF, filename: "avatar.gif", mimeType: "image/gif"
            )
            #expect(uploaded.status == .ok, "avatar body: \(uploaded.body.string ?? "")")
            let uploadedBody = try rosterJSON(uploaded)
            let avatarURL = try #require(uploadedBody["avatarUrl"] as? String)
            #expect(avatarURL.wholeMatch(of: /^\/api\/avatars\/users\/[0-9a-f]{32}\.webp$/) != nil)

            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let roster = try await client.send(
                .get, headers: ownerHeaders, to: "/api/channels/\(fixture.channelId)/members"
            )
            #expect(roster.status == .ok, "roster body: \(roster.body.string ?? "")")
            let rosterBody = try rosterJSON(roster)
            #expect((rosterBody["externalMembers"] as? [Any])?.isEmpty == true)
            let humans = rosterBody["humans"] as? [[String: Any]] ?? []
            let memberRow = try #require(humans.first { $0["id"] as? String == fixture.memberId })
            #expect(memberRow["avatarUrl"] as? String == avatarURL)
            #expect(memberRow["gravatarHash"] as? String == expectedGravatar)
            #expect(memberRow["displayName"] as? String == "Roster Display")
            #expect(memberRow["description"] as? String == "Roster description")
            #expect(memberRow["name"] as? String == "roster-member")
            #expect(memberRow["serverId"] as? String == fixture.serverId)
            #expect(memberRow["serverName"] as? String == "Roster Avatar")
            #expect(memberRow["serverSlug"] as? String == "roster-avatar")
            #expect(memberRow["role"] as? String == "member")
            #expect(memberRow["serverRole"] as? String == "member")
            #expect(memberRow["channelRole"] as? String == "member")
            #expect(memberRow["effectiveChannelRole"] as? String == "member")
            let ownerRow = try #require(humans.first { $0["id"] as? String == fixture.ownerId })
            #expect(ownerRow["avatarUrl"] is NSNull)
            #expect(ownerRow["gravatarHash"] as? String == rosterSHA256("roster-avatar-owner@slock.test"))

            let serverRoster = try await client.send(
                .get, headers: ownerHeaders, to: "/api/servers/\(fixture.serverId)/members"
            )
            #expect(serverRoster.status == .ok)
            let serverRows = (try JSONSerialization.jsonObject(
                with: Data((serverRoster.body.string ?? "").utf8)
            )) as? [[String: Any]] ?? []
            let serverMemberRow = try #require(serverRows.first { $0["userId"] as? String == fixture.memberId })
            #expect(serverMemberRow["avatarUrl"] as? String == avatarURL)
            #expect(serverMemberRow["gravatarHash"] as? String == expectedGravatar)
            #expect(serverMemberRow["displayName"] as? String == "Roster Display")
            #expect(serverMemberRow["description"] as? String == "Roster description")
            #expect(serverMemberRow["role"] as? String == "member")
            #expect(serverMemberRow["email"] as? String == fixture.memberEmail)

            let profile = try await client.send(
                .get, headers: ownerHeaders,
                to: "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)/profile"
            )
            #expect(profile.status == .ok, "profile body: \(profile.body.string ?? "")")
            let profileBody = try rosterJSON(profile)
            #expect(profileBody["userId"] as? String == fixture.memberId)
            #expect(profileBody["serverId"] as? String == fixture.serverId)
            #expect(profileBody["serverName"] as? String == "Roster Avatar")
            #expect(profileBody["serverSlug"] as? String == "roster-avatar")
            #expect(profileBody["name"] as? String == "roster-member")
            #expect(profileBody["displayName"] as? String == "Roster Display")
            #expect(profileBody["description"] as? String == "Roster description")
            #expect(profileBody["avatarUrl"] as? String == avatarURL)
            #expect(profileBody["gravatarHash"] as? String == expectedGravatar)
            #expect(profileBody["role"] as? String == "member")
            #expect(profileBody["membershipStatus"] as? String == "active")

            // A non-admin viewer of a current member sees the identity/avatar but
            // never the email; the gravatar hash still derives from the stored
            // email, matching the pinned row.
            var memberHeaders = HTTPFields()
            memberHeaders[.authorization] = "Bearer \(memberToken)"
            memberHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let ownerProfile = try await client.send(
                .get, headers: memberHeaders,
                to: "/api/servers/\(fixture.serverId)/members/\(fixture.ownerId)/profile"
            )
            #expect(ownerProfile.status == .ok)
            let ownerBody = try rosterJSON(ownerProfile)
            #expect(ownerBody["email"] is NSNull)
            #expect(ownerBody["gravatarHash"] as? String
                == rosterSHA256("roster-avatar-owner@slock.test"))
            #expect(ownerBody["role"] as? String == "owner")
            #expect(ownerBody["membershipStatus"] as? String == "active")
            let createdAgents = try #require(ownerBody["createdAgents"] as? [[String: Any]])
            let createdAgent = try #require(createdAgents.first { $0["id"] as? String == agentId })
            #expect(createdAgent["displayName"] as? String == "Roster Agent")
            #expect(createdAgent["avatarUrl"] as? String == agentAvatarURL)
            #expect(createdAgent["runtime"] as? String == "codex")
            #expect(createdAgent["status"] as? String == "inactive")

            let graph = try await client.send(
                .get, headers: ownerHeaders, to: "/api/servers/\(fixture.serverId)/member-graph"
            )
            #expect(graph.status == .ok, "graph body: \(graph.body.string ?? "")")
            let graphBody = try rosterJSON(graph)
            let graphHumans = graphBody["humans"] as? [[String: Any]] ?? []
            let graphMember = try #require(graphHumans.first { $0["id"] as? String == fixture.memberId })
            #expect(graphMember["type"] as? String == "human")
            #expect(graphMember["displayName"] as? String == "Roster Display")
            #expect(graphMember["avatarUrl"] as? String == avatarURL)
            #expect(graphMember["gravatarHash"] as? String == expectedGravatar)
            #expect(graphMember["role"] as? String == "member")
            #expect(graphMember["name"] as? String == "roster-member")
            #expect((graphMember["channelIds"] as? [String])?.contains(fixture.channelId) == true)
            let graphAgents = graphBody["agents"] as? [[String: Any]] ?? []
            let graphAgent = try #require(graphAgents.first { $0["id"] as? String == agentId })
            #expect(graphAgent["type"] as? String == "agent")
            #expect(graphAgent["name"] as? String == "roster-agent")
            #expect(graphAgent["displayName"] as? String == "Roster Agent")
            #expect(graphAgent["avatarUrl"] as? String == agentAvatarURL)
            #expect(graphAgent["runtime"] as? String == "codex")
            #expect(graphAgent["status"] as? String == "inactive")
            let graphChannels = graphBody["channels"] as? [[String: Any]] ?? []
            let graphChannel = try #require(graphChannels.first { $0["id"] as? String == fixture.channelId })
            #expect(graphChannel["type"] as? String == "channel")
            #expect(graphChannel["humanCount"] as? Int == 2)
            #expect(graphChannel["agentCount"] as? Int == 0)
            #expect(graphChannel["memberCount"] as? Int == 2)
        }
    }
}

@Test func guestChannelRosterPublishesTheBoundedAvatarIdentity() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111653"
    let guestId = "11111111-1111-4111-8111-111111111654"
    let serverId = "33333333-3333-4333-8333-333333333678"
    accounts.addAccount(id: ownerId, email: "roster-guest-owner@slock.test", password: "password123")
    accounts.addAccount(id: guestId, email: "roster-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "roster-guest", name: "Roster Guest", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "roster-guest", creatorUserId: ownerId)
    for id in [ownerId, guestId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: "roster-guest")
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    accounts.setAccountProfileForTesting(id: ownerId, name: "guest-owner", displayName: "Guest Owner")
    accounts.setAccountDescriptionForTesting(userId: ownerId, description: "Owner private description")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerToken = try await rosterLogin(client, email: "roster-guest-owner@slock.test")
            let uploaded = try await rosterUploadAvatar(
                client, token: ownerToken, bytes: rosterGIF, filename: "avatar.gif", mimeType: "image/gif"
            )
            let avatarURL = try #require(try rosterJSON(uploaded)["avatarUrl"] as? String)
            let guestToken = try await rosterLogin(client, email: "roster-guest@slock.test")
            var guestHeaders = HTTPFields()
            guestHeaders[.authorization] = "Bearer \(guestToken)"
            guestHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let roster = try await client.send(
                .get, headers: guestHeaders, to: "/api/channels/\(channelId)/members"
            )
            #expect(roster.status == .ok, "guest roster body: \(roster.body.string ?? "")")
            let humans = try rosterJSON(roster)["humans"] as? [[String: Any]] ?? []
            let ownerRow = try #require(humans.first { $0["id"] as? String == ownerId })
            #expect(ownerRow["name"] as? String == "guest-owner")
            #expect(ownerRow["displayName"] as? String == "Guest Owner")
            #expect(ownerRow["avatarUrl"] as? String == avatarURL)
            #expect(ownerRow["gravatarHash"] as? String == rosterSHA256("roster-guest-owner@slock.test"))
            // The bounded Guest roster must not publish the account description,
            // server metadata or member role facts.
            for key in ["description", "serverId", "serverName", "serverSlug", "role", "serverRole", "channelRole", "channelAdminBasis", "servers"] {
                #expect(!ownerRow.keys.contains(key))
            }
            // The pinned Guest branch answers only {agents, humans}; no
            // externalMembers member.
            #expect(!(try rosterJSON(roster).keys.contains("externalMembers")))
        }
    }
}

@Test func channelHistoryProjectsTheCurrentProfileAvatarAfterEachUpload() async throws {
    let fixture = RosterFixture()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let ownerToken = try await rosterLogin(client, email: "roster-avatar-owner@slock.test")
            let memberToken = try await rosterLogin(client, email: fixture.memberEmail)

            let first = try await rosterUploadAvatar(
                client, token: memberToken, bytes: rosterGIF, filename: "avatar.gif", mimeType: "image/gif"
            )
            let firstURL = try #require(try rosterJSON(first)["avatarUrl"] as? String)

            var memberHeaders = HTTPFields()
            memberHeaders[.authorization] = "Bearer \(memberToken)"
            memberHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let sent = try await client.send(.post, headers: memberHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"avatar roster history\",\"randomId\":\"roster-avatar-history-1\"}")
            }
            #expect(sent.status == .ok, "send body: \(sent.body.string ?? "")")

            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let firstHistory = try await client.send(
                .get, headers: ownerHeaders, to: "/api/messages/channel/\(fixture.channelId)"
            )
            #expect(firstHistory.status == .ok)
            let firstRow = try #require(try rosterJSON(firstHistory)["messages"] as? [[String: Any]])
                .first { $0["senderId"] as? String == fixture.memberId }
            #expect(firstRow?["senderAvatarUrl"] as? String == firstURL)

            // A different image has different bytes, so the content-addressed
            // key must change; the retained history row then projects the new
            // profile URL rather than a send-time snapshot or the old key.
            let second = try await rosterUploadAvatar(
                client, token: memberToken, bytes: rosterPNG, filename: "avatar.png", mimeType: "image/png"
            )
            let secondURL = try #require(try rosterJSON(second)["avatarUrl"] as? String)
            #expect(secondURL != firstURL)

            let secondHistory = try await client.send(
                .get, headers: ownerHeaders, to: "/api/messages/channel/\(fixture.channelId)"
            )
            #expect(secondHistory.status == .ok)
            let secondRow = try #require(try rosterJSON(secondHistory)["messages"] as? [[String: Any]])
                .first { $0["senderId"] as? String == fixture.memberId }
            #expect(secondRow?["senderAvatarUrl"] as? String == secondURL)

            var firstObject = try await client.get(URI(string: firstURL))
            #expect(firstObject.status == .ok)
            #expect((try await firstObject.body.collect() ?? Data()) == rosterGIF)
            var secondObject = try await client.get(URI(string: secondURL))
            #expect(secondObject.status == .ok)
            #expect((try await secondObject.body.collect() ?? Data()) == rosterPNG)
        }
    }
}

@Test func jointChannelRosterAttributesEachHumanToItsOwnServer() async throws {
    let accounts = EmailLoginDirectory()
    let hostServerId = "33333333-3333-4333-8333-333333333681"
    let peerServerId = "33333333-3333-4333-8333-333333333682"
    let hostOwnerId = "11111111-1111-4111-8111-111111111661"
    let peerMemberId = "11111111-1111-4111-8111-111111111662"
    let hostMemberId = "11111111-1111-4111-8111-111111111663"
    for (id, email) in [
        (hostOwnerId, "roster-joint-host@slock.test"),
        (peerMemberId, "roster-joint-peer@slock.test"),
        (hostMemberId, "roster-joint-host-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addMember(serverId: hostServerId, userId: hostMemberId, role: "member")
    // The host owner genuinely participates through both servers; the third
    // host human has a stale peer channel row without a peer server membership.
    accounts.oauth.addMember(serverId: peerServerId, userId: hostOwnerId, role: "member")
    accounts.oauth.addOwnedServer(id: hostServerId, slug: "roster-joint-host", name: "Roster Joint Host", ownerId: hostOwnerId)
    accounts.oauth.addOwnedServer(id: peerServerId, slug: "roster-joint-peer", name: "Roster Joint Peer", ownerId: peerMemberId)
    let canonical = accounts.oauth.createChannel(serverId: hostServerId, name: "joint-storage", creatorUserId: hostOwnerId)
    let hostProjection = accounts.oauth.createChannel(serverId: hostServerId, name: "joint-room", creatorUserId: hostOwnerId, type: "joint")
    let peerProjection = accounts.oauth.createChannel(serverId: peerServerId, name: "joint-room", creatorUserId: peerMemberId, type: "joint")
    accounts.oauth.addChannelHuman(channelId: hostProjection, userId: hostOwnerId)
    accounts.oauth.addChannelHuman(channelId: hostProjection, userId: hostMemberId)
    accounts.oauth.addChannelHuman(channelId: peerProjection, userId: peerMemberId)
    accounts.oauth.addChannelHuman(channelId: peerProjection, userId: hostOwnerId)
    accounts.oauth.addChannelHuman(channelId: peerProjection, userId: hostMemberId)
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: canonical, serverId: hostServerId)
    accounts.addJointChannelProjection(localChannelId: peerProjection, canonicalChannelId: canonical, serverId: peerServerId)
    accounts.addPostableChannel(serverId: hostServerId, channelId: hostProjection, memberId: hostOwnerId, kind: "joint", name: "joint-room")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await rosterLogin(client, email: "roster-joint-host@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = hostServerId
            let roster = try await client.send(
                .get, headers: headers, to: "/api/channels/\(hostProjection)/members"
            )
            #expect(roster.status == .ok, "joint roster body: \(roster.body.string ?? "")")
            let humans = try rosterJSON(roster)["humans"] as? [[String: Any]] ?? []
            // Pinned joint merge order: peer projection humans first, then the
            // viewed projection's humans (duplicates keep the first position).
            // The peer projection order is the ledger's id order here because
            // the pinned `channel_humans.joined_at` ordering is not retained.
            // Peer projection rows are id-ordered by the ledger (the pinned
            // `channel_humans.joined_at` ordering is not retained); a duplicate
            // identity keeps the first position.
            #expect(humans.compactMap { $0["id"] as? String } == [hostOwnerId, peerMemberId, hostMemberId])
            #expect(humans.filter { $0["id"] as? String == hostOwnerId }.count == 1)
            let hostRow = try #require(humans.first { $0["id"] as? String == hostOwnerId })
            #expect(hostRow["serverId"] as? String == hostServerId)
            #expect(hostRow["serverName"] as? String == "Roster Joint Host")
            #expect(hostRow["role"] as? String == "owner")
            // `servers` publishes every projection the human participates through,
            // viewed server first (`channelService.ts:5955-6034`).
            let hostServers = try #require(hostRow["servers"] as? [[String: Any]])
            #expect(hostServers.compactMap { $0["id"] as? String } == [hostServerId, peerServerId])
            #expect(hostServers.first?["name"] as? String == "Roster Joint Host")
            #expect(hostRow["channelRole"] as? String == "member")
            let peerRow = try #require(humans.first { $0["id"] as? String == peerMemberId })
            // A joint roster row keeps the metadata of its owning projection,
            // never the server id from the request header.
            #expect(peerRow["serverId"] as? String == peerServerId)
            #expect(peerRow["serverName"] as? String == "Roster Joint Peer")
            #expect(peerRow["serverSlug"] as? String == "roster-joint-peer")
            #expect(peerRow["role"] as? String == "owner")
            #expect(peerRow["channelRole"] as? String == "member")
            let peerServers = try #require(peerRow["servers"] as? [[String: Any]])
            #expect(peerServers.compactMap { $0["id"] as? String } == [peerServerId])
            #expect(peerRow["gravatarHash"] as? String == rosterSHA256("roster-joint-peer@slock.test"))
            // Pinned `getLocalChannelMemberIds` targetability: a peer projection
            // row is never role-targetable from the viewed channel, and the
            // viewed owner is protected.
            #expect(peerRow["canChangeChannelRole"] as? Bool == false)
            #expect(hostRow["canChangeChannelRole"] as? Bool == false)
            let staleRow = try #require(humans.first { $0["id"] as? String == hostMemberId })
            // The viewed projection owns this row. The stale peer channel row
            // must not add peer server metadata or a peer `servers` entry.
            #expect(staleRow["serverId"] as? String == hostServerId)
            #expect(staleRow["canChangeChannelRole"] as? Bool == true)
            let staleServers = try #require(staleRow["servers"] as? [[String: Any]])
            #expect(staleServers.compactMap { $0["id"] as? String } == [hostServerId])
        }
    }
}

@Test func phantomChannelHumanWithoutAnAccountIsNotPublished() async throws {
    let fixture = RosterFixture()
    let phantomId = "11111111-1111-4111-8111-111111111659"
    fixture.accounts.oauth.addChannelHuman(channelId: fixture.channelId, userId: phantomId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await rosterLogin(client, email: "roster-avatar-owner@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let roster = try await client.send(
                .get, headers: headers, to: "/api/channels/\(fixture.channelId)/members"
            )
            #expect(roster.status == .ok)
            let humans = try rosterJSON(roster)["humans"] as? [[String: Any]] ?? []
            // Pinned `getChannelHumansRawForChannels` inner-joins `users`, so a
            // membership row without an account row never reaches the roster.
            #expect(humans.contains { $0["id"] as? String == phantomId } == false)
            #expect(Set(humans.compactMap { $0["id"] as? String }) == [fixture.ownerId, fixture.memberId])
        }
    }
}

@Test func allChannelRosterOmitsChannelRoleAndExcludesGuests() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111663"
    let memberId = "11111111-1111-4111-8111-111111111664"
    let guestId = "11111111-1111-4111-8111-111111111665"
    let serverId = "33333333-3333-4333-8333-333333333683"
    for (id, email) in [
        (ownerId, "roster-all-owner@slock.test"),
        (memberId, "roster-all-member@slock.test"),
        (guestId, "roster-all-guest@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "roster-all", name: "Roster All", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    // `addOwnedServer` seeds the server's virtual #all channel; the audience is
    // derived from server membership, not channel_humans rows.
    let allChannel = try #require(accounts.oauth.allChannelId(serverId: serverId))
    accounts.addPostableChannel(serverId: serverId, channelId: allChannel, memberId: ownerId, name: "all")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await rosterLogin(client, email: "roster-all-owner@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let roster = try await client.send(
                .get, headers: headers, to: "/api/channels/\(allChannel)/members"
            )
            #expect(roster.status == .ok, "all roster body: \(roster.body.string ?? "")")
            let humans = try rosterJSON(roster)["humans"] as? [[String: Any]] ?? []
            // The virtual #all audience is the non-Guest server audience.
            #expect(
                Set(humans.compactMap { $0["id"] as? String }) == [ownerId, memberId],
                "all roster body: \(roster.body.string ?? "")"
            )
            for human in humans {
                // #all has no stored channel-role rows; the pinned row shape
                // therefore carries no `channelRole` member at all (absent, not
                // JSON null).
                #expect(!human.keys.contains("channelRole"))
                #expect(human["serverId"] as? String == serverId)
            }
            // Pinned #all row order: role, gravatarHash, serverRole, then the
            // effective role triple.
            let rendered = roster.body.string ?? ""
            let roleIndex = try #require(rendered.range(of: "\"role\":\"owner\""))
            let gravatarIndex = try #require(rendered.range(of: "\"gravatarHash\":\""))
            let serverRoleIndex = try #require(rendered.range(of: "\"serverRole\":\"owner\""))
            #expect(roleIndex.lowerBound < gravatarIndex.lowerBound)
            #expect(gravatarIndex.lowerBound < serverRoleIndex.lowerBound)
            // Guest bodies never carry externalMembers; the #all request above is
            // owner-scoped and does.
            #expect((try rosterJSON(roster)["externalMembers"] as? [Any])?.isEmpty == true)
        }
    }
}

@Test func removedMemberProfileKeepsAccountFactsAndPinnedStatus() async throws {
    let fixture = RosterFixture()
    let viewerId = "11111111-1111-4111-8111-111111111660"
    fixture.accounts.addAccount(id: viewerId, email: "roster-avatar-viewer@slock.test", password: "password123")
    fixture.accounts.markEmailVerified(userId: viewerId)
    fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: viewerId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let ownerToken = try await rosterLogin(client, email: "roster-avatar-owner@slock.test")
            let memberToken = try await rosterLogin(client, email: fixture.memberEmail)
            let uploaded = try await rosterUploadAvatar(
                client, token: memberToken, bytes: rosterGIF, filename: "avatar.gif", mimeType: "image/gif"
            )
            let avatarURL = try #require(try rosterJSON(uploaded)["avatarUrl"] as? String)

            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let removed = try await client.send(
                .delete, headers: ownerHeaders,
                to: "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)"
            )
            #expect(removed.status == .ok, "remove body: \(removed.body.string ?? "")")

            let profile = try await client.send(
                .get, headers: ownerHeaders,
                to: "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)/profile"
            )
            #expect(profile.status == .ok, "removed profile body: \(profile.body.string ?? "")")
            let body = try rosterJSON(profile)
            #expect(body["membershipStatus"] as? String == "removed")
            #expect(body["role"] is NSNull)
            #expect(body["email"] as? String == fixture.memberEmail)
            #expect(body["displayName"] as? String == "Roster Display")
            #expect(body["description"] as? String == "Roster description")
            #expect(body["avatarUrl"] as? String == avatarURL)
            #expect(body["gravatarHash"] as? String == rosterSHA256(fixture.memberEmail))
            #expect((body["createdAgents"] as? [Any])?.isEmpty == true)

            // A removed member's profile stays gated by the pre-existing
            // owner/admin/self rule; a plain member still receives not-found.
            let viewerToken = try await rosterLogin(client, email: "roster-avatar-viewer@slock.test")
            var viewerHeaders = HTTPFields()
            viewerHeaders[.authorization] = "Bearer \(viewerToken)"
            viewerHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let refused = try await client.send(
                .get, headers: viewerHeaders,
                to: "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)/profile"
            )
            #expect(refused.status == .notFound)

        }
    }
}

@Test func leftMemberProfilePublishesTheRetainedDepartureStatus() async throws {
    let fixture = RosterFixture()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let ownerToken = try await rosterLogin(client, email: "roster-avatar-owner@slock.test")
            let memberToken = try await rosterLogin(client, email: fixture.memberEmail)
            var memberHeaders = HTTPFields()
            memberHeaders[.authorization] = "Bearer \(memberToken)"
            memberHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let leave = try await client.send(
                .post, headers: memberHeaders,
                to: "/api/servers/\(fixture.serverId)/leave"
            )
            #expect(leave.status == .ok, "leave body: \(leave.body.string ?? "")")

            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let profile = try await client.send(
                .get, headers: ownerHeaders,
                to: "/api/servers/\(fixture.serverId)/members/\(fixture.memberId)/profile"
            )
            #expect(profile.status == .ok, "left profile body: \(profile.body.string ?? "")")
            let body = try rosterJSON(profile)
            // The store retains the departure reason ("left"); the profile must
            // publish it instead of collapsing every departure to "removed".
            #expect(body["membershipStatus"] as? String == "left")
            #expect(body["role"] is NSNull)
            #expect(body["email"] as? String == fixture.memberEmail)
            #expect(body["displayName"] as? String == "Roster Display")
            #expect(body["description"] as? String == "Roster description")
            #expect((body["createdAgents"] as? [Any])?.isEmpty == true)

            // The departed human is no longer a server member, so the roster's
            // server-membership join removes any residual channel membership row
            // (pinned `getChannelHumansRawForChannels` inner-joins server_members).
            fixture.accounts.oauth.addChannelHuman(channelId: fixture.channelId, userId: fixture.memberId)
            let roster = try await client.send(
                .get, headers: ownerHeaders, to: "/api/channels/\(fixture.channelId)/members"
            )
            #expect(roster.status == .ok)
            let humans = try rosterJSON(roster)["humans"] as? [[String: Any]] ?? []
            #expect(humans.contains { $0["id"] as? String == fixture.memberId } == false)
        }
    }
}

@Test func threadUnderAllChannelUsesTheVirtualAudience() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111666"
    let memberId = "11111111-1111-4111-8111-111111111667"
    let guestId = "11111111-1111-4111-8111-111111111668"
    let serverId = "33333333-3333-4333-8333-333333333684"
    for (id, email) in [
        (ownerId, "roster-all-thread-owner@slock.test"),
        (memberId, "roster-all-thread-member@slock.test"),
        (guestId, "roster-all-thread-guest@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "roster-all-thread", name: "Roster All Thread", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let allChannel = try #require(accounts.oauth.allChannelId(serverId: serverId))
    accounts.addPostableChannel(serverId: serverId, channelId: allChannel, memberId: ownerId, name: "all")
    let threadChannel = accounts.oauth.createThreadChannel(parentChannelId: allChannel, parentMessageId: "11111111-1111-4111-8111-000000000666")
    accounts.addThreadChannel(
        serverId: serverId, threadChannelId: threadChannel, parentChannelId: allChannel,
        parentMessageId: "11111111-1111-4111-8111-000000000666", memberId: ownerId
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await rosterLogin(client, email: "roster-all-thread-owner@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let roster = try await client.send(
                .get, headers: headers, to: "/api/channels/\(threadChannel)/members"
            )
            #expect(roster.status == .ok, "thread roster body: \(roster.body.string ?? "")")
            let humans = try rosterJSON(roster)["humans"] as? [[String: Any]] ?? []
            // A thread delegates its roster to the parent #all audience.
            #expect(Set(humans.compactMap { $0["id"] as? String }) == [ownerId, memberId])
            for human in humans {
                #expect(!human.keys.contains("channelRole"))
            }
        }
    }
}
