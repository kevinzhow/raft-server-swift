import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// `internal.attestedSend.api`: the legacy machine-on-behalf send route
/// (`POST /internal/agent/:agentId/send`) against the pinned upstream contract.
/// Every assertion below is a published request/response or a retained-row
/// read (attested-send event, agent read cursor, activity entry); no
/// orchestrator, inbox or tracer sink is injected.
private struct LegacyHTTPReply: Sendable {
    let status: Int
    let body: String
}

private struct LegacyFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let ownerToken: String
    let channelId: String
    let channelName: String
    let agentId: String
    let agentName: String
    /// A machine-row key whose agent assignment is this agent.
    let machineKey: String
    let secondMachineKey: String
    let secondMachineId: String
    let peerId: String
    let peerName: String
    let peerKey: String
}

private func makeLegacyFixture(_ suffix: String) -> LegacyFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001180\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001180\(suffix)"
    let ownerName = "LegacyOwner\(suffix)"
    accounts.addAccount(id: ownerId, email: "legacy-attested-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: ownerName)
    accounts.oauth.addOwnedServer(id: serverId, slug: "legacy-attested-\(suffix)", name: "Legacy Attested \(suffix)", ownerId: ownerId)
    let channelName = "legacy-attested-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentName = "LegacyBot\(suffix)"
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let peerName = "LegacyPeer\(suffix)"
    let peerId = accounts.oauth.createAgent(serverId: serverId, name: peerName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: peerId)
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "legacy-machine-\(suffix)")
    let machineKey = accounts.machineAPIKey(machineId: machineId) ?? ""
    accounts.assignAgentMachineForTesting(agentId: agentId, machineId: machineId)
    let secondMachineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "legacy-second-machine-\(suffix)")
    let secondMachineKey = accounts.machineAPIKey(machineId: secondMachineId) ?? ""
    accounts.setSendFreshnessModeForTesting("force")
    return LegacyFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        channelId: channelId,
        channelName: channelName,
        agentId: agentId,
        agentName: agentName,
        machineKey: machineKey,
        secondMachineKey: secondMachineKey,
        secondMachineId: secondMachineId,
        peerId: peerId,
        peerName: peerName,
        peerKey: accounts.registerMachineForAgent(serverId: serverId, agentId: peerId)
    )
}

private func legacyHumanHeaders(_ fixture: LegacyFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
    return headers
}

private func legacyAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func legacyJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func legacyPostHuman(
    _ client: any Client,
    _ fixture: LegacyFixture,
    _ content: String,
    channelId: String? = nil
) async throws -> (id: String, seq: Int) {
    let channel = channelId ?? fixture.channelId
    let response = try await client.send(.post, headers: legacyHumanHeaders(fixture), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\(legacyJSONString(content))}")
    }
    let body = legacyJSON(response)
    let id = body["id"] as? String ?? ""
    return (id, body["seq"] as? Int ?? fixture.accounts.humanMessageSequence(id: id) ?? 0)
}

private func legacySend(
    _ client: any Client,
    key: String,
    agentId: String,
    body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: legacyAgentHeaders(key), to: "/internal/agent/\(agentId)/send") { request in
        request.body = .init(string: body)
    }
}

private func legacySendBody(target: String, content: String, extra: String = "") -> String {
    "{\"target\":\(legacyJSONString(target)),\"content\":\(legacyJSONString(content))\(extra)}"
}

private func legacyJSONString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let text = String(decoding: data, as: UTF8.self)
    return String(text.dropFirst().dropLast())
}

private func legacyEvents(_ fixture: LegacyFixture, type: String? = nil) -> [[String: Any]] {
    fixture.accounts.attestedSendEventsForTesting().filter { event in
        type == nil || event["eventType"] as? String == type
    }
}

private func legacyActivity(_ fixture: LegacyFixture, title: String, text: String) -> Bool {
    fixture.accounts.recentAgentSendActivityForTesting(agentId: fixture.agentId).contains { entry in
        (entry["title"] ?? "").contains(title) && (entry["text"] ?? "").contains(text)
    }
}

private func legacyLatestChannelMessage(
    _ client: any Client,
    _ fixture: LegacyFixture,
    channelId: String? = nil
) async throws -> [String: Any] {
    let channel = channelId ?? fixture.channelId
    let response = try await client.get(
        URI(string: "/api/messages/channel/\(channel)"),
        headers: legacyHumanHeaders(fixture)
    )
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let messages = body["messages"] as? [[String: Any]] ?? []
    return messages.max { lhs, rhs in
        (lhs["seq"] as? Int ?? 0) < (rhs["seq"] as? Int ?? 0)
    } ?? [:]
}

private func legacyCreateThread(
    _ fixture: LegacyFixture,
    parentMessageId: String,
    name: String = "thread"
) -> String {
    let threadId = fixture.accounts.oauth.createThreadChannel(
        parentChannelId: fixture.channelId,
        parentMessageId: parentMessageId
    )
    for member in [fixture.ownerId, fixture.agentId, fixture.peerId] {
        fixture.accounts.addPostableChannel(
            serverId: fixture.serverId,
            channelId: threadId,
            memberId: member,
            kind: "thread",
            parentChannelId: fixture.channelId,
            parentMessageId: parentMessageId,
            name: name
        )
    }
    return threadId
}

private func legacyCreateDM(_ fixture: LegacyFixture) -> String {
    let dmId = fixture.accounts.oauth.createDirectChannel(
        serverId: fixture.serverId,
        firstUserId: fixture.ownerId,
        secondUserId: fixture.agentId,
        firstKind: .human,
        secondKind: .agent
    )
    for member in [fixture.ownerId, fixture.agentId] {
        fixture.accounts.addPostableChannel(
            serverId: fixture.serverId,
            channelId: dmId,
            memberId: member,
            kind: "dm",
            name: "dm"
        )
    }
    return dmId
}

@Suite
struct LegacyAttestedSendTests {
    // MARK: - #1 malformed body contract

    @Test func malformedBodiesFailClosedBeforeSideEffects() async throws {
        let fixture = makeLegacyFixture("001")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let before = (
                    fixture.accounts.humanMessageCount,
                    legacyEvents(fixture).count,
                    fixture.accounts.recentAgentSendActivityForTesting(agentId: fixture.agentId).count
                )
                let malformed: [(path: String, body: String)] = [
                    ("target", "{\"target\":{\"channel\":\"\(fixture.channelName)\"},\"content\":\"must not send\"}"),
                    ("content", "{\"target\":\"#\(fixture.channelName)\",\"content\":{\"text\":\"must not send\"}}"),
                    ("sendDraft", "{\"target\":\"#\(fixture.channelName)\",\"content\":\"must not send\",\"sendDraft\":\"true\"}"),
                ]
                for entry in malformed {
                    let response = try await legacySend(client, key: fixture.machineKey, agentId: fixture.agentId, body: entry.body)
                    #expect(response.status == .badRequest)
                    let body = legacyJSON(response)
                    #expect(body["code"] as? String == "legacy_agent_send_contract_invalid")
                    let issues = body["issues"] as? [[String: Any]] ?? []
                    #expect(issues.contains { $0["path"] as? String == entry.path }, "must identify \(entry.path)")
                }
                let after = (
                    fixture.accounts.humanMessageCount,
                    legacyEvents(fixture).count,
                    fixture.accounts.recentAgentSendActivityForTesting(agentId: fixture.agentId).count
                )
                #expect(after.0 == before.0)
                #expect(after.1 == before.1)
                #expect(after.2 == before.2)
            }
        }
    }

    // MARK: - #2/#3 mode semantics

    @Test func modeOffKeepsPlainSendAndRefusesMarkers() async throws {
        let fixture = makeLegacyFixture("002")
        fixture.accounts.setSendFreshnessModeForTesting("off")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await legacyPostHuman(client, fixture, "unread before send")

                let plain = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "public staging send")
                )
                #expect(plain.status == .ok)
                #expect(legacyJSON(plain)["state"] as? String == "sent")

                let marked = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "freshness-gated draft", extra: ",\"sendDraft\":true")
                )
                #expect(marked.status == .forbidden)
                #expect(((legacyJSON(marked)["error"] as? String) ?? "").contains("not enabled"))
            }
        }
        #expect(legacyEvents(fixture).isEmpty)
    }

    @Test func defaultOnGatesMarkedSendWithTheFullHeldEnvelope() async throws {
        let fixture = makeLegacyFixture("003")
        fixture.accounts.setSendFreshnessModeForTesting(nil)
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await legacyPostHuman(client, fixture, "unread before send")

                let publicSend = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "public send does not opt in")
                )
                #expect(publicSend.status == .ok)
                #expect(legacyJSON(publicSend)["state"] as? String == "sent")
                let publicSeq = legacyJSON(publicSend)["messageSeq"] as? Int ?? 0
                #expect(publicSeq > 0)
                let latest = try await legacyLatestChannelMessage(client, fixture)
                #expect(latest["id"] as? String == legacyJSON(publicSend)["messageId"] as? String)

                var unreadIds: [String] = []
                for index in 1...5 {
                    unreadIds.append(try await legacyPostHuman(client, fixture, "unread before freshness send \(index)").id)
                }

                let held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "send opts in with a freshness marker",
                        extra: ",\"seenUpToSeq\":\(publicSeq)"
                    )
                )
                #expect(held.status == .ok)
                let body = legacyJSON(held)
                #expect(body["state"] as? String == "held")
                #expect(body["outcome"] as? String == "held")
                #expect(body["subtype"] as? String == "freshness")
                #expect(body["reason"] as? String == "newer_messages_available")
                #expect(body["decision"] as? String == "syncing_hold")
                let producerFactId = body["producerFactId"] as? String ?? ""
                #expect(producerFactId.range(of: "^freshness_decision_fact:[0-9a-f]{64}$", options: .regularExpression) != nil)
                #expect(body["available_actions"] as? [String] == ["check_messages", "send_draft", "send_anyway"])
                #expect(body["newMessageCount"] as? Int == 5)
                #expect(body["shownMessageCount"] as? Int == 3)
                #expect(body["omittedMessageCount"] as? Int == 2)
                let heldMessages = body["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.compactMap { $0["id"] as? String } == Array(unreadIds.suffix(3)))
                #expect(body["pendingMentionActions"] == nil)
                #expect(legacyActivity(fixture, title: "Send held by freshness check", text: "unreviewed synced context for this target: 3 messages"))
                #expect(legacyActivity(fixture, title: "Send held by freshness check", text: "reason: this target's latest synced context was not yet in your reviewed context"))
                #expect(legacyActivity(fixture, title: "Send held by freshness check", text: "action: review the synced context before sending"))
                let matching = fixture.accounts.recentAgentSendActivityForTesting(agentId: fixture.agentId).first { entry in
                    (entry["title"] ?? "").contains("Send held by freshness check")
                        && entry["producerFactId"] == producerFactId
                }
                #expect(matching != nil)
            }
        }
    }

    // MARK: - #7 bounded first touch

    @Test func channelSendWithoutModelSeenBoundaryReturnsBoundedFirstTouchContext() async throws {
        let fixture = makeLegacyFixture("004")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                var unread: [(id: String, seq: Int)] = []
                for index in 1...5 {
                    unread.append(try await legacyPostHuman(client, fixture, "unread before first agent send \(index)"))
                }
                let response = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "first agent message must hold without seen boundary")
                )
                #expect(response.status == .ok)
                let body = legacyJSON(response)
                #expect(body["state"] as? String == "held")
                #expect(body["newMessageCount"] as? Int == 3)
                #expect(body["shownMessageCount"] as? Int == 3)
                #expect(body["omittedMessageCount"] as? Int == 0)
                let heldMessages = body["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.compactMap { $0["content"] as? String } == [
                    "unread before first agent send 3",
                    "unread before first agent send 4",
                    "unread before first agent send 5",
                ])
                #expect(body["seenUpToSeq"] as? Int == unread[4].seq)

                let gate = legacyEvents(fixture, type: "gate_triggered")
                #expect(gate.count == 1)
                let row = gate.first ?? [:]
                #expect(row["newMessageCount"] as? Int == 3)
                let metadata = row["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["boundary_source"] as? String == "none")
                #expect(metadata["boundary_seq"] as? Int == 0)
                #expect(metadata["copy_variant"] as? String == "no_send_v1")
                #expect(metadata["available_actions"] as? [String] == ["check_messages", "send_draft", "send_anyway"])
            }
        }
    }

    // MARK: - #8 legacy read cursor is not a model-seen boundary

    @Test func legacyReadCursorIsNotAModelSeenBoundary() async throws {
        let fixture = makeLegacyFixture("005")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "model saw this baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let unread = try await legacyPostHuman(client, fixture, "delivered after model context")

                let ack = try await client.send(
                    .post,
                    headers: legacyAgentHeaders(fixture.machineKey),
                    to: "/internal/agent/\(fixture.agentId)/receive-ack"
                ) { request in
                    request.body = .init(string: "{\"seqs\":[\(unread.seq)]}")
                }
                #expect(ack.status == .ok)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == unread.seq)

                let held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "stale turn reply", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(held.status == .ok)
                let body = legacyJSON(held)
                #expect(body["state"] as? String == "held")
                #expect(body["decision"] as? String == "syncing_hold")
                #expect(body["newMessageCount"] as? Int == 1)
                #expect((body["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == unread.id)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == unread.seq)

                let gate = legacyEvents(fixture, type: "gate_triggered").first ?? [:]
                let metadata = gate["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["boundary_source"] as? String == "client_seen")
                #expect(metadata["boundary_seq"] as? Int == baseline.seq)
                #expect(metadata["latest_seq"] as? Int == unread.seq)
            }
        }
    }

    // MARK: - #9 receive-ack volatile with the model-seen capability fact

    @Test func receiveAckStaysVolatileWithModelSeenCapability() async throws {
        let fixture = makeLegacyFixture("006")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "model-seen capable baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let unread = try await legacyPostHuman(client, fixture, "model-seen capable delivery ack")
                fixture.accounts.setMachineModelSeenCapabilityForTesting(agentId: fixture.agentId, enabled: true)
                let ack = try await client.send(
                    .post,
                    headers: legacyAgentHeaders(fixture.machineKey),
                    to: "/internal/agent/\(fixture.agentId)/receive-ack"
                ) { request in
                    request.body = .init(string: "{\"seqs\":[\(unread.seq)]}")
                }
                #expect(ack.status == .ok)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == baseline.seq)
            }
        }
    }

    // MARK: - #12 explicit seen cursor satisfies the gate

    @Test func explicitSeenUpToSeqSatisfiesTheGate() async throws {
        let fixture = makeLegacyFixture("007")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let unread = try await legacyPostHuman(client, fixture, "agent has seen this locally")
                let response = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "reply with explicit freshness claim",
                        extra: ",\"seenUpToSeq\":\(unread.seq)"
                    )
                )
                #expect(response.status == .ok)
                #expect(legacyJSON(response)["state"] as? String == "sent")
                #expect(legacyEvents(fixture, type: "gate_triggered").isEmpty)
            }
        }
    }

    // MARK: - #13/#14 thread parent seeding and concurrent first replies

    @Test func firstSendToANewThreadSeedsFreshnessFromTheParent() async throws {
        let fixture = makeLegacyFixture("008")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let parent = try await legacyPostHuman(client, fixture, "please reply in this thread")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: parent.seq)
                _ = legacyCreateThread(fixture, parentMessageId: parent.id)
                let target = "#\(fixture.channelName):\(parent.id.prefix(8))"

                let first = try await legacySend(
                    client, key: fixture.peerKey, agentId: fixture.peerId,
                    body: legacySendBody(target: target, content: "peer got here first")
                )
                #expect(first.status == .ok)
                #expect(legacyJSON(first)["state"] as? String == "sent")
                let firstMessageId = legacyJSON(first)["messageId"] as? String ?? ""

                let held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: target, content: "second reply should reconsider")
                )
                #expect(held.status == .ok)
                let body = legacyJSON(held)
                #expect(body["state"] as? String == "held")
                #expect(body["newMessageCount"] as? Int == 1)
                let heldMessages = body["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.count == 1)
                #expect(heldMessages.first?["id"] as? String == firstMessageId)
                #expect(heldMessages.first?["content"] as? String == "peer got here first")

                let gate = legacyEvents(fixture, type: "gate_triggered").first ?? [:]
                let metadata = gate["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["last_seen_msg_id"] as? String == parent.id)
                #expect(metadata["latest_msg_id"] as? String == firstMessageId)
                #expect(metadata["boundary_source"] as? String == "thread_parent")
                #expect(metadata["boundary_seq"] as? Int == parent.seq)
            }
        }
    }

    @Test func concurrentFirstRepliesToANewThreadGateOneOfTwo() async throws {
        let fixture = makeLegacyFixture("009")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let parent = try await legacyPostHuman(client, fixture, "count in this thread")
                let threadId = legacyCreateThread(fixture, parentMessageId: parent.id)
                let target = "#\(fixture.channelName):\(parent.id.prefix(8))"
                let body = legacySendBody(target: target, content: "1")

                let replies = try await withThrowingTaskGroup(of: LegacyHTTPReply.self) { group in
                    group.addTask {
                        let response = try await legacySend(client, key: fixture.machineKey, agentId: fixture.agentId, body: body)
                        return LegacyHTTPReply(status: Int(response.status.code), body: response.body.string ?? "")
                    }
                    group.addTask {
                        let response = try await legacySend(client, key: fixture.peerKey, agentId: fixture.peerId, body: body)
                        return LegacyHTTPReply(status: Int(response.status.code), body: response.body.string ?? "")
                    }
                    var results: [LegacyHTTPReply] = []
                    for try await result in group { results.append(result) }
                    return results
                }
                #expect(replies.allSatisfy { $0.status == 200 })
                #expect(replies.count == 2)
                let bodies = replies.map { reply -> [String: Any] in
                    (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any] ?? [:]
                }
                let sent = bodies.filter { $0["state"] as? String == "sent" }
                let held = bodies.filter { $0["state"] as? String == "held" }
                #expect(sent.count == 1)
                #expect(held.count == 1)
                let sentMessageId = sent.first?["messageId"] as? String ?? ""
                #expect(held.first?["newMessageCount"] as? Int == 1)
                let heldMessages = held.first?["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.first?["id"] as? String == sentMessageId)
                #expect(heldMessages.first?["content"] as? String == "1")

                let response = try await client.get(
                    URI(string: "/api/messages/channel/\(threadId)"),
                    headers: legacyHumanHeaders(fixture)
                )
                let threadBody = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                let threadMessages = threadBody["messages"] as? [[String: Any]] ?? []
                #expect(threadMessages.compactMap { $0["content"] as? String } == ["1"])

                let gates = legacyEvents(fixture, type: "gate_triggered")
                #expect(gates.count == 1)
                let metadata = gates.first?["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["boundary_source"] as? String == "thread_parent")
                #expect(metadata["last_seen_msg_id"] as? String == parent.id)
                #expect(metadata["latest_msg_id"] as? String == sentMessageId)
            }
        }
    }

    // MARK: - #15 deprecated continue and draft replacement

    @Test func deprecatedContinueIsRejectedAndNormalSendReplacesDraft() async throws {
        let fixture = makeLegacyFixture("010")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let parent = try await legacyPostHuman(client, fixture, "count in this thread")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: parent.seq)
                let threadId = legacyCreateThread(fixture, parentMessageId: parent.id)
                let target = "#\(fixture.channelName):\(parent.id.prefix(8))"

                let first = try await legacySend(
                    client, key: fixture.peerKey, agentId: fixture.peerId,
                    body: legacySendBody(target: target, content: "1")
                )
                #expect(legacyJSON(first)["state"] as? String == "sent")

                let held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: target, content: "1")
                )
                #expect(legacyJSON(held)["state"] as? String == "held")
                #expect((legacyJSON(held)["heldMessages"] as? [[String: Any]])?.first?["content"] as? String == "1")

                let rejected = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: target, content: "2", extra: ",\"continue\":true")
                )
                #expect(rejected.status == .badRequest)
                #expect(((legacyJSON(rejected)["error"] as? String) ?? "").contains("--continue is no longer supported"))

                let latestAfterReject = try await legacyLatestChannelMessage(client, fixture, channelId: threadId)
                #expect(latestAfterReject["id"] as? String == legacyJSON(first)["messageId"] as? String)
                #expect(latestAfterReject["content"] as? String == "1")

                let replacement = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: target,
                        content: "2",
                        extra: ",\"seenUpToSeq\":\(legacyJSON(held)["seenUpToSeq"] as? Int ?? 0)"
                    )
                )
                #expect(replacement.status == .ok)
                #expect(legacyJSON(replacement)["state"] as? String == "sent")
                let latest = try await legacyLatestChannelMessage(client, fixture, channelId: threadId)
                #expect(latest["id"] as? String == legacyJSON(replacement)["messageId"] as? String)
                #expect(latest["content"] as? String == "2")
            }
        }
    }

    // MARK: - #16/#17 send-draft requires content and commits when clean

    @Test func sendDraftRequiresContentInTheSendAttempt() async throws {
        let fixture = makeLegacyFixture("011")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let response = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: "{\"target\":\"#\(fixture.channelName)\",\"sendDraft\":true}"
                )
                #expect(response.status == .badRequest)
                #expect(((legacyJSON(response)["error"] as? String) ?? "").contains("Content is required"))
            }
        }
    }

    @Test func sendDraftCommitsWhenFreshnessIsClean() async throws {
        let fixture = makeLegacyFixture("012")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await legacyPostHuman(client, fixture, "unread")

                let held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "draft X", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(legacyJSON(held)["state"] as? String == "held")

                let sent = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "draft X",
                        extra: ",\"sendDraft\":true,\"seenUpToSeq\":\(legacyJSON(held)["seenUpToSeq"] as? Int ?? 0)"
                    )
                )
                #expect(sent.status == .ok)
                #expect(legacyJSON(sent)["state"] as? String == "sent")
                let latest = try await legacyLatestChannelMessage(client, fixture)
                #expect(latest["id"] as? String == legacyJSON(sent)["messageId"] as? String)
                #expect(latest["content"] as? String == "draft X")
            }
        }
    }

    // MARK: - #4/#5/#18 E1 formal mention exemption

    @Test func formalMentionBypassesStaleHoldAndRecordsE1Exempt() async throws {
        let fixture = makeLegacyFixture("013")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let mention = try await legacyPostHuman(client, fixture, "please review this @\(fixture.agentName)")
                #expect(mention.seq > baseline.seq)

                let response = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "bot reply after mention",
                        extra: ",\"seenUpToSeq\":\(baseline.seq)"
                    )
                )
                #expect(response.status == .ok)
                #expect(legacyJSON(response)["state"] as? String == "sent")

                let exempt = legacyEvents(fixture, type: "e1_exempt")
                #expect(exempt.count == 1)
                #expect(exempt.first?["messageId"] as? String == mention.id)
                let metadata = exempt.first?["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["mentioned_handle"] as? String == fixture.agentName)
                #expect(metadata["mention_message_id"] as? String == mention.id)
                #expect(legacyActivity(fixture, title: "Send freshness check passed by mention", text: "reason: direct @\(fixture.agentName) mention"))
            }
        }
    }

    @Test func mentionAtTheBoundaryDoesNotExempt() async throws {
        let fixture = makeLegacyFixture("014")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let mention = try await legacyPostHuman(client, fixture, "@\(fixture.agentName) old mention")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: mention.seq)
                _ = try await legacyPostHuman(client, fixture, "later non-mention chatter")

                let response = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "bot reply should hold", extra: ",\"seenUpToSeq\":\(mention.seq)")
                )
                #expect(response.status == .ok)
                #expect(legacyJSON(response)["state"] as? String == "held")
                #expect(legacyJSON(response)["newMessageCount"] as? Int == 1)
                #expect(legacyEvents(fixture, type: "e1_exempt").isEmpty)
                let gate = legacyEvents(fixture, type: "gate_triggered").first ?? [:]
                let metadata = gate["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["last_seen_msg_id"] as? String == mention.id)
            }
        }
    }

    @Test func everyoneMentionDoesNotExempt() async throws {
        let fixture = makeLegacyFixture("015")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await legacyPostHuman(client, fixture, "@everyone take a look")
                let response = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "bot reply should still hold", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(legacyJSON(response)["state"] as? String == "held")
                #expect(legacyEvents(fixture, type: "e1_exempt").isEmpty)
            }
        }
    }

    // MARK: - #6 mute attention facts

    @Test func freshnessContextFollowsAgentMuteAttentionFacts() async throws {
        let fixture = makeLegacyFixture("016")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline before mute")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                fixture.accounts.setAgentMuteForTesting(
                    channelId: fixture.channelId,
                    agentId: fixture.agentId,
                    serverId: fixture.serverId,
                    muteFromSeq: baseline.seq
                )
                let mutedOrdinary = try await legacyPostHuman(client, fixture, "muted ordinary before legacy send")
                let throughMutedTail = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "legacy send after muted ordinary",
                        extra: ",\"seenUpToSeq\":\(baseline.seq)"
                    )
                )
                #expect(throughMutedTail.status == .ok)
                #expect(legacyJSON(throughMutedTail)["state"] as? String == "sent")

                _ = fixture.accounts.oauth.setActivityMuted(
                    channelId: fixture.channelId,
                    receiverId: fixture.agentId,
                    muted: false,
                    muteFromSeq: nil
                )
                let visibleOrdinary = try await legacyPostHuman(client, fixture, "visible ordinary after unmute")
                // Upstream derives this from inbox-notification-fact rows that
                // are created (or suppressed) when the message arrives, so an
                // unmute cannot retroactively add the muted row. This port has
                // no such ledger for ordinary human messages and evaluates
                // mute prefs dynamically; the reviewed boundary here is the
                // muted tail, which keeps the response scenario identical. The
                // history half is adjudicated in docs/BEHAVIOR.md.
                let held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "legacy send after visible ordinary",
                        extra: ",\"seenUpToSeq\":\(mutedOrdinary.seq)"
                    )
                )
                let body = legacyJSON(held)
                #expect(body["state"] as? String == "held")
                #expect(body["newMessageCount"] as? Int == 1)
                let heldMessages = body["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.compactMap { $0["id"] as? String } == [visibleOrdinary.id])
                #expect(heldMessages.contains { $0["id"] as? String == mutedOrdinary.id } == false)
                #expect(body["seenUpToSeq"] as? Int == visibleOrdinary.seq)
            }
        }
    }

    // MARK: - #19/#23 rehold and explicit seen cursor

    @Test func sendDraftReholdShowsOnlyIncrementalMessages() async throws {
        let fixture = makeLegacyFixture("017")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let firstUnread = try await legacyPostHuman(client, fixture, "first unread")
                let firstHold = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "draft one", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                let firstBody = legacyJSON(firstHold)
                #expect(firstBody["state"] as? String == "held")
                #expect(firstBody["newMessageCount"] as? Int == 1)
                #expect((firstBody["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == firstUnread.id)
                #expect(fixture.accounts.agentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId) == firstUnread.seq)

                let secondUnread = try await legacyPostHuman(client, fixture, "second unread")
                let secondHold = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "draft one",
                        extra: ",\"sendDraft\":true,\"draftReholdCount\":1,\"seenUpToSeq\":\(firstBody["seenUpToSeq"] as? Int ?? 0)"
                    )
                )
                let secondBody = legacyJSON(secondHold)
                #expect(secondBody["state"] as? String == "held")
                #expect(secondBody["newMessageCount"] as? Int == 1)
                #expect((secondBody["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == secondUnread.id)
                #expect(legacyEvents(fixture, type: "gate_triggered").count == 2)
            }
        }
    }

    @Test func sendDraftRecheckUsesExplicitSeenUpToSeq() async throws {
        let fixture = makeLegacyFixture("018")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await legacyPostHuman(client, fixture, "first unread")
                let firstHold = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "draft one", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(legacyJSON(firstHold)["state"] as? String == "held")

                let secondUnread = try await legacyPostHuman(client, fixture, "second unread")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: secondUnread.seq)
                let continued = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "draft one",
                        extra: ",\"sendDraft\":true,\"seenUpToSeq\":\(secondUnread.seq)"
                    )
                )
                #expect(continued.status == .ok)
                #expect(legacyJSON(continued)["state"] as? String == "sent")
                let latest = try await legacyLatestChannelMessage(client, fixture)
                #expect(latest["id"] as? String == legacyJSON(continued)["messageId"] as? String)
                #expect(latest["content"] as? String == "draft one")
            }
        }
    }

    // MARK: - #24/#25 replacement metadata and --anyway

    @Test func replacementMetadataIsClientDeclaredAndEventOnly() async throws {
        let fixture = makeLegacyFixture("019")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await legacyPostHuman(client, fixture, "first unread")
                let firstHold = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "draft one", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(legacyJSON(firstHold)["state"] as? String == "held")
                _ = try await legacyPostHuman(client, fixture, "second unread")

                let secondHold = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "draft two",
                        extra: ",\"draftReplacedExisting\":true,\"seenUpToSeq\":\(legacyJSON(firstHold)["seenUpToSeq"] as? Int ?? 0)"
                    )
                )
                #expect(legacyJSON(secondHold)["state"] as? String == "held")
                let raw = secondHold.body.string ?? ""
                #expect(!raw.contains("draftReplacedExisting"))
                #expect(!raw.contains("draft_replaced_existing"))
                let gates = legacyEvents(fixture, type: "gate_triggered")
                #expect(gates.count == 2)
                let metadata = gates.last?["metadata"] as? [String: Any] ?? [:]
                #expect(metadata["draft_replaced_existing"] as? Bool == true)
            }
        }
    }

    @Test func anywayIsSuggestedAfterThreeReholdsAndCommitsStaleDraft() async throws {
        let fixture = makeLegacyFixture("020")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                _ = try await legacyPostHuman(client, fixture, "unread-1")
                var held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "draft one", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                #expect(legacyJSON(held)["state"] as? String == "held")
                #expect(legacyJSON(held)["continueAnywaySuggested"] as? Bool == false)

                for index in 0..<3 {
                    _ = try await legacyPostHuman(client, fixture, "extra-unread-\(index + 2)")
                    held = try await legacySend(
                        client, key: fixture.machineKey, agentId: fixture.agentId,
                        body: legacySendBody(
                            target: "#\(fixture.channelName)",
                            content: "draft one",
                            extra: ",\"sendDraft\":true,\"draftReholdCount\":\(index + 1),\"seenUpToSeq\":\(legacyJSON(held)["seenUpToSeq"] as? Int ?? 0)"
                        )
                    )
                    #expect(legacyJSON(held)["state"] as? String == "held")
                    if index < 2 {
                        #expect(legacyJSON(held)["continueAnywaySuggested"] as? Bool == false)
                    }
                }
                #expect(legacyJSON(held)["continueAnywaySuggested"] as? Bool == true)

                _ = try await legacyPostHuman(client, fixture, "freshness would still fail")
                let committed = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "draft one",
                        extra: ",\"sendDraft\":true,\"continueAnyway\":true,\"draftReholdCount\":4,\"seenUpToSeq\":\(legacyJSON(held)["seenUpToSeq"] as? Int ?? 0)"
                    )
                )
                #expect(committed.status == .ok)
                #expect(legacyJSON(committed)["state"] as? String == "sent")
                let latest = try await legacyLatestChannelMessage(client, fixture)
                #expect(latest["id"] as? String == legacyJSON(committed)["messageId"] as? String)
                #expect(latest["content"] as? String == "draft one")

                let continues = legacyEvents(fixture, type: "continue")
                #expect(continues.contains { $0["result"] as? String == "committed_anyway" })
                #expect(legacyActivity(fixture, title: "Send draft held", text: "unreviewed synced context for this target: 1 message"))
                #expect(legacyActivity(fixture, title: "Send draft held", text: "action: review the synced context before sending"))
                #expect(legacyActivity(fixture, title: "Send draft sent anyway", text: "freshness updates:"))
                #expect(legacyActivity(fixture, title: "Send draft sent anyway", text: "decision: sent anyway after reviewing freshness context"))
            }
        }
    }

    // MARK: - #20/#21/#22 HTTP-visible target scope (ack arrays excluded)

    @Test func heldContextIsTargetScopedAndExposesNoGlobalInbox() async throws {
        let fixture = makeLegacyFixture("021")
        let sideChannelId = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "legacy-side-room", creatorUserId: fixture.ownerId)
        fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: sideChannelId, memberId: fixture.ownerId, kind: "channel", name: "legacy-side-room")
        fixture.accounts.oauth.addChannelHuman(channelId: sideChannelId, userId: fixture.ownerId)
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "baseline")
                fixture.accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
                let sideMessage = try await legacyPostHuman(client, fixture, "side target stays inbox-owned", channelId: sideChannelId)
                let targetUnread = try await legacyPostHuman(client, fixture, "target unread")
                let held = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "draft should hold", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                let body = legacyJSON(held)
                #expect(body["state"] as? String == "held")
                #expect(body["recentUnread"] == nil)
                let heldMessages = body["heldMessages"] as? [[String: Any]] ?? []
                #expect(heldMessages.compactMap { $0["id"] as? String } == [targetUnread.id])
                #expect(heldMessages.contains { $0["id"] as? String == sideMessage.id } == false)
            }
        }
    }

    // MARK: - #26 held identity across channel, DM and thread

    @Test func heldContextCarriesChannelDMAndThreadIdentity() async throws {
        let fixture = makeLegacyFixture("022")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let baseline = try await legacyPostHuman(client, fixture, "legacy baseline")
                _ = try await legacyPostHuman(client, fixture, "legacy fresh")
                let heldChannel = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#\(fixture.channelName)", content: "legacy stale channel reply", extra: ",\"seenUpToSeq\":\(baseline.seq)")
                )
                let channelBody = legacyJSON(heldChannel)
                #expect(channelBody["state"] as? String == "held")
                let channelHeld = channelBody["heldMessages"] as? [[String: Any]] ?? []
                #expect(!channelHeld.isEmpty)
                for message in channelHeld {
                    #expect(message["channel_type"] as? String == "channel")
                    #expect(message["channel_name"] as? String == fixture.channelName)
                    #expect(message["channel_id"] as? String == fixture.channelId)
                }

                let dmId = legacyCreateDM(fixture)
                let dmBaseline = try await legacyPostHuman(client, fixture, "legacy dm baseline", channelId: dmId)
                _ = try await legacyPostHuman(client, fixture, "legacy dm fresh", channelId: dmId)
                let heldDM = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "dm:@\(fixture.ownerName)", content: "legacy stale dm reply", extra: ",\"seenUpToSeq\":\(dmBaseline.seq)")
                )
                let dmBody = legacyJSON(heldDM)
                #expect(dmBody["state"] as? String == "held")
                let dmHeld = dmBody["heldMessages"] as? [[String: Any]] ?? []
                #expect(!dmHeld.isEmpty)
                for message in dmHeld {
                    #expect(message["channel_type"] as? String == "dm")
                    #expect(message["channel_name"] as? String == fixture.ownerName)
                }

                let parent = try await legacyPostHuman(client, fixture, "legacy thread parent")
                let threadId = legacyCreateThread(fixture, parentMessageId: parent.id)
                _ = try await legacyPostHuman(client, fixture, "legacy thread reply", channelId: threadId)
                let heldThread = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName):\(parent.id.prefix(8))",
                        content: "legacy stale thread reply",
                        extra: ",\"seenUpToSeq\":\(parent.seq)"
                    )
                )
                let threadBody = legacyJSON(heldThread)
                #expect(threadBody["state"] as? String == "held")
                let threadHeld = threadBody["heldMessages"] as? [[String: Any]] ?? []
                #expect(!threadHeld.isEmpty)
                for message in threadHeld {
                    #expect(message["channel_type"] as? String == "thread")
                    #expect(message["parent_channel_type"] as? String == "channel")
                    #expect(message["parent_channel_name"] as? String == fixture.channelName)
                }
            }
        }
    }

    // MARK: - machine authentication and ownership

    @Test func machineAuthenticationAndOwnershipRefusals() async throws {
        let fixture = makeLegacyFixture("023")
        fixture.accounts.oauth.addOwnedServer(id: "33333333-3333-4333-8333-000001189999", slug: "legacy-foreign", name: "Legacy Foreign", ownerId: fixture.ownerId)
        let foreignAgent = fixture.accounts.oauth.createAgent(
            serverId: "33333333-3333-4333-8333-000001189999",
            name: "LegacyForeignAgent",
            creatorUserId: fixture.ownerId
        )
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let body = legacySendBody(target: "#\(fixture.channelName)", content: "probe")

                var noAuthHeaders = HTTPFields()
                noAuthHeaders[.contentType] = "application/json"
                let noAuth = try await client.send(.post, headers: noAuthHeaders, to: "/internal/agent/\(fixture.agentId)/send") { request in
                    request.body = .init(string: body)
                }
                #expect(noAuth.status == .unauthorized)
                #expect(legacyJSON(noAuth)["error"] as? String == "Missing machine API key")

                let badKey = try await legacySend(client, key: "sk_machine_deadbeef", agentId: fixture.agentId, body: body)
                #expect(badKey.status == .unauthorized)
                #expect(legacyJSON(badKey)["error"] as? String == "Invalid machine API key")

                let crossServer = try await legacySend(client, key: fixture.machineKey, agentId: foreignAgent, body: body)
                #expect(crossServer.status == .notFound)
                #expect(legacyJSON(crossServer)["error"] as? String == "Agent not found")

                let missingAgent = try await legacySend(
                    client, key: fixture.machineKey,
                    agentId: "11111111-1111-4111-8111-000001189998",
                    body: body
                )
                #expect(missingAgent.status == .notFound)
                #expect(legacyJSON(missingAgent)["error"] as? String == "Agent not found")

                // A machine row that does not own the agent.
                let wrongMachine = try await legacySend(client, key: fixture.secondMachineKey, agentId: fixture.agentId, body: body)
                #expect(wrongMachine.status == .forbidden)
                #expect(legacyJSON(wrongMachine)["error"] as? String == "This agent is not assigned to your machine")

                // A legacy machine key bound to another agent.
                let peerKey = fixture.peerKey
                let wrongLegacyKey = try await legacySend(client, key: peerKey, agentId: fixture.agentId, body: body)
                #expect(wrongLegacyKey.status == .forbidden)
                #expect(legacyJSON(wrongLegacyKey)["error"] as? String == "This agent is not assigned to your machine")

                // An explicit grant set without message:send.
                fixture.accounts.setAgentGrantsForTesting(agentId: fixture.agentId, scopes: ["read"])
                let denied = try await legacySend(client, key: fixture.machineKey, agentId: fixture.agentId, body: body)
                #expect(denied.status == .forbidden)
                let deniedBody = legacyJSON(denied)
                #expect(deniedBody["error"] as? String == "missing required scope")
                #expect(deniedBody["requiredScope"] as? String == "message:send")
                #expect(deniedBody["reason"] as? String == "missing_scope")
            }
        }
    }

    // MARK: - idempotency and attachments

    @Test func idempotencyKeyReplaysTheSameMessageAndRejectsADifferentPayload() async throws {
        let fixture = makeLegacyFixture("026")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let body = legacySendBody(
                    target: "#\(fixture.channelName)",
                    content: "idempotent legacy send",
                    extra: ",\"idempotencyKey\":\"legacy-key-1\""
                )
                let first = try await legacySend(client, key: fixture.machineKey, agentId: fixture.agentId, body: body)
                #expect(first.status == .ok)
                let firstBody = legacyJSON(first)
                let replay = try await legacySend(client, key: fixture.machineKey, agentId: fixture.agentId, body: body)
                #expect(replay.status == .ok)
                #expect(legacyJSON(replay)["messageId"] as? String == firstBody["messageId"] as? String)
                #expect(legacyJSON(replay)["messageSeq"] as? Int == firstBody["messageSeq"] as? Int)
                #expect(fixture.accounts.humanMessageIds(channelId: fixture.channelId).count == 1)

                let mismatched = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(
                        target: "#\(fixture.channelName)",
                        content: "different payload",
                        extra: ",\"idempotencyKey\":\"legacy-key-1\""
                    )
                )
                #expect(mismatched.status == .conflict)
                let mismatchBody = legacyJSON(mismatched)
                #expect(mismatchBody["code"] as? String == "idempotency_key_reused")
                #expect(mismatchBody["mismatch"] as? String == "content")
                #expect(fixture.accounts.humanMessageIds(channelId: fixture.channelId).count == 1)
            }
        }
    }

    @Test func attachmentIdsAreLinkedAndRefusedOnReuse() async throws {
        let fixture = makeLegacyFixture("027")
        let attachmentId = fixture.accounts.addChannelAttachment(
            channelId: fixture.channelId,
            uploaderId: fixture.agentId,
            filename: "legacy.txt"
        )
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let sent = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: "{\"target\":\"#\(fixture.channelName)\",\"content\":\"with attachment\",\"attachmentIds\":[\"\(attachmentId)\"]}"
                )
                #expect(sent.status == .ok)
                #expect(legacyJSON(sent)["state"] as? String == "sent")

                let reused = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: "{\"target\":\"#\(fixture.channelName)\",\"content\":\"reuse\",\"attachmentIds\":[\"\(attachmentId)\"]}"
                )
                #expect(reused.status == .badRequest)
                #expect(legacyJSON(reused)["code"] as? String == "attachment_already_linked")
                let linked = fixture.accounts.linkedAttachmentRecords(ids: [attachmentId])
                #expect(linked.count == 1)
                #expect(linked.first?.messageId != nil)
            }
        }
    }

    // MARK: - target forms and refusals

    @Test func channelAndDMFormsResolveAndSend() async throws {
        let fixture = makeLegacyFixture("024")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let withoutMarker = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: "{\"channel\":\"#\(fixture.channelName)\",\"content\":\"channel field form\"}"
                )
                #expect(withoutMarker.status == .ok)
                let channelSent = legacyJSON(withoutMarker)
                #expect(channelSent["state"] as? String == "sent")
                #expect(channelSent["ok"] as? Bool == true)
                #expect(channelSent["messageId"] as? String != nil)
                #expect(channelSent["messageSeq"] as? Int != nil)
                #expect(channelSent["id"] == nil)
                #expect(channelSent["channelId"] == nil)

                fixture.accounts.oauth.addChannelHuman(channelId: fixture.channelId, userId: fixture.ownerId)
                let dmForm = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: "{\"dm_to\":\"@\(fixture.ownerName)\",\"content\":\"dm_to form\"}"
                )
                #expect(dmForm.status == .ok)
                #expect(legacyJSON(dmForm)["state"] as? String == "sent")

                let dmTarget = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "dm:@\(fixture.ownerName)", content: "dm target form")
                )
                #expect(dmTarget.status == .ok)
                #expect(legacyJSON(dmTarget)["state"] as? String == "sent")
            }
        }
    }

    @Test func targetRefusalsKeepThePublishedTexts() async throws {
        let fixture = makeLegacyFixture("025")
        let outsiderChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "legacy-outsider-room", creatorUserId: fixture.ownerId)
        fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: outsiderChannel, memberId: fixture.ownerId, kind: "channel", name: "legacy-outsider-room")
        fixture.accounts.oauth.addChannelHuman(channelId: outsiderChannel, userId: fixture.ownerId)
        let privateChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "legacy-private-room", creatorUserId: fixture.ownerId)
        fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: privateChannel, memberId: fixture.ownerId, kind: "private", name: "legacy-private-room")
        fixture.accounts.oauth.addChannelHuman(channelId: privateChannel, userId: fixture.ownerId)
        fixture.accounts.oauth.setChannelType(id: privateChannel, type: "private")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let unknownChannel = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#no-such-legacy-room", content: "probe")
                )
                #expect(unknownChannel.status == .notFound)
                #expect(legacyJSON(unknownChannel)["error"] as? String == "Channel not found: #no-such-legacy-room")

                let legacyAtTarget = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "@\(fixture.ownerName)", content: "probe")
                )
                #expect(legacyAtTarget.status == .notFound)
                #expect(legacyJSON(legacyAtTarget)["error"] as? String == "Channel not found: @\(fixture.ownerName)")

                let unknownPeer = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "dm:@NobodyByThisName", content: "probe")
                )
                #expect(unknownPeer.status == .notFound)
                #expect(legacyJSON(unknownPeer)["error"] as? String == "User or agent not found: @NobodyByThisName")

                let selfDM = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "dm:@\(fixture.agentName)", content: "probe")
                )
                #expect(selfDM.status == .badRequest)
                #expect(legacyJSON(selfDM)["error"] as? String == "Cannot create a DM with yourself")

                let notMember = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#legacy-outsider-room", content: "probe")
                )
                #expect(notMember.status == .forbidden)
                #expect(((legacyJSON(notMember)["error"] as? String) ?? "").contains("not a member"))

                // A private channel the agent cannot see is the neutral
                // not-found cloak, not a membership 403.
                let privateChannel = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#legacy-private-room", content: "probe")
                )
                #expect(privateChannel.status == .notFound)
                #expect(legacyJSON(privateChannel)["error"] as? String == "Channel not found: #legacy-private-room")

                let privateThread = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: legacySendBody(target: "#legacy-private-room:abcdef12", content: "probe")
                )
                #expect(privateThread.status == .notFound)
                #expect(((legacyJSON(privateThread)["error"] as? String) ?? "").hasPrefix("Thread target not found or not replyable: #legacy-private-room:abcdef12"))

                let missingTarget = try await legacySend(
                    client, key: fixture.machineKey, agentId: fixture.agentId,
                    body: "{\"content\":\"probe\"}"
                )
                #expect(missingTarget.status == .badRequest)
                #expect(legacyJSON(missingTarget)["error"] as? String == "target is required")
            }
        }
    }
}
