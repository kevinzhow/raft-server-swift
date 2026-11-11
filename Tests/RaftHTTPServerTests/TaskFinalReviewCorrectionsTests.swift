import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func reviewHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func reviewPost(
    _ client: any Client, key: String, _ path: String, _ body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: reviewHeaders(key), to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func reviewObject(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func reviewJSONString(_ value: String) -> String {
    let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
    return String(decoding: data, as: UTF8.self)
}

private struct ReviewDMWorld {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let key: String
    let roomName: String
    let roomId: String
    let ownerDM: String
    let peerHumanId: String
    let peerHumanName: String
    let peerHumanDM: String
    let twinHumanId: String
    let twinAgentId: String
    let twinHumanDM: String
    let twinAgentDM: String
    let peerAgentId: String
    let peerAgentName: String
    let peerAgentDM: String
    let remindersId: String
}

private func makeReviewDMWorld(_ suffix: String) -> ReviewDMWorld {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001310\(suffix)"
    let ownerId = "11111111-1111-4111-8111-000001310\(suffix)"
    let peerHumanId = "11111111-1111-4111-8111-000001311\(suffix)"
    let twinHumanId = "11111111-1111-4111-8111-000001312\(suffix)"
    accounts.addAccount(id: ownerId, email: "review-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerHumanId, email: "review-peer-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerHumanId)
    accounts.addAccount(id: twinHumanId, email: "review-twin-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: twinHumanId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "review-owner-\(suffix)", displayName: "Review Owner")
    accounts.setAccountProfileForTesting(id: peerHumanId, name: "remindersX\(suffix)", displayName: "Peer Human")
    accounts.setAccountProfileForTesting(id: twinHumanId, name: "Twin\(suffix)", displayName: "Human Twin")
    accounts.oauth.addOwnedServer(id: serverId, slug: "review-dm-\(suffix)", name: "Review DM", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerHumanId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: twinHumanId, role: "member")

    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ReviewBot\(suffix)", runtime: "codex")
    let peerAgentId = accounts.oauth.createAgent(serverId: serverId, name: "PeerAgent\(suffix)", runtime: "codex")
    let twinAgentId = accounts.oauth.createAgent(serverId: serverId, name: "Twin\(suffix)", runtime: "claude")
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "tasks"], name: "review-dm-\(suffix)")

    let roomName = "review-room-\(suffix)"
    let roomId = accounts.oauth.createChannel(serverId: serverId, name: roomName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: ownerId, name: roomName)
    accounts.oauth.addChannelHuman(channelId: roomId, userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: agentId, name: roomName)
    accounts.oauth.addChannelAgent(channelId: roomId, agentId: agentId)

    func dm(_ first: String, _ second: String, firstKind: String, secondKind: String) -> String {
        let id = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: first, secondUserId: second,
            firstKind: firstKind == "human" ? .human : .agent,
            secondKind: secondKind == "human" ? .human : .agent
        )
        for member in [first, second] {
            accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: member, kind: "dm", name: "dm")
        }
        return id
    }
    let ownerDM = dm(ownerId, agentId, firstKind: "human", secondKind: "agent")
    let peerHumanDM = dm(peerHumanId, agentId, firstKind: "human", secondKind: "agent")
    let twinHumanDM = dm(twinHumanId, agentId, firstKind: "human", secondKind: "agent")
    let twinAgentDM = dm(twinAgentId, agentId, firstKind: "agent", secondKind: "agent")
    let peerAgentDM = dm(peerAgentId, agentId, firstKind: "agent", secondKind: "agent")
    accounts.insertHumanMessage(
        id: UUID().uuidString.lowercased(), channelId: peerHumanDM,
        senderId: peerHumanId, content: "peer human history"
    )
    accounts.insertHumanMessage(
        id: UUID().uuidString.lowercased(), channelId: twinHumanDM,
        senderId: twinHumanId, content: "twin human history"
    )

    let remindersId = accounts.oauth.createChannel(
        serverId: serverId, name: "reminders", creatorUserId: agentId, type: "dm"
    )
    accounts.oauth.addChannelAgent(channelId: remindersId, agentId: agentId)
    accounts.addPostableChannel(
        serverId: serverId, channelId: remindersId, memberId: agentId, kind: "dm", name: "reminders"
    )
    accounts.setAgentReminderSurfaceForTesting(agentId: agentId, channelId: remindersId)

    return ReviewDMWorld(
        accounts: accounts, serverId: serverId, ownerId: ownerId, agentId: agentId, key: key,
        roomName: roomName, roomId: roomId, ownerDM: ownerDM,
        peerHumanId: peerHumanId, peerHumanName: "remindersX\(suffix)", peerHumanDM: peerHumanDM,
        twinHumanId: twinHumanId, twinAgentId: twinAgentId, twinHumanDM: twinHumanDM, twinAgentDM: twinAgentDM,
        peerAgentId: peerAgentId, peerAgentName: "PeerAgent\(suffix)", peerAgentDM: peerAgentDM,
        remindersId: remindersId
    )
}

private func reviewSend(
    _ client: any Client, key: String, target: String, content: String = "review send"
) async throws -> ClientResponse {
    let payload = "{\"target\":\(reviewJSONString(target)),\"content\":\(reviewJSONString(content)),"
        + "\"idempotencyKey\":\"\(UUID().uuidString.lowercased())\"}"
    return try await reviewPost(client, key: key, "/internal/agent-api/v2/send", payload)
}

@Test func sendTargetKeepsThePublishedChannelRefGrammar() async throws {
    let f = makeReviewDMWorld("01")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            // A longer ordinary handle that starts with the reserved word is
            // still a real peer, not the private reminder surface.
            let ordinary = try await reviewSend(client, key: f.key, target: "dm:@\(f.peerHumanName)")
            #expect(ordinary.status == .ok, Comment(rawValue: ordinary.body.string ?? ""))

            let missing = try await reviewSend(client, key: f.key, target: "dm:@remindersY01")
            #expect(missing.status == .notFound)
            #expect(reviewObject(missing)["error"] as? String == "User or agent not found: @remindersY01")

            // `dm:@reminders~bot` is the caller-fixable invalid kind 400.
            let badKind = try await reviewSend(client, key: f.key, target: "dm:@reminders~bot")
            #expect(badKind.status == .badRequest)
            let badKindBody = reviewObject(badKind)
            #expect(badKindBody["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")
            let expectedBadKind = "dm:@reminders~bot has an unknown peer kind \"bot\". "
                + "Use dm:@<name>, dm:@<name>~agent or dm:@<name>~human."
            #expect(badKindBody["error"] as? String == expectedBadKind)
            #expect(badKindBody["suggestedNextAction"] as? String
                == "retry with dm:@<name>, dm:@<name>~agent or dm:@<name>~human")

            // Only the exact reserved handle (optionally with ~agent/~human,
            // any case) is the read-only reminder surface.
            for target in ["dm:@reminders", "dm:@Reminders", "dm:@reminders~agent", "dm:@reminders:12345678"] {
                let reserved = try await reviewSend(client, key: f.key, target: target)
                #expect(reserved.status == .forbidden, Comment(rawValue: target))
                let body = reviewObject(reserved)
                #expect(body["code"] as? String == "DM_TARGET_NOT_SENDABLE", Comment(rawValue: target))
                #expect(body["suggestedNextAction"] as? String
                    == "send to the reminder's anchor target instead of dm:@reminders")
            }

            // A colon suffix is a thread marker only for exactly eight hex
            // characters. `Twin01:zzzz` stays one unknown peer name.
            let notAThread = try await reviewSend(client, key: f.key, target: "dm:@Twin01:zzzz")
            #expect(notAThread.status == .notFound)
            #expect(f.accounts.oauth.historyMessages(channelId: f.twinHumanDM).count == 1)
            #expect(f.accounts.oauth.historyMessages(channelId: f.twinAgentDM).isEmpty)

            // The uppercase prefix names the same peer.
            let uppercase = try await reviewSend(client, key: f.key, target: "DM:@\(f.peerAgentName)")
            #expect(uppercase.status == .ok, Comment(rawValue: uppercase.body.string ?? ""))

            // A non-eight-hex `#room:1` is a channel name, not a thread.
            let channelNotThread = try await reviewSend(client, key: f.key, target: "#\(f.roomName):1")
            #expect(channelNotThread.status == .notFound)
        }
    }
}

@Test func dmTargetResolutionErrorsUseThePinnedProjection() async throws {
    let f = makeReviewDMWorld("02")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let ambiguous = try await reviewSend(client, key: f.key, target: "dm:@Twin02")
            #expect(ambiguous.status == .conflict)
            let ambiguousBody = reviewObject(ambiguous)
            let peer = "Twin02"
            let agentRef = "dm:@\(peer)~agent"
            let humanRef = "dm:@\(peer)~human"
            let ambiguousError = "dm:@\(peer) matches both a human and an agent named \(peer). "
                + "Name the one you mean: \(agentRef) for the agent, or \(humanRef) for the human "
                + "(for example: raft message read --target \"\(agentRef)\")."
            #expect(ambiguousBody["error"] as? String == ambiguousError)
            #expect(ambiguousBody["code"] as? String == "DM_TARGET_AMBIGUOUS")
            #expect(ambiguousBody["suggestedNextAction"] as? String
                == "retry with \(agentRef) for the agent or \(humanRef) for the human")
            #expect(ambiguous.body.string == "{\"error\":\(reviewJSONString(ambiguousError)),"
                + "\"code\":\"DM_TARGET_AMBIGUOUS\","
                + "\"suggestedNextAction\":\(reviewJSONString("retry with \(agentRef) for the agent or \(humanRef) for the human"))}")

            // The task family publishes the same helper bytes and order.
            let claim = try await reviewPost(
                client, key: f.key, "/internal/agent-api/tasks/claim",
                "{\"channel\":\"dm:@Twin02\",\"task_numbers\":[1]}"
            )
            #expect(claim.status == .conflict)
            #expect(claim.body.string == ambiguous.body.string)
        }
    }
}

private struct ReviewAssigneeWorld {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelName: String
    let channelId: String
    let key: String
    let aliceId: String
    let bobId: String
    let carolId: String
    let twinHumanId: String
    let twinAgentId: String
}

private func makeReviewAssigneeWorld(_ suffix: String) -> ReviewAssigneeWorld {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001320\(suffix)"
    let ownerId = "11111111-1111-4111-8111-000001320\(suffix)"
    let aliceId = "11111111-1111-4111-8111-000001321\(suffix)"
    let bobId = "11111111-1111-4111-8111-000001322\(suffix)"
    let twinHumanId = "11111111-1111-4111-8111-000001323\(suffix)"
    accounts.addAccount(id: ownerId, email: "assign-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    for (id, email, name, display) in [
        (aliceId, "assign-alice-\(suffix)@slock.test", "alice\(suffix)", "bob\(suffix)"),
        (bobId, "assign-bob-\(suffix)@slock.test", "bob\(suffix)", "Bobby"),
        (twinHumanId, "assign-twin-\(suffix)@slock.test", "Twin\(suffix)", "Human Twin"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        accounts.setAccountProfileForTesting(id: id, name: name, displayName: display)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "review-assign-\(suffix)", name: "Review Assign", ownerId: ownerId)
    for id in [aliceId, bobId, twinHumanId] {
        accounts.oauth.addMember(serverId: serverId, userId: id, role: "member")
    }
    let channelName = "review-assign-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    for id in [aliceId, bobId, twinHumanId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: channelName)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let actor = accounts.oauth.createAgent(serverId: serverId, name: "AssignActor\(suffix)", runtime: "codex")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: actor, name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: actor)
    // carol's canonical handle is not alice; her displayName is.
    let carolId = accounts.oauth.createAgent(
        serverId: serverId, name: "carol\(suffix)", displayName: "alice\(suffix)", runtime: "claude"
    )
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: carolId, name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: carolId)
    let twinAgentId = accounts.oauth.createAgent(serverId: serverId, name: "Twin\(suffix)", runtime: "claude")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: twinAgentId, name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: twinAgentId)
    for index in 0..<2 {
        let duplicate = accounts.oauth.createAgent(serverId: serverId, name: "Dup\(suffix)", runtime: "claude")
        _ = index
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: duplicate, name: channelName)
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: duplicate)
    }
    let key = accounts.mintAgentCredential(agentId: actor, scopes: ["read", "send", "tasks"], name: "assign-\(suffix)")
    return ReviewAssigneeWorld(
        accounts: accounts, serverId: serverId, channelName: channelName, channelId: channelId, key: key,
        aliceId: aliceId, bobId: bobId, carolId: carolId,
        twinHumanId: twinHumanId, twinAgentId: twinAgentId
    )
}

@Test func taskAssigneeUsesTheCanonicalExactHandleOnly() async throws {
    let f = makeReviewAssigneeWorld("01")
    let taskId = f.accounts.addTaskForClaimTesting(channelId: f.channelId, title: "assign target", status: "todo")
    func assignee() -> String? {
        f.accounts.taskClaimFactsForTesting(taskId: taskId)?.assigneeId
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            func assign(_ handle: String) async throws -> ClientResponse {
                try await reviewPost(client, key: f.key, "/internal/agent-api/tasks/assign",
                    "{\"channel\":\"#\(f.channelName)\",\"task_number\":1,\"assignee\":\(reviewJSONString("@\(handle)"))}")
            }

            let alice = try await assign("alice01")
            #expect(alice.status == .ok, Comment(rawValue: alice.body.string ?? ""))
            #expect(reviewObject(alice)["claimedById"] as? String == f.aliceId)
            #expect(assignee() == f.aliceId)

            // A case variant is not the canonical handle.
            let caseVariant = try await assign("Alice01")
            #expect(caseVariant.status == .notFound)
            #expect(reviewObject(caseVariant)["code"] as? String == "assignee_not_assignable")
            #expect(assignee() == f.aliceId)

            // bob's handle beats alice's displayName, which is also "bob01".
            let bob = try await assign("bob01")
            #expect(bob.status == .ok)
            #expect(reviewObject(bob)["claimedById"] as? String == f.bobId)
            #expect(assignee() == f.bobId)

            let displayName = try await assign("Bobby")
            #expect(displayName.status == .notFound)
            #expect(assignee() == f.bobId)

            // carol's displayName is alice's handle: the human must win.
            _ = try await reviewPost(client, key: f.key, "/internal/agent-api/tasks/assign",
                "{\"channel\":\"#\(f.channelName)\",\"task_number\":1,\"assignee\":null}")
            let aliceAgain = try await assign("alice01")
            #expect(aliceAgain.status == .ok)
            #expect(reviewObject(aliceAgain)["claimedById"] as? String == f.aliceId)
            #expect(assignee() == f.aliceId)
            #expect(f.carolId != f.aliceId)

            // A cross-kind twin is ambiguous for assignment: fail closed.
            let twin = try await assign("Twin01")
            #expect(twin.status == .notFound)
            #expect(reviewObject(twin)["code"] as? String == "assignee_not_assignable")
            #expect(assignee() == f.aliceId)

            // The pinned assign resolver has no `~kind` syntax.
            let typed = try await assign("Twin01~agent")
            #expect(typed.status == .notFound)
            #expect(assignee() == f.aliceId)

            // Two agents with the same canonical handle are not one candidate.
            let duplicates = try await assign("Dup01")
            #expect(duplicates.status == .notFound)
            #expect(reviewObject(duplicates)["code"] as? String == "assignee_not_assignable")
            #expect(assignee() == f.aliceId)

            // Create uses the same canonical resolver and receipt name.
            let created = try await reviewPost(client, key: f.key, "/internal/agent-api/tasks",
                "{\"channel\":\"#\(f.channelName)\",\"tasks\":[{\"title\":\"canonical assignee\"}],"
                + "\"assignee\":\"@alice01\"}")
            #expect(created.status == .ok, Comment(rawValue: created.body.string ?? ""))
            let createdBody = reviewObject(created)
            #expect((createdBody["assignmentReceipt"] as? [String: Any])?["assignee"] as? String == "@alice01")
            let createdTask = (createdBody["tasks"] as? [[String: Any]])?.first
            #expect(createdTask?["claimedById"] as? String == f.aliceId)

            let caseCreated = try await reviewPost(client, key: f.key, "/internal/agent-api/tasks",
                "{\"channel\":\"#\(f.channelName)\",\"tasks\":[{\"title\":\"wrong case\"}],"
                + "\"assignee\":\"@Alice01\"}")
            #expect(caseCreated.status == .notFound)
        }
    }
}

private struct ReviewAssistantWorld {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let assistantId: String
    let key: String
    let roomId: String
    let roomName: String
    let ownerDM: String
    let foreignDM: String
    let peerDM: String
    let allId: String
}

private func makeReviewAssistantWorld(_ suffix: String) -> ReviewAssistantWorld {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001330\(suffix)"
    let ownerId = "11111111-1111-4111-8111-000001330\(suffix)"
    let foreignId = "11111111-1111-4111-8111-000001331\(suffix)"
    accounts.addAccount(id: ownerId, email: "review-assistant-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: foreignId, email: "review-assistant-foreign-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: foreignId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "assistant-owner-\(suffix)")
    accounts.setAccountProfileForTesting(id: foreignId, name: "assistant-foreign-\(suffix)")
    accounts.oauth.addOwnedServer(id: serverId, slug: "review-assistant-\(suffix)", name: "Review Assistant", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: foreignId, role: "member")
    // identity_borrowing stays off: posting must still use the raw link.
    let assistant = accounts.oauth.createAgent(serverId: serverId, name: "ReviewAssistant\(suffix)", runtime: "codex")
    accounts.linkAssistantOwnerForTesting(agentId: assistant, userId: ownerId)
    let peer = accounts.oauth.createAgent(serverId: serverId, name: "ReviewAssistantPeer\(suffix)", runtime: "codex")
    let key = accounts.mintAgentCredential(agentId: assistant, scopes: ["read", "send", "tasks"], name: "review-assistant-\(suffix)")

    let roomName = "review-assistant-room-\(suffix)"
    let roomId = accounts.oauth.createChannel(serverId: serverId, name: roomName, creatorUserId: ownerId)
    for member in [ownerId, assistant] {
        accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: member, name: roomName)
    }
    accounts.oauth.addChannelHuman(channelId: roomId, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: roomId, agentId: assistant)

    func dm(_ first: String, _ second: String, firstKind: String, secondKind: String) -> String {
        let id = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: first, secondUserId: second,
            firstKind: firstKind == "human" ? .human : .agent,
            secondKind: secondKind == "human" ? .human : .agent
        )
        for member in [first, second] {
            accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: member, kind: "dm", name: "dm")
        }
        return id
    }
    let ownerDM = dm(ownerId, assistant, firstKind: "human", secondKind: "agent")
    let foreignDM = dm(foreignId, assistant, firstKind: "human", secondKind: "agent")
    let peerDM = dm(peer, assistant, firstKind: "agent", secondKind: "agent")
    let allId = accounts.oauth.allChannelId(serverId: serverId) ?? ""
    if !allId.isEmpty {
        accounts.addPostableChannel(serverId: serverId, channelId: allId, memberId: ownerId, name: "all")
        accounts.oauth.addChannelHuman(channelId: allId, userId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: allId, memberId: assistant, name: "all")
        accounts.oauth.addChannelAgent(channelId: allId, agentId: assistant)
        _ = accounts.oauth.setChannelType(id: allId, type: "channel")
    }
    return ReviewAssistantWorld(
        accounts: accounts, serverId: serverId, ownerId: ownerId, assistantId: assistant, key: key,
        roomId: roomId, roomName: roomName, ownerDM: ownerDM, foreignDM: foreignDM, peerDM: peerDM, allId: allId
    )
}

@Test func assistantPostingUsesTheRetainedOwnerWithoutTheBorrowingFlag() async throws {
    let f = makeReviewAssistantWorld("01")
    #expect(!f.allId.isEmpty)
    f.accounts.addTaskForClaimTesting(channelId: f.ownerDM, title: "owner task", status: "todo")
    f.accounts.addTaskForClaimTesting(channelId: f.roomId, title: "room task", status: "todo")
    f.accounts.addTaskForClaimTesting(channelId: f.allId, title: "all task", status: "todo")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            func send(_ target: String) async throws -> ClientResponse {
                try await reviewSend(client, key: f.key, target: target)
            }
            func claim(_ channel: String) async throws -> ClientResponse {
                try await reviewPost(client, key: f.key, "/internal/agent-api/tasks/claim",
                    "{\"channel\":\(reviewJSONString(channel)),\"task_numbers\":[1]}")
            }

            // Flag off, owner still a member: the raw link still confines the
            // assistant to the owner's DM. Before the raw-owner fix these were
            // ordinary-member sends/claims and succeeded.
            #expect(try await send("#\(f.roomName)").status == .forbidden)
            #expect(try await send("dm:@assistant-foreign-01").status == .forbidden)
            #expect(try await send("dm:@ReviewAssistantPeer01").status == .forbidden)
            #expect(try await send("#all").status == .forbidden)
            #expect(try await claim(f.roomId).status == .forbidden)
            #expect(try await claim(f.allId).status == .forbidden)

            let ownerSend = try await send("dm:@assistant-owner-01")
            #expect(ownerSend.status == .ok, Comment(rawValue: ownerSend.body.string ?? ""))
            let typedOwner = try await send("dm:@assistant-owner-01~human")
            #expect(typedOwner.status == .ok)
            #expect(try await claim(f.ownerDM).status == .ok)

            // The owner leaving the server does not retire the retained link
            // or the DM's own participant rows.
            f.accounts.oauth.removeMember(serverId: f.serverId, userId: f.ownerId)
            #expect(try await send("dm:@assistant-owner-01").status == .forbidden)
            #expect(try await claim(f.ownerDM).status == .ok)
            #expect(try await claim(f.roomId).status == .forbidden)

            // Without the owner's channel_humans row the DM is no longer the
            // owner DM, so the assistant cannot post there either.
            f.accounts.oauth.removeChannelHuman(channelId: f.ownerDM, userId: f.ownerId)
            #expect(try await claim(f.ownerDM).status == .forbidden)
        }
    }
}

/// The Task-owned inbox projection follows the pinned `agentFacingDmRef`:
/// qualify the kind only when a cross-kind twin makes the bare name unstable,
/// and keep the bare/reminders/receipt spellings stable otherwise.
@Test func taskInboxTargetsQualifyOnlyCrossKindTwins() async throws {
    let f = makeReviewDMWorld("03")
    f.accounts.insertHumanMessage(
        id: UUID().uuidString.lowercased(), channelId: f.peerAgentDM,
        senderId: f.peerAgentId, content: "peer agent history"
    )
    f.accounts.insertHumanMessage(
        id: UUID().uuidString.lowercased(), channelId: f.twinAgentDM,
        senderId: f.twinAgentId, content: "twin agent history"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.key)"
            let response = try await client.get(
                URI(string: "/internal/agent-api/inbox/conversations?limit=100"), headers: headers
            )
            #expect(response.status == .ok)
            let body = reviewObject(response)
            let items = (body["items"] as? [[String: Any]]) ?? []
            let targets = Set(items.compactMap { $0["target"] as? String })
            #expect(targets.contains("dm:@Twin03~human"))
            #expect(targets.contains("dm:@Twin03~agent"))
            #expect(targets.contains("dm:@PeerAgent03"))
            #expect(targets.contains("dm:@remindersX03"))
            #expect(!targets.contains("dm:@remindersX03~human"))
        }
    }
}
