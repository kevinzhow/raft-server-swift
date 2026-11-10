import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct SendHoldFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let ownerToken: String
    let channelId: String
    let channelName: String
    let agentId: String
    let agentName: String
    let agentKey: String
    let otherAgentId: String
}

private func makeSendHoldFixture(_ suffix: String) -> SendHoldFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001160\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001160\(suffix)"
    accounts.addAccount(id: ownerId, email: "send-hold-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "send-hold-\(suffix)", name: "Send Hold \(suffix)", ownerId: ownerId)
    let channelName = "send-hold-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentName = "HoldBot\(suffix)"
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "OtherHoldBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: otherAgentId)
    // The upstream send module runs with the freshness interface forced on, so
    // a markerless send is gated too.
    accounts.setSendFreshnessModeForTesting("force")
    return SendHoldFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: "send-hold-\(suffix)",
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        channelId: channelId,
        channelName: channelName,
        agentId: agentId,
        agentName: agentName,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "hold-\(suffix)"),
        otherAgentId: otherAgentId
    )
}

private func holdHumanHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func holdAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func holdPostHuman(
    _ client: any Client,
    _ fixture: SendHoldFixture,
    content: String
) async throws -> (id: String, seq: Int) {
    let response = try await client.send(.post, headers: holdHumanHeaders(fixture.ownerToken, fixture.serverId), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"\(content)\"}")
    }
    let id = (try holdJSON(response)["id"] as? String) ?? ""
    return (id, fixture.accounts.humanMessageSequence(id: id) ?? 0)
}

private func holdSendOwnProgress(
    _ client: any Client,
    _ fixture: SendHoldFixture,
    content: String
) async throws {
    // A committed own message: the gated send path would hold here, so the row
    // is appended directly, exactly like a previous turn that did send.
    fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: content,
        senderId: fixture.agentId,
        senderType: "agent"
    )
}

private func holdJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func holdSend(
    _ client: any Client,
    key: String,
    body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: holdAgentHeaders(key), to: "/internal/agent-api/send") { request in
        request.body = .init(string: body)
    }
}

private func holdChannelMessages(
    _ client: any Client,
    fixture: SendHoldFixture
) async throws -> [[String: Any]] {
    let response = try await client.get(
        URI(string: "/api/messages/channel/\(fixture.channelId)"),
        headers: holdHumanHeaders(fixture.ownerToken, fixture.serverId)
    )
    return (try holdJSON(response)["messages"] as? [[String: Any]]) ?? []
}

@Test func agentApiSendHoldsAStaleDraftWithInlineFreshnessContext() async throws {
    let f = makeSendHoldFixture("001")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            let fresh = try await holdPostHuman(client, f, content: "fresh unread before agent-api send")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent-api draft\",\"seenUpToSeq\":\(baseline.seq)}"
            )
            #expect(held.status == .ok)
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["outcome"] as? String == "held")
            #expect(body["subtype"] as? String == "freshness")
            #expect(body["reason"] as? String == "newer_messages_available")
            let factId = try #require(body["producerFactId"] as? String)
            #expect(factId.hasPrefix("freshness_decision_fact:"))
            #expect(factId.count == "freshness_decision_fact:".count + 64)
            #expect(body["available_actions"] as? [String] == ["check_messages", "send_draft", "send_anyway"])
            #expect(body["newMessageCount"] as? Int == 1)
            #expect(body["shownMessageCount"] as? Int == 1)
            #expect(body["omittedMessageCount"] as? Int == 0)
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.map { $0["id"] as? String } == [fresh.id])
            #expect(body["seenUpToSeq"] as? Int == fresh.seq)
            #expect(body["pendingMentionActions"] == nil)
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == fresh.seq)

            let rows = try await holdChannelMessages(client, fixture: f)
            #expect(!rows.contains { $0["content"] as? String == "agent-api draft" }, "a held draft must not be persisted")
        }
    }
}

@Test func agentApiSendHoldsOnlyForNewerMessagesFromOthers() async throws {
    let f = makeSendHoldFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            try await holdSendOwnProgress(client, f, content: "own later progress")
            let sent = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"follow-up after own progress\",\"seenUpToSeq\":\(baseline.seq)}"
            )
            #expect(sent.status == .ok)
            let body = try holdJSON(sent)
            #expect(body["state"] as? String == "sent")
            #expect(body["messageId"] as? String != nil)
            let rows = try await holdChannelMessages(client, fixture: f)
            #expect(rows.contains { $0["content"] as? String == "follow-up after own progress" })
        }
    }
}

@Test func agentApiSendHoldShowsBoundedContextAndKeepsUnshownMessagesUnread() async throws {
    let f = makeSendHoldFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            f.accounts.setAgentReadCursorForTesting(agentId: f.agentId, channelId: f.channelId, seq: baseline.seq)
            var unread: [(id: String, seq: Int)] = []
            for index in 1...5 {
                unread.append(try await holdPostHuman(client, f, content: "fresh unread \(index)"))
            }
            let latest = try #require(unread.last)
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent-api draft with many unread messages\",\"seenUpToSeq\":\(baseline.seq)}"
            )
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["newMessageCount"] as? Int == 5)
            #expect(body["shownMessageCount"] as? Int == 3)
            #expect(body["omittedMessageCount"] as? Int == 2)
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.map { $0["content"] as? String } == ["fresh unread 3", "fresh unread 4", "fresh unread 5"])
            #expect(body["seenUpToSeq"] as? Int == latest.seq)
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == baseline.seq, "omitted messages stay unread")

            let one = try await holdPostHuman(client, f, content: "one fresh unread")
            let single = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent-api draft with one unread message\",\"seenUpToSeq\":\(latest.seq)}"
            )
            let singleBody = try holdJSON(single)
            #expect(singleBody["state"] as? String == "held")
            #expect(singleBody["omittedMessageCount"] as? Int == 0)
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == one.seq, "showing every held message reads through to it")
        }
    }
}

@Test func agentApiSendWithheldHoldAdvancesNothingAndContinuesOnDemand() async throws {
    let f = makeSendHoldFixture("004")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            _ = try await holdPostHuman(client, f, content: "peer reviewer verdict: REQUEST CHANGES")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"my independent verdict\",\"seenUpToSeq\":\(baseline.seq),\"freshnessContextMode\":\"withheld\",\"draftReholdCount\":99}"
            )
            #expect(held.status == .ok)
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["freshnessContextMode"] as? String == "withheld")
            #expect(body["withheldMessageCount"] as? Int == 1)
            #expect(body.count == 3, "withheld holds expose only held state plus the count")
            #expect(!(held.body.string ?? "").contains("REQUEST CHANGES"))
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == 0)

            let continued = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"my independent verdict\",\"sendDraft\":true,\"continueAnyway\":true,\"seenUpToSeq\":\(baseline.seq),\"freshnessContextMode\":\"withheld\"}"
            )
            #expect(continued.status == .ok)
            let continuedBody = try holdJSON(continued)
            #expect(continuedBody["state"] as? String == "sent")
            #expect(continuedBody["messageId"] as? String != nil)
            #expect(continuedBody["seenUpToSeq"] == nil)
            let rows = try await holdChannelMessages(client, fixture: f)
            #expect(rows.contains { $0["content"] as? String == "my independent verdict" })
        }
    }
}

@Test func agentApiSendHonorsSeenUpToSeqOverTheReadCursor() async throws {
    let f = makeSendHoldFixture("005")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            let fresh = try await holdPostHuman(client, f, content: "fresh unread before read cursor advance")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent-api draft with stale model state\",\"seenUpToSeq\":\(baseline.seq)}"
            )
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["newMessageCount"] as? Int == 1)
            #expect((body["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == fresh.id)
            #expect(body["seenUpToSeq"] as? Int == fresh.seq)
        }
    }
}

@Test func agentApiSendHeldEnvelopeCarriesTheProjectedFreshnessDecision() async throws {
    let f = makeSendHoldFixture("101")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            let fresh = try await holdPostHuman(client, f, content: "fresh message before projected hold")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent-api draft\",\"seenUpToSeq\":\(baseline.seq)}"
            )
            let body = try holdJSON(held)
            #expect(body["ok"] as? Bool == true)
            #expect(body["state"] as? String == "held")
            #expect(body["outcome"] as? String == "held")
            #expect(body["subtype"] as? String == "freshness")
            #expect(body["reason"] as? String == "newer_messages_available")
            #expect(body["decision"] as? String == "syncing_hold")
            let factId = try #require(body["producerFactId"] as? String)
            #expect(factId.hasPrefix("freshness_decision_fact:"))
            #expect(factId.dropFirst("freshness_decision_fact:".count).allSatisfy { $0.isHexDigit })
            #expect(factId.count == "freshness_decision_fact:".count + 64)
            #expect(body["available_actions"] as? [String] == ["check_messages", "send_draft", "send_anyway"])
            #expect(body["newMessageCount"] as? Int == 1)
            #expect(body["shownMessageCount"] as? Int == 1)
            #expect(body["omittedMessageCount"] as? Int == 0)
            #expect(body["seenUpToSeq"] as? Int == fresh.seq)
            #expect(body["seenUpToMessageId"] as? String == fresh.id)
            #expect(body["firstShownSeq"] as? Int == fresh.seq)
            #expect((body["mentionAnnotation"] as? [String: Any])?["formalMentionCount"] as? Int == 0)
            #expect(body["pendingMentionActions"] == nil)
            #expect(body["continueAnywaySuggested"] == nil)
            #expect(body["neverShownRange"] == nil)
            #expect(body["neverShownCount"] == nil)
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.count == 1)
            #expect(heldMessages[0]["message_id"] as? String == fresh.id)
            #expect(heldMessages[0]["channel_type"] as? String == "channel")
            #expect(heldMessages[0]["channel_name"] as? String == f.channelName)
            #expect(heldMessages[0]["channel_id"] as? String == f.channelId)
            #expect(heldMessages[0]["sender_type"] as? String == "human")
            #expect(heldMessages[0]["timestamp"] as? String != nil)
        }
    }
}

@Test func agentApiSendWithoutFreshnessBoundaryReturnsBoundedFirstTouchContext() async throws {
    let f = makeSendHoldFixture("102")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for index in 1...5 {
                _ = try await holdPostHuman(client, f, content: "history message \(index)")
            }
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent-api draft without boundary\"}"
            )
            #expect(held.status == .ok)
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["newMessageCount"] as? Int == 3)
            #expect(body["shownMessageCount"] as? Int == 3)
            #expect(body["omittedMessageCount"] as? Int == 0)
            #expect(body["reason"] as? String == "newer_messages_available")
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.compactMap { $0["content"] as? String } == [
                "history message 3", "history message 4", "history message 5",
            ])
            let latest = try #require(heldMessages.last)
            #expect(body["seenUpToSeq"] as? Int == latest["seq"] as? Int)
        }
    }
}

@Test func agentApiSendDraftCommitsOnceSeenBoundaryReachesLatestState() async throws {
    let f = makeSendHoldFixture("103")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            f.accounts.setAgentReadCursorForTesting(agentId: f.agentId, channelId: f.channelId, seq: baseline.seq)
            let fresh = try await holdPostHuman(client, f, content: "fresh unread before draft commit")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent-api draft\",\"seenUpToSeq\":\(baseline.seq)}"
            )
            let heldBody = try holdJSON(held)
            #expect(heldBody["state"] as? String == "held")
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == fresh.seq)

            let committed = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"sendDraft\":true,\"content\":\"agent-api draft\",\"seenUpToSeq\":\(fresh.seq)}"
            )
            #expect(committed.status == .ok)
            let committedBody = try holdJSON(committed)
            #expect(committedBody["state"] as? String == "sent")
            #expect(committedBody["messageId"] as? String != nil)
            let rows = try await holdChannelMessages(client, fixture: f)
            #expect(rows.contains { $0["content"] as? String == "agent-api draft" })
        }
    }
}

@Test func agentApiSendRejectsDeprecatedContinueAndDraftlessAnyway() async throws {
    let f = makeSendHoldFixture("104")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let rejected = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"continue attempt\",\"continue\":true}"
            )
            #expect(rejected.status == .badRequest)
            #expect((try holdJSON(rejected)["error"] as? String)?.contains("--continue is no longer supported") == true)

            let anywayWithoutDraft = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"anyway attempt\",\"continueAnyway\":true}"
            )
            #expect(anywayWithoutDraft.status == .badRequest)
            #expect(try holdJSON(anywayWithoutDraft)["error"] as? String == "--send-draft --anyway requires a saved draft")

            let rows = try await holdChannelMessages(client, fixture: f)
            #expect(rows.isEmpty)
        }
    }
}

@Test func agentApiSendRequiresContentUnlessReconciling() async throws {
    let f = makeSendHoldFixture("105")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let empty = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"sendDraft\":true}"
            )
            #expect(empty.status == .badRequest)
            #expect(try holdJSON(empty)["error"] as? String == "Content is required")
        }
    }
}

@Test func agentApiHeldContextCarriesDMTargetPeerIdentity() async throws {
    let f = makeSendHoldFixture("106")
    let dmId = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.agentId)
    for member in [f.ownerId, f.agentId] {
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: dmId, memberId: member, kind: "dm", name: "dm")
    }
    f.accounts.oauth.removeChannelHuman(channelId: dmId, userId: f.agentId)
    f.accounts.oauth.addChannelAgent(channelId: dmId, agentId: f.agentId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await client.send(.post, headers: holdHumanHeaders(f.ownerToken, f.serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(dmId)\",\"content\":\"dm baseline\"}")
            }
            let baselineId = try #require(try holdJSON(baseline)["id"] as? String)
            let baselineSeq = try #require(f.accounts.humanMessageSequence(id: baselineId))
            _ = try await client.send(.post, headers: holdHumanHeaders(f.ownerToken, f.serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(dmId)\",\"content\":\"dm fresh the agent has not seen\"}")
            }
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"dm:@\(f.ownerName)\",\"content\":\"stale dm draft\",\"seenUpToSeq\":\(baselineSeq)}"
            )
            #expect(held.status == .ok)
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.count == 1)
            #expect(heldMessages[0]["content"] as? String == "dm fresh the agent has not seen")
            #expect(heldMessages[0]["channel_type"] as? String == "dm")
            #expect(heldMessages[0]["channel_name"] as? String == f.ownerName)
        }
    }
}

@Test func agentApiHeldContextOnAChannelThreadCarriesTheParentIdentity() async throws {
    let f = makeSendHoldFixture("107")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let parent = try await holdPostHuman(client, f, content: "channel thread parent")
            let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: f.channelId, parentMessageId: parent.id)
            for member in [f.ownerId, f.agentId] {
                f.accounts.addPostableChannel(serverId: f.serverId, channelId: threadId, memberId: member, kind: "thread", parentChannelId: f.channelId, parentMessageId: parent.id, name: "thread")
            }
            f.accounts.oauth.addChannelAgent(channelId: threadId, agentId: f.agentId)
            _ = f.accounts.addChannelMessageForTesting(channelId: threadId, content: "channel thread reply", senderId: f.ownerId)
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName):\(parent.id.prefix(8))\",\"content\":\"stale channel thread reply\",\"seenUpToSeq\":\(parent.seq)}"
            )
            #expect(held.status == .ok)
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.count == 1)
            #expect(heldMessages[0]["content"] as? String == "channel thread reply")
            #expect(heldMessages[0]["channel_type"] as? String == "thread")
            #expect(heldMessages[0]["parent_channel_type"] as? String == "channel")
            #expect(heldMessages[0]["parent_channel_name"] as? String == f.channelName)
        }
    }
}

@Test func agentApiHeldEnvelopeCountsFormalMentionsInsideTheSeenBoundaryOnly() async throws {
    let f = makeSendHoldFixture("108")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            let readCoveredMention = try await holdPostHuman(client, f, content: "read-covered @\(f.agentName)")
            let unreadMention = try await holdPostHuman(client, f, content: "still-unread @\(f.agentName)")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"draft after reading the first mention\",\"seenUpToSeq\":\(readCoveredMention.seq)}"
            )
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["newMessageCount"] as? Int == 1)
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.map { $0["id"] as? String } == [unreadMention.id])
            #expect((body["mentionAnnotation"] as? [String: Any])?["formalMentionCount"] as? Int == 1)
            #expect(readCoveredMention.seq < unreadMention.seq)
            #expect(baseline.seq < readCoveredMention.seq)
        }
    }
}

@Test func agentApiSendSuggestsAnywayAfterThreeReholds() async throws {
    let f = makeSendHoldFixture("109")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            _ = try await holdPostHuman(client, f, content: "fresh unread")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"sendDraft\":true,\"content\":\"draft\",\"seenUpToSeq\":\(baseline.seq),\"draftReholdCount\":3}"
            )
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["continueAnywaySuggested"] as? Bool == true)
        }
    }
}

@Test func agentApiHeldContextExcludesNewerMessagesFromTheSender() async throws {
    let f = makeSendHoldFixture("110")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await holdPostHuman(client, f, content: "baseline")
            let peer = try await holdPostHuman(client, f, content: "peer update")
            try await holdSendOwnProgress(client, f, content: "own later progress")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"stale follow-up\",\"seenUpToSeq\":\(baseline.seq)}"
            )
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["newMessageCount"] as? Int == 1)
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.map { $0["id"] as? String } == [peer.id])
        }
    }
}

/// The shared projector's `channelCardRev`: `v1:` plus two FNV-1a 32-bit hashes
/// over the fixed-order JSON tuple of what the card shows.
private func holdChannelCardRev(_ card: [String: Any]) -> String {
    let type = (card["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let visibility: String
    if type == "joint" { visibility = "joint" } else if type == "private" || type == "dm" { visibility = "private" } else { visibility = "public" }
    let description = (card["description"] as? String ?? "")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    let tuple: [Any] = [card["name"] as? String ?? "", visibility, card["archived"] as? Bool == true, description]
    let data = try! JSONSerialization.data(withJSONObject: tuple, options: [.fragmentsAllowed])
    let text = String(decoding: data, as: UTF8.self)
    func fnv1a32(_ text: String, _ seed: UInt32) -> UInt32 {
        var hash = seed
        for unit in text.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
    return String(format: "v1:%08x%08x", fnv1a32(text, 0x811c_9dc5), fnv1a32(text, 0x050c_5d1f))
}

private func holdCard(_ f: SendHoldFixture, description: String? = nil, archived: Bool = false) -> [String: Any] {
    var card: [String: Any] = [
        "id": f.channelId,
        "name": f.channelName,
        "type": "channel",
        "archived": archived,
    ]
    card["description"] = description ?? NSNull()
    return card
}

@Test func agentApiSendChecksTheChannelCardOnlyWhenTheClientNamesIt() async throws {
    let f = makeSendHoldFixture("201")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let plain = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"no card field\"}"
            )
            let plainBody = try holdJSON(plain)
            #expect(plainBody["state"] as? String == "sent")
            #expect(plainBody["channelCard"] == nil)
            let plainSeq = try #require(plainBody["messageSeq"] as? Int)

            let unseen = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"first post this context\",\"seenUpToSeq\":\(plainSeq),\"seenCards\":{\"channel\":null}}"
            )
            let unseenBody = try holdJSON(unseen)
            #expect(unseenBody["state"] as? String == "held")
            #expect(unseenBody["holdReasons"] as? [String] == ["channel_card"])
            #expect(unseenBody["newMessageCount"] as? Int == 0)
            let unseenCard = try #require(unseenBody["channelCard"] as? [String: Any])
            #expect(unseenCard["id"] as? String == f.channelId)
            #expect(unseenCard["name"] as? String == f.channelName)
            #expect(unseenCard["type"] as? String == "channel")
            #expect(unseenCard["description"] == nil || unseenCard["description"] is NSNull)
            #expect(unseenCard["archived"] as? Bool == false)
            #expect(unseenBody["channelCardChanged"] == nil)
            let rowsAfterHold = try await holdChannelMessages(client, fixture: f)
            #expect(rowsAfterHold.count == 1, "a card-only hold must not post")

            let seen = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"card seen\",\"seenUpToSeq\":\(plainSeq),\"seenCards\":{\"channel\":\"\(holdChannelCardRev(holdCard(f)))\"}}"
            )
            let seenBody = try holdJSON(seen)
            #expect(seenBody["state"] as? String == "sent")
            #expect(seenBody["channelCard"] == nil)

            _ = f.accounts.oauth.updateChannel(id: f.channelId, name: nil, description: "Release coordination only.", systemMessage: nil)
            let changed = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"card changed since\",\"seenUpToSeq\":\(plainSeq),\"seenCards\":{\"channel\":\"\(holdChannelCardRev(holdCard(f)))\"}}"
            )
            let changedBody = try holdJSON(changed)
            #expect(changedBody["state"] as? String == "sent")
            let changedCard = try #require(changedBody["channelCard"] as? [String: Any])
            #expect(changedCard["description"] as? String == "Release coordination only.")
            #expect(changedBody["channelCardChanged"] as? Bool == true)
        }
    }
}

@Test func agentApiSendUsesTheParentChannelCardForAThreadTarget() async throws {
    let f = makeSendHoldFixture("202")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let parent = try await holdPostHuman(client, f, content: "thread root for the card")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName):\(parent.id.prefix(8))\",\"content\":\"thread post with unseen card\",\"seenUpToSeq\":\(parent.seq),\"seenCards\":{\"channel\":null}}"
            )
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["holdReasons"] as? [String] == ["channel_card"])
            let card = try #require(body["channelCard"] as? [String: Any])
            #expect(card["id"] as? String == f.channelId, "a thread carries its parent channel's card")
        }
    }
}

@Test func agentApiSendHoldsUnreadMessagesAndAnUnseenChannelCardInOneHold() async throws {
    let f = makeSendHoldFixture("203")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"before\"}"
            )
            let firstSeq = try #require(try holdJSON(first)["messageSeq"] as? Int)
            let fresh = try await holdPostHuman(client, f, content: "news the agent has not seen")
            let held = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"reply\",\"seenUpToSeq\":\(firstSeq),\"seenCards\":{\"channel\":null}}"
            )
            let body = try holdJSON(held)
            #expect(body["state"] as? String == "held")
            #expect(body["holdReasons"] as? [String] == ["unread_messages", "channel_card"])
            #expect(body["newMessageCount"] as? Int == 1)
            let card = try #require(body["channelCard"] as? [String: Any])
            #expect(card["id"] as? String == f.channelId)
            let heldMessages = try #require(body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.first?["id"] as? String == fresh.id)
        }
    }
}

@Test func agentApiSendAnywayCommitsAnUnseenCardAndReturnsIt() async throws {
    let f = makeSendHoldFixture("204")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let anyway = try await holdSend(
                client,
                key: f.agentKey,
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"anyway\",\"sendDraft\":true,\"continueAnyway\":true,\"seenCards\":{\"channel\":null}}"
            )
            let body = try holdJSON(anyway)
            #expect(body["state"] as? String == "sent")
            let card = try #require(body["channelCard"] as? [String: Any])
            #expect(card["id"] as? String == f.channelId)
            #expect(body["channelCardChanged"] == nil)
        }
    }
}
