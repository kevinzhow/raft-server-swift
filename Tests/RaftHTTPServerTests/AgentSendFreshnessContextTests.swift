import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct FreshnessFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001113001"
    let ownerId = "11111111-1111-4111-8111-000001113001"
    var agentId = ""
    var channelId = ""
    var channelName = "freshness-room"
    var key = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "freshness-owner@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "freshness", name: "Freshness", ownerId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "FreshnessBot", creatorUserId: ownerId, runtime: "claude")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId, type: "channel")
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName, humanIds: [ownerId], agentIds: [agentId])
        key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read", "channels"], name: "freshness")
    }

    func human(_ content: String) -> (id: String, seq: Int) {
        let id = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: content)
        return (id, accounts.messageSeqForTesting(messageId: id) ?? 0)
    }

    func selfMessage(_ content: String) -> (id: String, seq: Int) {
        let id = accounts.addHumanMessageForTesting(channelId: channelId, senderId: agentId, content: content, senderType: "agent")
        return (id, accounts.messageSeqForTesting(messageId: id) ?? 0)
    }
}

private func freshnessSend(_ client: any Client, _ key: String, _ target: String, _ content: String, seen: Int) async throws -> [String: Any] {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    let data = try JSONSerialization.data(withJSONObject: ["target": target, "content": content, "seenUpToSeq": seen])
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
        request.body = .init(data: data)
    }
    return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func senderOnlyNewerDoesNotHoldButPeerRowsDo() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    _ = fixture.selfMessage("previous agent progress")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let ownOnly = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "follow-up after own progress", seen: baseline.seq)
            #expect(ownOnly["state"] as? String == "sent")

            let freshUnread = fixture.human("peer update")
            _ = fixture.selfMessage("own later progress")
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "stale follow-up", seen: baseline.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 1)
            let heldRows = held["heldMessages"] as? [[String: Any]] ?? []
            #expect(heldRows.count == 1)
            #expect(heldRows.first?["id"] as? String == freshUnread.id)
            #expect(held["seenUpToSeq"] as? Int == freshUnread.seq)
        }
    }
}

@Test func readCursorIsNotFreshnessProofAndBoundedHoldDoesNotReadThrough() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    let freshUnread = fixture.human("fresh unread before read cursor advance")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: freshUnread.seq)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "stale model state", seen: baseline.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 1)
            #expect((held["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == freshUnread.id)
            #expect(held["seenUpToSeq"] as? Int == freshUnread.seq)
        }
    }

    var bounded = FreshnessFixture()
    bounded.seed()
    let boundedAccounts = bounded.accounts
    let base = bounded.human("baseline")
    boundedAccounts.markAgentLegacyReadForTesting(agentId: bounded.agentId, channelId: bounded.channelId, seq: base.seq)
    var latestSeq = 0
    for index in 1...5 {
        latestSeq = bounded.human("fresh unread \(index)").seq
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: boundedAccounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, bounded.key, "#\(bounded.channelName)", "many unread", seen: base.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 5)
            #expect(held["shownMessageCount"] as? Int == 3)
            #expect(held["omittedMessageCount"] as? Int == 2)
            #expect((held["heldMessages"] as? [[String: Any]])?.count == 3)
            #expect(held["seenUpToSeq"] as? Int == latestSeq)
            #expect(boundedAccounts.agentReadCursorForTesting(agentId: bounded.agentId, channelId: bounded.channelId) == base.seq)
        }
    }

    var allShown = FreshnessFixture()
    allShown.seed()
    let shownAccounts = allShown.accounts
    let shownBase = allShown.human("baseline")
    shownAccounts.markAgentLegacyReadForTesting(agentId: allShown.agentId, channelId: allShown.channelId, seq: shownBase.seq)
    let fresh = allShown.human("one fresh unread")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: shownAccounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, allShown.key, "#\(allShown.channelName)", "one unread", seen: shownBase.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["omittedMessageCount"] as? Int == 0)
            #expect(shownAccounts.agentReadCursorForTesting(agentId: allShown.agentId, channelId: allShown.channelId) == fresh.seq)
        }
    }
}

@Test func staleDraftHoldsWithEnvelopeAndSendDraftCommits() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    let fresh = fixture.human("fresh unread before agent-api send")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "agent-api draft", seen: baseline.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["outcome"] as? String == "held")
            #expect(held["subtype"] as? String == "freshness")
            #expect(held["reason"] as? String == "newer_messages_available")
            #expect(((held["producerFactId"] as? String) ?? "").hasPrefix("freshness_decision_fact:"))
            #expect(held["available_actions"] as? [String] == ["check_messages", "send_draft", "send_anyway"])
            #expect(held["newMessageCount"] as? Int == 1)
            #expect(held["shownMessageCount"] as? Int == 1)
            #expect(held["omittedMessageCount"] as? Int == 0)
            #expect((held["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == fresh.id)
            #expect(held["seenUpToSeq"] as? Int == fresh.seq)
            #expect(held["pendingMentionActions"] == nil)
            #expect(accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == fresh.seq)

            let committed = try await draftSend(client, fixture.key, "#\(fixture.channelName)", "agent-api draft", seen: fresh.seq)
            #expect(committed["state"] as? String == "sent")
            let messageId = try #require(committed["messageId"] as? String)
            #expect(accounts.messageCountForTesting(channelId: fixture.channelId) == 3)
            #expect(accounts.messageAttachmentIdsForTesting(messageId: messageId).isEmpty)
        }
    }
}

@Test func firstTouchWithoutBoundaryReturnsBoundedContext() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    accounts.setSendFreshnessModeForTesting("force")
    var latest = 0
    for index in 1...5 {
        latest = fixture.human("history message \(index)").seq
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.key)"
            headers[.contentType] = "application/json"
            let data = try JSONSerialization.data(withJSONObject: ["target": "#\(fixture.channelName)", "content": "draft without boundary"])
            let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
                request.body = .init(data: data)
            }
            let held = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 3)
            #expect(held["shownMessageCount"] as? Int == 3)
            #expect(held["omittedMessageCount"] as? Int == 0)
            #expect((held["heldMessages"] as? [[String: Any]])?.compactMap { $0["content"] as? String } == ["history message 3", "history message 4", "history message 5"])
            #expect(held["seenUpToSeq"] as? Int == latest)
        }
    }
}

private func draftSend(_ client: any Client, _ key: String, _ target: String, _ content: String, seen: Int) async throws -> [String: Any] {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    let data = try JSONSerialization.data(withJSONObject: ["target": target, "content": content, "sendDraft": true, "seenUpToSeq": seen])
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
        request.body = .init(data: data)
    }
    return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func muteSuppressesOrdinaryFreshnessButPierceHolds() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline before mute")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.key)"
            headers[.contentType] = "application/json"
            let mute = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/channels/\(fixture.channelId)/mute")) { request in
                request.body = .init(string: "{}")
            }
            #expect(mute.status == .ok)

            _ = fixture.human("muted ordinary before agent-api send")
            let sent = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "send after muted ordinary", seen: baseline.seq)
            #expect(sent["state"] as? String == "sent", "muted ordinary must not hold")

            let pierceId = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "@FreshnessBot pierce after muted ordinary")
            accounts.addStoredMentionForTesting(channelId: fixture.channelId, messageId: pierceId, targetId: fixture.agentId, targetType: "agent", handle: "FreshnessBot")
            let pierceSeq = accounts.messageSeqForTesting(messageId: pierceId) ?? 0
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "send after pierce", seen: baseline.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 1)
            #expect((held["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == pierceId)
            #expect(held["seenUpToSeq"] as? Int == pierceSeq)
        }
    }
}

@Test func heldMentionRowsAndCountShareTheBoundary() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    let readCoveredId = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "@FreshnessBot read-covered")
    accounts.addStoredMentionForTesting(channelId: fixture.channelId, messageId: readCoveredId, targetId: fixture.agentId, targetType: "agent", handle: "FreshnessBot")
    let readCoveredSeq = accounts.messageSeqForTesting(messageId: readCoveredId) ?? 0
    let unreadId = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "@FreshnessBot still-unread")
    accounts.addStoredMentionForTesting(channelId: fixture.channelId, messageId: unreadId, targetId: fixture.agentId, targetType: "agent", handle: "FreshnessBot")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "draft after reading first mention", seen: readCoveredSeq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 1)
            #expect((held["heldMessages"] as? [[String: Any]])?.map { $0["id"] as? String } == [unreadId])
            #expect((held["mentionAnnotation"] as? [String: Any])?["formalMentionCount"] as? Int == 1)
        }
    }
}

@Test func withheldReviewerContextExposesOnlyStateAndCount() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    let poison = "peer reviewer verdict: REQUEST CHANGES at 2042-08-09T10:11:12.000Z"
    _ = fixture.human(poison)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(fixture.key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let held = try await send([
                "target": "#\(fixture.channelName)", "content": "my independent verdict",
                "seenUpToSeq": baseline.seq, "freshnessContextMode": "withheld", "draftReholdCount": 99,
            ])
            #expect(held.0.status == .ok)
            #expect(held.1["state"] as? String == "held")
            #expect(held.1["freshnessContextMode"] as? String == "withheld")
            #expect(held.1["withheldMessageCount"] as? Int == 1)
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: held.1), as: UTF8.self)
            #expect(!serialized.contains("peer reviewer"))
            #expect(!serialized.contains("REQUEST CHANGES"))
            #expect(!serialized.contains("2042-08-09"))
            #expect(accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == baseline.seq)

            let continued = try await send([
                "target": "#\(fixture.channelName)", "content": "my independent verdict",
                "sendDraft": true, "continueAnyway": true, "seenUpToSeq": baseline.seq,
                "freshnessContextMode": "withheld",
            ])
            #expect(continued.0.status == .ok)
            #expect(continued.1["state"] as? String == "sent")
            #expect(continued.1["seenUpToSeq"] == nil)
            let serializedContinued = String(decoding: try JSONSerialization.data(withJSONObject: continued.1), as: UTF8.self)
            #expect(!serializedContinued.contains("peer reviewer"))
            #expect(accounts.messageCountForTesting(channelId: fixture.channelId) == 3)
        }
    }
}

@Test func heldContextCarriesChannelAndThreadIdentity() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    _ = fixture.human("fresh one")
    _ = fixture.human("fresh two")
    let parent = fixture.human("thread parent")
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: fixture.channelId, parentMessageId: parent.id)
    accounts.addThreadChannel(serverId: fixture.serverId, threadChannelId: threadId, parentChannelId: fixture.channelId, parentMessageId: parent.id, memberId: fixture.agentId)
    _ = accounts.addHumanMessageForTesting(channelId: threadId, senderId: fixture.ownerId, content: "thread reply")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let channelHeld = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "stale channel draft", seen: baseline.seq)
            #expect(channelHeld["state"] as? String == "held")
            let channelRows = channelHeld["heldMessages"] as? [[String: Any]] ?? []
            #expect(channelRows.count == 3)
            #expect(channelRows.allSatisfy { ($0["channel_type"] as? String) == "channel" && ($0["channel_name"] as? String) == fixture.channelName })

            let threadHeld = try await freshnessSend(client, fixture.key, "#\(fixture.channelName):\(parent.id.prefix(8))", "stale thread reply", seen: parent.seq)
            #expect(threadHeld["state"] as? String == "held")
            let threadRows = threadHeld["heldMessages"] as? [[String: Any]] ?? []
            #expect(!threadRows.isEmpty)
            #expect(threadRows.allSatisfy {
                ($0["channel_type"] as? String) == "thread"
                    && ($0["parent_channel_type"] as? String) == "channel"
                    && ($0["parent_channel_name"] as? String) == fixture.channelName
                    && ($0["sender_name"] as? String) == "freshness-owner"
            })
        }
    }
}

@Test func heldContextOnDMNamesTheAgentFacingPeer() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let dmId = accounts.seedDMForTesting(serverId: fixture.serverId, humanUserId: fixture.ownerId, agentId: fixture.agentId)
    let baseline = accounts.addHumanMessageForTesting(channelId: dmId, senderId: fixture.ownerId, content: "dm baseline")
    let baselineSeq = accounts.messageSeqForTesting(messageId: baseline) ?? 0
    let fresh = accounts.addHumanMessageForTesting(channelId: dmId, senderId: fixture.ownerId, content: "dm fresh the agent has not seen")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, fixture.key, "dm:@freshness-owner", "stale dm draft", seen: baselineSeq)
            #expect(held["state"] as? String == "held")
            let rows = held["heldMessages"] as? [[String: Any]] ?? []
            #expect(rows.map { $0["id"] as? String } == [fresh])
            #expect(rows.allSatisfy { ($0["channel_type"] as? String) == "dm" && ($0["channel_name"] as? String) == "freshness-owner" })
        }
    }
}

@Test func heldResponseCarriesTrueSkippedCountAndBeforeAnchor() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("skip baseline")
    let noiseChannel = accounts.oauth.createChannel(serverId: fixture.serverId, name: "skip-noise", creatorUserId: fixture.ownerId, type: "channel")
    var planted: [(id: String, seq: Int)] = []
    for index in 1...5 {
        for spacer in 0..<3 {
            _ = accounts.addHumanMessageForTesting(channelId: noiseChannel, senderId: fixture.ownerId, content: "seq spacer \(index)-\(spacer)")
        }
        planted.append(fixture.human("skip fact \(index)"))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "stale reply", seen: baseline.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 5)
            #expect(held["shownMessageCount"] as? Int == 3)
            #expect(held["omittedMessageCount"] as? Int == 2)
            #expect(held["firstShownSeq"] as? Int == planted[2].seq)
            #expect(held["neverShownRange"] == nil)
            #expect(held["neverShownCount"] == nil)
            #expect(planted[1].seq - planted[0].seq + 1 > 2)
        }
    }
}

@Test func heldContextOnJointChannelUsesLocalProjectionName() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let canonicalId = accounts.oauth.createChannel(serverId: fixture.serverId, name: "joint-canonical", creatorUserId: fixture.ownerId, type: "joint")
    let localId = accounts.oauth.createChannel(serverId: fixture.serverId, name: "joint-local-name", creatorUserId: fixture.ownerId, type: "joint")
    accounts.addJointChannelProjection(localChannelId: localId, canonicalChannelId: canonicalId, serverId: fixture.serverId)
    accounts.seedPostableChannelForTesting(serverId: fixture.serverId, channelId: localId, name: "joint-local-name", humanIds: [fixture.ownerId], agentIds: [fixture.agentId])
    let baseline = accounts.addHumanMessageForTesting(channelId: canonicalId, senderId: fixture.ownerId, content: "joint baseline")
    let baselineSeq = accounts.messageSeqForTesting(messageId: baseline) ?? 0
    let fresh = accounts.addHumanMessageForTesting(channelId: canonicalId, senderId: fixture.ownerId, content: "joint fresh")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, fixture.key, "#joint-local-name", "stale joint draft", seen: baselineSeq)
            #expect(held["state"] as? String == "held")
            let rows = held["heldMessages"] as? [[String: Any]] ?? []
            #expect(rows.map { $0["id"] as? String } == [fresh])
            #expect(rows.allSatisfy { ($0["channel_type"] as? String) == "channel" && ($0["channel_name"] as? String) == "joint-local-name" })
        }
    }
}

@Test func heldContextOnDMThreadNamesTheParentPeer() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let dmId = accounts.seedDMForTesting(serverId: fixture.serverId, humanUserId: fixture.ownerId, agentId: fixture.agentId)
    let parent = accounts.addHumanMessageForTesting(channelId: dmId, senderId: fixture.ownerId, content: "dm thread parent")
    let parentSeq = accounts.messageSeqForTesting(messageId: parent) ?? 0
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: dmId, parentMessageId: parent)
    accounts.addThreadChannel(serverId: fixture.serverId, threadChannelId: threadId, parentChannelId: dmId, parentMessageId: parent, memberId: fixture.agentId)
    let reply = accounts.addHumanMessageForTesting(channelId: threadId, senderId: fixture.ownerId, content: "dm thread reply")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let target = "dm:@freshness-owner:\(parent.prefix(8))"
            let held = try await freshnessSend(client, fixture.key, target, "stale dm thread reply", seen: parentSeq)
            #expect(held["state"] as? String == "held")
            let rows = held["heldMessages"] as? [[String: Any]] ?? []
            #expect(rows.map { $0["id"] as? String } == [reply])
            #expect(rows.allSatisfy {
                ($0["channel_type"] as? String) == "thread"
                    && ($0["parent_channel_type"] as? String) == "dm"
                    && ($0["parent_channel_name"] as? String) == "freshness-owner"
                    && ($0["sender_name"] as? String) == "freshness-owner"
            })
        }
    }
}
