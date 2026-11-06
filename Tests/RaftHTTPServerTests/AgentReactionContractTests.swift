import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ReactionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let agentName: String
    let agentKey: String
    let channelId: String
    let privateChannelId: String
}

private func makeReactionFixture(_ suffix: String) -> ReactionFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001220\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001220\(suffix)"
    accounts.addAccount(id: ownerId, email: "reaction-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "reaction-\(suffix)", name: "Reaction \(suffix)", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "reaction-room-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: "reaction-room-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let privateChannelId = accounts.oauth.createChannel(serverId: serverId, name: "reaction-private-\(suffix)", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: "reaction-private-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: ownerId)
    let agentName = "ReactionBot\(suffix)"
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    return ReactionFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        agentId: agentId,
        agentName: agentName,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "reactions"], name: "reaction-\(suffix)"),
        channelId: channelId,
        privateChannelId: privateChannelId
    )
}

private func reactionRequest(
    _ client: any Client,
    f: ReactionFixture,
    messageRef: String,
    emoji: String = "👀",
    remove: Bool = false
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    headers[.contentType] = "application/json"
    let response = try await client.send(remove ? .delete : .post, headers: headers, to: URI(string: "/internal/agent-api/messages/\(messageRef)/reactions")) { request in
        request.body = .init(string: "{\"emoji\":\"\(emoji)\"}")
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func agentReactionsCloakPrivateMessagesAndRejectMalformedIds() async throws {
    let f = makeReactionFixture("901")
    let privateChat = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: privateChat, channelId: f.privateChannelId, senderId: f.ownerId, content: "private chat reaction probe")
    let privateSystem = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: privateSystem, channelId: f.privateChannelId, senderId: "system", content: "private system reaction probe", messageType: "system", senderType: "system")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for reference in [privateChat, privateSystem] {
                let add = try await reactionRequest(client, f: f, messageRef: reference)
                #expect(add.status == .notFound, "private message existence is cloaked")
                let remove = try await reactionRequest(client, f: f, messageRef: reference, remove: true)
                #expect(remove.status == .notFound)
            }

            let malformed = try await reactionRequest(client, f: f, messageRef: "not-a-message-id")
            #expect(malformed.status == .badRequest)
            #expect(malformed.body["error"] as? String == "Message id must be a full UUID or 8-character short id")
        }
    }
}

@Test func agentReactionsAddIdempotentlyAndRemove() async throws {
    let f = makeReactionFixture("902")
    let message = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: message, channelId: f.channelId, senderId: f.ownerId, content: "agent-api reaction target")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await reactionRequest(client, f: f, messageRef: message)
            #expect(first.status == .ok)
            let reactions = try #require(first.body["reactions"] as? [[String: Any]])
            #expect(reactions.count == 1)
            #expect(reactions[0]["emoji"] as? String == "👀")
            #expect(reactions[0]["count"] as? Int == 1)
            #expect(reactions[0]["reactorIds"] as? [String] == [f.agentId])
            #expect(reactions[0]["reactorNames"] as? [String] == [f.agentName])

            let second = try await reactionRequest(client, f: f, messageRef: message)
            #expect(second.status == .ok)
            let secondReactions = try #require(second.body["reactions"] as? [[String: Any]])
            #expect(secondReactions.count == 1, "adding the same reaction is idempotent")
            #expect(secondReactions[0]["count"] as? Int == 1)

            let remove = try await reactionRequest(client, f: f, messageRef: message, remove: true)
            #expect(remove.status == .ok)
            #expect((remove.body["reactions"] as? [[String: Any]])?.isEmpty == true)
        }
    }
}

@Test func agentReactionsWorkOnThreadRepliesThroughParentMembership() async throws {
    let f = makeReactionFixture("903")
    let parent = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: parent, channelId: f.channelId, senderId: f.ownerId, content: "reaction thread parent")
    let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: f.channelId, parentMessageId: parent)
    f.accounts.addPostableChannel(
        serverId: f.serverId,
        channelId: threadId,
        memberId: f.ownerId,
        kind: "thread",
        parentChannelId: f.channelId,
        parentMessageId: parent,
        name: "thread"
    )
    let reply = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: reply, channelId: threadId, senderId: f.ownerId, content: "reaction thread reply")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let add = try await reactionRequest(client, f: f, messageRef: String(reply.prefix(8)))
            #expect(add.status == .ok)
            let reactions = try #require(add.body["reactions"] as? [[String: Any]])
            #expect(reactions.first?["reactorIds"] as? [String] == [f.agentId])

            let remove = try await reactionRequest(client, f: f, messageRef: String(reply.prefix(8)), remove: true)
            #expect(remove.status == .ok)
            #expect((remove.body["reactions"] as? [[String: Any]])?.isEmpty == true)
        }
    }
}

@Test func agentReactionsResolveOnlyVisibleShortIdCollisions() async throws {
    let f = makeReactionFixture("904")
    f.accounts.insertHumanMessage(
        id: "cccccccc-1111-4111-8111-111111111111",
        channelId: f.privateChannelId,
        senderId: f.ownerId,
        content: "private reaction collision one"
    )
    let visibleCollision = "cccccccc-3333-4333-8333-333333333333"
    f.accounts.insertHumanMessage(
        id: visibleCollision,
        channelId: f.channelId,
        senderId: f.ownerId,
        content: "visible reaction collision"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let add = try await reactionRequest(client, f: f, messageRef: "cccccccc")
            #expect(add.status == .ok, "only the visible message may match the short id")
            let reactions = try #require(add.body["reactions"] as? [[String: Any]])
            #expect(reactions.first?["reactorIds"] as? [String] == [f.agentId])
            #expect(visibleCollision.hasPrefix("cccccccc"))
        }
    }
}

@Test func agentReactionsRejectAnAmbiguousVisibleShortId() async throws {
    let f = makeReactionFixture("905")
    f.accounts.insertHumanMessage(
        id: "dddddddd-1111-4111-8111-111111111111",
        channelId: f.channelId,
        senderId: f.ownerId,
        content: "ambiguous reaction one"
    )
    f.accounts.insertHumanMessage(
        id: "dddddddd-2222-4222-8222-222222222222",
        channelId: f.channelId,
        senderId: f.ownerId,
        content: "ambiguous reaction two"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let add = try await reactionRequest(client, f: f, messageRef: "dddddddd")
            #expect(add.status == .badRequest)
            #expect(add.body["errorCode"] as? String == "AMBIGUOUS_ID")
        }
    }
}
