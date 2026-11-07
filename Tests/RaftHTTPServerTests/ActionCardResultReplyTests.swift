import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ActionCardReplyFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverName: String
    let ownerId: String
    let ownerEmail: String
    let ownerName: String
    let agentId: String
    let agentName: String
    let channelId: String
    let apiKey: String
}

private func makeActionCardReplyFixture(suffix: String) -> ActionCardReplyFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 700_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 980_000 + number)
    let ownerName = "card-reply-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "card-reply-\(suffix)", name: "Card Reply", ownerId: ownerId)
    let agentName = "card-reply-agent-\(suffix)"
    let agent = accounts.oauth.createAgent(serverId: serverId, name: agentName, runtime: "claude")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "card-reply-room", creatorUserId: ownerId)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: member, name: "card-reply-room")
    }
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read", "mentions"], name: "card-reply-\(suffix)")
    return ActionCardReplyFixture(
        accounts: accounts,
        serverId: serverId,
        serverName: "Card Reply",
        ownerId: ownerId,
        ownerEmail: "\(ownerName)@slock.test",
        ownerName: ownerName,
        agentId: agent,
        agentName: agentName,
        channelId: channel,
        apiKey: apiKey
    )
}

private func actionCardLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func actionCardPrepare(_ client: any Client, apiKey: String, target: String, name: String) async throws -> (status: HTTPResponse.Status, messageId: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/prepare-action") { request in
        request.body = .init(string: "{\"target\":\"\(target)\",\"action\":{\"type\":\"channel:create\",\"name\":\"\(name)\",\"visibility\":\"public\"}}")
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
    return (response.status, body?["messageId"] as? String ?? "")
}

private func actionCardExecute(_ client: any Client, token: String, serverId: String, messageId: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return try await client.send(.post, headers: headers, to: "/api/actions/\(messageId)/execute") { request in
        request.body = .init(string: "{\"expectedState\":\"prepared\"}")
    }
}

private func actionCardThread(_ client: any Client, token: String, serverId: String, channelId: String, messageId: String) async throws -> String {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.get(
        URI(string: "/api/channels/\(channelId)/threads?parentMessageIds=\(messageId)"),
        headers: headers
    )
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
    let summary = body?[messageId] as? [String: Any]
    return summary?["threadChannelId"] as? String ?? ""
}

private func actionCardMessages(_ client: any Client, token: String, serverId: String, threadId: String) async throws -> [[String: Any]] {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.get(URI(string: "/api/messages/channel/\(threadId)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
    return body?["messages"] as? [[String: Any]] ?? []
}

@Test func actionCardResultReplyIsDurableAndMentionedForTheManagedPreparer() async throws {
    let fixture = makeActionCardReplyFixture(suffix: "751")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await actionCardLogin(client, email: fixture.ownerEmail)

            let prepared = try await actionCardPrepare(client, apiKey: fixture.apiKey, target: "#card-reply-room", name: "card-reply-created")
            #expect(prepared.status == .created)
            #expect(!prepared.messageId.isEmpty)

            let executed = try await actionCardExecute(client, token: owner, serverId: fixture.serverId, messageId: prepared.messageId)
            #expect(executed.status == .ok)

            let threadId = try await actionCardThread(
                client,
                token: owner,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                messageId: prepared.messageId
            )
            #expect(!threadId.isEmpty)
            #expect(fixture.accounts.oauth.channelKind(channelId: threadId) == "thread")
            #expect(fixture.accounts.oauth.channelServerId(channelId: threadId) == fixture.serverId)
            #expect(fixture.accounts.oauth.channelParentChannelId(id: threadId) == fixture.channelId)
            let replies = try await actionCardMessages(client, token: owner, serverId: fixture.serverId, threadId: threadId)
            let reply = try #require(replies.first { ($0["content"] as? String)?.hasPrefix("@\(fixture.agentName) ") == true })
            let content = reply["content"] as? String ?? ""
            #expect(content.contains("executed by @\(fixture.ownerName) on \(fixture.serverName)"))
            #expect(content.contains("created channel #card-reply-created"))
            #expect(content.contains(String(prepared.messageId.prefix(8))))

            let facts = fixture.accounts.inboxFacts(messageId: reply["id"] as? String ?? "", receiverIds: [fixture.agentId, fixture.ownerId])
            let agentFact = facts.first { $0.receiverType == "agent" && $0.receiverId == fixture.agentId }
            #expect(agentFact?.personalMention == true)
            #expect(agentFact?.unreadEligible == true)
            let humanFacts = facts.filter { $0.receiverType == "user" && $0.receiverId == fixture.ownerId }
            #expect(!humanFacts.isEmpty)
            #expect(humanFacts.allSatisfy { $0.unreadEligible == false })

            var mentionHeaders = HTTPFields()
            mentionHeaders[.authorization] = "Bearer \(fixture.apiKey)"
            let mentions = try await client.get("/internal/agent-api/mentions", headers: mentionHeaders)
            #expect(mentions.status == .ok)
            let mentionBody = (try? JSONSerialization.jsonObject(with: Data((mentions.body.string ?? "").utf8))) as? [String: Any]
            let mentionIds = (mentionBody?["mentions"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String }
            #expect(mentionIds.contains(reply["id"] as? String ?? ""))

            let failing = try await actionCardPrepare(client, apiKey: fixture.apiKey, target: "#card-reply-room", name: "card-reply-created")
            #expect(failing.status == .created)
            let failed = try await actionCardExecute(client, token: owner, serverId: fixture.serverId, messageId: failing.messageId)
            #expect(failed.status == .conflict)
            let failThread = try await actionCardThread(
                client,
                token: owner,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                messageId: failing.messageId
            )
            let failReplies = try await actionCardMessages(client, token: owner, serverId: fixture.serverId, threadId: failThread)
            let failReply = try #require(failReplies.first { ($0["content"] as? String)?.hasPrefix("@\(fixture.agentName) ") == true })
            let failContent = failReply["content"] as? String ?? ""
            #expect(failContent.contains("failed when"))
            #expect(failContent.contains("still pending and can be retried"))
        }
    }
}

@Test func jointActionCardReplyReachesTheExternalPreparerThroughEvents() async throws {
    let accounts = EmailLoginDirectory()
    let hostOwnerId = "11111111-1111-4111-8111-111111111902"
    let peerOwnerId = "11111111-1111-4111-8111-111111111903"
    let dualId = "11111111-1111-4111-8111-111111111904"
    let hostServerId = "33333333-3333-4333-8333-333333333905"
    let peerServerId = "33333333-3333-4333-8333-333333333906"
    for (id, email, role) in [
        (hostOwnerId, "reply-host-owner@slock.test", "owner"),
        (peerOwnerId, "reply-peer-owner@slock.test", "owner"),
        (dualId, "reply-dual@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            if id == hostOwnerId {
                accounts.oauth.addOwnedServer(id: hostServerId, slug: "reply-host", name: "Reply Host", ownerId: id)
            } else {
                accounts.oauth.addOwnedServer(id: peerServerId, slug: "reply-peer", name: "Reply Peer", ownerId: id)
            }
        }
    }
    accounts.oauth.addMember(serverId: hostServerId, userId: peerOwnerId, role: "member")
    accounts.oauth.addMember(serverId: peerServerId, userId: hostOwnerId, role: "member")
    accounts.oauth.addMember(serverId: hostServerId, userId: dualId, role: "member")
    accounts.oauth.addMember(serverId: peerServerId, userId: dualId, role: "member")

    let canonical = accounts.oauth.createChannel(serverId: hostServerId, name: "reply-joint-storage", creatorUserId: hostOwnerId)
    accounts.addPostableChannel(serverId: hostServerId, channelId: canonical, memberId: hostOwnerId, name: "reply-joint-storage")
    let hostProjection = accounts.oauth.createChannel(serverId: hostServerId, name: "reply-joint", creatorUserId: hostOwnerId, type: "joint")
    let peerProjection = accounts.oauth.createChannel(serverId: peerServerId, name: "reply-joint", creatorUserId: peerOwnerId, type: "joint")
    for (channel, server, owner) in [(hostProjection, hostServerId, hostOwnerId), (peerProjection, peerServerId, peerOwnerId)] {
        for member in [owner, dualId] {
            accounts.addPostableChannel(serverId: server, channelId: channel, memberId: member, kind: "joint", name: "reply-joint")
        }
        accounts.oauth.addChannelHuman(channelId: channel, userId: owner)
        accounts.oauth.addChannelHuman(channelId: channel, userId: dualId)
    }
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: canonical, serverId: hostServerId)
    accounts.addJointChannelProjection(localChannelId: peerProjection, canonicalChannelId: canonical, serverId: peerServerId)

    let agentName = "ReplyExternal-752"
    let agent = accounts.oauth.createAgent(serverId: peerServerId, name: agentName, runtime: "external")
    accounts.addPostableChannel(serverId: peerServerId, channelId: peerProjection, memberId: agent, kind: "joint", name: "reply-joint")
    accounts.oauth.addChannelAgent(channelId: peerProjection, agentId: agent)
    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read", "mentions"], name: "reply-external-752")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let dual = try await actionCardLogin(client, email: "reply-dual@slock.test")
            let hostOwner = try await actionCardLogin(client, email: "reply-host-owner@slock.test")

            var eventHeaders = HTTPFields()
            eventHeaders[.authorization] = "Bearer \(apiKey)"
            _ = try await client.get("/internal/agent-api/events", headers: eventHeaders)

            let prepared = try await actionCardPrepare(client, apiKey: apiKey, target: "#reply-joint", name: "reply-joint-created")
            #expect(prepared.status == .created)

            let executed = try await actionCardExecute(client, token: dual, serverId: hostServerId, messageId: prepared.messageId)
            #expect(executed.status == .ok)

            let hostThread = try await actionCardThread(
                client,
                token: hostOwner,
                serverId: hostServerId,
                channelId: hostProjection,
                messageId: prepared.messageId
            )
            #expect(!hostThread.isEmpty)
            #expect(accounts.oauth.channelKind(channelId: hostThread) == "thread")
            #expect(accounts.oauth.channelServerId(channelId: hostThread) == hostServerId)
            #expect(accounts.oauth.channelParentChannelId(id: hostThread) == hostProjection)
            let replies = try await actionCardMessages(client, token: hostOwner, serverId: hostServerId, threadId: hostThread)
            let reply = try #require(replies.first { ($0["content"] as? String)?.hasPrefix("@\(agentName) ") == true })
            let replyId = reply["id"] as? String ?? ""
            let content = reply["content"] as? String ?? ""
            #expect(content.contains("created channel #reply-joint-created"))
            #expect(content.contains("on Reply Peer"))

            let events = try await client.get("/internal/agent-api/events", headers: eventHeaders)
            #expect(events.status == .ok)
            let body = (try? JSONSerialization.jsonObject(with: Data((events.body.string ?? "").utf8))) as? [String: Any]
            let eventRows = body?["events"] as? [[String: Any]] ?? []
            let event = try #require(eventRows.first { $0["message_id"] as? String == replyId })
            #expect((event["content"] as? String)?.contains("created channel #reply-joint-created") == true)
        }
    }
}
