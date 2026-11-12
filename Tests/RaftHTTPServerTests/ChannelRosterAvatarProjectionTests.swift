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
            #expect((graphMember["channelIds"] as? [String])?.contains(fixture.channelId) == true)
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
            for key in ["description", "serverId", "serverName", "serverSlug", "role", "serverRole", "channelRole", "channelAdminBasis"] {
                #expect(ownerRow[key] == nil)
            }
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
