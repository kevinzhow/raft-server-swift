import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AgentInboxFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerName: String
    let agentId: String
    let apiKey: String
    let generalId: String
    let dmId: String
    let threadId: String
    let dmThreadId: String
    let dmParentId: String
    let threadParentId: String
    let dmParentAt: Date
}

private func makeAgentInboxFixture(suffix: String) -> AgentInboxFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 150_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 150_000 + number)
    let ownerName = "inbox-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-\(suffix)", name: "Inbox List", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "InboxBot-\(suffix)", runtime: "claude")

    let general = accounts.oauth.createChannel(serverId: serverId, name: "general-\(suffix)", creatorUserId: ownerId)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: general, memberId: member, name: "general-\(suffix)")
    }
    accounts.oauth.addChannelHuman(channelId: general, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: general, agentId: agent)

    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: agent)
    accounts.oauth.removeChannelHuman(channelId: dm, userId: agent)
    accounts.oauth.addChannelAgent(channelId: dm, agentId: agent)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: dm, memberId: member, kind: "dm", name: "dm")
    }

    _ = accounts.addChannelMessageForTesting(channelId: general, content: "hello general", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(channelId: dm, content: "hello dm", senderId: ownerId)
    let threadParent = accounts.addChannelMessageForTesting(channelId: general, content: "thread parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: general, parentMessageId: threadParent)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: member, kind: "thread", parentChannelId: general, parentMessageId: threadParent, name: "thread")
    }
    accounts.oauth.addChannelAgent(channelId: thread, agentId: agent)
    let threadReply = accounts.addChannelMessageForTesting(channelId: thread, content: "thread reply mentioning the agent", senderId: ownerId)
    accounts.followThreadForTesting(serverId: serverId, userId: agent, threadChannelId: thread, parentMessageId: threadParent)
    accounts.addStoredMentionForTesting(channelId: thread, messageId: threadReply, targetId: agent, targetType: "agent")

    let dmParentAt = Date()
    let dmParent = accounts.addChannelMessageForTesting(channelId: dm, content: "dm thread parent", senderId: ownerId, createdAt: dmParentAt)
    let dmThread = accounts.oauth.createThreadChannel(parentChannelId: dm, parentMessageId: dmParent)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: dmThread, memberId: member, kind: "thread", parentChannelId: dm, parentMessageId: dmParent, name: "thread")
    }
    accounts.oauth.addChannelAgent(channelId: dmThread, agentId: agent)
    _ = accounts.addChannelMessageForTesting(channelId: dmThread, content: "dm thread reply", senderId: ownerId)
    accounts.followThreadForTesting(serverId: serverId, userId: agent, threadChannelId: dmThread, parentMessageId: dmParent)


    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "inbox-list-\(suffix)")
    return AgentInboxFixture(
        accounts: accounts,
        serverId: serverId,
        ownerName: ownerName,
        agentId: agent,
        apiKey: apiKey,
        generalId: general,
        dmId: dm,
        threadId: thread,
        dmThreadId: dmThread,
        dmParentId: dmParent,
        threadParentId: threadParent,
        dmParentAt: dmParentAt
    )
}

private func agentInboxGet(_ client: any Client, key: String, query: String = "") async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    let response = try await client.get(URI(string: "/internal/agent-api/inbox/conversations\(query)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

@Test func agentInboxListsOfferedConversationsNewestFirstAndFiltersMentions() async throws {
    let fixture = makeAgentInboxFixture(suffix: "811")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let dmThreadTarget = "dm:@\(fixture.ownerName):\(String(fixture.dmParentId.prefix(8)))"
            let threadTarget = "#general-811:\(String(fixture.threadParentId.prefix(8)))"
            let dmTarget = "dm:@\(fixture.ownerName)"

            let first = try await agentInboxGet(client, key: fixture.apiKey, query: "?limit=2")
            #expect(first.status == .ok)
            #expect(first.body["view"] as? String == "unread")
            #expect(first.body["totals"] as? NSDictionary == ["conversations": 4, "dms": 1, "mentions": 1] as NSDictionary)
            let firstItems = first.body["items"] as? [[String: Any]] ?? []
            #expect(firstItems.map { $0["target"] as? String } == [dmThreadTarget, dmTarget])
            #expect(first.body["hasMore"] as? Bool == true)
            let nextBefore = first.body["nextBeforeSeq"] as? Int
            #expect(nextBefore != nil)

            let dmItem = firstItems[1]
            #expect(dmItem["kind"] as? String == "dm")
            #expect(dmItem["unread"] as? Int == 2)
            #expect(dmItem["mentions"] as? Int == 0)
            #expect(dmItem["lastReadSeq"] as? Int == 0)
            #expect(dmItem["latestSenderName"] as? String == fixture.ownerName)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(dmItem["latestAt"] as? String == formatter.string(from: fixture.dmParentAt))

            let second = try await agentInboxGet(client, key: fixture.apiKey, query: "?limit=2&before_seq=\(nextBefore ?? 0)")
            #expect(second.status == .ok)
            let secondItems = second.body["items"] as? [[String: Any]] ?? []
            #expect(secondItems.map { $0["target"] as? String } == [threadTarget, "#general-811"])
            #expect(secondItems.map { $0["kind"] as? String } == ["thread", "channel"])
            #expect(secondItems.first?["unread"] as? Int == 1)
            #expect(secondItems.first?["mentions"] as? Int == 1)
            #expect(second.body["hasMore"] as? Bool == false)
            #expect(second.body["nextBeforeSeq"] is NSNull)

            let mentions = try await agentInboxGet(client, key: fixture.apiKey, query: "?view=mentions")
            #expect(mentions.status == .ok)
            #expect(mentions.body["view"] as? String == "mentions")
            #expect((mentions.body["items"] as? [[String: Any]] ?? []).map { $0["target"] as? String } == [threadTarget])
            #expect(mentions.body["totals"] as? NSDictionary == ["conversations": 4, "dms": 1, "mentions": 1] as NSDictionary)

            #expect(try await agentInboxGet(client, key: fixture.apiKey, query: "?view=everything").status == .badRequest)
            #expect(try await agentInboxGet(client, key: fixture.apiKey, query: "?before_seq=abc").status == .badRequest)
            #expect(try await agentInboxGet(client, key: fixture.apiKey, query: "?limit=0").status == .badRequest)

            fixture.accounts.setAgentInboxAvailableForTesting(false)
            let unavailable = try await agentInboxGet(client, key: fixture.apiKey)
            #expect(unavailable.status == .serviceUnavailable)
            #expect(unavailable.body["code"] as? String == "INBOX_UNAVAILABLE")
            fixture.accounts.setAgentInboxAvailableForTesting(nil)
            #expect(try await agentInboxGet(client, key: fixture.apiKey).status == .ok)
        }
    }
}

@Test func jointThreadInboxTargetUsesTheLocalParentAndCanonicalShortId() async throws {
    let accounts = EmailLoginDirectory()
    let hostOwnerId = "11111111-1111-4111-8111-111111112811"
    let peerOwnerId = "11111111-1111-4111-8111-111111112812"
    let hostServerId = "33333333-3333-4333-8333-333333335811"
    let peerServerId = "33333333-3333-4333-8333-333333335812"
    accounts.addAccount(id: hostOwnerId, email: "joint-inbox-host@slock.test", password: "password123")
    accounts.markEmailVerified(userId: hostOwnerId)
    accounts.addAccount(id: peerOwnerId, email: "joint-inbox-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerOwnerId)
    accounts.oauth.addOwnedServer(id: hostServerId, slug: "joint-inbox-host", name: "Joint A", ownerId: hostOwnerId)
    accounts.oauth.addOwnedServer(id: peerServerId, slug: "joint-inbox-peer", name: "Joint B", ownerId: peerOwnerId)
    let agent = accounts.oauth.createAgent(serverId: peerServerId, name: "JointInboxBot", runtime: "claude")

    let canonical = accounts.oauth.createChannel(serverId: hostServerId, name: "joint-canonical", creatorUserId: hostOwnerId)
    let localB = accounts.oauth.createChannel(serverId: peerServerId, name: "joint-b-local", creatorUserId: peerOwnerId, type: "joint")
    for member in [peerOwnerId, agent] {
        accounts.addPostableChannel(serverId: peerServerId, channelId: localB, memberId: member, kind: "joint", name: "joint-b-local")
    }
    accounts.oauth.addChannelAgent(channelId: localB, agentId: agent)

    let parentAt = Date()
    let parent = accounts.addChannelMessageForTesting(channelId: canonical, content: "joint parent", senderId: hostOwnerId, createdAt: parentAt)
    let canonicalThread = accounts.oauth.createThreadChannel(parentChannelId: canonical, parentMessageId: parent)
    _ = accounts.addChannelMessageForTesting(channelId: canonicalThread, content: "joint thread reply", senderId: hostOwnerId)

    let threadB = accounts.oauth.createThreadChannel(parentChannelId: localB, parentMessageId: parent)
    accounts.addPostableChannel(serverId: peerServerId, channelId: threadB, memberId: agent, kind: "thread", parentChannelId: localB, parentMessageId: parent, name: "thread")
    accounts.oauth.addChannelAgent(channelId: threadB, agentId: agent)
    accounts.addJointChannelProjection(localChannelId: threadB, canonicalChannelId: canonicalThread, serverId: peerServerId)
    accounts.followThreadForTesting(serverId: peerServerId, userId: agent, threadChannelId: threadB, parentMessageId: parent)
    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "joint-inbox")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let result = try await agentInboxGet(client, key: apiKey)
            #expect(result.status == .ok)
            let items = result.body["items"] as? [[String: Any]] ?? []
            #expect(items.map { $0["target"] as? String } == ["#joint-b-local:\(String(parent.prefix(8)))"])
            #expect(items.first?["latestSenderName"] as? String == "joint-inbox-host")
        }
    }
}
