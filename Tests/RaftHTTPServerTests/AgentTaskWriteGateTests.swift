import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Synchronization
import Testing
import TestSupport
import Vapor
import VaporTesting

/// One task family fixture: a writable room, a public channel the agent has not
/// joined, an archived channel the agent has joined, and a thread under the
/// room. The same agent credential drives every published task write.
private struct TaskGateFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let key: String
    let roomId: String
    let roomRef: String
    let outsideId: String
    let outsideRef: String
    let archivedId: String
    let archivedRef: String
    let threadId: String
    let threadRef: String
    let parentMessageId: String
}

private func makeTaskGateFixture(_ suffix: String) -> TaskGateFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-0000010265\(suffix)"
    let ownerId = "11111111-1111-4111-8111-0000010265\(suffix)"
    accounts.addAccount(id: ownerId, email: "task-gate-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "gate-owner-\(suffix)")
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-gate-\(suffix)", name: "Task Gate", ownerId: ownerId)

    let roomName = "gate-room-\(suffix)"
    let roomId = accounts.oauth.createChannel(serverId: serverId, name: roomName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: ownerId, name: roomName)
    accounts.oauth.addChannelHuman(channelId: roomId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "GateBot\(suffix)", runtime: "codex")
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: agentId, name: roomName)
    accounts.oauth.addChannelAgent(channelId: roomId, agentId: agentId)

    let outsideName = "gate-outside-\(suffix)"
    let outsideId = accounts.oauth.createChannel(serverId: serverId, name: outsideName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: outsideId, memberId: ownerId, name: outsideName)
    accounts.oauth.addChannelHuman(channelId: outsideId, userId: ownerId)

    let archivedName = "gate-archived-\(suffix)"
    let archivedId = accounts.oauth.createChannel(serverId: serverId, name: archivedName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: archivedId, memberId: ownerId, name: archivedName)
    accounts.addPostableChannel(serverId: serverId, channelId: archivedId, memberId: agentId, name: archivedName)
    accounts.oauth.addChannelHuman(channelId: archivedId, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: archivedId, agentId: agentId)
    accounts.oauth.setChannelArchived(id: archivedId, archivedAt: Date())

    let parentMessageId = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: parentMessageId, channelId: roomId, senderId: ownerId, content: "thread parent")
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: roomId, parentMessageId: parentMessageId)
    accounts.addPostableChannel(
        serverId: serverId, channelId: threadId, memberId: agentId, kind: "thread",
        parentChannelId: roomId, parentMessageId: parentMessageId, name: "thread"
    )
    accounts.oauth.addChannelAgent(channelId: threadId, agentId: agentId)
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "tasks"], name: "gate-\(suffix)")
    return TaskGateFixture(
        accounts: accounts, serverId: serverId, ownerId: ownerId, agentId: agentId, key: key,
        roomId: roomId, roomRef: "#\(roomName)", outsideId: outsideId, outsideRef: "#\(outsideName)",
        archivedId: archivedId, archivedRef: "#\(archivedName)",
        threadId: threadId, threadRef: "#\(roomName):\(String(parentMessageId.prefix(8)))",
        parentMessageId: parentMessageId
    )
}

private func taskGateHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func taskGatePost(_ client: any Client, key: String, _ path: String, _ body: String) async throws -> ClientResponse {
    try await client.send(.post, headers: taskGateHeaders(key), to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func taskGateObject(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func taskGateClaimResult(_ response: ClientResponse) -> [String: Any] {
    (taskGateObject(response)["results"] as? [[String: Any]] ?? []).first ?? [:]
}

private let taskGateReceipt = """
{"object":"gate object","purpose":"gate purpose","teardown_owner":"@GateBot","security_privacy":"internal",\
"expiry":"2099-09-01T00:00:00.000Z","runbook":"runbooks/gate.md","tracking":"gate"}
"""

/// Every published task write goes through the same upstream boundary before
/// any freshness gate, task lookup or mutation: a thread target that the route
/// cannot address, a non-postable channel, then an archived channel. Reads
/// (list/history) never take this boundary.
@Test func taskWriteFamilyRefusesUnwritableTargetsBeforeMutation() async throws {
    let f = makeTaskGateFixture("301")
    let outsideTask = f.accounts.addTaskForClaimTesting(
        channelId: f.outsideId, title: "outside task", status: "todo", creatorId: f.ownerId
    )
    let archivedTask = f.accounts.addTaskForClaimTesting(
        channelId: f.archivedId, title: "archived task", status: "todo", creatorId: f.ownerId
    )
    let outsideMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: outsideMessage, channelId: f.outsideId, senderId: f.ownerId, content: "outside")
    let archivedMessage = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: archivedMessage, channelId: f.archivedId, senderId: f.ownerId, content: "archived")
    let before = [
        f.roomId: f.accounts.taskSnapshotsForTesting(channelId: f.roomId),
        f.outsideId: f.accounts.taskSnapshotsForTesting(channelId: f.outsideId),
        f.archivedId: f.accounts.taskSnapshotsForTesting(channelId: f.archivedId),
        f.threadId: f.accounts.taskSnapshotsForTesting(channelId: f.threadId),
    ]

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let frames = Mutex<[(room: String, event: String, payload: String?)]>([])
            f.accounts.realtimeRelay.install { room, event, payload in
                frames.withLock { $0.append((room, event, payload)) }
            }
            defer { f.accounts.realtimeRelay.install(nil) }

            func expect(_ path: String, _ body: String, _ status: HTTPResponse.Status,
                        error: String? = nil, code: String? = nil) async throws {
                let response = try await taskGatePost(client, key: f.key, path, body)
                #expect(response.status == status, Comment(rawValue: "\(path) -> \(response.body.string ?? "")"))
                let object = taskGateObject(response)
                if let error { #expect(object["error"] as? String == error) }
                if let code { #expect(object["code"] as? String == code) }
            }

            // Create: thread 409 with its own wording, then 403/409.
            try await expect("/internal/agent-api/tasks",
                "{\"channel\":\"\(f.threadRef)\",\"tasks\":[{\"title\":\"thread create\"}]}",
                .conflict, error: "Thread messages cannot become tasks")
            try await expect("/internal/agent-api/tasks",
                "{\"channel\":\"\(f.outsideRef)\",\"tasks\":[{\"title\":\"outside create\"}]}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks",
                "{\"channel\":\"\(f.archivedRef)\",\"tasks\":[{\"title\":\"archived create\"}]}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Claim: thread refusal is pinned by wording; outside/archived too.
            try await expect("/internal/agent-api/tasks/claim",
                "{\"channel\":\"\(f.threadRef)\",\"task_numbers\":[1]}",
                .conflict, error: "Thread messages cannot be claimed as tasks")
            try await expect("/internal/agent-api/tasks/claim",
                "{\"channel\":\"\(f.outsideRef)\",\"task_numbers\":[1]}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/claim",
                "{\"channel\":\"\(f.archivedRef)\",\"task_numbers\":[1]}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Assign.
            try await expect("/internal/agent-api/tasks/assign",
                "{\"channel\":\"\(f.outsideRef)\",\"task_number\":1,\"assignee\":\"@GateBot301\"}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/assign",
                "{\"channel\":\"\(f.archivedRef)\",\"task_number\":1,\"assignee\":\"@GateBot301\"}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Update status.
            try await expect("/internal/agent-api/tasks/update-status",
                "{\"channel\":\"\(f.outsideRef)\",\"task_number\":1,\"status\":\"in_progress\"}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/update-status",
                "{\"channel\":\"\(f.archivedRef)\",\"task_number\":1,\"status\":\"in_progress\"}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Amend.
            try await expect("/internal/agent-api/tasks/amend",
                "{\"channel\":\"\(f.outsideRef)\",\"task_number\":1,\"title\":\"outside rename\"}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/amend",
                "{\"channel\":\"\(f.archivedRef)\",\"task_number\":1,\"title\":\"archived rename\"}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Unclaim.
            try await expect("/internal/agent-api/tasks/unclaim",
                "{\"channel\":\"\(f.outsideRef)\",\"task_number\":1}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/unclaim",
                "{\"channel\":\"\(f.archivedRef)\",\"task_number\":1}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Resource receipt.
            try await expect("/internal/agent-api/tasks/resource-receipt",
                "{\"channel\":\"\(f.outsideRef)\",\"task_number\":1,\"receipt\":\(taskGateReceipt)}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/resource-receipt",
                "{\"channel\":\"\(f.archivedRef)\",\"task_number\":1,\"receipt\":\(taskGateReceipt)}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Delete.
            try await expect("/internal/agent-api/tasks/delete",
                "{\"channel\":\"\(f.outsideRef)\",\"task_number\":1}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/delete",
                "{\"channel\":\"\(f.archivedRef)\",\"task_number\":1}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Convert.
            try await expect("/internal/agent-api/tasks/convert",
                "{\"channel\":\"\(f.outsideRef)\",\"message_id\":\"\(String(outsideMessage.prefix(8)))\"}",
                .forbidden, error: "Agent must join this channel to modify tasks")
            try await expect("/internal/agent-api/tasks/convert",
                "{\"channel\":\"\(f.archivedRef)\",\"message_id\":\"\(String(archivedMessage.prefix(8)))\"}",
                .conflict, error: "This channel is archived", code: "channel_archived")

            // Every refusal wrote nothing and published nothing.
            let after = [
                f.roomId: f.accounts.taskSnapshotsForTesting(channelId: f.roomId),
                f.outsideId: f.accounts.taskSnapshotsForTesting(channelId: f.outsideId),
                f.archivedId: f.accounts.taskSnapshotsForTesting(channelId: f.archivedId),
                f.threadId: f.accounts.taskSnapshotsForTesting(channelId: f.threadId),
            ]
            #expect(after[f.outsideId]!.map(\.taskNumber) == before[f.outsideId]!.map(\.taskNumber))
            #expect(after[f.archivedId]!.map(\.status) == before[f.archivedId]!.map(\.status))
            #expect(after[f.roomId]!.map(\.status) == before[f.roomId]!.map(\.status))
            #expect(f.accounts.taskClaimFactsForTesting(taskId: outsideTask)?.assigneeId == nil)
            #expect(f.accounts.taskClaimFactsForTesting(taskId: archivedTask)?.assigneeId == nil)
            #expect(f.accounts.messageTaskShadowForTesting(messageId: outsideMessage) == nil)
            #expect(f.accounts.messageTaskShadowForTesting(messageId: archivedMessage) == nil)
            let published = frames.withLock { $0 }
            #expect(!published.contains { ["task:created", "task:updated", "message:updated"].contains($0.event) },
                    Comment(rawValue: "\(published.map(\.event))"))

            // The authorized room and a normal owner DM are unchanged.
            let created = try await taskGatePost(
                client, key: f.key, "/internal/agent-api/tasks",
                "{\"channel\":\"\(f.roomRef)\",\"tasks\":[{\"title\":\"authorized room task\"}]}"
            )
            #expect(created.status == .ok, Comment(rawValue: created.body.string ?? ""))
            let dm = f.accounts.oauth.createDirectChannel(
                serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.agentId,
                firstKind: .human, secondKind: .agent
            )
            for member in [f.ownerId, f.agentId] {
                f.accounts.addPostableChannel(serverId: f.serverId, channelId: dm, memberId: member, kind: "dm", name: "dm")
            }
            f.accounts.oauth.addChannelHuman(channelId: dm, userId: f.ownerId)
            f.accounts.oauth.addChannelAgent(channelId: dm, agentId: f.agentId)
            let host = UUID().uuidString.lowercased()
            f.accounts.insertHumanMessage(id: host, channelId: dm, senderId: f.ownerId, content: "plain dm host")
            let claimed = try await taskGatePost(
                client, key: f.key, "/internal/agent-api/tasks/claim",
                "{\"channel\":\"dm:@gate-owner-301\",\"message_ids\":[\"\(String(host.prefix(8)))\"]}"
            )
            #expect(claimed.status == .ok, Comment(rawValue: claimed.body.string ?? ""))
            let result = taskGateClaimResult(claimed)
            #expect(result["success"] as? Bool == true)
            #expect(result["messageId"] as? String == host)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: dm).first?.title == "plain dm host")
        }
    }
}

/// RFC 074 / upstream `assistantMayPostTo`: an assistant's task writes are
/// confined to its owner's DM, including after the enabled #all shortcut and
/// regardless of ordinary membership anywhere else.
@Test func assistantTaskWritesAreConfinedToTheOwnerDM() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-0000010265302"
    let ownerId = "11111111-1111-4111-8111-0000010265302"
    accounts.addAccount(id: ownerId, email: "assistant-gate-302@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "assistant-gate-owner")
    accounts.oauth.addOwnedServer(id: serverId, slug: "assistant-gate-302", name: "Assistant Gate", ownerId: ownerId)
    accounts.createFeatureFlagForTesting(key: "identity_borrowing", defaultEnabled: true)
    let assistant = accounts.oauth.createAgent(serverId: serverId, name: "AssistantGate", runtime: "codex")
    accounts.linkAssistantOwnerForTesting(agentId: assistant, userId: ownerId)
    let peer = accounts.oauth.createAgent(serverId: serverId, name: "AssistantPeer", runtime: "codex")
    let key = accounts.mintAgentCredential(agentId: assistant, scopes: ["read", "send", "tasks"], name: "assistant-gate")

    let roomName = "assistant-room-302"
    let roomId = accounts.oauth.createChannel(serverId: serverId, name: roomName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: ownerId, name: roomName)
    accounts.oauth.addChannelHuman(channelId: roomId, userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: assistant, name: roomName)
    accounts.oauth.addChannelAgent(channelId: roomId, agentId: assistant)
    accounts.addTaskForClaimTesting(channelId: roomId, title: "room task", status: "todo")

    let allChannel = try #require(accounts.oauth.allChannelId(serverId: serverId))
    accounts.addPostableChannel(serverId: serverId, channelId: allChannel, memberId: ownerId, name: "all")
    accounts.oauth.addChannelHuman(channelId: allChannel, userId: ownerId)
    _ = accounts.oauth.setChannelType(id: allChannel, type: "channel")
    accounts.addTaskForClaimTesting(channelId: allChannel, title: "all task", status: "todo")

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
    let ownerDm = dm(ownerId, assistant, firstKind: "human", secondKind: "agent")
    accounts.oauth.addChannelHuman(channelId: ownerDm, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: ownerDm, agentId: assistant)
    accounts.addTaskForClaimTesting(channelId: ownerDm, title: "owner dm task", status: "todo")

    let peerDm = dm(peer, assistant, firstKind: "agent", secondKind: "agent")
    accounts.oauth.addChannelAgent(channelId: peerDm, agentId: peer)
    accounts.oauth.addChannelAgent(channelId: peerDm, agentId: assistant)
    accounts.addTaskForClaimTesting(channelId: peerDm, title: "peer dm task", status: "todo")

    let reminders = accounts.oauth.createChannel(serverId: serverId, name: "reminders", creatorUserId: assistant, type: "dm")
    accounts.oauth.addChannelAgent(channelId: reminders, agentId: assistant)
    accounts.addPostableChannel(serverId: serverId, channelId: reminders, memberId: assistant, kind: "dm", name: "reminders")
    accounts.setAgentReminderSurfaceForTesting(agentId: assistant, channelId: reminders)
    accounts.addTaskForClaimTesting(channelId: reminders, title: "reminder task", status: "todo")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func claim(_ target: String, _ number: Int = 1) async throws -> ClientResponse {
                try await taskGatePost(
                    client, key: key, "/internal/agent-api/tasks/claim",
                    "{\"channel\":\"\(target)\",\"task_numbers\":[\(number)]}"
                )
            }
            for target in ["#\(roomName)", "#all", "dm:@AssistantPeer", "dm:@reminders"] {
                let refused = try await claim(target)
                #expect(refused.status == .forbidden, Comment(rawValue: "\(target) -> \(refused.body.string ?? "")"))
                #expect(taskGateObject(refused)["error"] as? String == "Agent must join this channel to modify tasks")
            }
            let allowed = try await claim("dm:@assistant-gate-owner")
            #expect(allowed.status == .ok, Comment(rawValue: allowed.body.string ?? ""))
            #expect(taskGateClaimResult(allowed)["success"] as? Bool == true)

            // A non-assistant agent with the same memberships keeps the
            // ordinary room claim; the restriction is the ownership link only.
            let ordinary = accounts.mintAgentCredential(agentId: peer, scopes: ["read", "send", "tasks"], name: "ordinary")
            accounts.oauth.addChannelAgent(channelId: roomId, agentId: peer)
            accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: peer, name: roomName)
            let ordinaryClaim = try await taskGatePost(
                client, key: ordinary, "/internal/agent-api/tasks/claim",
                "{\"channel\":\"#\(roomName)\",\"task_numbers\":[1]}"
            )
            #expect(ordinaryClaim.status == .ok, Comment(rawValue: ordinaryClaim.body.string ?? ""))
            #expect(taskGateClaimResult(ordinaryClaim)["success"] as? Bool == true)
        }
    }
}

/// The claim rejection carries the writer's own observation: a foreign
/// assignee is the pinned prose plus `claim_conflict`; self/closed/done
/// rejections stay prose-only. Repeating any rejection adds no task event.
@Test func taskClaimRejectionsPublishStructuredConflictOnce() async throws {
    let f = makeTaskGateFixture("303")
    let rival = f.accounts.oauth.createAgent(serverId: f.serverId, name: "RivalBot303", runtime: "codex")
    f.accounts.oauth.addChannelAgent(channelId: f.roomId, agentId: rival)
    let claimedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let foreign = f.accounts.addTaskForClaimTesting(
        channelId: f.roomId, title: "foreign claim", messageId: UUID().uuidString.lowercased(),
        status: "in_progress", assigneeType: "agent", assigneeId: rival, claimedAt: claimedAt
    )
    let closed = f.accounts.addTaskForClaimTesting(
        channelId: f.roomId, title: "closed claim", status: "closed"
    )
    let done = f.accounts.addTaskForClaimTesting(
        channelId: f.roomId, title: "done claim", status: "done"
    )
    let preassigned = f.accounts.addTaskForClaimTesting(
        channelId: f.roomId, title: "preassigned claim", status: "todo",
        assigneeType: "agent", assigneeId: f.agentId
    )
    let human = f.accounts.addTaskForClaimTesting(
        channelId: f.roomId, title: "human claim", status: "in_progress",
        assigneeType: "user", assigneeId: f.ownerId, claimedAt: claimedAt
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            func claimNumbers(_ numbers: [Int]) async throws -> ClientResponse {
                try await taskGatePost(
                    client, key: f.key, "/internal/agent-api/tasks/claim",
                    "{\"channel\":\"\(f.roomRef)\",\"task_numbers\":\(numbers)}"
                )
            }
            func claimMessage(_ messageId: String) async throws -> ClientResponse {
                try await taskGatePost(
                    client, key: f.key, "/internal/agent-api/tasks/claim",
                    "{\"channel\":\"\(f.roomRef)\",\"message_ids\":[\"\(String(messageId.prefix(8)))\"]}"
                )
            }
            let before = f.accounts.taskPublishedEventTypesForTesting(taskId: foreign)
            let rejected = try await claimNumbers([1])
            #expect(rejected.status == .ok)
            let result = taskGateClaimResult(rejected)
            #expect(result["taskNumber"] as? Int == 1)
            #expect(result["success"] as? Bool == false)
            #expect(result["reason"] as? String == "already assigned to @RivalBot303")
            let conflict = try #require(result["conflict"] as? [String: Any])
            #expect(conflict["kind"] as? String == "claim_conflict")
            #expect(conflict["conflictScope"] as? String == "implementation_execution")
            #expect(conflict["blockedActions"] as? [String] == ["start_conflicting_execution"])
            #expect(conflict["unblockedActionExamples"] as? [String] == ["read", "coordinate", "review", "request_reassign", "handoff"])
            let assignee = try #require(conflict["currentAssignee"] as? [String: Any])
            #expect(assignee["type"] as? String == "agent")
            #expect(assignee["name"] as? String == "RivalBot303")
            #expect(conflict["taskStatus"] as? String == "in_progress")
            #expect(conflict["claimedAt"] as? String == "2027-01-15T08:00:00.000Z")
            let observedAt = try #require(conflict["observedAt"] as? String)
            #expect(observedAt.hasSuffix("Z"))
            // The conflict object keeps the pinned key order and member text.
            let expected = "{\"results\":[{\"taskNumber\":1,\"success\":false,"
                + "\"reason\":\"already assigned to @RivalBot303\",\"conflict\":{"
                + "\"kind\":\"claim_conflict\",\"conflictScope\":\"implementation_execution\","
                + "\"blockedActions\":[\"start_conflicting_execution\"],"
                + "\"unblockedActionExamples\":[\"read\",\"coordinate\",\"review\",\"request_reassign\",\"handoff\"],"
                + "\"currentAssignee\":{\"type\":\"agent\",\"name\":\"RivalBot303\"},"
                + "\"taskStatus\":\"in_progress\",\"claimedAt\":\"2027-01-15T08:00:00.000Z\","
                + "\"observedAt\":\"\(observedAt)\"}}]}"
            #expect(rejected.body.string == expected)
            // A message-id claim names the resolved host and keeps the same
            // writer observation; neither form appends an event.
            let byMessage = try await claimMessage(f.accounts.taskSnapshotsForTesting(channelId: f.roomId)
                .first { $0.id == foreign }!.messageId)
            #expect(byMessage.status == .ok)
            let messageResult = taskGateClaimResult(byMessage)
            #expect(messageResult["messageId"] as? String == f.accounts.taskSnapshotsForTesting(channelId: f.roomId)
                .first { $0.id == foreign }!.messageId)
            #expect(messageResult["taskNumber"] as? Int == 1)
            #expect(messageResult["reason"] as? String == "already assigned to @RivalBot303")
            #expect((messageResult["conflict"] as? [String: Any])?["kind"] as? String == "claim_conflict")
            #expect(f.accounts.taskPublishedEventTypesForTesting(taskId: foreign) == before)

            // Human assignee keeps the "user" actor kind and canonical name.
            let humanResult = taskGateClaimResult(try await claimNumbers([5]))
            #expect(humanResult["reason"] as? String == "already assigned to @gate-owner-303")
            let humanConflict = try #require(humanResult["conflict"] as? [String: Any])
            #expect((humanConflict["currentAssignee"] as? [String: Any])?["type"] as? String == "user")
            #expect((humanConflict["currentAssignee"] as? [String: Any])?["name"] as? String == "gate-owner-303")

            // Closed and done are prose-only, with the pinned wording.
            let closedResult = taskGateClaimResult(try await claimNumbers([2]))
            #expect(closedResult["reason"] as? String == "task is closed; reopen it before claiming")
            #expect(closedResult["conflict"] == nil)
            let doneResult = taskGateClaimResult(try await claimNumbers([3]))
            #expect(doneResult["reason"] as? String == "task is done")
            #expect(doneResult["conflict"] == nil)
            #expect(f.accounts.taskPublishedEventTypesForTesting(taskId: closed).isEmpty)
            #expect(f.accounts.taskPublishedEventTypesForTesting(taskId: done).isEmpty)

            // A todo task preassigned to this agent may take its one first
            // claim; a repeat is prose-only "already claimed by you".
            let first = taskGateClaimResult(try await claimNumbers([4]))
            #expect(first["success"] as? Bool == true)
            #expect(f.accounts.taskClaimFactsForTesting(taskId: preassigned)?.status == "in_progress")
            let repeatClaim = taskGateClaimResult(try await claimNumbers([4]))
            #expect(repeatClaim["reason"] as? String == "already claimed by you")
            #expect(repeatClaim["conflict"] == nil)
            #expect(f.accounts.taskPublishedEventTypesForTesting(taskId: preassigned) == ["assignee_changed", "status_changed"])
        }
    }
}

/// The resolver grammar is common to the family: `#channel:<8-hex>` addresses
/// the thread's own task board for writes that can target a thread, while
/// claim/create keep their pinned refusals.
@Test func taskThreadTargetsAddressTheThreadBoard() async throws {
    let f = makeTaskGateFixture("304")
    let threadTask = f.accounts.addTaskForClaimTesting(
        channelId: f.threadId, title: "thread task", status: "todo", creatorId: f.agentId
    )
    let parentTask = f.accounts.addTaskForClaimTesting(
        channelId: f.roomId, title: "parent task", status: "todo", creatorId: f.agentId
    )
    let peer = f.accounts.oauth.createAgent(serverId: f.serverId, name: "ThreadPeer304", runtime: "codex")
    f.accounts.oauth.addChannelAgent(channelId: f.threadId, agentId: peer)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                try await taskGatePost(client, key: f.key, path, body)
            }
            let updated = try await post("/internal/agent-api/tasks/update-status",
                "{\"channel\":\"\(f.threadRef)\",\"task_number\":1,\"status\":\"in_progress\"}")
            #expect(updated.status == .ok, Comment(rawValue: updated.body.string ?? ""))
            #expect(f.accounts.taskClaimFactsForTesting(taskId: threadTask)?.status == "in_progress")
            #expect(f.accounts.taskClaimFactsForTesting(taskId: parentTask)?.status == "todo")

            let amended = try await post("/internal/agent-api/tasks/amend",
                "{\"channel\":\"\(f.threadRef)\",\"task_number\":1,\"title\":\"thread renamed\"}")
            #expect(amended.status == .ok, Comment(rawValue: amended.body.string ?? ""))
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.threadId).first?.title == "thread renamed")
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.roomId).first?.title == "parent task")

            let assigned = try await post("/internal/agent-api/tasks/assign",
                "{\"channel\":\"\(f.threadRef)\",\"task_number\":1,\"assignee\":\"@ThreadPeer304\"}")
            #expect(assigned.status == .ok, Comment(rawValue: assigned.body.string ?? ""))
            #expect(f.accounts.taskClaimFactsForTesting(taskId: threadTask)?.assigneeId == peer)

            let unclaimed = try await post("/internal/agent-api/tasks/unclaim",
                "{\"channel\":\"\(f.threadRef)\",\"task_number\":1}")
            #expect(unclaimed.status == .ok, Comment(rawValue: unclaimed.body.string ?? ""))
            #expect(f.accounts.taskClaimFactsForTesting(taskId: threadTask)?.assigneeId == nil)

            let list = try await client.get(
                URI(string: "/internal/agent-api/tasks?channel=\(f.threadRef.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"),
                headers: taskGateHeaders(f.key)
            )
            #expect(list.status == .ok)
            let listed = taskGateObject(list)["tasks"] as? [[String: Any]] ?? []
            #expect(listed.count == 1)
            #expect(listed.first?["taskNumber"] as? Int == 1)
            #expect(listed.first?["title"] as? String == "thread renamed")

            let deleted = try await post("/internal/agent-api/tasks/delete",
                "{\"channel\":\"\(f.threadRef)\",\"task_number\":1}")
            #expect(deleted.status == .ok, Comment(rawValue: deleted.body.string ?? ""))
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.threadId).isEmpty)
            #expect(f.accounts.taskSnapshotsForTesting(channelId: f.roomId).count == 1)

            let claim = try await post("/internal/agent-api/tasks/claim",
                "{\"channel\":\"\(f.threadRef)\",\"task_numbers\":[1]}")
            #expect(claim.status == .conflict)
            #expect(taskGateObject(claim)["error"] as? String == "Thread messages cannot be claimed as tasks")
            let create = try await post("/internal/agent-api/tasks",
                "{\"channel\":\"\(f.threadRef)\",\"tasks\":[{\"title\":\"no thread create\"}]}")
            #expect(create.status == .conflict)
            #expect(taskGateObject(create)["error"] as? String == "Thread messages cannot become tasks")
        }
    }
}
