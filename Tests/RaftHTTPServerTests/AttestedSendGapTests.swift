import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// `internal.attestedSend.api` gaps: attested-send mode semantics, E1 formal
/// mention exemption, legacy receive-ack compatibility checkpoint, new-thread
/// parent seeding, and client-declared replacement metadata. The remaining
/// cases of the module are covered by `InternalAgentSendHoldTests` and
/// `AgentSendFreshnessContextTests`.
@Suite
struct AttestedSendGapTests {
    struct Fixture {
        let accounts: EmailLoginDirectory
        let serverId: String
        let ownerId: String
        let ownerToken: String
        let channelId: String
        let channelName: String
        let agentId: String
        let agentName: String
        let agentKey: String
        let peerId: String
        let peerName: String
        let peerKey: String
        let machineKey: String
    }

    private func makeFixture(_ suffix: String) -> Fixture {
        let accounts = EmailLoginDirectory()
        let ownerId = "11111111-1111-4111-8111-000001170\(suffix)"
        let serverId = "33333333-3333-4333-8333-000001170\(suffix)"
        accounts.addAccount(id: ownerId, email: "attested-gap-\(suffix)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "attested-gap-\(suffix)", name: "Attested Gap \(suffix)", ownerId: ownerId)
        let channelName = "attested-gap-room-\(suffix)"
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        let agentName = "GapBot\(suffix)"
        let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        let peerName = "GapPeer\(suffix)"
        let peerId = accounts.oauth.createAgent(serverId: serverId, name: peerName, creatorUserId: ownerId, runtime: "claude")
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: peerId)
        accounts.setSendFreshnessModeForTesting("force")
        return Fixture(
            accounts: accounts,
            serverId: serverId,
            ownerId: ownerId,
            ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
            channelId: channelId,
            channelName: channelName,
            agentId: agentId,
            agentName: agentName,
            agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "gap-\(suffix)"),
            peerId: peerId,
            peerName: peerName,
            peerKey: accounts.mintAgentCredential(agentId: peerId, scopes: ["read", "send"], name: "peer-\(suffix)"),
            machineKey: accounts.registerMachineForAgent(serverId: serverId, agentId: agentId)
        )
    }

    private func humanHeaders(_ fixture: Fixture) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(fixture.ownerToken)"
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
        return headers
    }

    private func agentHeaders(_ key: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(key)"
        headers[.contentType] = "application/json"
        return headers
    }

    private func json(_ response: ClientResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    }

    private func postHuman(
        _ client: any Client,
        _ fixture: Fixture,
        _ content: String,
        channelId: String? = nil
    ) async throws -> (id: String, seq: Int) {
        let channel = channelId ?? fixture.channelId
        let response = try await client.send(.post, headers: humanHeaders(fixture), to: "/api/messages") { request in
            request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\(jsonStringTest(content))}")
        }
        let body = json(response)
        let id = body["id"] as? String ?? ""
        return (id, fixture.accounts.humanMessageSequence(id: id) ?? 0)
    }

    private func sendAgent(
        _ client: any Client,
        key: String,
        body: String
    ) async throws -> ClientResponse {
        try await client.send(.post, headers: agentHeaders(key), to: "/internal/agent-api/send") { request in
            request.body = .init(string: body)
        }
    }

    private func sendBody(target: String, content: String, extra: String = "") -> String {
        "{\"target\":\(jsonStringTest(target)),\"content\":\(jsonStringTest(content))\(extra)}"
    }

    private func jsonStringTest(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    private func events(_ fixture: Fixture, type: String? = nil) -> [[String: Any]] {
        fixture.accounts.attestedSendEventsForTesting().filter { event in
            type == nil || event["eventType"] as? String == type
        }
    }

    private func activity(_ fixture: Fixture, title: String, text: String) -> Bool {
        fixture.accounts.recentAgentSendActivityForTesting(agentId: fixture.agentId).contains { entry in
            (entry["title"] ?? "").contains(title) && (entry["text"] ?? "").contains(text)
        }
    }

    private func createSideChannel(_ fixture: Fixture, name: String, agentMember: Bool) -> String {
        let channelId = fixture.accounts.oauth.createChannel(
            serverId: fixture.serverId,
            name: name,
            creatorUserId: fixture.ownerId
        )
        fixture.accounts.addPostableChannel(
            serverId: fixture.serverId,
            channelId: channelId,
            memberId: fixture.ownerId,
            kind: "channel",
            name: name
        )
        fixture.accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.ownerId)
        if agentMember {
            fixture.accounts.oauth.addChannelAgent(channelId: channelId, agentId: fixture.agentId)
        }
        return channelId
    }

    private func addChannelMessage(_ fixture: Fixture, channelId: String, content: String, senderId: String) -> Int {
        let id = fixture.accounts.addChannelMessageForTesting(
            channelId: channelId,
            content: content,
            senderId: senderId,
            senderType: senderId == fixture.agentId ? "agent" : "human"
        )
        return fixture.accounts.humanMessageSequence(id: id) ?? 0
    }

    // MARK: - 1. mode off

    @Test func modeOffPreservesLegacySendAndRejectsFreshnessMarker() async throws {
        let fixture = makeFixture("001")
        fixture.accounts.setSendFreshnessModeForTesting("off")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await postHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await postHuman(client, fixture, "unread before send")

                let sent = try await sendAgent(client, key: fixture.agentKey, body: sendBody(target: "#\(fixture.channelName)", content: "public staging send"))
                #expect(sent.status == .ok)
                #expect(json(sent)["state"] as? String == "sent")

                let explicit = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(target: "#\(fixture.channelName)", content: "freshness-gated draft", extra: ",\"sendDraft\":true")
                )
                #expect(explicit.status == .forbidden)
                #expect((json(explicit)["error"] as? String ?? "").contains("not enabled"))
            }
        }
        #expect(events(fixture).isEmpty, "mode off must not write attested-send events")
    }

    // MARK: - 2. default-on interface

    @Test func defaultOnDoesNotGateLegacySendButGatesMarkedSend() async throws {
        let fixture = makeFixture("002")
        fixture.accounts.setSendFreshnessModeForTesting(nil)
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await postHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await postHuman(client, fixture, "unread before send")

                let publicSend = try await sendAgent(client, key: fixture.agentKey, body: sendBody(target: "#\(fixture.channelName)", content: "public send does not opt in"))
                #expect(publicSend.status == .ok)
                #expect(json(publicSend)["state"] as? String == "sent")
                let publicSeq = json(publicSend)["messageSeq"] as? Int ?? 0
                #expect(publicSeq > 0)

                var unreadIds: [String] = []
                for index in 1...5 {
                    unreadIds.append(try await postHuman(client, fixture, "unread before freshness send \(index)").id)
                }

                let held = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(target: "#\(fixture.channelName)", content: "send opts in with a freshness marker", extra: ",\"seenUpToSeq\":\(publicSeq)")
                )
                #expect(held.status == .ok)
                let heldBody = json(held)
                #expect(heldBody["state"] as? String == "held")
                #expect(heldBody["outcome"] as? String == "held")
                #expect(heldBody["subtype"] as? String == "freshness")
                #expect(heldBody["reason"] as? String == "newer_messages_available")
                #expect(heldBody["decision"] as? String == "syncing_hold")
                let producerFactId = heldBody["producerFactId"] as? String ?? ""
                #expect(producerFactId.range(of: "^freshness_decision_fact:[0-9a-f]{64}$", options: .regularExpression) != nil)
                #expect(heldBody["available_actions"] as? [String] == ["check_messages", "send_draft", "send_anyway"])
                #expect(heldBody["newMessageCount"] as? Int == 5)
                #expect(heldBody["shownMessageCount"] as? Int == 3)
                #expect(heldBody["omittedMessageCount"] as? Int == 2)
                let heldMessages = heldBody["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.compactMap { $0["id"] as? String } == Array(unreadIds.suffix(3)))
                #expect(heldBody["pendingMentionActions"] == nil)
                #expect(activity(fixture, title: "Send held by freshness check", text: "unreviewed synced context for this target: 3 messages"))
                #expect(activity(fixture, title: "Send held by freshness check", text: "reason: this target's latest synced context was not yet in your reviewed context"))
                #expect(activity(fixture, title: "Send held by freshness check", text: "action: review the synced context before sending"))
                let matching = fixture.accounts.recentAgentSendActivityForTesting(agentId: fixture.agentId).first { entry in
                    (entry["title"] ?? "").contains("Send held by freshness check")
                        && (entry["text"] ?? "").contains(
                            "unreviewed synced context for this target: 3 messages"
                        )
                        && entry["producerFactId"] == producerFactId
                }
                #expect(matching != nil)
            }
        }
    }

    // MARK: - 3. E1 mention exemption

    @Test func e1FormalMentionExemptsStaleHoldAndRecordsEvent() async throws {
        let fixture = makeFixture("003")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await postHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let mention = try await postHuman(client, fixture, "please review this @\(fixture.agentName)")

                let response = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(target: "#\(fixture.channelName)", content: "bot reply after mention", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(response.status == .ok)
                #expect(json(response)["state"] as? String == "sent")

                let exempt = events(fixture, type: "e1_exempt")
                #expect(exempt.count == 1)
                #expect(exempt.first?["messageId"] as? String == mention.id)
                let metadata = exempt.first?["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["mentioned_handle"] as? String == fixture.agentName)
                #expect(activity(fixture, title: "Send freshness check passed by mention", text: "reason: direct @\(fixture.agentName) mention"))
            }
        }
    }

    // MARK: - 4. E1 left-exclusive range

    @Test func e1RangeIsLeftExclusive() async throws {
        let fixture = makeFixture("004")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let mention = try await postHuman(client, fixture, "@\(fixture.agentName) old mention")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: mention.seq)
                _ = try await postHuman(client, fixture, "later non-mention chatter")

                let response = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(target: "#\(fixture.channelName)", content: "bot reply should hold", extra: ",\"seenUpToSeq\":\(mention.seq)")
                )
                #expect(response.status == .ok)
                #expect(json(response)["state"] as? String == "held")
                #expect(json(response)["newMessageCount"] as? Int == 1)

                #expect(events(fixture, type: "e1_exempt").isEmpty)
                let gate = events(fixture, type: "gate_triggered")
                #expect(gate.count == 1)
                let metadata = gate.first?["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["last_seen_msg_id"] as? String == mention.id)
            }
        }
    }

    @Test func nonFormalMentionDoesNotExempt() async throws {
        let fixture = makeFixture("005")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await postHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await postHuman(client, fixture, "@everyone take a look")

                let response = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(target: "#\(fixture.channelName)", content: "bot reply should still hold", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(json(response)["state"] as? String == "held")
                #expect(events(fixture, type: "e1_exempt").isEmpty)
            }
        }
    }

    // MARK: - 5. legacy receive-ack

    @Test func receiveAckIsVolatileWhenMachineAdvertisesModelSeenCapability() async throws {
        let fixture = makeFixture("006")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await postHuman(client, fixture, "model-seen capable baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let unread = try await postHuman(client, fixture, "model-seen capable delivery ack")
                fixture.accounts.setMachineModelSeenCapabilityForTesting(agentId: fixture.agentId, enabled: true)

                let ack = try await client.send(
                    .post,
                    headers: agentHeaders(fixture.machineKey),
                    to: "/internal/agent/\(fixture.agentId)/receive-ack"
                ) { request in
                    request.body = .init(string: "{\"seqs\":[\(unread.seq)]}")
                }
                #expect(ack.status == .ok)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == baseline.seq)
            }
        }
    }

    @Test func receiveAckCheckpointIsPerChannelAndMembershipScoped() async throws {
        let fixture = makeFixture("007")
        let memberChannel = createSideChannel(fixture, name: "ack-member-room", agentMember: true)
        let nonMemberChannel = createSideChannel(fixture, name: "ack-non-member-room", agentMember: false)
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let mainFirst = try await postHuman(client, fixture, "main first acked")
                let mainSecond = try await postHuman(client, fixture, "main second acked")
                let memberFirst = try await postHuman(client, fixture, "member first acked", channelId: memberChannel)
                let memberSecond = try await postHuman(client, fixture, "member second acked", channelId: memberChannel)
                let nonMemberFirst = try await postHuman(client, fixture, "non-member first acked", channelId: nonMemberChannel)
                let nonMemberSecond = try await postHuman(client, fixture, "non-member second acked", channelId: nonMemberChannel)

                let seqs = [mainFirst.seq, mainSecond.seq, memberFirst.seq, memberSecond.seq, nonMemberFirst.seq, nonMemberSecond.seq]
                let ack = try await client.send(
                    .post,
                    headers: agentHeaders(fixture.machineKey),
                    to: "/internal/agent/\(fixture.agentId)/receive-ack"
                ) { request in
                    request.body = .init(string: "{\"seqs\":[\(seqs.map(String.init).joined(separator: ","))]}")
                }
                #expect(ack.status == .ok)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == mainSecond.seq)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: memberChannel) == memberSecond.seq)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: nonMemberChannel) == 0)
            }
        }
    }

    @Test func receiveAckHandlesThreadAndDMIdempotently() async throws {
        let fixture = makeFixture("008")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let parent = try await postHuman(client, fixture, "thread parent for legacy ack")
                let threadId = fixture.accounts.oauth.createThreadChannel(
                    parentChannelId: fixture.channelId,
                    parentMessageId: parent.id
                )
                fixture.accounts.addPostableChannel(
                    serverId: fixture.serverId,
                    channelId: threadId,
                    memberId: fixture.agentId,
                    kind: "thread",
                    parentChannelId: fixture.channelId,
                    parentMessageId: parent.id,
                    name: "thread"
                )
                let threadFirst = addChannelMessage(fixture, channelId: threadId, content: "thread first acked", senderId: fixture.ownerId)
                let threadSecond = addChannelMessage(fixture, channelId: threadId, content: "thread second acked", senderId: fixture.ownerId)

                let dmId = fixture.accounts.oauth.createDirectChannel(
                    serverId: fixture.serverId,
                    firstUserId: fixture.ownerId,
                    secondUserId: fixture.agentId
                )
                fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: dmId, memberId: fixture.ownerId, kind: "dm", name: "dm")
                fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: dmId, memberId: fixture.agentId, kind: "dm", name: "dm")
                let dmFirst = addChannelMessage(fixture, channelId: dmId, content: "dm first acked", senderId: fixture.ownerId)
                let dmSecond = addChannelMessage(fixture, channelId: dmId, content: "dm second acked", senderId: fixture.ownerId)

                let ackSeqs = [threadFirst, threadSecond, dmFirst, dmSecond, threadSecond, -1, 0, 999_999]
                for _ in 0..<2 {
                    let ack = try await client.send(
                        .post,
                        headers: agentHeaders(fixture.machineKey),
                        to: "/internal/agent/\(fixture.agentId)/receive-ack"
                    ) { request in
                        request.body = .init(string: "{\"seqs\":[\(ackSeqs.map(String.init).joined(separator: ","))]}")
                    }
                    #expect(ack.status == .ok)
                    #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: threadId) == threadSecond)
                    #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: dmId) == dmSecond)
                }
            }
        }
    }

    // MARK: - 6. new-thread parent seeding / concurrent first replies

    @Test func newThreadFirstSendSeedsFreshnessFromParent() async throws {
        let fixture = makeFixture("009")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let parent = try await postHuman(client, fixture, "please reply in this thread")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: parent.seq)
                let threadId = fixture.accounts.oauth.createThreadChannel(
                    parentChannelId: fixture.channelId,
                    parentMessageId: parent.id
                )
                for member in [fixture.agentId, fixture.peerId] {
                    fixture.accounts.addPostableChannel(
                        serverId: fixture.serverId,
                        channelId: threadId,
                        memberId: member,
                        kind: "thread",
                        parentChannelId: fixture.channelId,
                        parentMessageId: parent.id,
                        name: "thread"
                    )
                }
                let target = "#\(fixture.channelName):\(String(parent.id.prefix(8)))"
                let firstReply = try await sendAgent(client, key: fixture.peerKey, body: sendBody(target: target, content: "peer got here first"))
                #expect(firstReply.status == .ok)
                #expect(json(firstReply)["state"] as? String == "sent")
                let firstMessageId = json(firstReply)["messageId"] as? String ?? ""

                let held = try await sendAgent(client, key: fixture.agentKey, body: sendBody(target: target, content: "second reply should reconsider"))
                #expect(json(held)["state"] as? String == "held")
                let heldBody = json(held)
                #expect(heldBody["newMessageCount"] as? Int == 1)
                let heldMessages = heldBody["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.count == 1)
                #expect(heldMessages.first?["id"] as? String == firstMessageId)
                #expect(heldMessages.first?["content"] as? String == "peer got here first")

                let gate = events(fixture, type: "gate_triggered")
                #expect(gate.count == 1)
                let metadata = gate.first?["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["last_seen_msg_id"] as? String == parent.id)
                #expect(metadata["latest_msg_id"] as? String == firstMessageId)
                #expect(metadata["boundary_source"] as? String == "thread_parent")
                #expect(metadata["boundary_seq"] as? Int == parent.seq)
            }
        }
    }

    @Test func concurrentFirstRepliesToNewThreadAreGated() async throws {
        let fixture = makeFixture("010")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let parent = try await postHuman(client, fixture, "count in this thread")
                let threadId = fixture.accounts.oauth.createThreadChannel(
                    parentChannelId: fixture.channelId,
                    parentMessageId: parent.id
                )
                for member in [fixture.agentId, fixture.peerId] {
                    fixture.accounts.addPostableChannel(
                        serverId: fixture.serverId,
                        channelId: threadId,
                        memberId: member,
                        kind: "thread",
                        parentChannelId: fixture.channelId,
                        parentMessageId: parent.id,
                        name: "thread"
                    )
                }
                let target = "#\(fixture.channelName):\(String(parent.id.prefix(8)))"
                let body = sendBody(target: target, content: "1")

                let results = SendResults()
                DispatchQueue.concurrentPerform(iterations: 2) { index in
                    let key = index == 0 ? fixture.agentKey : fixture.peerKey
                    let reply = fixture.accounts.agentSendMessage(
                        authorization: "Bearer \(key)",
                        body: body,
                        v2: true
                    )
                    let parsed = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any] ?? [:]
                    results.append(parsed)
                }
                let bodies = results.all()
                #expect(bodies.count == 2)
                let sent = bodies.filter { $0["state"] as? String == "sent" }
                let held = bodies.filter { $0["state"] as? String == "held" }
                #expect(sent.count == 1)
                #expect(held.count == 1)
                let sentMessageId = sent.first?["messageId"] as? String ?? ""
                let heldMessages = held.first?["heldMessages"] as? [[String: Any]] ?? []
                #expect(held.first?["newMessageCount"] as? Int == 1)
                #expect(heldMessages.first?["id"] as? String == sentMessageId)
                #expect(heldMessages.first?["content"] as? String == "1")
                #expect(events(fixture, type: "gate_triggered").count == 1)
            }
        }
    }

    @Test func sendDraftReholdShowsOnlyIncrementalMessages() async throws {
        let fixture = makeFixture("012")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await postHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let firstUnread = try await postHuman(client, fixture, "first unread")
                let firstHold = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(target: "#\(fixture.channelName)", content: "draft one", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(json(firstHold)["state"] as? String == "held")
                #expect(json(firstHold)["newMessageCount"] as? Int == 1)
                #expect((json(firstHold)["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == firstUnread.id)
                let seen = json(firstHold)["seenUpToSeq"] as? Int ?? 0

                let secondUnread = try await postHuman(client, fixture, "second unread")
                let rehold = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(
                        target: "#\(fixture.channelName)",
                        content: "draft one",
                        extra: ",\"sendDraft\":true,\"draftReholdCount\":1,\"seenUpToSeq\":\(seen)"
                    )
                )
                #expect(json(rehold)["state"] as? String == "held")
                #expect(json(rehold)["newMessageCount"] as? Int == 1)
                let held = json(rehold)["heldMessages"] as? [[String: Any]] ?? []
                #expect(held.map { $0["id"] as? String } == [secondUnread.id])
                #expect(events(fixture, type: "gate_triggered").count == 2)
            }
        }
    }

    // MARK: - 7. replacement metadata

    @Test func replacementMetadataIsClientDeclaredAndEventOnly() async throws {
        let fixture = makeFixture("011")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await postHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await postHuman(client, fixture, "first unread")
                let firstHold = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(target: "#\(fixture.channelName)", content: "draft one", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(json(firstHold)["state"] as? String == "held")
                let seen = json(firstHold)["seenUpToSeq"] as? Int ?? 0
                _ = try await postHuman(client, fixture, "second unread")

                let secondHold = try await sendAgent(
                    client,
                    key: fixture.agentKey,
                    body: sendBody(
                        target: "#\(fixture.channelName)",
                        content: "draft two",
                        extra: ",\"draftReplacedExisting\":true,\"seenUpToSeq\":\(seen)"
                    )
                )
                #expect(json(secondHold)["state"] as? String == "held")
                let serialized = secondHold.body.string ?? ""
                #expect(!serialized.contains("draftReplacedExisting"))
                #expect(!serialized.contains("draft_replaced_existing"))

                let gates = events(fixture, type: "gate_triggered")
                #expect(gates.count == 2)
                let metadata = gates.last?["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["draft_replaced_existing"] as? Bool == true)
            }
        }
    }
}

/// Thread-safe collector for the concurrent first-reply case.
private final class SendResults: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []

    func append(_ row: [String: Any]) {
        lock.lock(); rows.append(row); lock.unlock()
    }

    func all() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return rows
    }
}
