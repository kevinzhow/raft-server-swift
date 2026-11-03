import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct GetJoinedFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let otherId: String
}

private func makeGetJoinedFixture() -> GetJoinedFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111651"
    let otherId = "11111111-1111-4111-8111-111111111652"
    let serverId = "33333333-3333-4333-8333-333333333687"
    for (id, email) in [(ownerId, "joined-owner@slock.test"), (otherId, "joined-other@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "get-joined", name: "Get Joined", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")
    return GetJoinedFixture(accounts: accounts, serverId: serverId, ownerId: ownerId, otherId: otherId)
}

private func joinedChannel(
    _ client: any Client,
    _ f: GetJoinedFixture,
    channelId: String,
    as userId: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.accounts.mintAccessTokenForTesting(userId: userId))"
    headers[HTTPField.Name("X-Server-Id")!] = f.serverId
    let response = try await client.send(.get, headers: headers, to: URI(string: "/api/channels/\(channelId)"))
    let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

@Test func channelDetailReportsJoinedPerRequester() async throws {
    let f = makeGetJoinedFixture()
    let regular = f.accounts.oauth.createChannel(serverId: f.serverId, name: "general", creatorUserId: f.ownerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: regular, memberId: f.ownerId, name: "general")
    f.accounts.oauth.addChannelHuman(channelId: regular, userId: f.ownerId)
    let secret = f.accounts.oauth.createChannel(serverId: f.serverId, name: "secret", creatorUserId: f.ownerId, type: "private")
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: secret, memberId: f.ownerId, kind: "private", name: "secret")
    f.accounts.oauth.addChannelHuman(channelId: secret, userId: f.ownerId)
    let all = f.accounts.oauth.createChannel(serverId: f.serverId, name: "all", creatorUserId: f.ownerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: all, memberId: f.ownerId, name: "all")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let ownerRegular = try await joinedChannel(client, f, channelId: regular, as: f.ownerId)
            #expect(ownerRegular.status == .ok)
            #expect(ownerRegular.body["joined"] as? Bool == true)
            #expect(ownerRegular.body["id"] as? String == regular)
            let ownerSecret = try await joinedChannel(client, f, channelId: secret, as: f.ownerId)
            #expect(ownerSecret.status == .ok)
            #expect(ownerSecret.body["joined"] as? Bool == true)
            let otherRegular = try await joinedChannel(client, f, channelId: regular, as: f.otherId)
            #expect(otherRegular.body["joined"] as? Bool == false, "a server member who did not join must not read as joined")
            let implicitAll = try await joinedChannel(client, f, channelId: all, as: f.otherId)
            #expect(implicitAll.status == .ok)
            #expect(implicitAll.body["name"] as? String == "all")
            #expect(implicitAll.body["joined"] as? Bool == true, "the enabled #all channel is joined implicitly")

            f.accounts.oauth.addChannelHuman(channelId: regular, userId: f.otherId)
            let afterAdd = try await joinedChannel(client, f, channelId: regular, as: f.otherId)
            #expect(afterAdd.body["joined"] as? Bool == true)

            let notAChannel = try await joinedChannel(client, f, channelId: "threads", as: f.ownerId)
            #expect(notAChannel.status == .notFound)
            #expect(notAChannel.body["error"] as? String == "Channel not found")
        }
    }
}

@Test func threadDetailHydratesOnlyWhenItsParentIsVisible() async throws {
    let f = makeGetJoinedFixture()
    let publicParent = f.accounts.oauth.createChannel(serverId: f.serverId, name: "regular-parent", creatorUserId: f.ownerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: publicParent, memberId: f.ownerId, name: "regular-parent")
    f.accounts.oauth.addChannelHuman(channelId: publicParent, userId: f.ownerId)
    let publicParentMessage = f.accounts.addChannelMessageForTesting(channelId: publicParent, content: "public parent", senderId: f.ownerId)
    let publicThread = f.accounts.oauth.createThreadChannel(parentChannelId: publicParent, parentMessageId: publicParentMessage)
    f.accounts.addPostableChannel(
        serverId: f.serverId, channelId: publicThread, memberId: f.ownerId, kind: "thread",
        parentChannelId: publicParent, parentMessageId: publicParentMessage, name: "thread"
    )

    let privateParent = f.accounts.oauth.createChannel(serverId: f.serverId, name: "private-parent", creatorUserId: f.ownerId, type: "private")
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: privateParent, memberId: f.ownerId, kind: "private", name: "private-parent")
    f.accounts.oauth.addChannelHuman(channelId: privateParent, userId: f.ownerId)
    let privateParentMessage = f.accounts.addChannelMessageForTesting(channelId: privateParent, content: "secret parent", senderId: f.ownerId)
    let privateThread = f.accounts.oauth.createThreadChannel(parentChannelId: privateParent, parentMessageId: privateParentMessage)
    f.accounts.addPostableChannel(
        serverId: f.serverId, channelId: privateThread, memberId: f.ownerId, kind: "thread",
        parentChannelId: privateParent, parentMessageId: privateParentMessage, name: "thread"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let visible = try await joinedChannel(client, f, channelId: publicThread, as: f.otherId)
            #expect(visible.status == .ok, "a server member who can read the regular parent can hydrate its thread")
            #expect(visible.body["id"] as? String == publicThread)
            #expect(visible.body["type"] as? String == "thread")

            let cloaked = try await joinedChannel(client, f, channelId: privateThread, as: f.otherId)
            #expect(cloaked.status == .notFound, "a private parent must not leak its thread metadata")
            #expect(cloaked.body["error"] as? String == "Channel not found")
        }
    }
}

@Test func dmDetailHydratesDMParticipantsEvenAfterAgentDeletion() async throws {
    let f = makeGetJoinedFixture()
    let humanDm = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.otherId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: humanDm, memberId: f.ownerId, kind: "dm", name: "dm")
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: humanDm, memberId: f.otherId, kind: "dm", name: "dm")
    f.accounts.oauth.addChannelHuman(channelId: humanDm, userId: f.ownerId)
    f.accounts.oauth.addChannelHuman(channelId: humanDm, userId: f.otherId)
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "removed-search-peer", creatorUserId: f.ownerId, runtime: "codex")
    let agentDm = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: agent)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: agentDm, memberId: f.ownerId, kind: "dm", name: "dm")
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: agentDm, memberId: agent, kind: "dm", name: "dm")
    f.accounts.oauth.addChannelHuman(channelId: agentDm, userId: f.ownerId)
    f.accounts.oauth.addChannelAgent(channelId: agentDm, agentId: agent)
    f.accounts.oauth.deleteAgent(id: agent)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let human = try await joinedChannel(client, f, channelId: humanDm, as: f.ownerId)
            #expect(human.status == .ok)
            #expect(human.body["type"] as? String == "dm")
            #expect(human.body["joined"] as? Bool == true, "DM membership is implicit by participation")

            let deletedPeer = try await joinedChannel(client, f, channelId: agentDm, as: f.ownerId)
            #expect(deletedPeer.status == .ok, "a participant DM still hydrates after its agent peer is deleted")
            #expect(deletedPeer.body["id"] as? String == agentDm)
            #expect(deletedPeer.body["type"] as? String == "dm")
            #expect(deletedPeer.body["joined"] as? Bool == true)
            #expect(deletedPeer.body["peerType"] as? String == "agent")
            #expect(deletedPeer.body["peerId"] as? String == agent)
            #expect(deletedPeer.body["peerName"] as? String == "removed-search-peer")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.accounts.mintAccessTokenForTesting(userId: f.ownerId))"
            headers[HTTPField.Name("X-Server-Id")!] = f.serverId
            let list = try await client.get(URI(string: "/api/channels/dm"), headers: headers)
            let entries = (try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            #expect(!entries.contains { ($0["id"] as? String) == agentDm }, "detail hydration must not resurrect deleted-agent DMs in the DM list")
        }
    }
}
