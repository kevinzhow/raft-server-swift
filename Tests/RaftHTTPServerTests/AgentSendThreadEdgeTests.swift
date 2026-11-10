import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ThreadEdgeFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001112001"
    let ownerId = "11111111-1111-4111-8111-000001112001"
    var agentId = ""
    var channelId = ""
    var channelName = "thread-edge-room"
    var key = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "thread-edge-owner@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "thread-edge", name: "Thread Edge", ownerId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "ThreadEdgeBot", creatorUserId: ownerId, runtime: "claude")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId, type: "channel")
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName, humanIds: [ownerId], agentIds: [agentId])
        key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "thread-edge")
    }
}

private func edgeSend(_ client: any Client, key: String, target: String, content: String, seen: Int) async throws -> (ClientResponse, [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    let data = try JSONSerialization.data(withJSONObject: ["target": target, "content": content, "seenUpToSeq": seen])
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
        request.body = .init(data: data)
    }
    return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
}

@Test func threadEdgeCasesReuseCloakAndRequireMembership() async throws {
    var fixture = ThreadEdgeFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let parent = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "opened thread parent")
    let parentSeq = accounts.messageSeqForTesting(messageId: parent) ?? 0
    let existingThread = accounts.oauth.createThreadChannel(parentChannelId: fixture.channelId, parentMessageId: parent)
    accounts.addThreadChannel(serverId: fixture.serverId, threadChannelId: existingThread, parentChannelId: fixture.channelId, parentMessageId: parent, memberId: fixture.ownerId)
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: existingThread, memberId: fixture.agentId, kind: "thread", parentChannelId: fixture.channelId, parentMessageId: parent, name: "thread")

    let privateChannelId = accounts.oauth.createChannel(serverId: fixture.serverId, name: "hidden-thread-parent", creatorUserId: fixture.ownerId, type: "private")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: fixture.ownerId)
    let hiddenParent = accounts.addHumanMessageForTesting(channelId: privateChannelId, senderId: fixture.ownerId, content: "hidden private parent")
    let hiddenSeq = accounts.messageSeqForTesting(messageId: hiddenParent) ?? 0

    let dmId = accounts.seedDMForTesting(serverId: fixture.serverId, humanUserId: fixture.ownerId, agentId: fixture.agentId)
    accounts.oauth.removeChannelHuman(channelId: dmId, userId: fixture.agentId)
    accounts.oauth.addChannelAgent(channelId: dmId, agentId: fixture.agentId)
    #expect(accounts.oauth.channelAgentIds(channelId: dmId) == [fixture.agentId])
    #expect(accounts.oauth.channelHumanIds(channelId: dmId) == [fixture.ownerId])
    let dmParent = accounts.addHumanMessageForTesting(channelId: dmId, senderId: fixture.ownerId, content: "fresh DM thread parent")
    let dmSeq = accounts.messageSeqForTesting(messageId: dmParent) ?? 0

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let reused = try await edgeSend(client, key: fixture.key, target: "#\(fixture.channelName):\(parent.prefix(8))", content: "reply in opened empty thread", seen: parentSeq)
            #expect(reused.0.status == .ok)
            let reusedId = try #require(reused.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: reusedId) == existingThread)

            let privateTarget = "#hidden-thread-parent:\(hiddenParent.prefix(8))"
            let cloaked = try await edgeSend(client, key: fixture.key, target: privateTarget, content: "should cloak", seen: hiddenSeq)
            #expect(cloaked.0.status == .notFound)
            #expect(((cloaked.1["error"] as? String) ?? "").contains("Thread target not found or not replyable"))

            let missing = try await edgeSend(client, key: fixture.key, target: "#\(fixture.channelName):deadbeef", content: "missing parent", seen: 0)
            #expect(missing.0.status == .notFound)
            #expect(((missing.1["error"] as? String) ?? "").contains("parent message must exist"))

            let dmReply = try await edgeSend(client, key: fixture.key, target: "dm:@thread-edge-owner:\(dmParent.prefix(8))", content: "first DM thread reply", seen: dmSeq)
            #expect(dmReply.0.status == .ok)
            let dmReplyId = try #require(dmReply.1["messageId"] as? String)
            let dmThreadChannel = try #require(accounts.messageChannelIdForTesting(messageId: dmReplyId))
            #expect(dmThreadChannel != dmId)
            #expect(accounts.oauth.channelType(id: dmThreadChannel) == "thread")
            let followers = accounts.threadFollowerIdsForTesting(threadChannelId: dmThreadChannel)
            #expect(followers.contains(fixture.ownerId))
            #expect(followers.contains(fixture.agentId))

            var outsider = EmailLoginDirectory()
            outsider.oauth.addOwnedServer(id: "33333333-3333-4333-8333-000001112002", slug: "outsider", name: "Outsider", ownerId: fixture.ownerId)
            _ = outsider
        }
    }
}

@Test func threadReplyRequiresParentChannelMembership() async throws {
    var fixture = ThreadEdgeFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let outsiderId = accounts.oauth.createAgent(serverId: fixture.serverId, name: "ThreadOutsider", creatorUserId: fixture.ownerId, runtime: "claude")
    let outsiderKey = accounts.mintAgentCredential(agentId: outsiderId, scopes: ["send", "read"], name: "thread-outsider")
    let parent = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "members only thread parent")
    let parentSeq = accounts.messageSeqForTesting(messageId: parent) ?? 0
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let denied = try await edgeSend(client, key: outsiderKey, target: "#\(fixture.channelName):\(parent.prefix(8))", content: "should not send", seen: parentSeq)
            #expect(denied.0.status == .forbidden)
            #expect(((denied.1["error"] as? String) ?? "").contains("not a member of the parent channel"))
        }
    }
}

@Test func freshAgentDmsRetainTypedMembersAndCommitThreadFollowersThroughPublicSends() async throws {
    var fixture = ThreadEdgeFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let peerId = accounts.oauth.createAgent(serverId: fixture.serverId, name: "ThreadEdgePeer", creatorUserId: fixture.ownerId, runtime: "claude")
    let peerKey = accounts.mintAgentCredential(agentId: peerId, scopes: ["send", "read"], name: "thread-edge-peer")
    #expect(accounts.humanMessageCount == 0)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"thread-edge-owner@test.invalid\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let loginObject = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any]
            let ownerToken = try #require(loginObject?["accessToken"] as? String)
            var humanHeaders = loginHeaders
            humanHeaders[.authorization] = "Bearer \(ownerToken)"
            humanHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let initialDms = try await client.get("/api/channels/dm", headers: humanHeaders)
            #expect(initialDms.status == .ok)
            let initialRows = try JSONSerialization.jsonObject(with: Data((initialDms.body.string ?? "").utf8)) as? [[String: Any]]
            #expect(initialRows?.isEmpty == true)

            let opened = try await edgeSend(client, key: fixture.key, target: "dm:@thread-edge-owner", content: "normal fresh owner DM", seen: 0)
            #expect(opened.0.status == .ok)
            let openingId = try #require(opened.1["messageId"] as? String)
            let ownerDm = try #require(accounts.messageChannelIdForTesting(messageId: openingId))
            #expect(accounts.oauth.channelType(id: ownerDm) == "dm")
            #expect(accounts.oauth.channelServerId(channelId: ownerDm) == fixture.serverId)
            #expect(accounts.oauth.channelAgentIds(channelId: ownerDm) == [fixture.agentId])
            #expect(accounts.oauth.channelHumanIds(channelId: ownerDm) == [fixture.ownerId])
            let parent = try await client.send(.post, headers: humanHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(ownerDm)\",\"content\":\"actual human thread parent\"}")
            }
            #expect(parent.status == .ok)
            let parentObject = try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any]
            let parentId = try #require(parentObject?["id"] as? String)
            let parentFact = try #require(accounts.oauth.historyMessages(channelId: ownerDm).first { $0.id == parentId })
            #expect(parentFact.senderId == fixture.ownerId)
            #expect(parentFact.senderType == "user")
            let reply = try await edgeSend(client, key: fixture.key, target: "dm:@thread-edge-owner:\(parentId.prefix(8))", content: "normal owner thread reply", seen: parentFact.seq)
            #expect(reply.0.status == .ok)
            let replyId = try #require(reply.1["messageId"] as? String)
            let ownerThread = try #require(accounts.messageChannelIdForTesting(messageId: replyId))
            #expect(ownerThread != ownerDm)
            #expect(accounts.oauth.channelType(id: ownerThread) == "thread")
            #expect(accounts.oauth.channelServerId(channelId: ownerThread) == fixture.serverId)
            #expect(accounts.threadFollowerIdsForTesting(threadChannelId: ownerThread) == [fixture.ownerId, fixture.agentId].sorted())
            #expect(accounts.humanMessageIds(channelId: ownerDm) == [openingId, parentId])
            #expect(accounts.humanMessageIds(channelId: ownerThread) == [replyId])
            #expect(accounts.humanMessageCount == 3)

            let peerOpened = try await edgeSend(client, key: fixture.key, target: "dm:@ThreadEdgePeer~agent", content: "normal fresh agent DM", seen: 0)
            #expect(peerOpened.0.status == .ok)
            let peerOpeningId = try #require(peerOpened.1["messageId"] as? String)
            let peerDm = try #require(accounts.messageChannelIdForTesting(messageId: peerOpeningId))
            #expect(peerDm != ownerDm)
            #expect(accounts.oauth.channelType(id: peerDm) == "dm")
            #expect(accounts.oauth.channelServerId(channelId: peerDm) == fixture.serverId)
            #expect(accounts.oauth.channelAgentIds(channelId: peerDm) == [fixture.agentId, peerId].sorted())
            #expect(accounts.oauth.channelHumanIds(channelId: peerDm).isEmpty)
            let peerOpeningFact = try #require(accounts.oauth.historyMessages(channelId: peerDm).first { $0.id == peerOpeningId })
            let peerParent = try await edgeSend(client, key: peerKey, target: "dm:@ThreadEdgeBot~agent", content: "actual agent-authored parent", seen: peerOpeningFact.seq)
            #expect(peerParent.0.status == .ok)
            let peerParentId = try #require(peerParent.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: peerParentId) == peerDm)
            let peerParentFact = try #require(accounts.oauth.historyMessages(channelId: peerDm).first { $0.id == peerParentId })
            #expect(peerParentFact.senderId == peerId)
            #expect(peerParentFact.senderType == "agent")
            let request: [String: Any] = ["target": "dm:@ThreadEdgePeer~agent:\(peerParentId.prefix(8))", "content": "normal agent parent thread reply", "seenUpToSeq": peerParentFact.seq, "idempotencyKey": UUID().uuidString.lowercased()]
            let data = try JSONSerialization.data(withJSONObject: request)
            var agentHeaders = loginHeaders
            agentHeaders[.authorization] = "Bearer \(fixture.key)"
            var committedId: String?
            var committedThread: String?
            for _ in 0..<2 {
                let response = try await client.send(.post, headers: agentHeaders, to: "/internal/agent-api/v2/send") { request in
                    request.body = .init(data: data)
                }
                #expect(response.status == .ok)
                let object = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                let actualId = try #require(object?["messageId"] as? String)
                let thread = try #require(accounts.messageChannelIdForTesting(messageId: actualId))
                if let committedId { #expect(actualId == committedId) }
                else { committedId = actualId }
                if let committedThread { #expect(thread == committedThread) }
                else { committedThread = thread }
                #expect(thread != peerDm)
                #expect(accounts.oauth.channelType(id: thread) == "thread")
                #expect(accounts.oauth.channelServerId(channelId: thread) == fixture.serverId)
                #expect(accounts.threadFollowerIdsForTesting(threadChannelId: thread) == [fixture.agentId, peerId].sorted())
                #expect(accounts.humanMessageIds(channelId: peerDm) == [peerOpeningId, peerParentId])
                #expect(accounts.humanMessageIds(channelId: thread) == [actualId])
                #expect(accounts.humanMessageCount == 6)
            }
            #expect(accounts.threadFollowerIdsForTesting(threadChannelId: ownerThread) == [fixture.ownerId, fixture.agentId].sorted())
            #expect(accounts.humanMessageIds(channelId: ownerThread) == [replyId])

            // Create real unread DM work for the peer, in addition to its unread thread reply.
            let offered = try await edgeSend(client, key: fixture.key, target: "dm:@ThreadEdgePeer~agent", content: "actual unread peer inbox message", seen: peerParentFact.seq)
            #expect(offered.0.status == .ok)
            let offeredId = try #require(offered.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: offeredId) == peerDm)
            #expect(accounts.humanMessageCount == 7)
            var peerHeaders = loginHeaders
            peerHeaders[.authorization] = "Bearer \(peerKey)"
            let inbox = try await client.get("/internal/agent-api/inbox/conversations", headers: peerHeaders)
            #expect(inbox.status == .ok)
            let inboxObject = try JSONSerialization.jsonObject(with: Data((inbox.body.string ?? "").utf8)) as? [String: Any]
            let items = try #require(inboxObject?["items"] as? [[String: Any]])
            let dmItem = items.first { $0["kind"] as? String == "dm" && $0["target"] as? String == "dm:@ThreadEdgeBot" }
            let threadItem = items.first { $0["kind"] as? String == "thread" && $0["target"] as? String == "dm:@ThreadEdgeBot:\(peerParentId.prefix(8))" }
            #expect((dmItem?["unread"] as? Int ?? 0) > 0)
            #expect((threadItem?["unread"] as? Int ?? 0) > 0)
            #expect(dmItem?["latestSenderName"] as? String == "ThreadEdgeBot")
            #expect(threadItem?["latestSenderName"] as? String == "ThreadEdgeBot")

            // A human and an agent may own the same UUID in their distinct typed stores.
            accounts.addAccount(id: peerId, email: "thread-edge-human-twin@test.invalid", password: "password123")
            accounts.markEmailVerified(userId: peerId)
            accounts.setAccountProfileForTesting(id: peerId, name: "ThreadEdgePeer")
            accounts.oauth.addMember(serverId: fixture.serverId, userId: peerId, role: "member")
            let humanTwin = try await edgeSend(client, key: fixture.key, target: "dm:@ThreadEdgePeer~human", content: "actual same UUID human conversation", seen: 0)
            #expect(humanTwin.0.status == .ok)
            let humanTwinId = try #require(humanTwin.1["messageId"] as? String)
            let humanTwinDm = try #require(accounts.messageChannelIdForTesting(messageId: humanTwinId))
            #expect(humanTwinDm != peerDm)
            #expect(humanTwinDm != ownerDm)
            #expect(accounts.oauth.channelHumanIds(channelId: humanTwinDm) == [peerId])
            #expect(accounts.oauth.channelAgentIds(channelId: humanTwinDm) == [fixture.agentId])
            let offeredFact = try #require(accounts.oauth.historyMessages(channelId: peerDm).first { $0.id == offeredId })
            let agentTwin = try await edgeSend(client, key: fixture.key, target: "dm:@ThreadEdgePeer~agent", content: "actual same UUID agent conversation", seen: offeredFact.seq)
            #expect(agentTwin.0.status == .ok)
            let agentTwinId = try #require(agentTwin.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: agentTwinId) == peerDm)
            #expect(accounts.oauth.channelHumanIds(channelId: peerDm).isEmpty)
            #expect(accounts.oauth.channelAgentIds(channelId: peerDm) == [fixture.agentId, peerId].sorted())
            #expect(accounts.humanMessageIds(channelId: humanTwinDm) == [humanTwinId])
            #expect(accounts.humanMessageIds(channelId: peerDm) == [peerOpeningId, peerParentId, offeredId, agentTwinId])
            #expect(accounts.humanMessageCount == 9)
        }
    }
}

@Test func agentInboxHumanPeerSharingTheActorUUIDHasAConsumableTypedTarget() async throws {
    var fixture = ThreadEdgeFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let humanId = fixture.agentId
    accounts.addAccount(id: humanId, email: "actor-human-twin@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: humanId)
    accounts.setAccountProfileForTesting(id: humanId, name: "ActorHumanTwin")
    accounts.oauth.addMember(serverId: fixture.serverId, userId: humanId, role: "member")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"actor-human-twin@test.invalid\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let loginObject = try #require(try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])
            let token = try #require(loginObject["accessToken"] as? String)
            var humanHeaders = loginHeaders
            humanHeaders[.authorization] = "Bearer \(token)"
            humanHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let opened = try await client.send(.post, headers: humanHeaders, to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"agentId\":\"\(fixture.agentId)\"}")
            }
            #expect(opened.status == .ok)
            let openedObject = try #require(try JSONSerialization.jsonObject(with: Data((opened.body.string ?? "").utf8)) as? [String: Any])
            let dm = try #require(openedObject["id"] as? String)
            #expect(accounts.oauth.channelHumanIds(channelId: dm) == [humanId])
            #expect(accounts.oauth.channelAgentIds(channelId: dm) == [fixture.agentId])
            let mentionBody: [String: Any] = ["channelId": dm, "content": "ordinary human @ThreadEdgeBot", "mentions": [["type": "agent", "id": fixture.agentId, "name": "ThreadEdgeBot"]]]
            let mentionData = try JSONSerialization.data(withJSONObject: mentionBody)
            let mentioned = try await client.send(.post, headers: humanHeaders, to: "/api/messages") { request in
                request.body = .init(data: mentionData)
            }
            #expect(mentioned.status == .ok)
            let mentionedObject = try #require(try JSONSerialization.jsonObject(with: Data((mentioned.body.string ?? "").utf8)) as? [String: Any])
            let mentionId = try #require(mentionedObject["id"] as? String)
            let mentionFact = try #require(accounts.oauth.historyMessages(channelId: dm).first { $0.id == mentionId })
            #expect(mentionFact.senderId == fixture.agentId)
            #expect(mentionFact.senderType == "user")

            let selfOpened = try await client.send(.post, headers: humanHeaders, to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(humanId)\"}")
            }
            #expect(selfOpened.status == .ok)
            let selfObject = try #require(try JSONSerialization.jsonObject(with: Data((selfOpened.body.string ?? "").utf8)) as? [String: Any])
            let humanSelfDm = try #require(selfObject["id"] as? String)
            #expect(humanSelfDm != dm)
            #expect(accounts.oauth.channelHumanIds(channelId: humanSelfDm) == [humanId])
            #expect(accounts.oauth.channelAgentIds(channelId: humanSelfDm).isEmpty)
            let privatePost = try await client.send(.post, headers: humanHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(humanSelfDm)\",\"content\":\"human self DM private message\"}")
            }
            #expect(privatePost.status == .ok)
            let privateObject = try #require(try JSONSerialization.jsonObject(with: Data((privatePost.body.string ?? "").utf8)) as? [String: Any])
            let privateId = try #require(privateObject["id"] as? String)

            var agentHeaders = loginHeaders
            agentHeaders[.authorization] = "Bearer \(fixture.key)"
            let inbox = try await client.get("/internal/agent-api/inbox/conversations?view=mentions", headers: agentHeaders)
            #expect(inbox.status == .ok)
            let inboxObject = try #require(try JSONSerialization.jsonObject(with: Data((inbox.body.string ?? "").utf8)) as? [String: Any])
            let items = try #require(inboxObject["items"] as? [[String: Any]])
            let dmItems = items.filter { $0["kind"] as? String == "dm" }
            #expect(dmItems.count == 1)
            let row = try #require(dmItems.first)
            let returnedTarget = try #require(row["target"] as? String)
            #expect(returnedTarget == "dm:@ActorHumanTwin")
            #expect((row["mentions"] as? Int ?? 0) > 0)
            #expect((row["unread"] as? Int ?? 0) > 0)
            #expect(row["latestSenderName"] as? String == "ActorHumanTwin")
            for target in [returnedTarget, "dm:@ActorHumanTwin~human"] {
                let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                let history = try await client.get(URI(string: "/internal/agent-api/history?channel=\(encoded)&consume=false"), headers: agentHeaders)
                #expect(history.status == .ok)
                let historyObject = try #require(try JSONSerialization.jsonObject(with: Data((history.body.string ?? "").utf8)) as? [String: Any])
                let historyRows = try #require(historyObject["messages"] as? [[String: Any]])
                #expect(historyRows.contains { $0["id"] as? String == mentionId })
                #expect(!historyRows.contains { $0["id"] as? String == privateId || $0["content"] as? String == "human self DM private message" })
            }
            let sent = try await edgeSend(client, key: fixture.key, target: returnedTarget, content: "agent reply to distinct human actor", seen: mentionFact.seq)
            #expect(sent.0.status == .ok)
            let sentId = try #require(sent.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: sentId) == dm)
            let sentFact = try #require(accounts.oauth.historyMessages(channelId: dm).first { $0.id == sentId })
            #expect(sentFact.senderType == "agent")
            let pinned = try await edgeSend(client, key: fixture.key, target: "dm:@ActorHumanTwin~human", content: "agent reply to pinned human kind", seen: sentFact.seq)
            #expect(pinned.0.status == .ok)
            let pinnedId = try #require(pinned.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: pinnedId) == dm)
            #expect(accounts.humanMessageIds(channelId: dm) == [mentionId, sentId, pinnedId])
            #expect(accounts.humanMessageIds(channelId: humanSelfDm) == [privateId])
            #expect(accounts.humanMessageCount == 4)
        }
    }
}

@Test func agentInboxRejectsRetainedUnknownNativeParticipantsWithoutPublishingATarget() async throws {
    var fixture = ThreadEdgeFixture()
    fixture.seed()
    let accounts = fixture.accounts
    // Preserve the actual legacy public producer shape. Do not normalize its unknown human row.
    let dm = accounts.oauth.createDirectChannel(serverId: fixture.serverId, firstUserId: fixture.ownerId, secondUserId: fixture.agentId)
    accounts.oauth.addChannelAgent(channelId: dm, agentId: fixture.agentId)
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: dm, memberId: fixture.ownerId, kind: "dm", name: "dm")
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: dm, memberId: fixture.agentId, kind: "dm", name: "dm")
    #expect(accounts.userCount == 1)
    #expect(accounts.oauth.channelHumanIds(channelId: dm) == [fixture.ownerId, fixture.agentId].sorted())
    #expect(accounts.oauth.channelAgentIds(channelId: dm) == [fixture.agentId])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"thread-edge-owner@test.invalid\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let loginObject = try #require(try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])
            let token = try #require(loginObject["accessToken"] as? String)
            var humanHeaders = loginHeaders
            humanHeaders[.authorization] = "Bearer \(token)"
            humanHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let posted = try await client.send(.post, headers: humanHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(dm)\",\"content\":\"real human host in a retained legacy DM\"}")
            }
            #expect(posted.status == .ok)
            let postedObject = try #require(try JSONSerialization.jsonObject(with: Data((posted.body.string ?? "").utf8)) as? [String: Any])
            let messageId = try #require(postedObject["id"] as? String)
            let fact = try #require(accounts.oauth.historyMessages(channelId: dm).first { $0.id == messageId })
            #expect(fact.senderId == fixture.ownerId)
            #expect(fact.senderType == "user")
            let beforeCount = accounts.humanMessageCount
            var agentHeaders = loginHeaders
            agentHeaders[.authorization] = "Bearer \(fixture.key)"
            let inbox = try await client.get("/internal/agent-api/inbox/conversations", headers: agentHeaders)
            #expect(inbox.status == .serviceUnavailable)
            let body = try #require(try JSONSerialization.jsonObject(with: Data((inbox.body.string ?? "").utf8)) as? [String: Any])
            #expect(body["code"] as? String == "INBOX_DM_TARGET_UNAVAILABLE")
            #expect(body["items"] == nil)
            #expect(body["target"] == nil)
            #expect(accounts.humanMessageCount == beforeCount)
            #expect(accounts.humanMessageIds(channelId: dm) == [messageId])
            #expect(accounts.oauth.channelHumanIds(channelId: dm) == [fixture.ownerId, fixture.agentId].sorted())
            #expect(accounts.oauth.channelAgentIds(channelId: dm) == [fixture.agentId])
        }
    }
}
