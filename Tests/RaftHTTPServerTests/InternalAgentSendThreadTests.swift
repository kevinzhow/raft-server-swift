import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct SendThreadFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let ownerToken: String
    let channelId: String
    let channelName: String
    let agentId: String
    let agentKey: String
    let outsiderAgentId: String
    let outsiderKey: String
    let privateChannelId: String
    let privateChannelName: String
}

private func makeSendThreadFixture(_ suffix: String) -> SendThreadFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001130\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001130\(suffix)"
    accounts.addAccount(id: ownerId, email: "send-thread-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "send-thread-\(suffix)", name: "Send Thread \(suffix)", ownerId: ownerId)
    let ownerName = "send-thread-\(suffix)"

    let channelName = "send-thread-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "SendThreadBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let agentKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "thread-\(suffix)")

    let outsiderAgentId = accounts.oauth.createAgent(serverId: serverId, name: "OutsiderBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    let outsiderKey = accounts.mintAgentCredential(agentId: outsiderAgentId, scopes: ["read", "send"], name: "outsider-\(suffix)")

    let privateChannelName = "send-thread-private-\(suffix)"
    let privateChannelId = accounts.oauth.createChannel(serverId: serverId, name: privateChannelName, creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: privateChannelName)
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: ownerId)

    return SendThreadFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        channelId: channelId,
        channelName: channelName,
        agentId: agentId,
        agentKey: agentKey,
        outsiderAgentId: outsiderAgentId,
        outsiderKey: outsiderKey,
        privateChannelId: privateChannelId,
        privateChannelName: privateChannelName
    )
}

private func sendThreadHumanHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func sendThreadAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func sendThreadJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func sendThreadMessage(
    _ client: any Client,
    key: String,
    target: String,
    content: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: sendThreadAgentHeaders(key), to: "/internal/agent-api/send") { request in
        request.body = .init(string: "{\"target\":\"\(target)\",\"content\":\"\(content)\"}")
    }
}

private func sendThreadInfo(
    _ client: any Client,
    fixture: SendThreadFixture,
    channelId: String,
    messageId: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.get(
        URI(string: "/api/channels/\(channelId)/threads/\(messageId)"),
        headers: sendThreadHumanHeaders(fixture.ownerToken, fixture.serverId)
    )
    return (response.status, try sendThreadJSON(response))
}

@Test func agentApiSendCreatesAFreshChannelThreadAndReportsSent() async throws {
    let f = makeSendThreadFixture("001")
    let parentId = f.accounts.addHumanMessageForTesting(channelId: f.channelId, senderId: f.ownerId, content: "fresh thread parent")
    let parent = try #require(f.accounts.oauth.historyMessages(channelId: f.channelId).first { $0.id == parentId })
    #expect(parent.senderId == f.ownerId)
    #expect(parent.senderType == "user")
    #expect(f.accounts.messageChannelIdForTesting(messageId: parent.id) == f.channelId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await sendThreadMessage(
                client,
                key: f.agentKey,
                target: "#\(f.channelName):\(parent.id.prefix(8))",
                content: "agent-api first thread reply"
            )
            #expect(sent.status == .ok)
            let body = try sendThreadJSON(sent)
            #expect(body["ok"] as? Bool == true)
            #expect(body["state"] as? String == "sent")
            let messageId = try #require(body["messageId"] as? String)
            #expect(body["messageSeq"] as? Int != nil)

            let info = try await sendThreadInfo(client, fixture: f, channelId: f.channelId, messageId: parent.id)
            #expect(info.status == .ok)
            #expect(info.body["replyCount"] as? Int == 1)
            let threadId = try #require(info.body["threadChannelId"] as? String)
            #expect(threadId != f.channelId)

            let threadHistory = try await client.get(
                URI(string: "/api/messages/channel/\(threadId)"),
                headers: sendThreadHumanHeaders(f.ownerToken, f.serverId)
            )
            #expect(threadHistory.status == .ok)
            let rows = (try sendThreadJSON(threadHistory)["messages"] as? [[String: Any]]) ?? []
            #expect(rows.contains { $0["id"] as? String == messageId && $0["content"] as? String == "agent-api first thread reply" })
        }
    }
}

@Test func agentApiSendThreadIDPrefixLandsOnTheNamedThread() async throws {
    let f = makeSendThreadFixture("002")
    let parentId = f.accounts.addHumanMessageForTesting(channelId: f.channelId, senderId: f.ownerId, content: "threadId-target parent")
    let parent = try #require(f.accounts.oauth.historyMessages(channelId: f.channelId).first { $0.id == parentId })
    #expect(parent.senderId == f.ownerId)
    #expect(parent.senderType == "user")
    #expect(f.accounts.messageChannelIdForTesting(messageId: parent.id) == f.channelId)
    let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: f.channelId, parentMessageId: parent.id)
    f.accounts.addPostableChannel(
        serverId: f.serverId,
        channelId: threadId,
        memberId: f.ownerId,
        kind: "thread",
        parentChannelId: f.channelId,
        parentMessageId: parent.id,
        name: "thread"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await sendThreadMessage(
                client,
                key: f.agentKey,
                target: "#\(f.channelName):\(threadId.prefix(8))",
                content: "agent-api reply via threadId target"
            )
            #expect(sent.status == .ok)
            #expect(try sendThreadJSON(sent)["state"] as? String == "sent")

            let info = try await sendThreadInfo(client, fixture: f, channelId: f.channelId, messageId: parent.id)
            #expect(info.body["threadChannelId"] as? String == threadId)
            #expect(info.body["replyCount"] as? Int == 1, "the reply must land on the thread the threadId names")
        }
    }
}

@Test func agentApiSendReusesAnExistingEmptyThreadChannel() async throws {
    let f = makeSendThreadFixture("003")
    let parentId = f.accounts.addHumanMessageForTesting(channelId: f.channelId, senderId: f.ownerId, content: "opened thread parent")
    let parent = try #require(f.accounts.oauth.historyMessages(channelId: f.channelId).first { $0.id == parentId })
    #expect(parent.senderId == f.ownerId)
    #expect(parent.senderType == "user")
    #expect(f.accounts.messageChannelIdForTesting(messageId: parent.id) == f.channelId)
    let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: f.channelId, parentMessageId: parent.id)
    f.accounts.addPostableChannel(
        serverId: f.serverId,
        channelId: threadId,
        memberId: f.ownerId,
        kind: "thread",
        parentChannelId: f.channelId,
        parentMessageId: parent.id,
        name: "thread"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await sendThreadMessage(
                client,
                key: f.agentKey,
                target: "#\(f.channelName):\(parent.id.prefix(8))",
                content: "agent-api reply in opened empty thread"
            )
            #expect(sent.status == .ok)
            let info = try await sendThreadInfo(client, fixture: f, channelId: f.channelId, messageId: parent.id)
            #expect(info.body["threadChannelId"] as? String == threadId)
            #expect(info.body["replyCount"] as? Int == 1)
        }
    }
}

@Test func agentApiThreadTargetRequiresParentChannelMembership() async throws {
    let f = makeSendThreadFixture("004")
    let parentId = f.accounts.addHumanMessageForTesting(channelId: f.channelId, senderId: f.ownerId, content: "members only thread parent")
    let parent = try #require(f.accounts.oauth.historyMessages(channelId: f.channelId).first { $0.id == parentId })
    #expect(parent.senderId == f.ownerId)
    #expect(parent.senderType == "user")
    #expect(f.accounts.messageChannelIdForTesting(messageId: parent.id) == f.channelId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let denied = try await sendThreadMessage(
                client,
                key: f.outsiderKey,
                target: "#\(f.channelName):\(parent.id.prefix(8))",
                content: "should not send"
            )
            #expect(denied.status == .forbidden)
            #expect(((try sendThreadJSON(denied)["error"] as? String) ?? "").contains("not a member of the parent channel"))
        }
    }
}

@Test func agentApiThreadTargetCloaksAHiddenPrivateParent() async throws {
    let f = makeSendThreadFixture("005")
    let parentId = f.accounts.addHumanMessageForTesting(channelId: f.privateChannelId, senderId: f.ownerId, content: "hidden private parent")
    let parent = try #require(f.accounts.oauth.historyMessages(channelId: f.privateChannelId).first { $0.id == parentId })
    #expect(parent.senderId == f.ownerId)
    #expect(parent.senderType == "user")
    #expect(f.accounts.messageChannelIdForTesting(messageId: parent.id) == f.privateChannelId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let denied = try await sendThreadMessage(
                client,
                key: f.agentKey,
                target: "#\(f.privateChannelName):\(parent.id.prefix(8))",
                content: "should cloak hidden private parent"
            )
            #expect(denied.status == .notFound)
            #expect(((try sendThreadJSON(denied)["error"] as? String) ?? "").contains("Thread target not found or not replyable"))
        }
    }
}

@Test func agentApiThreadTargetExplainsAnUnresolvedReplyTarget() async throws {
    let f = makeSendThreadFixture("006")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let missing = try await sendThreadMessage(
                client,
                key: f.agentKey,
                target: "#\(f.channelName):deadbeef",
                content: "missing parent"
            )
            #expect(missing.status == .notFound)
            let error = (try sendThreadJSON(missing)["error"] as? String) ?? ""
            #expect(error.contains("Thread target not found or not replyable"))
            #expect(error.contains("parent message must exist"))
        }
    }
}

@Test func agentApiSendCreatesAFreshDMThread() async throws {
    let f = makeSendThreadFixture("007")
    let dm = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.agentId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: dm, memberId: f.ownerId, kind: "dm", name: "dm")
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: dm, memberId: f.agentId, kind: "dm", name: "dm")
    f.accounts.oauth.addChannelHuman(channelId: dm, userId: f.ownerId)
    f.accounts.oauth.removeChannelHuman(channelId: dm, userId: f.agentId)
    f.accounts.oauth.addChannelAgent(channelId: dm, agentId: f.agentId)
    #expect(f.accounts.oauth.channelHumanIds(channelId: dm) == [f.ownerId])
    #expect(f.accounts.oauth.channelAgentIds(channelId: dm) == [f.agentId])
    let parentId = f.accounts.addHumanMessageForTesting(channelId: dm, senderId: f.ownerId, content: "fresh DM thread parent")
    let parent = try #require(f.accounts.oauth.historyMessages(channelId: dm).first { $0.id == parentId })
    #expect(parent.senderId == f.ownerId)
    #expect(parent.senderType == "user")
    #expect(f.accounts.messageChannelIdForTesting(messageId: parent.id) == dm)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await sendThreadMessage(
                client,
                key: f.agentKey,
                target: "dm:@\(f.ownerName):\(parent.id.prefix(8))",
                content: "agent-api first DM thread reply"
            )
            #expect(sent.status == .ok)
            #expect(try sendThreadJSON(sent)["state"] as? String == "sent")

            let info = try await sendThreadInfo(client, fixture: f, channelId: dm, messageId: parent.id)
            #expect(info.status == .ok)
            #expect(info.body["threadChannelId"] as? String != dm)
            #expect(info.body["replyCount"] as? Int == 1)
        }
    }
}
