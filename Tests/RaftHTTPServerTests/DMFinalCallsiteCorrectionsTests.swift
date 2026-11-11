import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

// The final DM call-site corrections, over the published routes only:
//
// - history, search and the legacy machine send answer a fixable DM target
//   with the pinned `DmTargetResolutionError.toResponseBody()` bytes
//   (`error`, `code`, `suggestedNextAction`, in that order);
// - an empty peer name is refused before the peer kind, so `dm:@~bot` is the
//   same neutral miss as `dm:@~agent`;
// - the legacy machine send uses the RAW retained assistant binding for post
//   authority even while `identity_borrowing` is off;
// - `agent:create` prepare resolves a typed `dm:@peer[:shortId]` target (human
//   or agent) through the shared canonical peer rules, refuses a malformed or
//   unresolvable one without creating a DM/thread/card.

// MARK: - Expected bodies

private func ambiguousBody(_ name: String) -> String {
    #"{"error":"dm:@\#(name) matches both a human and an agent named \#(name). Name the one you mean: dm:@\#(name)~agent for the agent, or dm:@\#(name)~human for the human (for example: raft message read --target \"dm:@\#(name)~agent\").","code":"DM_TARGET_AMBIGUOUS","suggestedNextAction":"retry with dm:@\#(name)~agent for the agent or dm:@\#(name)~human for the human"}"#
}

private func jsonQuoted(_ value: String) -> String {
    let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
    return String(decoding: data, as: UTF8.self)
}

private func invalidKindBody(rawPeer: String, suffix: String) -> String {
    let message = "dm:@\(rawPeer) has an unknown peer kind \"\(suffix)\". "
        + "Use dm:@<name>, dm:@<name>~agent or dm:@<name>~human."
    let next = "retry with dm:@<name>, dm:@<name>~agent or dm:@<name>~human"
    return "{\"error\":\(jsonQuoted(message)),\"code\":\"DM_TARGET_INVALID_PEER_KIND\","
        + "\"suggestedNextAction\":\(jsonQuoted(next))}"
}

private let reminderNotSendableBody = #"{"error":"dm:@reminders is your private reminder conversation; nobody else reads it. Act at the reminder's anchor instead.","code":"DM_TARGET_NOT_SENDABLE","suggestedNextAction":"send to the reminder's anchor target instead of dm:@reminders"}"#

private func migrationReceiptBody(_ target: String) -> String {
    #"{"error":"\#(target) is a migration receipt: a one-way notice from Raft about your move, with no one on the other side. No reply is needed. To tell your owner something, send it to their DM.","code":"MIGRATION_RECEIPT_READ_ONLY","suggestedNextAction":"send to your owner's DM (dm:@<owner>) instead of the migration receipt"}"#
}

private let forbiddenChannelBody = #"{"error":"Agent cannot post in this channel - not a member. If you were @mentioned and need to respond, DM the person who mentioned you and let them know you're not in the channel."}"#

private func dmPeerNotFoundBody(_ peer: String) -> String {
    #"{"error":"User or agent not found: @\#(peer)"}"#
}

private func couldNotResolveBody(_ target: String) -> String {
    #"{"error":"Could not resolve target: \#(target)"}"#
}

private func channelNotFoundBody(_ target: String) -> String {
    #"{"error":"Channel not found: \#(target)"}"#
}

// MARK: - HTTP helpers

private func encoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
}

private func object(_ raw: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
}

private func historyRaw(
    _ client: any Client, apiKey: String, target: String
) async throws -> (status: HTTPResponse.Status, raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(
        URI(string: "/internal/agent-api/history?channel=\(encoded(target))"), headers: headers
    )
    return (response.status, response.body.string ?? "")
}

private func searchRaw(
    _ client: any Client, apiKey: String, channel: String
) async throws -> (status: HTTPResponse.Status, raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(
        URI(string: "/internal/agent-api/search?q=needle&channel=\(encoded(channel))"),
        headers: headers
    )
    return (response.status, response.body.string ?? "")
}

private func machineSendRaw(
    _ client: any Client, apiKey: String, agentId: String, target: String
) async throws -> (status: HTTPResponse.Status, raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let payload: [String: Any] = ["target": target, "content": "dm callsite send"]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let response = try await client.send(
        .post, headers: headers, to: URI(string: "/internal/agent/\(agentId)/send")
    ) { request in
        request.body = .init(data: data)
    }
    return (response.status, response.body.string ?? "")
}

private func modernSendRaw(
    _ client: any Client, apiKey: String, target: String, v2: Bool
) async throws -> (status: HTTPResponse.Status, raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let payload: [String: Any] = ["target": target, "content": "modern dm callsite send"]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let path = v2 ? "/internal/agent-api/v2/send" : "/internal/agent-api/send"
    let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(data: data)
    }
    return (response.status, response.body.string ?? "")
}

private func taskClaimRaw(
    _ client: any Client, apiKey: String, target: String
) async throws -> (status: HTTPResponse.Status, raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let payload: [String: Any] = ["channel": target, "task_numbers": [1]]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let response = try await client.send(
        .post, headers: headers, to: URI(string: "/internal/agent-api/tasks/claim")
    ) { request in
        request.body = .init(data: data)
    }
    return (response.status, response.body.string ?? "")
}

private func prepareRaw(
    _ client: any Client, apiKey: String, target: String, actionName: String
) async throws -> (status: HTTPResponse.Status, raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let payload: [String: Any] = [
        "target": target,
        "action": ["type": "agent:create", "name": actionName],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let response = try await client.send(
        .post, headers: headers, to: "/internal/agent-api/prepare-action"
    ) { request in
        request.body = .init(data: data)
    }
    return (response.status, response.body.string ?? "")
}

private func configuredApp(
    _ accounts: EmailLoginDirectory,
    _ body: (any Client) async throws -> Void
) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            try await body(client)
        }
    }
}

// MARK: - History / search / legacy send fixture

private struct DMCallsiteWireFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let graceId: String
    let receiptId: String
    let agentKey: String
    let machineKey: String
}

private func makeDMCallsiteWireFixture() -> DMCallsiteWireFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001422001"
    let ownerId = "11111111-1111-4111-8111-000001422001"
    let humanTwinId = "11111111-1111-4111-8111-000001422002"
    accounts.addAccount(id: ownerId, email: "callsite-wire-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: humanTwinId, email: "callsite-wire-twin@slock.test", password: "password123")
    accounts.markEmailVerified(userId: humanTwinId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "callsite-wire", name: "Callsite Wire", ownerId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "Owner")
    accounts.setAccountProfileForTesting(id: humanTwinId, name: "Twin")
    accounts.oauth.addMember(serverId: serverId, userId: humanTwinId, role: "member")

    let grace = accounts.oauth.createAgent(serverId: serverId, name: "Grace", runtime: "claude")
    let agentTwin = accounts.oauth.createAgent(serverId: serverId, name: "Twin", runtime: "claude")
    func dm(_ peer: String, kind: OAuthLedger.DirectChannelParticipantKind) -> String {
        let channel = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: grace, secondUserId: peer,
            firstKind: .agent, secondKind: kind
        )
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: grace, kind: "dm", name: "dm")
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: peer, kind: "dm", name: "dm")
        if kind == .human {
            accounts.oauth.addChannelHuman(channelId: channel, userId: peer)
        } else {
            accounts.oauth.addChannelAgent(channelId: channel, agentId: peer)
        }
        return channel
    }
    _ = dm(humanTwinId, kind: .human)
    _ = dm(agentTwin, kind: .agent)

    // A one-way migration receipt owned by Grace: name-only, single member.
    let receiptName = "migration-receipt-callsite"
    let receipt = accounts.oauth.createChannel(
        serverId: serverId, name: receiptName, creatorUserId: grace, type: "dm"
    )
    accounts.oauth.addChannelAgent(channelId: receipt, agentId: grace)
    accounts.addPostableChannel(
        serverId: serverId, channelId: receipt, memberId: grace, kind: "dm", name: receiptName
    )

    // Grace's private reminder surface, for the reserved-handle refusal.
    let reminderName = "reminders"
    let reminder = accounts.oauth.createChannel(
        serverId: serverId, name: reminderName, creatorUserId: grace, type: "dm"
    )
    accounts.oauth.addChannelAgent(channelId: reminder, agentId: grace)
    accounts.addPostableChannel(
        serverId: serverId, channelId: reminder, memberId: grace, kind: "dm", name: reminderName
    )
    accounts.setAgentReminderSurfaceForTesting(agentId: grace, channelId: reminder)

    return DMCallsiteWireFixture(
        accounts: accounts,
        serverId: serverId,
        graceId: grace,
        receiptId: receipt,
        agentKey: accounts.mintAgentCredential(
            agentId: grace, scopes: ["send", "read", "tasks"], name: "callsite-wire"
        ),
        machineKey: accounts.registerMachineForAgent(serverId: serverId, agentId: grace)
    )
}

// MARK: - History / search wire bodies

@Test func historyAndSearchPublishTheExactDMTargetBodies() async throws {
    let f = makeDMCallsiteWireFixture()
    try await configuredApp(f.accounts) { client in
        let ambiguous = try await historyRaw(client, apiKey: f.agentKey, target: "dm:@Twin")
        #expect(ambiguous.status == .conflict)
        #expect(ambiguous.raw == ambiguousBody("Twin"))

        let invalid = try await historyRaw(client, apiKey: f.agentKey, target: "dm:@Twin~bot")
        #expect(invalid.status == .badRequest)
        #expect(invalid.raw == invalidKindBody(rawPeer: "Twin~bot", suffix: "bot"))

        // A kind suffix is exact lowercase.
        let uppercaseKind = try await historyRaw(client, apiKey: f.agentKey, target: "dm:@Twin~AGENT")
        #expect(uppercaseKind.status == .badRequest)
        #expect(uppercaseKind.raw == invalidKindBody(rawPeer: "Twin~AGENT", suffix: "AGENT"))

        // An empty peer name is refused before the kind, so `~bot` here is the
        // same neutral not-found as `~agent` (not the 400 kind refusal).
        for empty in ["dm:@~bot", "dm:@~agent"] {
            let miss = try await historyRaw(client, apiKey: f.agentKey, target: empty)
            #expect(miss.status == .notFound, Comment(rawValue: empty))
            #expect(object(miss.raw)["error"] as? String == "Channel not found or not visible")
        }

        let searchAmbiguous = try await searchRaw(client, apiKey: f.agentKey, channel: "dm:@Twin")
        #expect(searchAmbiguous.status == .conflict)
        #expect(searchAmbiguous.raw == ambiguousBody("Twin"))

        let searchInvalid = try await searchRaw(client, apiKey: f.agentKey, channel: "dm:@Twin~bot")
        #expect(searchInvalid.status == .badRequest)
        #expect(searchInvalid.raw == invalidKindBody(rawPeer: "Twin~bot", suffix: "bot"))

        let searchUppercase = try await searchRaw(client, apiKey: f.agentKey, channel: "dm:@Twin~AGENT")
        #expect(searchUppercase.status == .badRequest)
        #expect(searchUppercase.raw == invalidKindBody(rawPeer: "Twin~AGENT", suffix: "AGENT"))
    }
}

@Test func legacyMachineSendPublishesTheExactDMTargetBodies() async throws {
    let f = makeDMCallsiteWireFixture()
    try await configuredApp(f.accounts) { client in
        let ambiguous = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: "dm:@Twin"
        )
        #expect(ambiguous.status == .conflict)
        #expect(ambiguous.raw == ambiguousBody("Twin"))

        let invalid = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: "dm:@Twin~bot"
        )
        #expect(invalid.status == .badRequest)
        #expect(invalid.raw == invalidKindBody(rawPeer: "Twin~bot", suffix: "bot"))

        let uppercaseKind = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: "dm:@Twin~AGENT"
        )
        #expect(uppercaseKind.status == .badRequest)
        #expect(uppercaseKind.raw == invalidKindBody(rawPeer: "Twin~AGENT", suffix: "AGENT"))

        let reminders = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: "dm:@reminders"
        )
        #expect(reminders.status == .forbidden)
        #expect(reminders.raw == reminderNotSendableBody)

        let receiptTarget = "dm:@migration-receipt-callsite"
        let receipt = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: receiptTarget
        )
        #expect(receipt.status == .conflict)
        #expect(receipt.raw == migrationReceiptBody(receiptTarget))

        // A colon suffix that is not a full thread id is the pinned
        // thread-shaped fallback: no DM is created and the route publishes its
        // plain not-found text.
        let looseSuffix = "dm:@Twin:1"
        let loose = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: looseSuffix
        )
        #expect(loose.status == .notFound)
        #expect(loose.raw == channelNotFoundBody(looseSuffix))

        // The empty name is a neutral 404, never the unknown-kind 400.
        let empty = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: "dm:@~bot"
        )
        #expect(empty.status == .notFound)
        #expect(empty.raw == dmPeerNotFoundBody("~bot"))

        // The typed target still sends.
        let pinned = try await machineSendRaw(
            client, apiKey: f.machineKey, agentId: f.graceId, target: "dm:@Twin~agent"
        )
        #expect(pinned.status == .ok, Comment(rawValue: pinned.raw))
    }
}

// MARK: - Modern send / task DM refusal wire

@Test func modernSendPublishesTheExactDMTargetRefusalBodiesAndWritesNothing() async throws {
    let f = makeDMCallsiteWireFixture()
    try await configuredApp(f.accounts) { client in
        // An arbitrary suffix can contain quotes and backslashes; the body must
        // stay valid, ordered, escaped JSON, not raw interpolation.
        let arbitrarySuffix = "a\"b\\c"
        let receiptTarget = "DM:@migration-receipt-callsite"
        let cases: [(target: String, status: HTTPResponse.Status, body: String)] = [
            ("dm:@Twin", .conflict, ambiguousBody("Twin")),
            ("dm:@Twin~bot", .badRequest, invalidKindBody(rawPeer: "Twin~bot", suffix: "bot")),
            (
                "dm:@Twin~\(arbitrarySuffix)", .badRequest,
                invalidKindBody(
                    rawPeer: "Twin~\(arbitrarySuffix)",
                    suffix: arbitrarySuffix
                )
            ),
            ("dm:@reminders", .forbidden, reminderNotSendableBody),
            (receiptTarget, .conflict, migrationReceiptBody(receiptTarget)),
        ]
        for v2 in [false, true] {
            for refusal in cases {
                let channelsBefore = f.accounts.postableChannelCountForTesting
                let messagesBefore = f.accounts.humanMessageCount
                let tasksBefore = f.accounts.taskRecordCountForTesting
                let cardsBefore = f.accounts.actionCardCountForTesting(agentId: f.graceId)
                let receiptMessagesBefore = f.accounts.oauth.historyMessages(
                    channelId: f.receiptId
                ).count

                let reply = try await modernSendRaw(
                    client, apiKey: f.agentKey, target: refusal.target, v2: v2
                )
                let label = Comment(rawValue: "v2=\(v2) target=\(refusal.target)")
                #expect(reply.status == refusal.status, label)
                #expect(reply.raw == refusal.body, label)
                #expect(f.accounts.postableChannelCountForTesting == channelsBefore, label)
                #expect(f.accounts.humanMessageCount == messagesBefore, label)
                #expect(f.accounts.taskRecordCountForTesting == tasksBefore, label)
                #expect(f.accounts.actionCardCountForTesting(agentId: f.graceId) == cardsBefore, label)
                #expect(
                    f.accounts.oauth.historyMessages(channelId: f.receiptId).count
                        == receiptMessagesBefore,
                    label
                )
            }
        }
    }
}

@Test func taskClaimPublishesTheExactDMTargetBodiesAndWritesNothing() async throws {
    let f = makeDMCallsiteWireFixture()
    try await configuredApp(f.accounts) { client in
        let arbitrarySuffix = "a\"b\\c"
        let cases: [(target: String, status: HTTPResponse.Status, body: String)] = [
            ("dm:@Twin", .conflict, ambiguousBody("Twin")),
            ("dm:@Twin~bot", .badRequest, invalidKindBody(rawPeer: "Twin~bot", suffix: "bot")),
            (
                "dm:@Twin~\(arbitrarySuffix)", .badRequest,
                invalidKindBody(
                    rawPeer: "Twin~\(arbitrarySuffix)",
                    suffix: arbitrarySuffix
                )
            ),
            ("dm:@Twin~AGENT", .badRequest, invalidKindBody(rawPeer: "Twin~AGENT", suffix: "AGENT")),
        ]
        for refusal in cases {
            let channelsBefore = f.accounts.postableChannelCountForTesting
            let messagesBefore = f.accounts.humanMessageCount
            let tasksBefore = f.accounts.taskRecordCountForTesting
            let cardsBefore = f.accounts.actionCardCountForTesting(agentId: f.graceId)

            let reply = try await taskClaimRaw(
                client, apiKey: f.agentKey, target: refusal.target
            )
            let label = Comment(rawValue: "target=\(refusal.target)")
            #expect(reply.status == refusal.status, label)
            #expect(reply.raw == refusal.body, label)
            #expect(f.accounts.postableChannelCountForTesting == channelsBefore, label)
            #expect(f.accounts.humanMessageCount == messagesBefore, label)
            #expect(f.accounts.taskRecordCountForTesting == tasksBefore, label)
            #expect(f.accounts.actionCardCountForTesting(agentId: f.graceId) == cardsBefore, label)
        }
    }
}

// MARK: - Assistant post authority fixture

private struct DMCallsiteAssistantFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerDM: String
    let ownerDMAnchor: String
    let assistantId: String
    let assistantKey: String
    let plainId: String
    let plainKey: String
}

private func makeDMCallsiteAssistantFixture() -> DMCallsiteAssistantFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001423001"
    let ownerId = "11111111-1111-4111-8111-000001423001"
    let peerId = "11111111-1111-4111-8111-000001423002"
    for (id, email, name) in [
        (ownerId, "callsite-assistant-owner", "Owner"),
        (peerId, "callsite-assistant-peer", "Peer"),
    ] {
        accounts.addAccount(id: id, email: "\(email)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: id)
        accounts.setAccountProfileForTesting(id: id, name: name)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "callsite-assistant", name: "Callsite Assistant", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")

    let allChannel = accounts.oauth.allChannelId(serverId: serverId) ?? ""
    accounts.addPostableChannel(
        serverId: serverId, channelId: allChannel, memberId: ownerId, name: "all"
    )

    let assistant = accounts.oauth.createAgent(serverId: serverId, name: "Assistant", runtime: "codex")
    let plain = accounts.oauth.createAgent(serverId: serverId, name: "Plain", runtime: "codex")
    // Raw retained binding; the `identity_borrowing` flag stays unset (off).
    accounts.linkAssistantOwnerForTesting(agentId: assistant, userId: ownerId)

    func dm(_ peerId: String, peerKind: OAuthLedger.DirectChannelParticipantKind) -> String {
        let channel = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: peerId, secondUserId: assistant,
            firstKind: peerKind, secondKind: .agent
        )
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: peerId, kind: "dm", name: "dm")
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: assistant, kind: "dm", name: "dm")
        accounts.oauth.addChannelAgent(channelId: channel, agentId: assistant)
        if peerKind == .human {
            accounts.oauth.addChannelHuman(channelId: channel, userId: peerId)
        } else {
            accounts.oauth.addChannelAgent(channelId: channel, agentId: peerId)
        }
        return channel
    }
    let ownerDM = dm(ownerId, peerKind: .human)
    _ = dm(peerId, peerKind: .human)
    let anchor = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: anchor, channelId: ownerDM, senderId: ownerId, content: "owner dm parent")

    return DMCallsiteAssistantFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerDM: ownerDM,
        ownerDMAnchor: anchor,
        assistantId: assistant,
        assistantKey: accounts.registerMachineForAgent(serverId: serverId, agentId: assistant),
        plainId: plain,
        plainKey: accounts.registerMachineForAgent(serverId: serverId, agentId: plain)
    )
}

@Test func legacyMachineSendAssistantUsesTheRawOwnerBindingWithTheFlagOff() async throws {
    let f = makeDMCallsiteAssistantFixture()
    try await configuredApp(f.accounts) { client in
        // The `identity_borrowing` flag is off; the raw assistant binding still
        // confines posting, including the enabled #all shortcut.
        let all = try await machineSendRaw(
            client, apiKey: f.assistantKey, agentId: f.assistantId, target: "#all"
        )
        #expect(all.status == .forbidden)
        #expect(all.raw == forbiddenChannelBody)

        let foreignDM = try await machineSendRaw(
            client, apiKey: f.assistantKey, agentId: f.assistantId, target: "dm:@Peer"
        )
        #expect(foreignDM.status == .forbidden)
        #expect(foreignDM.raw == forbiddenChannelBody)

        let ownerDM = try await machineSendRaw(
            client, apiKey: f.assistantKey, agentId: f.assistantId, target: "dm:@Owner"
        )
        #expect(ownerDM.status == .ok, Comment(rawValue: ownerDM.raw))

        let anchorShort = String(f.ownerDMAnchor.prefix(8))
        let ownerThread = try await machineSendRaw(
            client, apiKey: f.assistantKey, agentId: f.assistantId, target: "dm:@Owner:\(anchorShort)"
        )
        #expect(ownerThread.status == .ok, Comment(rawValue: ownerThread.raw))
        if let messageId = object(ownerThread.raw)["messageId"] as? String,
           let channelId = f.accounts.messageChannelIdForTesting(messageId: messageId) {
            #expect(f.accounts.oauth.channelType(id: channelId) == "thread")
            #expect(f.accounts.oauth.channelParentChannelId(id: channelId) == f.ownerDM)
        } else {
            Issue.record("owner DM thread send did not publish a thread message")
        }

        // A stale owner binding still closes #all (no server membership needed
        // for the raw posting restriction), while ordinary agents are unchanged.
        f.accounts.oauth.removeMember(serverId: f.serverId, userId: f.ownerId)
        let staleAll = try await machineSendRaw(
            client, apiKey: f.assistantKey, agentId: f.assistantId, target: "#all"
        )
        #expect(staleAll.status == .forbidden)
        #expect(staleAll.raw == forbiddenChannelBody)

        let plainAll = try await machineSendRaw(
            client, apiKey: f.plainKey, agentId: f.plainId, target: "#all"
        )
        #expect(plainAll.status == .ok, Comment(rawValue: plainAll.raw))
    }
}

// MARK: - agent:create prepare fixture

private struct DMCallsitePrepareFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerDM: String
    let peerDM: String
    let ownerAnchor: String
    let peerAnchor: String
    let key: String
}

private func makeDMCallsitePrepareFixture() -> DMCallsitePrepareFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001424001"
    let ownerId = "11111111-1111-4111-8111-000001424001"
    let twinHumanId = "11111111-1111-4111-8111-000001424002"
    accounts.addAccount(id: ownerId, email: "callsite-prepare-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: twinHumanId, email: "callsite-prepare-twin@slock.test", password: "password123")
    accounts.markEmailVerified(userId: twinHumanId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "callsite-prepare", name: "Callsite Prepare", ownerId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "Owner")
    accounts.setAccountProfileForTesting(id: twinHumanId, name: "Twin")
    accounts.oauth.addMember(serverId: serverId, userId: twinHumanId, role: "member")

    // A second server holds another "Foreigner": a cross-server target must
    // never resolve here.
    let otherServerId = "33333333-3333-4333-8333-000001424101"
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "callsite-elsewhere", name: "Elsewhere", ownerId: ownerId)
    let foreignerId = "11111111-1111-4111-8111-000001424101"
    accounts.addAccount(id: foreignerId, email: "callsite-foreigner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: foreignerId)
    accounts.setAccountProfileForTesting(id: foreignerId, name: "Foreigner")
    accounts.oauth.addMember(serverId: otherServerId, userId: foreignerId, role: "member")

    let requester = accounts.oauth.createAgent(serverId: serverId, name: "Requester", runtime: "claude")
    let peerAgent = accounts.oauth.createAgent(serverId: serverId, name: "PeerAgent", runtime: "claude")
    _ = accounts.oauth.createAgent(serverId: serverId, name: "Twin", runtime: "claude")

    func dm(
        _ second: String,
        secondKind: OAuthLedger.DirectChannelParticipantKind,
        sender: String,
        content: String
    ) -> (channel: String, anchor: String) {
        let channel = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: requester, secondUserId: second,
            firstKind: .agent, secondKind: secondKind
        )
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: requester, kind: "dm", name: "dm")
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: second, kind: "dm", name: "dm")
        accounts.oauth.addChannelAgent(channelId: channel, agentId: requester)
        if secondKind == .human {
            accounts.oauth.addChannelHuman(channelId: channel, userId: second)
        } else {
            accounts.oauth.addChannelAgent(channelId: channel, agentId: second)
        }
        let anchor = UUID().uuidString.lowercased()
        accounts.insertHumanMessage(id: anchor, channelId: channel, senderId: sender, content: content)
        return (channel, anchor)
    }
    let ownerDM = dm(ownerId, secondKind: .human, sender: ownerId, content: "owner dm card parent")
    let peerDM = dm(peerAgent, secondKind: .agent, sender: peerAgent, content: "agent dm card parent")

    return DMCallsitePrepareFixture(
        accounts: accounts,
        serverId: serverId,
        ownerDM: ownerDM.channel,
        peerDM: peerDM.channel,
        ownerAnchor: ownerDM.anchor,
        peerAnchor: peerDM.anchor,
        key: accounts.mintAgentCredential(
            agentId: requester, scopes: ["send", "read"], name: "callsite-prepare"
        )
    )
}

@Test func prepareActionAgentCreateResolvesTypedCanonicalDMPeers() async throws {
    let f = makeDMCallsitePrepareFixture()
    try await configuredApp(f.accounts) { client in
        let ownerShort = String(f.ownerAnchor.prefix(8))
        let humanThread = try await prepareRaw(
            client, apiKey: f.key,
            target: "dm:@Owner~human:\(ownerShort)", actionName: "HumanPeerCard"
        )
        #expect(humanThread.status == .created, Comment(rawValue: humanThread.raw))
        let humanMessageId = try #require(object(humanThread.raw)["messageId"] as? String)
        let humanChannel = try #require(f.accounts.messageChannelIdForTesting(messageId: humanMessageId))
        #expect(f.accounts.oauth.channelType(id: humanChannel) == "thread")
        #expect(f.accounts.oauth.channelParentChannelId(id: humanChannel) == f.ownerDM)

        let peerShort = String(f.peerAnchor.prefix(8))
        let agentThread = try await prepareRaw(
            client, apiKey: f.key,
            target: "dm:@PeerAgent~agent:\(peerShort)", actionName: "AgentPeerCard"
        )
        #expect(agentThread.status == .created, Comment(rawValue: agentThread.raw))
        let agentMessageId = try #require(object(agentThread.raw)["messageId"] as? String)
        let agentChannel = try #require(f.accounts.messageChannelIdForTesting(messageId: agentMessageId))
        #expect(f.accounts.oauth.channelType(id: agentChannel) == "thread")
        #expect(f.accounts.oauth.channelParentChannelId(id: agentChannel) == f.peerDM)

        // The legacy uppercase prefix is part of the pinned DM grammar; it
        // resolves the same thread.
        let uppercase = try await prepareRaw(
            client, apiKey: f.key,
            target: "DM:@Owner~human:\(ownerShort)", actionName: "UpperPrefixCard"
        )
        #expect(uppercase.status == .created, Comment(rawValue: uppercase.raw))
        let uppercaseMessageId = try #require(object(uppercase.raw)["messageId"] as? String)
        #expect(f.accounts.messageChannelIdForTesting(messageId: uppercaseMessageId) == humanChannel)

        // A plain DM target (no thread suffix) posts into the DM itself.
        let plainDM = try await prepareRaw(
            client, apiKey: f.key, target: "dm:@Owner~human", actionName: "PlainDMCard"
        )
        #expect(plainDM.status == .created, Comment(rawValue: plainDM.raw))
        let plainMessageId = try #require(object(plainDM.raw)["messageId"] as? String)
        #expect(f.accounts.messageChannelIdForTesting(messageId: plainMessageId) == f.ownerDM)
    }
}

@Test func prepareActionAgentCreateRefusalCreatesNothing() async throws {
    let f = makeDMCallsitePrepareFixture()
    try await configuredApp(f.accounts) { client in
        let channelsBefore = f.accounts.postableChannelCountForTesting
        let messagesBefore = f.accounts.humanMessageCount

        // A full 8-hex suffix that names no anchor: no DM and no thread may be
        // created just to report the miss.
        let missingAnchor = "dm:@Owner~human:deadbeef"
        let miss = try await prepareRaw(
            client, apiKey: f.key, target: missingAnchor, actionName: "NoAnchor"
        )
        #expect(miss.status == .badRequest)
        #expect(miss.raw == couldNotResolveBody(missingAnchor))

        // A loose `:...` is not a thread suffix; it stays in the peer spelling
        // (here an unknown kind), so the old "prefix 1" phantom thread cannot
        // be created either.
        let looseSuffix = "dm:@Owner~human:1"
        let loose = try await prepareRaw(
            client, apiKey: f.key, target: looseSuffix, actionName: "LooseSuffix"
        )
        #expect(loose.status == .badRequest)
        #expect(loose.raw == invalidKindBody(rawPeer: "Owner~human:1", suffix: "human:1"))

        // A bare-colon suffix that is not eight hex takes the pinned
        // thread-shaped fallback: it reuses no DM and reports the generic
        // unresolved target rather than materializing anything.
        let bareLoose = "dm:@Owner:1"
        let bare = try await prepareRaw(
            client, apiKey: f.key, target: bareLoose, actionName: "BareLooseSuffix"
        )
        #expect(bare.status == .badRequest)
        #expect(bare.raw == couldNotResolveBody(bareLoose))

        #expect(f.accounts.postableChannelCountForTesting == channelsBefore)
        #expect(f.accounts.humanMessageCount == messagesBefore)
    }
}

@Test func prepareActionAgentCreateRefusalsPublishTheirExactBodies() async throws {
    let f = makeDMCallsitePrepareFixture()
    try await configuredApp(f.accounts) { client in
        let ownerShort = String(f.ownerAnchor.prefix(8))

        let unknownKind = "dm:@Owner~bot:\(ownerShort)"
        let badKind = try await prepareRaw(
            client, apiKey: f.key, target: unknownKind, actionName: "BadKind"
        )
        #expect(badKind.status == .badRequest)
        #expect(badKind.raw == invalidKindBody(rawPeer: "Owner~bot", suffix: "bot"))

        let uppercaseKind = "dm:@Owner~AGENT:\(ownerShort)"
        let casedKind = try await prepareRaw(
            client, apiKey: f.key, target: uppercaseKind, actionName: "CasedKind"
        )
        #expect(casedKind.status == .badRequest)
        #expect(casedKind.raw == invalidKindBody(rawPeer: "Owner~AGENT", suffix: "AGENT"))

        // `Twin` names both a human member and a live agent here.
        let ambiguous = try await prepareRaw(
            client, apiKey: f.key, target: "dm:@Twin:\(ownerShort)", actionName: "TwinCard"
        )
        #expect(ambiguous.status == .conflict)
        #expect(ambiguous.raw == ambiguousBody("Twin"))

        // Canonical names are exact and case-sensitive.
        let wrongCase = try await prepareRaw(
            client, apiKey: f.key, target: "dm:@owner~human", actionName: "WrongCase"
        )
        #expect(wrongCase.status == .notFound)
        #expect(wrongCase.raw == dmPeerNotFoundBody("owner~human"))
    }
}

@Test func prepareActionAgentCreateNeverResolvesAcrossServers() async throws {
    let f = makeDMCallsitePrepareFixture()
    try await configuredApp(f.accounts) { client in
        let channelsBefore = f.accounts.postableChannelCountForTesting
        let messagesBefore = f.accounts.humanMessageCount

        let foreign = try await prepareRaw(
            client, apiKey: f.key, target: "dm:@Foreigner", actionName: "CrossServer"
        )
        #expect(foreign.status == .notFound)
        #expect(foreign.raw == dmPeerNotFoundBody("Foreigner"))

        #expect(f.accounts.postableChannelCountForTesting == channelsBefore)
        #expect(f.accounts.humanMessageCount == messagesBefore)
    }
}
