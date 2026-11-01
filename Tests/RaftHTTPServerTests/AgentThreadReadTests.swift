import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ThreadReadFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let agentId: String
    let apiKey: String
    let ownerId: String
    let ownerName: String
    let anchorNoRepliesId: String
    let anchorWithThreadId: String
    let threadId: String
    let hiddenChannelId: String
    let hiddenAnchorId: String
    let elsewhereId: String
    let dmId: String
    let dmParentId: String
    let dmThreadId: String
}

private func makeThreadReadFixture(suffix: String) -> ThreadReadFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 800_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 990_000 + number)
    let ownerName = "dx-thread-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "dx-thread-\(suffix)", name: "Thread Read Test", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ThreadReadBot-\(suffix)", runtime: "claude")

    func makeChannel(_ name: String, kind: String = "channel", ownerOnly: Bool = false) -> String {
        let id = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId, type: kind)
        accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: ownerId, kind: kind, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: ownerId)
        if !ownerOnly {
            accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: agent, kind: kind, name: name)
            accounts.oauth.addChannelAgent(channelId: id, agentId: agent)
        }
        return id
    }

    let parent = makeChannel("dx-parent")
    let other = makeChannel("dx-other")
    let hidden = makeChannel("dx-hidden", kind: "private", ownerOnly: true)

    let hiddenAnchor = accounts.oauth.createMessageRecord(channelId: hidden, content: "message in a hidden channel", senderId: ownerId).id
    let anchorNoReplies = accounts.oauth.createMessageRecord(channelId: parent, content: "anchor with no replies", senderId: ownerId).id
    let anchorWithThread = accounts.oauth.createMessageRecord(channelId: parent, content: "anchor with a thread", senderId: ownerId).id
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: anchorWithThread)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: thread,
            memberId: member,
            kind: "thread",
            parentChannelId: parent,
            parentMessageId: anchorWithThread,
            name: "thread"
        )
    }
    accounts.oauth.addChannelHuman(channelId: thread, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: thread, agentId: agent)
    _ = accounts.oauth.createMessageRecord(channelId: thread, content: "a reply, so the thread exists", senderId: ownerId)
    let elsewhere = accounts.oauth.createMessageRecord(channelId: other, content: "message in another channel", senderId: ownerId).id

    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: agent)
    accounts.oauth.addChannelHuman(channelId: dm, userId: agent)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: dm, memberId: member, kind: "dm", name: "dm")
    }
    let dmParent = accounts.oauth.createMessageRecord(channelId: dm, content: "DM parent", senderId: ownerId).id
    let dmThread = accounts.oauth.createThreadChannel(parentChannelId: dm, parentMessageId: dmParent)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: dmThread,
            memberId: member,
            kind: "thread",
            parentChannelId: dm,
            parentMessageId: dmParent,
            name: "thread"
        )
    }
    _ = accounts.oauth.createMessageRecord(channelId: dmThread, content: "DM reply", senderId: ownerId)

    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read"], name: "dx-thread-read-\(suffix)")
    return ThreadReadFixture(
        accounts: accounts,
        serverId: serverId,
        agentId: agent,
        apiKey: apiKey,
        ownerId: ownerId,
        ownerName: ownerName,
        anchorNoRepliesId: anchorNoReplies,
        anchorWithThreadId: anchorWithThread,
        threadId: thread,
        hiddenChannelId: hidden,
        hiddenAnchorId: hiddenAnchor,
        elsewhereId: elsewhere,
        dmId: dm,
        dmParentId: dmParent,
        dmThreadId: dmThread
    )
}

private func threadRead(
    _ client: any Client,
    apiKey: String,
    target: String,
    around: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
    var path = "/internal/agent-api/history?channel=\(encoded)"
    if let around, let encodedAround = around.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
        path += "&around=\(encodedAround)"
    }
    let response = try await client.get(URI(string: path), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func threadReadMessages(_ body: [String: Any]) -> [[String: Any]] {
    body["messages"] as? [[String: Any]] ?? []
}

@Test func agentThreadReadNamesTheEntityThatIsActuallyMissing() async throws {
    let fixture = makeThreadReadFixture(suffix: "761")
    let anchorShort = String(fixture.anchorWithThreadId.prefix(8))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let e = try await threadRead(client, apiKey: fixture.apiKey, target: "#dx-parent:\(anchorShort)")
            #expect(e.status == .ok)
            #expect(e.body["target"] as? String == "#dx-parent:\(anchorShort)")

            let f = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-parent:\(String(fixture.threadId.prefix(8)))"
            )
            #expect(f.status == .ok)
            #expect(f.body["target"] as? String == e.body["target"] as? String)
            #expect(threadReadMessages(f.body).contains { ($0["content"] as? String)?.contains("a reply, so the thread exists") == true })

            let fMiss = try await threadRead(client, apiKey: fixture.apiKey, target: "#dx-parent:cafebabe")
            let b = try await threadRead(client, apiKey: fixture.apiKey, target: "#dx-parent:deadbeef")
            #expect(fMiss.status == .notFound)
            #expect(fMiss.body as NSDictionary == b.body as NSDictionary)

            let aMissing = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-nonexistent:\(String(fixture.anchorNoRepliesId.prefix(8)))"
            )
            #expect(aMissing.status == .notFound)
            #expect(aMissing.body["error"] as? String == "Channel not found or not visible")

            let aInvisible = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-hidden:\(String(fixture.hiddenAnchorId.prefix(8)))"
            )
            #expect(aInvisible.status == .notFound)
            #expect(aInvisible.body as NSDictionary == aMissing.body as NSDictionary)

            let c = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-parent:\(String(fixture.anchorNoRepliesId.prefix(8)))"
            )
            #expect(c.status == .notFound)
            let cError = c.body["error"] as? String ?? ""
            #expect(cError.localizedCaseInsensitiveContains("no thread on message"))
            #expect(!cError.localizedCaseInsensitiveContains("channel not found"))
            let nextAction = try #require(c.body["suggestedNextAction"] as? String)
            let around = try #require(nextAction.split(separator: " ").last.map(String.init))
            let ran = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-parent",
                around: around
            )
            #expect(ran.status == .ok)
            #expect(threadReadMessages(ran.body).contains { $0["id"] as? String == fixture.anchorNoRepliesId })

            let d = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-parent:\(String(fixture.elsewhereId.prefix(8)))"
            )
            #expect(d.status == .notFound)
            #expect(d.body as NSDictionary == b.body as NSDictionary)
            #expect(!((d.body["error"] as? String) ?? "").contains("dx-other"))

            let handBuilt = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-parent",
                around: anchorShort
            )
            #expect(handBuilt.status == .ok)
            #expect(!threadReadMessages(handBuilt.body).isEmpty)
            let corrupted = try await threadRead(
                client,
                apiKey: fixture.apiKey,
                target: "#dx-parent",
                around: "deadbeef"
            )
            #expect(!(corrupted.status == .ok && !threadReadMessages(corrupted.body).isEmpty))
        }
    }
}

@Test func agentDMHistorySuppliesConsumptionIdentityOnlyForDMsAndDMThreads() async throws {
    let fixture = makeThreadReadFixture(suffix: "762")
    let dmParentShort = String(fixture.dmParentId.prefix(8))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let dmTarget = "dm:@\(fixture.ownerName)"
            let dm = try await threadRead(client, apiKey: fixture.apiKey, target: dmTarget)
            #expect(dm.status == .ok)
            let dmScope = dm.body["consumption_scope"] as? [String: Any]
            #expect(dmScope?["agent_id"] as? String == fixture.agentId)
            #expect(dmScope?["channel_id"] as? String == fixture.dmId)
            #expect(dmScope?["channel_type"] as? String == "dm")
            #expect(dmScope?["target"] as? String == dmTarget)
            #expect(threadReadMessages(dm.body).allSatisfy { $0["channelId"] as? String == fixture.dmId })

            let dmThreadTarget = "\(dmTarget):\(dmParentShort)"
            let dmThread = try await threadRead(client, apiKey: fixture.apiKey, target: dmThreadTarget)
            #expect(dmThread.status == .ok)
            let threadScope = dmThread.body["consumption_scope"] as? [String: Any]
            #expect(threadScope?["channel_id"] as? String == fixture.dmThreadId)
            #expect(threadScope?["channel_type"] as? String == "thread")
            #expect(threadScope?["target"] as? String == dmThreadTarget)

            let ordinary = try await threadRead(client, apiKey: fixture.apiKey, target: "#dx-parent")
            #expect(ordinary.status == .ok)
            #expect(ordinary.body["consumption_scope"] == nil)

            let unavailable = try await threadRead(client, apiKey: fixture.apiKey, target: "dm:@nonexistent-peer")
            #expect(unavailable.status == .notFound)
            #expect(unavailable.body["consumption_scope"] == nil)
        }
    }
}
