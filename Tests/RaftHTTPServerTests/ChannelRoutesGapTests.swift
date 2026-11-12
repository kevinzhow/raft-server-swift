import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func gapJSON(_ text: String?) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [String: Any] ?? [:]
}

private func gapLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return gapJSON(response.body.string)["accessToken"] as? String ?? ""
}

private func gapHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

// MARK: - D1: thread members inherit the parent's read policy

@Test func threadChannelMembersResolveThroughTheParentChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-211111111001"
    let memberId = "11111111-1111-4111-8111-211111111002"
    let outsiderId = "11111111-1111-4111-8111-211111111003"
    let serverId = "33333333-3333-4333-8333-211111111001"
    for (id, email) in [
        (ownerId, "thread-members-owner@slock.test"),
        (memberId, "thread-members-member@slock.test"),
        (outsiderId, "thread-members-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-members", name: "Thread Members", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")

    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "thread-members-room", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "private", name: "thread-members-room")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, kind: "private", name: "thread-members-room")
    for id in [ownerId, memberId] {
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let parentMessage = accounts.addChannelMessageForTesting(
        channelId: channelId, content: "thread parent", senderId: ownerId
    )
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parentMessage)
    accounts.addThreadChannel(
        serverId: serverId, threadChannelId: threadId,
        parentChannelId: channelId, parentMessageId: parentMessage, memberId: ownerId
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await gapLogin(client, email: "thread-members-owner@slock.test")
            let member = try await gapLogin(client, email: "thread-members-member@slock.test")
            let outsider = try await gapLogin(client, email: "thread-members-outsider@slock.test")

            // The published path the owner already reaches through GET /api/channels/:id.
            let detail = try await client.get(URI(string: "/api/channels/\(threadId)"), headers: gapHeaders(owner, serverId))
            #expect(detail.status == .ok)
            #expect(gapJSON(detail.body.string)["type"] as? String == "thread")

            let ownerMembers = try await client.get(
                URI(string: "/api/channels/\(threadId)/members"), headers: gapHeaders(owner, serverId)
            )
            #expect(ownerMembers.status == .ok, Comment(rawValue: ownerMembers.body.string ?? ""))
            let ownerBody = gapJSON(ownerMembers.body.string)
            let humanIds = (ownerBody["humans"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            #expect(Set(humanIds) == Set([ownerId, memberId]), "a thread roster delegates to its parent channel")
            #expect(ownerBody["agents"] as? [[String: Any]] != nil)

            let memberMembers = try await client.get(
                URI(string: "/api/channels/\(threadId)/members"), headers: gapHeaders(member, serverId)
            )
            #expect(memberMembers.status == .ok)

            // The adjacent agents read resolves the same thread parent.
            let threadAgents = try await client.get(
                URI(string: "/api/channels/\(threadId)/agents"), headers: gapHeaders(owner, serverId)
            )
            #expect(threadAgents.status == .ok, Comment(rawValue: threadAgents.body.string ?? ""))
            let threadAgentRows = gapJSON(threadAgents.body.string)["agents"] as? [[String: Any]] ?? []
            #expect(threadAgentRows.isEmpty)
            let outsiderAgents = try await client.get(
                URI(string: "/api/channels/\(threadId)/agents"), headers: gapHeaders(outsider, serverId)
            )
            #expect(outsiderAgents.status == .notFound)

            // A server member who is not in the private parent cannot see the
            // thread or its roster.
            let outsiderMembers = try await client.get(
                URI(string: "/api/channels/\(threadId)/members"), headers: gapHeaders(outsider, serverId)
            )
            #expect(outsiderMembers.status == .notFound)
            #expect(gapJSON(outsiderMembers.body.string)["error"] as? String == "Channel not found")
        }
    }
}

// MARK: - D2: DELETE /api/channels/saved/:messageId

@Test func deleteSavedMessageRemovesOnlyTheCallersSavedRow() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-211111111011"
    let memberId = "11111111-1111-4111-8111-211111111012"
    let serverId = "33333333-3333-4333-8333-211111111011"
    for (id, email) in [(ownerId, "delete-saved-owner@slock.test"), (memberId, "delete-saved-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "delete-saved", name: "Delete Saved", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "delete-saved-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "delete-saved-room")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, name: "delete-saved-room")
    for id in [ownerId, memberId] {
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let message = accounts.addChannelMessageForTesting(channelId: channelId, content: "saved once", senderId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await gapLogin(client, email: "delete-saved-owner@slock.test")
            let member = try await gapLogin(client, email: "delete-saved-member@slock.test")

            for token in [owner, member] {
                let save = try await client.send(
                    .post, headers: gapHeaders(token, serverId), to: "/api/channels/saved"
                ) { request in
                    request.body = .init(string: "{\"messageId\":\"\(message)\"}")
                }
                #expect(save.status == .ok)
            }

            let removed = try await client.send(
                .delete, headers: gapHeaders(member, serverId),
                to: "/api/channels/saved/\(message)"
            )
            #expect(removed.status == .ok)
            #expect(removed.body.string == "{\"ok\":true}")

            // Repeating the delete is the same success; an unknown id is too.
            for path in ["/api/channels/saved/\(message)", "/api/channels/saved/\(UUID().uuidString.lowercased())"] {
                let repeated = try await client.send(.delete, headers: gapHeaders(member, serverId), to: URI(string: path))
                #expect(repeated.status == .ok)
                #expect(repeated.body.string == "{\"ok\":true}")
            }

            let memberCheck = try await client.send(
                .post, headers: gapHeaders(member, serverId), to: "/api/channels/saved/check"
            ) { request in
                request.body = .init(string: "{\"messageIds\":[\"\(message)\"]}")
            }
            #expect(gapJSON(memberCheck.body.string)["savedIds"] as? [String] == [])

            // Another user's saved row is untouched.
            let ownerCheck = try await client.send(
                .post, headers: gapHeaders(owner, serverId), to: "/api/channels/saved/check"
            ) { request in
                request.body = .init(string: "{\"messageIds\":[\"\(message)\"]}")
            }
            #expect(gapJSON(ownerCheck.body.string)["savedIds"] as? [String] == [message])

            let unauthorized = try await client.send(
                .delete, headers: gapHeaders("not-a-token", serverId), to: "/api/channels/saved/\(message)"
            )
            #expect(unauthorized.status == .unauthorized)
        }
    }
}

// MARK: - Joint channel list, invite, resend, accept and disconnect

private struct JointGapFixture {
    let accounts = EmailLoginDirectory()
    let hostServerId = "33333333-3333-4333-8333-211111111101"
    let targetServerId = "33333333-3333-4333-8333-211111111102"
    let hostOwnerId = "11111111-1111-4111-8111-211111111101"
    let targetOwnerId = "11111111-1111-4111-8111-211111111102"
    let hostSlug = "joint-gap-host"
    let targetSlug = "joint-gap-target"
    var hostChannelId = ""
    var inviteId = ""
    var targetChannelId = ""
    var hostToken = ""
    var targetToken = ""

    mutating func seed() async throws {
        for (id, email) in [(hostOwnerId, "joint-gap-host"), (targetOwnerId, "joint-gap-target")] {
            accounts.addAccount(id: id, email: "\(email)@slock.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: hostServerId, slug: hostSlug, name: "Joint Gap Host", ownerId: hostOwnerId)
        accounts.oauth.addOwnedServer(id: targetServerId, slug: targetSlug, name: "Joint Gap Target", ownerId: targetOwnerId)
        hostToken = accounts.mintAccessTokenForTesting(userId: hostOwnerId)
        targetToken = accounts.mintAccessTokenForTesting(userId: targetOwnerId)
    }
}

@Test func jointChannelInviteListResendInviteAcceptAndDisconnect() async throws {
    var fixture = JointGapFixture()
    try await fixture.seed()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let created = try await client.send(
                .post, headers: gapHeaders(fixture.hostToken, fixture.hostServerId), to: "/api/channels"
            ) { request in
                request.body = .init(string: "{\"name\":\"joint-gap-room\",\"visibility\":\"joint\",\"targetServerSlug\":\"\(fixture.targetSlug)\",\"invitedPeople\":[\"@joint-gap-target\"]}")
            }
            #expect(created.status == .ok, Comment(rawValue: created.body.string ?? ""))
            let createdBody = gapJSON(created.body.string)
            fixture.hostChannelId = try #require(createdBody["id"] as? String)
            fixture.inviteId = try #require((createdBody["jointInvite"] as? [String: Any])?["id"] as? String)

            let list = try await client.get(
                URI(string: "/api/channels/joint-invites"),
                headers: gapHeaders(fixture.targetToken, fixture.targetServerId)
            )
            #expect(list.status == .ok, Comment(rawValue: list.body.string ?? ""))
            let invites = gapJSON(list.body.string)["invites"] as? [[String: Any]] ?? []
            #expect(invites.count == 1)
            #expect(invites.first?["id"] as? String == fixture.inviteId)
            #expect(invites.first?["fromServerName"] as? String == "Joint Gap Host")
            #expect(invites.first?["fromServerSlug"] as? String == fixture.hostSlug)
            #expect(invites.first?["channelName"] as? String == "joint-gap-room")
            #expect(invites.first?["invitedUserId"] as? String == fixture.targetOwnerId)
            #expect(invites.first?["createdAt"] is String)
            #expect(invites.first?["expiresAt"] is String)

            let hostList = try await client.get(
                URI(string: "/api/channels/joint-invites"),
                headers: gapHeaders(fixture.hostToken, fixture.hostServerId)
            )
            let hostListRows = gapJSON(hostList.body.string)["invites"] as? [[String: Any]] ?? []
            #expect(hostListRows.isEmpty)

            let resent = try await client.send(
                .post, headers: gapHeaders(fixture.hostToken, fixture.hostServerId),
                to: URI(string: "/api/channels/\(fixture.hostChannelId)/joint-invite/resend")
            )
            #expect(resent.status == .ok, Comment(rawValue: resent.body.string ?? ""))
            #expect(gapJSON(resent.body.string)["ok"] as? Bool == true)
            #expect(gapJSON(resent.body.string)["resentCount"] as? Int == 1)

            let accepted = try await client.send(
                .post, headers: gapHeaders(fixture.targetToken, fixture.targetServerId),
                to: URI(string: "/api/channels/joint-invites/\(fixture.inviteId)/accept")
            )
            #expect(accepted.status == .ok, Comment(rawValue: accepted.body.string ?? ""))
            fixture.targetChannelId = try #require(gapJSON(accepted.body.string)["id"] as? String)

            // Invite the host server's owner from the target projection. The
            // target server already projects into this joint, so no new
            // projection/channel is created.
            let invited = try await client.send(
                .post, headers: gapHeaders(fixture.targetToken, fixture.targetServerId),
                to: URI(string: "/api/channels/\(fixture.targetChannelId)/joint-invites")
            ) { request in
                request.body = .init(string: "{\"targetServerSlug\":\"\(fixture.hostSlug)\",\"invitedPeople\":[\"@joint-gap-host\"]}")
            }
            #expect(invited.status == .ok, Comment(rawValue: invited.body.string ?? ""))
            let invitedBody = gapJSON(invited.body.string)
            #expect(invitedBody["id"] as? String == fixture.targetChannelId)
            #expect(invitedBody["type"] as? String == "joint")
            let newInvites = invitedBody["jointInvites"] as? [[String: Any]] ?? []
            #expect(newInvites.count == 1)
            #expect(newInvites.first?["invitedUserId"] as? String == fixture.hostOwnerId)

            let hostInvites = try await client.get(
                URI(string: "/api/channels/joint-invites"),
                headers: gapHeaders(fixture.hostToken, fixture.hostServerId)
            )
            let hostRows = gapJSON(hostInvites.body.string)["invites"] as? [[String: Any]] ?? []
            #expect(hostRows.count == 1)
            #expect(hostRows.first?["fromServerName"] as? String == "Joint Gap Target")
            let hostInviteId = try #require(hostRows.first?["id"] as? String)
            let hostAccepted = try await client.send(
                .post, headers: gapHeaders(fixture.hostToken, fixture.hostServerId),
                to: URI(string: "/api/channels/joint-invites/\(hostInviteId)/accept")
            )
            #expect(hostAccepted.status == .ok, Comment(rawValue: hostAccepted.body.string ?? ""))

            let disconnected = try await client.send(
                .post, headers: gapHeaders(fixture.targetToken, fixture.targetServerId),
                to: URI(string: "/api/channels/\(fixture.targetChannelId)/disconnect")
            )
            #expect(disconnected.status == .ok, Comment(rawValue: disconnected.body.string ?? ""))
            #expect(disconnected.body.string == "{\"ok\":true}")

            // The dropped projection can no longer resend invites.
            let resendAfterDisconnect = try await client.send(
                .post, headers: gapHeaders(fixture.targetToken, fixture.targetServerId),
                to: URI(string: "/api/channels/\(fixture.targetChannelId)/joint-invite/resend")
            )
            #expect(resendAfterDisconnect.status == .notFound)
            #expect(gapJSON(resendAfterDisconnect.body.string)["error"] as? String == "Channel not found")

            // Invite validation order for an ordinary channel.
            let ordinary = accounts.oauth.createChannel(serverId: fixture.hostServerId, name: "ordinary-gap", creatorUserId: fixture.hostOwnerId)
            accounts.addPostableChannel(serverId: fixture.hostServerId, channelId: ordinary, memberId: fixture.hostOwnerId, name: "ordinary-gap")
            let notJoint = try await client.send(
                .post, headers: gapHeaders(fixture.hostToken, fixture.hostServerId),
                to: URI(string: "/api/channels/\(ordinary)/joint-invites")
            ) { request in
                request.body = .init(string: "{\"targetServerSlug\":\"\(fixture.targetSlug)\",\"invitedPeople\":[\"@joint-gap-target\"]}")
            }
            #expect(notJoint.status == .badRequest)
            #expect(gapJSON(notJoint.body.string)["error"] as? String == "Only joint channels can invite servers")

            let missingSlug = try await client.send(
                .post, headers: gapHeaders(fixture.hostToken, fixture.hostServerId),
                to: URI(string: "/api/channels/\(ordinary)/joint-invites")
            ) { request in
                request.body = .init(string: "{\"invitedPeople\":[\"@joint-gap-target\"]}")
            }
            #expect(missingSlug.status == .badRequest)
            #expect(gapJSON(missingSlug.body.string)["error"] as? String == "Invite server slug is required")
        }
    }
}

// MARK: - SOS and conversion gates

@Test func stopAllAgentsAndConversionRoutesPublishThePinnedDefaults() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-211111111201"
    let guestId = "11111111-1111-4111-8111-211111111202"
    let serverId = "33333333-3333-4333-8333-211111111201"
    for (id, email) in [(ownerId, "sos-owner@slock.test"), (guestId, "sos-guest@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "sos-gap", name: "SOS Gap", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "sos-gap-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "sos-gap-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await gapLogin(client, email: "sos-owner@slock.test")
            let guest = try await gapLogin(client, email: "sos-guest@slock.test")

            let stopped = try await client.send(
                .post, headers: gapHeaders(owner, serverId),
                to: URI(string: "/api/channels/\(channelId)/stop-all-agents")
            )
            #expect(stopped.status == .ok, Comment(rawValue: stopped.body.string ?? ""))
            #expect(stopped.body.string == "{\"ok\":true,\"stopped\":0,\"total\":0,\"results\":[]}")

            let refused = try await client.send(
                .post, headers: gapHeaders(guest, serverId),
                to: URI(string: "/api/channels/\(channelId)/stop-all-agents")
            )
            #expect(refused.status == .forbidden)
            #expect(gapJSON(refused.body.string)["error"] as? String
                == "The `controlAgentRuntime` capability is required to stop all agents in a channel")

            let conversionDisabled = "{\"error\":\"Channel to Joint conversion is not enabled\",\"code\":\"channel_to_joint_conversion_disabled\"}"
            for (method, path) in [
                (HTTPRequest.Method.get, "/api/channels/conversion-jobs/anything"),
                (.post, "/api/channels/conversion-jobs/anything/retry"),
                (.post, "/api/channels/conversion-jobs/anything/cancel"),
                (.post, "/api/channels/\(channelId)/convert-to-joint"),
            ] {
                let response = try await client.send(method, headers: gapHeaders(owner, serverId), to: URI(string: path))
                #expect(response.status == .notFound, Comment(rawValue: "\(path): \(response.body.string ?? "")"))
                #expect(response.body.string == conversionDisabled)
            }
        }
    }
}
