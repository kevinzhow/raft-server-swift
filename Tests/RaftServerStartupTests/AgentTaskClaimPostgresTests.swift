import Foundation
import RaftPersistence
import RaftRealtime
import RaftShared
import Testing
import TestSupport
@testable import RaftHTTP

private let agentTaskClaimPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_HUMAN_MESSAGE_EXECUTION_PG_ACCEPTANCE"] == "1"

/// A real PostgreSQL + real HTTP acceptance for the task-claim path this slice
/// changed: a human's plain DM message is claimed by the agent's real
/// credential, converted to a canonical task whose title is the unchanged host
/// text, published once as `task:created` through the durable outbox, and
/// refused without effects from an archived, unauthorized or owned-assistant
/// target. The same database is then reopened by a reconstructed runtime to
/// prove the task and its history are durable.
///
/// The runner supplies a dedicated empty database; this case never falls back
/// to DATABASE_URL or touches the production database.
@Test(.enabled(if: agentTaskClaimPGEnabled), .serialized)
func agentTaskClaimDMPlainMessagePublishesCanonicalTaskDurably() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_HUMAN_MESSAGE_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var fixtureClosed = false
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let me = try await fixture.http("GET", "/api/auth/me", token: owner)
        let ownerName = try me.object().requireString("name")

        let agentReply = try await fixture.http("POST", "/api/agents", token: owner, body: .init([
            "name": .string("DMTaskExternal"), "external": .bool(true),
        ]))
        guard agentReply.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try agentReply.object().requireString("id")
        let credential = try await fixture.http("POST", "/api/agents/\(agentID)/credentials", token: owner,
            body: .init(["scopes": .array([.string("read"), .string("send"), .string("tasks")])]))
        guard credential.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let key = try credential.object().requireString("apiKey")

        let dmReply = try await fixture.http("GET", "/api/channels/dm", token: owner)
        guard dmReply.status == 200,
              case .array(let dmValues) = try JSONDecoder().decode(JSONValue.self, from: dmReply.body) else {
            throw ProtocolPGFailure.invalidResponse
        }
        let dmPeer = try #require(dmValues.compactMap { value -> ProtocolPGObject? in
            guard case .object(let fields) = value else { return nil }
            return ProtocolPGObject(fields)
        }.first { $0.string("peerType") == "agent" && $0.string("peerId") == agentID })
        let dmID = try dmPeer.requireString("id")

        let hostText = "Plain DM work that becomes a task"
        let posted = try await fixture.http("POST", "/api/messages", token: owner, body: .init([
            "channelId": .string(dmID), "content": .string(hostText),
        ]))
        guard posted.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let messageID = try posted.object().requireString("id")
        let hostBefore = try #require(try await fixture.audit().messages.first { $0.string("id") == messageID })
        #expect(hostBefore.string("content") == hostText)

        // Pause the production publication worker so the committed effect is
        // observed as an undelivered durable outbox row, not a live callback.
        await fixture.pausePublications()

        func claim(_ token: String, _ target: String, _ message: String) async throws -> ProtocolPGHTTPResponse {
            try await fixture.http("POST", "/internal/agent-api/tasks/claim", token: token, body: .init([
                "channel": .string(target), "message_ids": .array([.string(message)]),
            ]))
        }
        func claimNumber(_ token: String, _ target: String, _ number: Int) async throws -> ProtocolPGHTTPResponse {
            try await fixture.http("POST", "/internal/agent-api/tasks/claim", token: token, body: .init([
                "channel": .string(target), "task_numbers": .array([.integer(Int64(number))]),
            ]))
        }

        let claimedResponse = try await claim(key, "dm:@\(ownerName)~human", messageID)
        #expect(claimedResponse.status == 200, Comment(rawValue: "claim status \(claimedResponse.status)"))
        let claimBody = try claimedResponse.object()
        guard case .object(let claimResult)? = claimBody.array("results")?.first else {
            throw ProtocolPGFailure.invalidResponse
        }
        let first = ProtocolPGObject(claimResult)
        #expect(first.bool("success") == true)
        #expect(first.string("messageId") == messageID)
        #expect(first.integer("taskNumber") == 1)

        let audit = try await fixture.audit()
        let task = try #require(audit.tasks.first { $0.string("messageId") == messageID })
        let taskID = try task.requireString("id")
        #expect(task.string("title") == hostText)
        #expect(task.string("status") == "in_progress")
        #expect(task.string("assigneeId") == agentID)
        #expect(task.string("assigneeType") == "agent")
        #expect(task.string("channelId") == dmID)
        #expect(audit.messages.first { $0.string("id") == messageID }?.string("content") == hostText)
        #expect(fixture.accounts.messageContentForTesting(messageId: messageID) == hostText)

        let created = try #require(try await fixture.pendingTaskPublication(taskId: taskID, channelId: dmID))
        #expect(created.deliveredAt == nil)
        let pending = try await fixture.observer.pendingOutbox(limit: 100)
        let publications = pending.compactMap(taskClaimPGPublication)
        #expect(publications.filter { $0.event == "task:created" && $0.payloadJSON.contains(taskID) }.count == 1)
        #expect(!publications.contains { $0.event == "message:updated" && $0.payloadJSON.contains(messageID) })
        #expect(try await taskClaimPGTaskEvents(fixture, taskID: taskID) == ["created", "assignee_changed", "status_changed"])

        // Repeating the identical claim converges on the same row and event
        // set; it publishes no second task:created/task:updated.
        let repeatClaim = try await claim(key, "dm:@\(ownerName)~human", messageID)
        #expect(repeatClaim.status == 200)
        guard case .object(let repeatResult)? = try repeatClaim.object().array("results")?.first else {
            throw ProtocolPGFailure.invalidResponse
        }
        let repeated = ProtocolPGObject(repeatResult)
        #expect(repeated.bool("success") == false)
        #expect(repeated.string("reason") == "already claimed by you")
        #expect((try await fixture.audit()).tasks.filter { $0.string("messageId") == messageID }.count == 1)
        #expect(try await taskClaimPGTaskEvents(fixture, taskID: taskID) == ["created", "assignee_changed", "status_changed"])
        let pendingAfterRepeat = try await fixture.observer.pendingOutbox(limit: 100)
        let repeatPublications = pendingAfterRepeat.compactMap(taskClaimPGPublication)
        #expect(repeatPublications.filter { $0.event == "task:created" && $0.payloadJSON.contains(taskID) }.count == 1)
        #expect(!repeatPublications.contains { $0.event == "task:updated" && $0.payloadJSON.contains(taskID) })

        // Build the three declined targets through the published human routes.
        let assistantReply = try await fixture.http("POST", "/api/agents", token: owner, body: .init([
            "name": .string("ClaimAssistantExternal"), "external": .bool(true),
        ]))
        guard assistantReply.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let assistantID = try assistantReply.object().requireString("id")
        let assistantCredential = try await fixture.http("POST", "/api/agents/\(assistantID)/credentials", token: owner,
            body: .init(["scopes": .array([.string("read"), .string("send"), .string("tasks")])]))
        guard assistantCredential.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let assistantKey = try assistantCredential.object().requireString("apiKey")
        let unauthorizedRoom = try await taskClaimPGCreateRoom(fixture, token: owner, name: "claim-unauthorized")
        let unauthorizedTask = try await taskClaimPGCreateTask(
            fixture, token: owner, channelID: unauthorizedRoom, title: "unauthorized task"
        )
        let archivedRoom = try await taskClaimPGCreateRoom(fixture, token: owner, name: "claim-archived")
        try await taskClaimPGAddAgent(fixture, token: owner, channelID: archivedRoom, agentID: agentID)
        let archivedTask = try await taskClaimPGCreateTask(
            fixture, token: owner, channelID: archivedRoom, title: "archived task"
        )
        let archived = try await fixture.http("POST", "/api/channels/\(archivedRoom)/archive", token: owner)
        #expect(archived.status == 200)
        let assistantRoom = try await taskClaimPGCreateRoom(fixture, token: owner, name: "claim-assistant-room")
        try await taskClaimPGAddAgent(fixture, token: owner, channelID: assistantRoom, agentID: assistantID)
        // The room membership is created first, then the agent becomes the
        // owner's assistant. The published member route correctly refuses to
        // add an already-linked assistant to a room, so this is the real shape
        // of an agent that was a member before the link existed.
        try await fixture.runtime.execute {
            fixture.accounts.createFeatureFlagForTesting(key: "identity_borrowing", defaultEnabled: true)
            fixture.accounts.linkAssistantOwnerForTesting(agentId: assistantID, userId: fixture.ownerId)
        }
        let assistantTask = try await taskClaimPGCreateTask(
            fixture, token: owner, channelID: assistantRoom, title: "assistant room task"
        )

        let declinedTaskIDs = [unauthorizedTask, archivedTask, assistantTask]
        var beforeEvents: [String: [String]] = [:]
        for taskID in declinedTaskIDs {
            beforeEvents[taskID] = try await taskClaimPGTaskEvents(fixture, taskID: taskID)
        }
        let beforeDeclined = try await fixture.audit()
        let beforePending = try await fixture.observer.pendingOutbox(limit: 100)
        let beforePendingIDs = Set(beforePending.map(\.effect.effectID))
        let unauthorized = try await claimNumber(key, "#claim-unauthorized", 1)
        #expect(unauthorized.status == 403)
        #expect(try unauthorized.object().string("error") == "Agent must join this channel to modify tasks")
        let archivedClaim = try await claimNumber(key, "#claim-archived", 1)
        #expect(archivedClaim.status == 409)
        #expect(try archivedClaim.object().string("code") == "channel_archived")
        let assistantClaim = try await claimNumber(assistantKey, "#claim-assistant-room", 1)
        #expect(assistantClaim.status == 403)
        #expect(try assistantClaim.object().string("error") == "Agent must join this channel to modify tasks")

        let afterDeclined = try await fixture.audit()
        #expect(afterDeclined.tasks.map(\.fields) == beforeDeclined.tasks.map(\.fields))
        #expect(afterDeclined.messages.map(\.fields) == beforeDeclined.messages.map(\.fields))
        let afterPending = try await fixture.observer.pendingOutbox(limit: 100)
        #expect(Set(afterPending.map(\.effect.effectID)) == beforePendingIDs)
        for taskID in declinedTaskIDs {
            #expect(try await taskClaimPGTaskEvents(fixture, taskID: taskID) == beforeEvents[taskID])
        }

        // A fresh Main view: close the running fixture, reopen the same
        // dedicated database with a second PG reader, then reconstruct the
        // production runtime and read the task back through its stores.
        await fixture.close()
        fixtureClosed = true
        let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        let reader = try await PostgresPersistence.start(configuration: configuration, migrate: false)
        let durableTaskKey = try DurableKey(domain: .tasksAndReminders, aggregateID: "root")
        let durableMessageKey = try DurableKey(domain: .messagesAndThreads, aggregateID: "root")
        let documents = try await reader.readSnapshot([durableTaskKey, durableMessageKey])
        #expect(documents.count == 2)
        let taskDocument = try #require(documents.first { $0.key == durableTaskKey })
        let taskRoot = try ProtocolPGObject(data: taskDocument.decode(Data.self, codecVersion: 1))
        let restoredTasks = (taskRoot.object("business")?.array("taskRecords") ?? []).compactMap {
            value -> ProtocolPGObject? in
            guard case .object(let fields) = value else { return nil }
            return ProtocolPGObject(fields)
        }
        let restoredTask = try #require(restoredTasks.first { $0.string("messageId") == messageID })
        #expect(restoredTask.string("title") == hostText)
        #expect(restoredTask.string("status") == "in_progress")
        #expect(restoredTask.string("assigneeType") == "agent")
        #expect(restoredTask.string("assigneeId") == agentID)
        let restoredEvents = (taskRoot.object("business")?.array("taskEvents") ?? []).compactMap {
            value -> String? in
            guard case .object(let fields) = value else { return nil }
            let event = ProtocolPGObject(fields)
            return event.string("taskId") == taskID ? event.string("eventType") : nil
        }
        #expect(restoredEvents == ["created", "assignee_changed", "status_changed"])
        let messageDocument = try #require(documents.first { $0.key == durableMessageKey })
        let messageRoot = try ProtocolPGObject(data: messageDocument.decode(Data.self, codecVersion: 1))
        let restoredMessages = (messageRoot.object("payload")?.array("humanMessageRows") ?? []).compactMap {
            value -> ProtocolPGObject? in
            guard case .object(let fields) = value else { return nil }
            return ProtocolPGObject(fields)
        }
        #expect(restoredMessages.first { $0.string("id") == messageID }?.string("content") == hostText)
        let readerOutbox = try await reader.pendingOutbox(limit: 100)
        #expect(readerOutbox.contains { entry in
            guard let publication = taskClaimPGPublication(entry) else { return false }
            return publication.event == "task:created" && publication.payloadJSON.contains(taskID)
        })
        await reader.close()
    } catch {
        if !fixtureClosed { await fixture.close() }
        throw error
    }
}

private func taskClaimPGPublication(_ entry: DurableOutboxEntry) -> RealtimePublication? {
    guard entry.effect.kind.rawValue == "realtime.publish" else { return nil }
    return try? JSONDecoder().decode(RealtimePublication.self, from: entry.effect.payload)
}

private func taskClaimPGTaskEvents(
    _ fixture: AgentExecutionPostgresFixture, taskID: String
) async throws -> [String] {
    let key = try DurableKey(domain: .tasksAndReminders, aggregateID: "root")
    let documents = try await fixture.observer.readSnapshot([key])
    guard let document = documents.first else { throw ProtocolPGFailure.invalidSnapshot }
    let root = try ProtocolPGObject(data: document.decode(Data.self, codecVersion: 1))
    let events = root.object("business")?.array("taskEvents") ?? []
    return events.compactMap { value -> String? in
        guard case .object(let fields) = value else { return nil }
        let event = ProtocolPGObject(fields)
        return event.string("taskId") == taskID ? event.string("eventType") : nil
    }
}

private func taskClaimPGCreateRoom(
    _ fixture: AgentExecutionPostgresFixture, token: String, name: String
) async throws -> String {
    let reply = try await fixture.http("POST", "/api/channels", token: token, body: .init([
        "name": .string(name),
    ]))
    guard reply.status == 200 else { throw ProtocolPGFailure.invalidResponse }
    return try reply.object().requireString("id")
}

private func taskClaimPGCreateTask(
    _ fixture: AgentExecutionPostgresFixture, token: String, channelID: String, title: String
) async throws -> String {
    let reply = try await fixture.http("POST", "/api/tasks/channel/\(channelID)", token: token, body: .init([
        "tasks": .array([.object(["title": .string(title)])]),
    ]))
    guard reply.status == 200, case .object(let task)? = try reply.object().array("tasks")?.first else {
        throw ProtocolPGFailure.invalidResponse
    }
    return try ProtocolPGObject(task).requireString("id")
}

private func taskClaimPGAddAgent(
    _ fixture: AgentExecutionPostgresFixture, token: String, channelID: String, agentID: String
) async throws {
    let reply = try await fixture.http("POST", "/api/channels/\(channelID)/members", token: token, body: .init([
        "agentId": .string(agentID),
    ]))
    guard reply.status == 200 else { throw ProtocolPGFailure.invalidResponse }
}
