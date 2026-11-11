import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Synchronization
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func agentApiTaskClaimStatusDeleteAndConvert() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001026001"
    let ownerId = "11111111-1111-4111-8111-000001026001"
    accounts.addAccount(id: ownerId, email: "agent-task-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-task", name: "Agent Task", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "agent-task-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "agent-task-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "TaskBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "tasks")
    let knownMessage = "11111111-1111-4111-8111-000001026099"
    accounts.addTaskForTesting(channelId: channel, title: "first task", messageId: knownMessage, assigneeType: nil, assigneeId: nil)
    _ = accounts.taskCatalog.addTasks(channelId: channel, titles: ["second task"])

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let channelRef = "#agent-task-room"

            let claim = try await post("/internal/agent-api/tasks/claim", "{\"channel\":\"\(channelRef)\",\"task_numbers\":[1]}")
            #expect(claim.status == .ok)
            let claimResults = object(claim)["results"] as? [[String: Any]] ?? []
            #expect(claimResults.first?["success"] as? Bool == true)
            #expect(claimResults.first?["taskNumber"] as? Int == 1)

            let already = try await post("/internal/agent-api/tasks/claim", "{\"channel\":\"\(channelRef)\",\"task_numbers\":[1]}")
            #expect((object(already)["results"] as? [[String: Any]] ?? []).first?["reason"] as? String == "already claimed by you")

            let idless = try await post("/internal/agent-api/tasks/claim", "{\"channel\":\"\(channelRef)\",\"message_ids\":[\"\(String(knownMessage.prefix(8)))\"]}")
            let idlessResult = (object(idless)["results"] as? [[String: Any]] ?? []).first
            #expect(idlessResult?["reason"] as? String == "already claimed by you")
            #expect(idlessResult?["taskNumber"] as? Int == 1)

            let demote = try await post("/internal/agent-api/tasks/update-status", "{\"channel\":\"\(channelRef)\",\"task_number\":1,\"status\":\"todo\"}")
            #expect(demote.status == .ok)
            #expect(object(demote)["status"] as? String == "todo")
            #expect(object(demote)["claimedById"] as? String == agent)
            #expect(object(demote)["claimedAt"] is NSNull)

            let memberDone = try await post("/internal/agent-api/tasks/update-status", "{\"channel\":\"\(channelRef)\",\"task_number\":2,\"status\":\"done\"}")
            #expect(memberDone.status == .conflict)
            #expect(((object(memberDone)["error"] as? String) ?? "").contains("cannot transition from todo to done"))

            accounts.oauth.setAgentRole(serverId: serverId, agentId: agent, role: "admin")
            let adminDone = try await post("/internal/agent-api/tasks/update-status", "{\"channel\":\"\(channelRef)\",\"task_number\":2,\"status\":\"done\"}")
            #expect(adminDone.status == .ok)
            #expect(object(adminDone)["status"] as? String == "done")

            let message = accounts.addChannelMessageForTesting(channelId: channel, content: "convert me", senderId: ownerId)
            let converted = try await post("/internal/agent-api/tasks/convert", "{\"channel\":\"\(channelRef)\",\"message_id\":\"\(message)\"}")
            #expect(converted.status == .ok)
            let task = try #require(object(converted)["task"] as? [String: Any])
            #expect(task["messageId"] as? String == message)
            #expect(task["status"] as? String == "todo")
            #expect(task["claimedById"] is NSNull)
            let taskNumber = try #require(task["taskNumber"] as? Int)

            let again = try await post("/internal/agent-api/tasks/convert", "{\"channel\":\"\(channelRef)\",\"message_id\":\"\(message)\"}")
            #expect(again.status == .conflict)

            let deleted = try await post("/internal/agent-api/tasks/delete", "{\"channel\":\"\(channelRef)\",\"task_number\":\(taskNumber)}")
            #expect(deleted.status == .ok)
            let deletedAgain = try await post("/internal/agent-api/tasks/delete", "{\"channel\":\"\(channelRef)\",\"task_number\":\(taskNumber)}")
            #expect(deletedAgain.status == .notFound)
        }
    }
}

/// The claim-before-work prompt claims an actionable top-level DM message by
/// `dm:@peer`, exactly like the pinned server's `resolveChannelByName`. The
/// task channel resolver must accept the DM arm; answering `400 Invalid task
/// claim request` blocks the agent from starting the attached work at all.
@Test func agentApiTaskClaimAndConvertResolveDMChannelReference() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001026002"
    let ownerId = "11111111-1111-4111-8111-000001026002"
    accounts.addAccount(id: ownerId, email: "agent-task-dm-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "dm-owner")
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-task-dm", name: "Agent Task DM", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "DMTaskBot", runtime: "codex")
    let dm = accounts.oauth.createDirectChannel(
        serverId: serverId, firstUserId: ownerId, secondUserId: agent,
        firstKind: .human, secondKind: .agent
    )
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: dm, memberId: member, kind: "dm", name: "dm")
    }
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "tasks")
    let claimMessage = UUID().uuidString.lowercased()
    let convertMessage = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: claimMessage, channelId: dm, senderId: ownerId, content: "claim this DM message")
    accounts.insertHumanMessage(id: convertMessage, channelId: dm, senderId: ownerId, content: "convert this DM message")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let dmRef = "dm:@dm-owner"

            let claim = try await post(
                "/internal/agent-api/tasks/claim",
                "{\"channel\":\"\(dmRef)\",\"message_ids\":[\"\(String(claimMessage.prefix(8)))\"]}"
            )
            #expect(claim.status == .ok, Comment(rawValue: claim.body.string ?? ""))
            let claimResult = (object(claim)["results"] as? [[String: Any]] ?? []).first
            #expect(claimResult?["success"] as? Bool == true)
            #expect(claimResult?["messageId"] as? String == claimMessage)
            #expect(claimResult?["taskNumber"] as? Int == 1)
            // The conversion links the canonical task to the unchanged DM host;
            // it never rewrites the chat row into a task shadow.
            #expect(accounts.messageTaskShadowForTesting(messageId: claimMessage) == nil)
            #expect(accounts.taskSnapshotsForTesting(channelId: dm).first?.title == "claim this DM message")

            let converted = try await post(
                "/internal/agent-api/tasks/convert",
                "{\"channel\":\"\(dmRef)\",\"message_id\":\"\(convertMessage)\"}"
            )
            #expect(converted.status == .ok, Comment(rawValue: converted.body.string ?? ""))
            let task = try #require(object(converted)["task"] as? [String: Any])
            #expect(task["messageId"] as? String == convertMessage)

            // A peer with no canonical account or DM is the published 404
            // `Agent or channel not found`, not an empty success.
            let missing = try await post(
                "/internal/agent-api/tasks/claim",
                "{\"channel\":\"dm:@missing-peer\",\"message_ids\":[\"\(String(claimMessage.prefix(8)))\"]}"
            )
            #expect(missing.status == .notFound)
        }
    }
}

// MARK: - Claim review follow-up: canonical DM peers, writable gate, conversion

private struct ClaimReviewFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let key: String
    let channelId: String
    let channelRef: String
}

private func makeClaimReviewFixture(_ suffix: String) -> ClaimReviewFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 102_600 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 102_600 + number)
    accounts.addAccount(id: ownerId, email: "claim-review-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "claim-owner-\(suffix)")
    accounts.oauth.addOwnedServer(id: serverId, slug: "claim-review-\(suffix)", name: "Claim Review", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(
        serverId: serverId, name: "claim-room-\(suffix)", creatorUserId: ownerId
    )
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "claim-room-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ClaimBot\(suffix)", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, name: "claim-room-\(suffix)")
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "tasks"], name: "claim-review-\(suffix)")
    return ClaimReviewFixture(
        accounts: accounts, serverId: serverId, ownerId: ownerId, agentId: agentId,
        key: key, channelId: channelId, channelRef: "#claim-room-\(suffix)"
    )
}

private func claimPost(_ client: any Client, key: String, body: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/claim") { request in
        request.body = .init(string: body)
    }
}

private func claimJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func claimResults(_ response: ClientResponse) -> [[String: Any]] {
    claimJSON(response)["results"] as? [[String: Any]] ?? []
}

/// A human whose display name is `bob` is not the peer named `bob`; the
/// pinned `findHumanPeerDm` matches `users.name` exactly, so aliases and
/// case-folded handles must not select a conversation.
@Test func agentApiTaskClaimMatchesCanonicalPeerNameExactly() async throws {
    let f = makeClaimReviewFixture("201")
    let aliceId = "11111111-1111-4111-8111-000001026211"
    let bobId = "11111111-1111-4111-8111-000001026212"
    f.accounts.addAccount(id: aliceId, email: "claim-alice-201@slock.test", password: "password123")
    f.accounts.setAccountProfileForTesting(id: aliceId, name: "alice", displayName: "bob")
    f.accounts.oauth.addMember(serverId: f.serverId, userId: aliceId, role: "member")
    let aliceDm = f.accounts.oauth.createDirectChannel(
        serverId: f.serverId, firstUserId: aliceId, secondUserId: f.agentId,
        firstKind: .human, secondKind: .agent
    )
    for member in [aliceId, f.agentId] {
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: aliceDm, memberId: member, kind: "dm", name: "dm")
    }
    let aliceMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: aliceMessage, channelId: aliceDm, senderId: aliceId, content: "alice message")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            // No human is canonically named bob yet: the display-name alias is
            // not a peer, so the DM target does not resolve at all.
            let alias = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@bob\",\"message_ids\":[\"\(String(aliceMessage.prefix(8)))\"]}"
            )
            #expect(alias.status == .notFound, Comment(rawValue: alias.body.string ?? ""))
            #expect(claimJSON(alias)["error"] as? String == "Agent or channel not found")
            #expect(f.accounts.taskSnapshotsForTesting(channelId: aliceDm).isEmpty)

            // Now a real human bob exists with his own DM; `dm:@bob` names that
            // conversation, never alice's display-name alias.
            f.accounts.addAccount(id: bobId, email: "claim-bob-201@slock.test", password: "password123")
            f.accounts.setAccountProfileForTesting(id: bobId, name: "bob", displayName: "Bob Person")
            f.accounts.oauth.addMember(serverId: f.serverId, userId: bobId, role: "member")
            let bobDm = f.accounts.oauth.createDirectChannel(
                serverId: f.serverId, firstUserId: bobId, secondUserId: f.agentId,
                firstKind: .human, secondKind: .agent
            )
            for member in [bobId, f.agentId] {
                f.accounts.addPostableChannel(serverId: f.serverId, channelId: bobDm, memberId: member, kind: "dm", name: "dm")
            }
            let bobMessage = UUID().uuidString.lowercased()
            f.accounts.insertHumanMessage(id: bobMessage, channelId: bobDm, senderId: bobId, content: "bob message")

            let wrongDm = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@bob\",\"message_ids\":[\"\(String(aliceMessage.prefix(8)))\"]}"
            )
            #expect(wrongDm.status == .ok)
            #expect(claimResults(wrongDm).first?["success"] as? Bool == false)
            #expect(claimResults(wrongDm).first?["reason"] as? String == "message not found")
            #expect(f.accounts.taskSnapshotsForTesting(channelId: aliceDm).isEmpty)

            let bobClaim = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@bob\",\"message_ids\":[\"\(String(bobMessage.prefix(8)))\"]}"
            )
            #expect(bobClaim.status == .ok)
            #expect(claimResults(bobClaim).first?["messageId"] as? String == bobMessage)
            #expect(claimResults(bobClaim).first?["success"] as? Bool == true)

            // Case folding is not the published rule either.
            let upperHuman = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@BOB\",\"message_ids\":[\"\(String(bobMessage.prefix(8)))\"]}"
            )
            #expect(upperHuman.status == .notFound)

            // The agent peer name is exact too; only the canonical spelling
            // resolves its agent-agent DM.
            let carol = f.accounts.oauth.createAgent(serverId: f.serverId, name: "CarolClaim", runtime: "claude")
            let carolDm = f.accounts.oauth.createDirectChannel(
                serverId: f.serverId, firstUserId: f.agentId, secondUserId: carol,
                firstKind: .agent, secondKind: .agent
            )
            for member in [f.agentId, carol] {
                f.accounts.addPostableChannel(serverId: f.serverId, channelId: carolDm, memberId: member, kind: "dm", name: "dm")
            }
            let carolMessage = UUID().uuidString.lowercased()
            f.accounts.insertHumanMessage(
                id: carolMessage, channelId: carolDm, senderId: carol, content: "carol message", senderType: "agent"
            )
            let lowerAgent = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@carolclaim\",\"message_ids\":[\"\(String(carolMessage.prefix(8)))\"]}"
            )
            #expect(lowerAgent.status == .notFound)
            let exactAgent = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@CarolClaim\",\"message_ids\":[\"\(String(carolMessage.prefix(8)))\"]}"
            )
            #expect(exactAgent.status == .ok)
            #expect(claimResults(exactAgent).first?["success"] as? Bool == true)
        }
    }
}

/// A bare name held by both a human and an agent is the published 409
/// `DM_TARGET_AMBIGUOUS`; `~human`/`~agent` pin the kind and an unknown suffix
/// is the 400 `DM_TARGET_INVALID_PEER_KIND` body.
@Test func agentApiTaskClaimKeepsPeerKindPinsAndCrossKindAmbiguity() async throws {
    let f = makeClaimReviewFixture("202")
    let humanId = "11111111-1111-4111-8111-000001026221"
    f.accounts.addAccount(id: humanId, email: "claim-twin-202@slock.test", password: "password123")
    f.accounts.setAccountProfileForTesting(id: humanId, name: "twinclaim", displayName: "Human Twinclaim")
    f.accounts.oauth.addMember(serverId: f.serverId, userId: humanId, role: "member")
    let humanDm = f.accounts.oauth.createDirectChannel(
        serverId: f.serverId, firstUserId: humanId, secondUserId: f.agentId,
        firstKind: .human, secondKind: .agent
    )
    for member in [humanId, f.agentId] {
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: humanDm, memberId: member, kind: "dm", name: "dm")
    }
    let humanMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: humanMessage, channelId: humanDm, senderId: humanId, content: "human twin message")

    let twinAgent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "twinclaim", runtime: "claude")
    let agentDm = f.accounts.oauth.createDirectChannel(
        serverId: f.serverId, firstUserId: f.agentId, secondUserId: twinAgent,
        firstKind: .agent, secondKind: .agent
    )
    for member in [f.agentId, twinAgent] {
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: agentDm, memberId: member, kind: "dm", name: "dm")
    }
    let agentMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(
        id: agentMessage, channelId: agentDm, senderId: twinAgent, content: "agent twin message", senderType: "agent"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let ambiguous = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@twinclaim\",\"message_ids\":[\"\(String(humanMessage.prefix(8)))\"]}"
            )
            #expect(ambiguous.status == .conflict, Comment(rawValue: ambiguous.body.string ?? ""))
            #expect(claimJSON(ambiguous)["code"] as? String == "DM_TARGET_AMBIGUOUS")
            #expect((claimJSON(ambiguous)["error"] as? String)?.contains("dm:@twinclaim~agent") == true)
            #expect((claimJSON(ambiguous)["error"] as? String)?.contains("dm:@twinclaim~human") == true)
            let suggestion = (claimJSON(ambiguous)["suggestedNextAction"] as? String) ?? ""
            #expect(suggestion.contains("dm:@twinclaim~agent"))
            #expect(suggestion.contains("dm:@twinclaim~human"))
            #expect(f.accounts.taskSnapshotsForTesting(channelId: humanDm).isEmpty)
            #expect(f.accounts.messageTaskShadowForTesting(messageId: humanMessage) == nil)

            let human = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@twinclaim~human\",\"message_ids\":[\"\(String(humanMessage.prefix(8)))\"]}"
            )
            #expect(human.status == .ok)
            #expect(claimResults(human).first?["success"] as? Bool == true)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: humanDm).count == 1)

            let agent = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@twinclaim~agent\",\"message_ids\":[\"\(String(agentMessage.prefix(8)))\"]}"
            )
            #expect(agent.status == .ok)
            #expect(claimResults(agent).first?["messageId"] as? String == agentMessage)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: agentDm).count == 1)

            let badKind = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@twinclaim~bot\",\"message_ids\":[\"\(String(humanMessage.prefix(8)))\"]}"
            )
            #expect(badKind.status == .badRequest)
            #expect(claimJSON(badKind)["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")
            #expect((claimJSON(badKind)["error"] as? String)?.contains("unknown peer kind \"bot\"") == true)
            #expect(((claimJSON(badKind)["suggestedNextAction"] as? String) ?? "").contains("dm:@<name>~agent"))
        }
    }
}

/// The published claim gate runs before freshness and before task lookup:
/// thread refs are 409; a channel the agent cannot post in is 403; an archived
/// channel is the 409 `channel_archived` body. No refusal may convert or claim.
@Test func agentApiTaskClaimRefusesUnwritableArchivedThreadAndReminderTargets() async throws {
    let f = makeClaimReviewFixture("203")
    let outside = f.accounts.oauth.createChannel(
        serverId: f.serverId, name: "claim-outside-203", creatorUserId: f.ownerId
    )
    f.accounts.addPostableChannel(
        serverId: f.serverId, channelId: outside, memberId: f.ownerId, name: "claim-outside-203"
    )
    let outsideMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: outsideMessage, channelId: outside, senderId: f.ownerId, content: "outside message")
    let roomTaskId = f.accounts.addTaskForTesting(
        channelId: f.channelId, title: "room task", messageId: UUID().uuidString.lowercased(),
        assigneeType: nil, assigneeId: nil
    )
    _ = roomTaskId
    let roomMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: roomMessage, channelId: f.channelId, senderId: f.ownerId, content: "room message")

    let archived = f.accounts.oauth.createChannel(
        serverId: f.serverId, name: "claim-archived-203", creatorUserId: f.ownerId
    )
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: archived, memberId: f.ownerId, name: "claim-archived-203")
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: archived, memberId: f.agentId, name: "claim-archived-203")
    _ = f.accounts.addTaskForTesting(
        channelId: archived, title: "archived task", messageId: UUID().uuidString.lowercased(),
        assigneeType: nil, assigneeId: nil
    )
    let archivedMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: archivedMessage, channelId: archived, senderId: f.ownerId, content: "archived message")
    f.accounts.oauth.setChannelArchived(id: archived, archivedAt: Date())

    let parent = "11111111-1111-4111-8111-000001026298"
    f.accounts.insertHumanMessage(id: parent, channelId: f.channelId, senderId: f.ownerId, content: "thread parent")
    let thread = f.accounts.oauth.createThreadChannel(parentChannelId: f.channelId, parentMessageId: parent)
    f.accounts.addPostableChannel(
        serverId: f.serverId, channelId: thread, memberId: f.agentId, kind: "thread",
        parentChannelId: f.channelId, parentMessageId: parent, name: "thread"
    )
    f.accounts.oauth.addChannelAgent(channelId: thread, agentId: f.agentId)
    let threadMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: threadMessage, channelId: thread, senderId: f.ownerId, content: "thread message")

    let reminders = f.accounts.oauth.createChannel(
        serverId: f.serverId, name: "reminders", creatorUserId: f.agentId, type: "dm"
    )
    f.accounts.oauth.addChannelAgent(channelId: reminders, agentId: f.agentId)
    f.accounts.addPostableChannel(
        serverId: f.serverId, channelId: reminders, memberId: f.agentId, kind: "dm", name: "reminders"
    )
    f.accounts.setAgentReminderSurfaceForTesting(agentId: f.agentId, channelId: reminders)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            // Public channel, not a member: 403 before the task lookup.
            let unauthorizedNumber = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"#claim-outside-203\",\"task_numbers\":[1]}"
            )
            #expect(unauthorizedNumber.status == .forbidden)
            #expect(claimJSON(unauthorizedNumber)["error"] as? String == "Agent must join this channel to modify tasks")

            let unauthorizedMessage = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"#claim-outside-203\",\"message_ids\":[\"\(String(outsideMessage.prefix(8)))\"]}"
            )
            #expect(unauthorizedMessage.status == .forbidden)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: outside).isEmpty)
            #expect(f.accounts.messageTaskShadowForTesting(messageId: outsideMessage) == nil)

            // Archived channel: 409 channel_archived, nothing converted.
            let archivedNumber = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"#claim-archived-203\",\"task_numbers\":[1]}"
            )
            #expect(archivedNumber.status == .conflict, Comment(rawValue: archivedNumber.body.string ?? ""))
            #expect(claimJSON(archivedNumber)["code"] as? String == "channel_archived")
            #expect(f.accounts.taskSnapshotsForTesting(channelId: archived).count == 1)

            // The convert route shares the same writable policy: an archived
            // channel and an unjoined public channel write nothing.
            for (target, messageId, status) in [
                ("#claim-outside-203", outsideMessage, HTTPResponse.Status.forbidden),
                ("#claim-archived-203", archivedMessage, .conflict)
            ] {
                let converted = try await client.send(
                    .post,
                    headers: {
                        var headers = HTTPFields()
                        headers[.authorization] = "Bearer \(f.key)"
                        headers[.contentType] = "application/json"
                        return headers
                    }(),
                    to: "/internal/agent-api/tasks/convert"
                ) { request in
                    request.body = .init(string: "{\"channel\":\"\(target)\",\"message_id\":\"\(String(messageId.prefix(8)))\"}")
                }
                #expect(converted.status == status, Comment(rawValue: converted.body.string ?? ""))
                #expect(f.accounts.messageTaskShadowForTesting(messageId: messageId) == nil)
            }

            // Thread target: the pinned 409 refusal for both task numbers and
            // message ids, with no conversion in the thread.
            for body in [
                "{\"channel\":\"#claim-room-203:\(String(parent.prefix(8)))\",\"task_numbers\":[1]}",
                "{\"channel\":\"#claim-room-203:\(String(parent.prefix(8)))\",\"message_ids\":[\"\(String(threadMessage.prefix(8)))\"]}"
            ] {
                let threadRefusal = try await claimPost(client, key: f.key, body: body)
                #expect(threadRefusal.status == .conflict, Comment(rawValue: threadRefusal.body.string ?? ""))
                #expect(claimJSON(threadRefusal)["error"] as? String == "Thread messages cannot be claimed as tasks")
            }
            #expect(f.accounts.taskSnapshotsForTesting(channelId: thread).isEmpty)
            #expect(f.accounts.messageTaskShadowForTesting(messageId: threadMessage) == nil)

            // `dm:@reminders` resolves the private surface upstream, and the
            // writable gate then refuses it (server-only surface) with 403.
            for target in ["dm:@reminders", "dm:@Reminders"] {
                let reminder = try await claimPost(
                    client, key: f.key, body: "{\"channel\":\"\(target)\",\"task_numbers\":[1]}"
                )
                #expect(reminder.status == .forbidden, Comment(rawValue: reminder.body.string ?? ""))
                #expect(claimJSON(reminder)["error"] as? String == "Agent must join this channel to modify tasks")
            }
            #expect(f.accounts.taskSnapshotsForTesting(channelId: reminders).isEmpty)

            // A disabled #all is closed to every agent; re-enabling it opens
            // the claim without adding a membership row.
            let allChannel = try #require(f.accounts.oauth.allChannelId(serverId: f.serverId))
            f.accounts.addPostableChannel(
                serverId: f.serverId, channelId: allChannel, memberId: f.ownerId, name: "all"
            )
            _ = f.accounts.addTaskForTesting(
                channelId: allChannel, title: "all task", messageId: UUID().uuidString.lowercased(),
                assigneeType: nil, assigneeId: nil
            )
            f.accounts.oauth.setChannelType(id: allChannel, type: "private")
            let disabledAll = try await claimPost(
                client, key: f.key, body: "{\"channel\":\"#all\",\"task_numbers\":[1]}"
            )
            #expect(disabledAll.status == .forbidden, Comment(rawValue: disabledAll.body.string ?? ""))
            #expect(f.accounts.taskSnapshotsForTesting(channelId: allChannel).first?.status == "in_progress")
            f.accounts.oauth.setChannelType(id: allChannel, type: "channel")
            let enabledAll = try await claimPost(
                client, key: f.key, body: "{\"channel\":\"#all\",\"task_numbers\":[1]}"
            )
            #expect(enabledAll.status == .ok, Comment(rawValue: enabledAll.body.string ?? ""))
            #expect(claimResults(enabledAll).first?["success"] as? Bool == true)

            // A channel on another server is not visible through this server's
            // agent credential (404, the same published miss as any unknown ref).
            let otherServer = "33333333-3333-4333-8333-000001026299"
            f.accounts.oauth.addOwnedServer(id: otherServer, slug: "claim-other-203", name: "Other", ownerId: f.ownerId)
            _ = f.accounts.oauth.createChannel(serverId: otherServer, name: "claim-foreign-203", creatorUserId: f.ownerId)
            let foreign = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"#claim-foreign-203\",\"task_numbers\":[1]}"
            )
            #expect(foreign.status == .notFound)
            #expect(claimJSON(foreign)["error"] as? String == "Agent or channel not found")
        }
    }
}

/// The claim-by-message-id branch publishes the resolved canonical host id,
/// converts once with the actual host text, and uses the published
/// `message not found` reason for a miss in this channel.
@Test func agentApiTaskClaimByMessageIDConvertsOnceWithCanonicalShape() async throws {
    let f = makeClaimReviewFixture("204")
    let host = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: host, channelId: f.channelId, senderId: f.ownerId, content: "convert me exactly")
    let foreignChannel = f.accounts.oauth.createChannel(
        serverId: f.serverId, name: "claim-foreign-204", creatorUserId: f.ownerId
    )
    f.accounts.addPostableChannel(
        serverId: f.serverId, channelId: foreignChannel, memberId: f.ownerId, name: "claim-foreign-204"
    )
    let foreignMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: foreignMessage, channelId: foreignChannel, senderId: f.ownerId, content: "elsewhere")
    let otherAgent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "ClaimOther204", runtime: "claude")
    let heldMessage = UUID().uuidString.lowercased()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let claim = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"\(f.channelRef)\",\"message_ids\":[\"\(String(host.prefix(8)))\"]}"
            )
            #expect(claim.status == .ok)
            #expect(
                claim.body.string
                    == "{\"results\":[{\"messageId\":\"\(host)\",\"success\":true,\"taskNumber\":1}]}"
            )
            let tasks = f.accounts.taskSnapshotsForTesting(channelId: f.channelId)
            #expect(tasks.count == 1)
            #expect(tasks.first?.messageId == host)
            #expect(tasks.first?.title == "convert me exactly")
            #expect(tasks.first?.status == "in_progress")
            #expect(tasks.first?.creatorId == f.agentId)
            #expect(tasks.first.map { f.accounts.taskPublishedEventTypesForTesting(taskId: $0.id).filter { $0 == "created" }.count } == 1)
            #expect(f.accounts.messageTaskShadowForTesting(messageId: host) == nil, "conversion must not rewrite the host message")

            let repeated = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"\(f.channelRef)\",\"message_ids\":[\"\(String(host.prefix(8)))\"]}"
            )
            #expect(repeated.status == .ok)
            #expect(
                repeated.body.string
                    == "{\"results\":[{\"messageId\":\"\(host)\",\"success\":false,\"reason\":\"already claimed by you\",\"taskNumber\":1}]}"
            )
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.channelId).count == 1)

            let missing = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"\(f.channelRef)\",\"message_ids\":[\"deadbeef\"]}"
            )
            #expect(missing.status == .ok)
            #expect(missing.body.string == "{\"results\":[{\"messageId\":\"deadbeef\",\"success\":false,\"reason\":\"message not found\"}]}")

            let crossChannel = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"\(f.channelRef)\",\"message_ids\":[\"\(String(foreignMessage.prefix(8)))\"]}"
            )
            #expect(crossChannel.status == .ok)
            #expect(claimResults(crossChannel).first?["reason"] as? String == "message not found")
            #expect(claimResults(crossChannel).first?["messageId"] as? String == String(foreignMessage.prefix(8)))
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.channelId).count == 1)

            _ = f.accounts.addTaskForTesting(
                channelId: f.channelId, title: "held task", messageId: heldMessage,
                assigneeType: "agent", assigneeId: otherAgent
            )
            let held = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"\(f.channelRef)\",\"message_ids\":[\"\(heldMessage)\"]}"
            )
            #expect(held.status == .ok)
            #expect(claimResults(held).first?["success"] as? Bool == false)
            #expect(claimResults(held).first?["taskNumber"] as? Int == 2)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.channelId).count == 2)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.channelId).map(\.taskNumber) == [1, 2])
        }
    }
}

/// A migration-receipt-looking name that has no receipt row falls through to
/// the ordinary peer rules, and a real receipt still resolves only for the
/// agent that owns it.
@Test func agentApiTaskClaimMigrationReceiptFallsBackToPeerRules() async throws {
    let f = makeClaimReviewFixture("205")
    let ghostId = "11111111-1111-4111-8111-000001026251"
    f.accounts.addAccount(id: ghostId, email: "claim-ghost-205@slock.test", password: "password123")
    f.accounts.setAccountProfileForTesting(id: ghostId, name: "migration-receipt-ghost")
    f.accounts.oauth.addMember(serverId: f.serverId, userId: ghostId, role: "member")
    let ghostDm = f.accounts.oauth.createDirectChannel(
        serverId: f.serverId, firstUserId: ghostId, secondUserId: f.agentId,
        firstKind: .human, secondKind: .agent
    )
    for member in [ghostId, f.agentId] {
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: ghostDm, memberId: member, kind: "dm", name: "dm")
    }
    let ghostMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(
        id: ghostMessage, channelId: ghostDm, senderId: ghostId, content: "ghost peer message"
    )

    let receiptAgent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "ReceiptOwner205", runtime: "claude")
    let receipt = f.accounts.createMigrationReceiptDmForTesting(agentId: receiptAgent, supportRef: "review-205")
    #expect(receipt != nil)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let fallback = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@migration-receipt-ghost\",\"message_ids\":[\"\(String(ghostMessage.prefix(8)))\"]}"
            )
            #expect(fallback.status == .ok, Comment(rawValue: fallback.body.string ?? ""))
            #expect(claimResults(fallback).first?["success"] as? Bool == true)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: ghostDm).count == 1)

            let foreignReceipt = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"dm:@migration-receipt-review-205\",\"task_numbers\":[1]}"
            )
            #expect(foreignReceipt.status == .notFound)
            #expect(claimJSON(foreignReceipt)["error"] as? String == "Agent or channel not found")
        }
    }
}

/// A converted claim teaches only the task board (`task:created`) because the
/// host message is unchanged; a claim of an existing task publishes
/// `task:updated`. Neither publishes `message:updated`.
@Test func agentApiTaskClaimPublishesOnlyTheTaskBoardFrame() async throws {
    let f = makeClaimReviewFixture("206")
    let host = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: host, channelId: f.channelId, senderId: f.ownerId, content: "converted host text")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let captured = Mutex<[(room: String, event: String, payload: String?)]>([])
            f.accounts.realtimeRelay.install { room, event, payload in
                captured.withLock { $0.append((room, event, payload)) }
            }
            defer { f.accounts.realtimeRelay.install(nil) }

            let converted = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"\(f.channelRef)\",\"message_ids\":[\"\(String(host.prefix(8)))\"]}"
            )
            #expect(converted.status == .ok)
            let conversionFrames = captured.withLock { $0 }
            #expect(!conversionFrames.contains { $0.event == "message:updated" || $0.event == "message:new" })
            let createdFrames = conversionFrames.filter { $0.event == "task:created" }
            #expect(createdFrames.count == 1, Comment(rawValue: "\(conversionFrames.map(\.event))"))
            let createdFrame = try #require(createdFrames.first)
            #expect(createdFrame.room == "channel:\(f.channelId)")
            let createdPayload = (try? JSONSerialization.jsonObject(with: Data((createdFrame.payload ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(createdPayload["channelId"] as? String == f.channelId)
            let createdTask = (createdPayload["tasks"] as? [[String: Any]] ?? []).first
            #expect(createdTask?["messageId"] as? String == host)
            #expect(createdTask?["title"] as? String == "converted host text")
            #expect(createdTask?["status"] as? String == "in_progress")
            #expect(createdTask?["taskNumber"] as? Int == 1)
            #expect(createdTask?["claimedById"] as? String == f.agentId)

            captured.withLock { $0.removeAll() }
            _ = f.accounts.addTaskForTesting(
                channelId: f.channelId, title: "number claim", messageId: UUID().uuidString.lowercased(),
                assigneeType: nil, assigneeId: nil
            )
            let numbered = try await claimPost(
                client, key: f.key,
                body: "{\"channel\":\"\(f.channelRef)\",\"task_numbers\":[2]}"
            )
            #expect(numbered.status == .ok)
            let numberFrames = captured.withLock { $0 }
            #expect(!numberFrames.contains { $0.event == "message:updated" || $0.event == "message:new" })
            let updatedFrames = numberFrames.filter { $0.event == "task:updated" }
            #expect(updatedFrames.count == 1)
            #expect(conversionFrames.filter { $0.event == "task:updated" }.isEmpty)
            let updatedFrame = try #require(updatedFrames.first)
            #expect(updatedFrame.room == "channel:\(f.channelId)")
            let updatedPayload = (try? JSONSerialization.jsonObject(with: Data((updatedFrame.payload ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(updatedPayload["channelId"] as? String == f.channelId)
            let updatedTask = updatedPayload["task"] as? [String: Any]
            #expect(updatedTask?["taskNumber"] as? Int == 2)
            #expect(updatedTask?["claimedById"] as? String == f.agentId)
            #expect(updatedTask?["status"] as? String == "in_progress")
        }
    }
}
