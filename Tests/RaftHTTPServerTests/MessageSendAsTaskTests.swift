import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Synchronization
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The pinned Web composer posts `/api/v2/messages` with `asTask: true` when its
/// "also create task" checkbox is set. Upstream persists a plain host message,
/// links a canonical `tasks` row in the same transaction, projects the task
/// facts onto the acknowledgement / `message:new` row, and emits a separate
/// `task:created` board frame.

private struct AsTaskSocketAuth: RealtimeAuthorizing {
    let auth: AuthCoreService
    let membership: SocketMembershipService
    func userId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { auth.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        membership.syncMessages(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)?.jsonBody()
    }
}

private struct AsTaskFixture: Sendable {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111661"
    let serverId = "33333333-3333-4333-8333-333333333681"

    init() {
        accounts.addAccount(id: ownerId, email: "as-task-owner@message-as-task.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "message-as-task", name: "Message As Task", ownerId: ownerId)
    }

    var auth: AsTaskSocketAuth {
        AsTaskSocketAuth(auth: accounts.authCore, membership: accounts.socketMembership)
    }

    var token: String { accounts.mintAccessTokenForTesting(userId: ownerId) }

    func headers(_ token: String? = nil) -> HTTPFields {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        fields[.authorization] = "Bearer \(token ?? self.token)"
        fields[HTTPField.Name("X-Server-Id")!] = serverId
        return fields
    }

    func addChannel(name: String) -> String {
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: name)
        return channelId
    }
}

private let taskCreatedEventKeys: Set<String> = [
    "id", "messageId", "channelId", "channelName", "channelType", "taskNumber", "title",
    "description", "status", "claimedByType", "claimedById", "claimedByName", "claimedAt",
    "completedAt", "createdByType", "createdById", "createdByName", "createdAt", "updatedAt",
    "revision", "taskCurrentProjection", "isLegacy",
]

private let messageTaskKeys = [
    "taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId", "taskClaimedAt", "taskCompletedAt",
]

private func asTaskObject(_ body: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
}

private func asTaskSocketFrame(_ frame: String) throws -> (event: String, payload: [String: Any]) {
    let array = try #require(try JSONSerialization.jsonObject(with: Data(frame.dropFirst(2).utf8)) as? [Any])
    return (
        try #require(array.first as? String),
        try #require(array.count == 2 ? array[1] as? [String: Any] : nil)
    )
}

private func asTaskConnect(_ fixture: AsTaskFixture, server: RealtimeServer) async throws -> SocketIOTestClient {
    let socket = try await SocketIOTestClient(port: server.port)
    _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
    socket.send("40{\"token\":\"\(fixture.token)\",\"serverId\":\"\(fixture.serverId)\"}")
    _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
    return socket
}

private func asTaskPost(_ client: any Client, _ path: String, _ body: String, _ headers: HTTPFields) async throws -> ClientResponse {
    try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func asTaskGet(_ client: any Client, _ path: String, _ headers: HTTPFields) async throws -> ClientResponse {
    try await client.send(.get, headers: headers, to: URI(string: path))
}

@Suite(.serialized)
struct MessageSendAsTaskTests {
    @Test func v2SendAsTaskCreatesCanonicalTaskAndPublishesBothFrames() async throws {
        let fixture = AsTaskFixture()
        let channelId = fixture.addChannel(name: "send-as-task")
        let content = "ship the asTask slice"
        let realtime = try await RealtimeServer.start(auth: fixture.auth)
        let socket = try await asTaskConnect(fixture, server: realtime)
        defer {
            socket.close()
            Task { try? await realtime.close() }
        }
        let hub = realtime.hub
        fixture.accounts.realtimeRelay.install { room, event, payload in
            hub.emit(room: room, event: event, payloadJSON: payload)
        }
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts, realtime: hub
            ))
            try await app.testing { client in
                let sent = try await asTaskPost(
                    client, "/api/v2/messages",
                    "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\",\"asTask\":true}",
                    fixture.headers()
                )
                #expect(sent.status == .ok)
                let envelope = try asTaskObject(try #require(sent.body.string))
                #expect(Set(envelope.keys) == ["message"])
                let message = try #require(envelope["message"] as? [String: Any])
                let messageId = try #require(message["id"] as? String)
                // Upstream v1.4 never persists task columns on the host row; the
                // acknowledgement projects the canonical task facts instead.
                #expect(message["taskStatus"] as? String == "todo")
                #expect(message["taskNumber"] as? Int == 1)
                #expect(message["taskAssigneeType"] is NSNull)
                #expect(message["taskAssigneeId"] is NSNull)
                #expect(message["taskClaimedAt"] is NSNull)
                #expect(message["taskCompletedAt"] is NSNull)

                let stored = try #require(fixture.accounts.messagesAndThreadsStore.humanMessageRow(id: messageId))
                #expect(stored.taskStatus == nil && stored.taskNumber == nil,
                        "the canonical task must not be written into the frozen message shadow")
                let task = try #require(fixture.accounts.tasksAndRemindersStore.task(messageId: messageId))
                #expect(task.title == content)
                #expect(task.status == "todo")
                #expect(task.taskNumber == 1)
                #expect(task.creatorId == fixture.ownerId)
                #expect(task.hasHostMessage)
                #expect(task.channelId == channelId)

                let newFrame = try #require(await socket.waitForText {
                    $0.hasPrefix(#"42["message:new""#) && $0.contains(content)
                })
                let (newEvent, newPayload) = try asTaskSocketFrame(newFrame)
                #expect(newEvent == "message:new")
                #expect(newPayload["id"] as? String == messageId)
                #expect(newPayload["taskStatus"] as? String == "todo")
                #expect(newPayload["taskNumber"] as? Int == 1)
                #expect(newPayload["taskAssigneeId"] is NSNull)
                let context = try #require(newPayload["conversationContext"] as? [String: Any])
                #expect(context["channelType"] as? String == "channel")

                let taskFrame = try #require(await socket.waitForText { $0.hasPrefix(#"42["task:created""#) })
                let (taskEvent, taskPayload) = try asTaskSocketFrame(taskFrame)
                #expect(taskEvent == "task:created")
                #expect(taskPayload["channelId"] as? String == channelId)
                let frameTasks = try #require(taskPayload["tasks"] as? [[String: Any]])
                #expect(frameTasks.count == 1)
                let frameTask = try #require(frameTasks.first)
                #expect(Set(frameTask.keys) == taskCreatedEventKeys)
                #expect(frameTask["id"] as? String == task.id)
                #expect(frameTask["messageId"] as? String == messageId)
                #expect(frameTask["channelId"] as? String == channelId)
                #expect(frameTask["channelName"] as? String == "send-as-task")
                #expect(frameTask["channelType"] as? String == "channel")
                #expect(frameTask["taskNumber"] as? Int == 1)
                #expect(frameTask["title"] as? String == content)
                #expect(frameTask["status"] as? String == "todo")
                #expect(frameTask["createdByType"] as? String == "user")
                #expect(frameTask["createdById"] as? String == fixture.ownerId)
                #expect(frameTask["createdByName"] as? String == "as-task-owner")
                #expect(frameTask["isLegacy"] as? Bool == false)

                // The task board route reads the same canonical row.
                let board = try await asTaskGet(client, "/api/tasks/channel/\(channelId)", fixture.headers())
                #expect(board.status == .ok)
                let boardBody = try #require(board.body.string)
                let boardTasks = try #require(try asTaskObject(boardBody)["tasks"] as? [[String: Any]])
                #expect(boardTasks.count == 1)
                #expect(boardTasks.first?["id"] as? String == task.id)
                #expect(boardTasks.first?["messageId"] as? String == messageId)

                // Cold message reads overlay the canonical task facts.
                let history = try await asTaskGet(client, "/api/messages/channel/\(channelId)?limit=50", fixture.headers())
                #expect(history.status == .ok)
                let historyBody = try #require(history.body.string)
                let rows = try #require(try asTaskObject(historyBody)["messages"] as? [[String: Any]])
                let host = try #require(rows.first { $0["id"] as? String == messageId })
                #expect(host["taskStatus"] as? String == "todo")
                #expect(host["taskNumber"] as? Int == 1)
                #expect(host["taskAssigneeType"] is NSNull)
                #expect(host["taskAssigneeId"] is NSNull)
                let current = try #require(host["taskCurrentProjection"] as? [String: Any])
                #expect(current["title"] as? String == content)
                #expect(current["source"] as? String == "tasks_current_projection")

                // The asTask row enters the existing claim mutation path; the
                // send itself must not invent an assignee.
                let claimed = try await client.send(.patch, headers: fixture.headers(),
                    to: URI(string: "/api/tasks/\(task.id)/claim"))
                #expect(claimed.status == .ok)
                let claimedBody = try #require(claimed.body.string)
                let claimedTask = try #require(try asTaskObject(claimedBody)["task"] as? [String: Any])
                #expect(claimedTask["id"] as? String == task.id)
                #expect(claimedTask["status"] as? String == "in_progress")
                #expect(fixture.accounts.tasksAndRemindersStore.task(messageId: messageId)?.assigneeId == fixture.ownerId)
            }
        }
    }

    @Test func v1SendAsTaskUsesTheNextChannelTaskNumber() async throws {
        let fixture = AsTaskFixture()
        let channelId = fixture.addChannel(name: "send-as-task-numbering")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                // Two board-created tasks occupy numbers 1 and 2.
                let board = try await asTaskPost(
                    client, "/api/tasks/channel/\(channelId)",
                    "{\"tasks\":[{\"title\":\"first board task\"},{\"title\":\"second board task\"}]}",
                    fixture.headers()
                )
                #expect(board.status == .ok)
                let boardBody = try #require(board.body.string)
                let boardTasks = try #require(try asTaskObject(boardBody)["tasks"] as? [[String: Any]])
                #expect(boardTasks.compactMap { $0["taskNumber"] as? Int } == [1, 2])

                let sent = try await asTaskPost(
                    client, "/api/messages",
                    "{\"channelId\":\"\(channelId)\",\"content\":\"third task by send\",\"asTask\":true}",
                    fixture.headers()
                )
                #expect(sent.status == .ok)
                // v1 answers with the bare message object.
                let message = try asTaskObject(try #require(sent.body.string))
                #expect(message["taskStatus"] as? String == "todo")
                #expect(message["taskNumber"] as? Int == 3)
                let messageId = try #require(message["id"] as? String)
                #expect(fixture.accounts.tasksAndRemindersStore.task(messageId: messageId)?.taskNumber == 3)

                // An ordinary send keeps the six task keys present as null and
                // never creates a task.
                let plain = try await asTaskPost(
                    client, "/api/messages",
                    "{\"channelId\":\"\(channelId)\",\"content\":\"plain message\"}",
                    fixture.headers()
                )
                #expect(plain.status == .ok)
                let plainMessage = try asTaskObject(try #require(plain.body.string))
                for key in messageTaskKeys {
                    #expect(plainMessage[key] is NSNull, "ordinary sends publish \(key) as null")
                }
                #expect(fixture.accounts.tasksAndRemindersStore.taskRecords.count == 3)
            }
        }
    }

    @Test func sendAsTaskOnAThreadCommitsTheMessageWithoutATask() async throws {
        let fixture = AsTaskFixture()
        let parentChannelId = fixture.addChannel(name: "send-as-task-thread-parent")
        let threadId = UUID().uuidString.lowercased()
        fixture.accounts.addThreadChannel(
            serverId: fixture.serverId, threadChannelId: threadId,
            parentChannelId: parentChannelId, parentMessageId: UUID().uuidString.lowercased(),
            memberId: fixture.ownerId
        )
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let sent = try await asTaskPost(
                    client, "/api/v2/messages",
                    "{\"channelId\":\"\(threadId)\",\"content\":\"thread asTask send\",\"asTask\":true}",
                    fixture.headers()
                )
                #expect(sent.status == .ok)
                let envelope = try asTaskObject(try #require(sent.body.string))
                let message = try #require(envelope["message"] as? [String: Any])
                let messageId = try #require(message["id"] as? String)
                #expect(message["taskStatus"] is NSNull)
                #expect(message["taskNumber"] is NSNull)
                // Upstream logs `thread messages cannot be claimed as tasks` and
                // still accepts the plain message; no task row exists.
                #expect(fixture.accounts.tasksAndRemindersStore.task(messageId: messageId) == nil)
                #expect(fixture.accounts.tasksAndRemindersStore.taskRecords.isEmpty)
            }
        }
    }

    @Test func sendAsTaskReplayConvergesOnOneTaskAndOneFrame() async throws {
        let fixture = AsTaskFixture()
        let channelId = fixture.addChannel(name: "send-as-task-replay")
        let events = Mutex<[(room: String, event: String, payload: String?)]>([])
        fixture.accounts.realtimeRelay.install { room, event, payload in
            events.withLock { $0.append((room, event, payload)) }
        }
        let randomId = "as-task-replay-001"
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                let first = try await asTaskPost(
                    client, "/api/v2/messages",
                    "{\"channelId\":\"\(channelId)\",\"content\":\"first asTask body\",\"asTask\":true,\"randomId\":\"\(randomId)\"}",
                    fixture.headers()
                )
                #expect(first.status == .ok)
                let firstBody = try #require(first.body.string)
                let firstMessage = try #require(try asTaskObject(firstBody)["message"] as? [String: Any])
                let firstId = try #require(firstMessage["id"] as? String)
                let firstTask = try #require(fixture.accounts.tasksAndRemindersStore.task(messageId: firstId))

                let replay = try await asTaskPost(
                    client, "/api/v2/messages",
                    "{\"channelId\":\"\(channelId)\",\"content\":\"retry body must not win\",\"asTask\":true,\"randomId\":\"\(randomId)\"}",
                    fixture.headers()
                )
                #expect(replay.status == .ok)
                let replayBody = try #require(replay.body.string)
                let replayMessage = try #require(try asTaskObject(replayBody)["message"] as? [String: Any])
                #expect(replayMessage["id"] as? String == firstId)
                #expect(replayMessage["content"] as? String == "first asTask body")
                #expect(replayMessage["taskStatus"] as? String == "todo")
                #expect(replayMessage["taskNumber"] as? Int == firstTask.taskNumber)

                #expect(fixture.accounts.tasksAndRemindersStore.taskRecords.count == 1)
                let converged = try #require(fixture.accounts.tasksAndRemindersStore.task(messageId: firstId))
                #expect(converged.id == firstTask.id)
                #expect(converged.title == "first asTask body")

                let recorded = events.withLock { $0 }
                #expect(recorded.filter { $0.event == "message:new" }.count == 1)
                #expect(recorded.filter { $0.event == "task:created" }.count == 1)
            }
        }
    }

    @Test func sendAsTaskRejectsANonBooleanFlagBeforeAnyWrite() async throws {
        let fixture = AsTaskFixture()
        let channelId = fixture.addChannel(name: "send-as-task-invalid")
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: fixture.accounts
            ))
            try await app.testing { client in
                for flag in ["null", "1", "\"yes\"", "{}"] {
                    let response = try await asTaskPost(
                        client, "/api/v2/messages",
                        "{\"channelId\":\"\(channelId)\",\"content\":\"must not persist\",\"asTask\":\(flag)}",
                        fixture.headers()
                    )
                    #expect(response.status == .badRequest)
                    let object = try asTaskObject(try #require(response.body.string))
                    #expect(object["error"] as? String == "Invalid message request body")
                }
                #expect(fixture.accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
                #expect(fixture.accounts.tasksAndRemindersStore.taskRecords.isEmpty)
            }
        }
    }
}
