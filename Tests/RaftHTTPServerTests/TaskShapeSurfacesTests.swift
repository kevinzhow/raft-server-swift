import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct TaskShapeFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let serverId: String
    let channelId: String
    let channelName: String
}

private func makeTaskShapeFixture(_ suffix: String) -> TaskShapeFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001039\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001039\(suffix)"
    accounts.addAccount(id: ownerId, email: "task-shape-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-shape-\(suffix)", name: "Task Shape \(suffix)", ownerId: ownerId)
    let channelName = "task-shape-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    return TaskShapeFixture(accounts: accounts, ownerId: ownerId, serverId: serverId, channelId: channelId, channelName: channelName)
}

private func taskShapeHeaders(_ bearer: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(bearer)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func taskShapeJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func listedTaskNumbers(_ client: any Client, _ fixture: TaskShapeFixture) async throws -> [Int] {
    let response = try await client.get(
        URI(string: "/api/tasks/channel/\(fixture.channelId)"),
        headers: taskShapeHeaders(fixture.accounts.mintAccessTokenForTesting(userId: fixture.ownerId), fixture.serverId)
    )
    #expect(response.status == .ok)
    let tasks = try taskShapeJSON(response)["tasks"] as? [[String: Any]] ?? []
    return tasks.compactMap { $0["taskNumber"] as? Int }.sorted()
}

@Test func deletingTasksRemovesEveryShapeWithoutResurrection() async throws {
    let fixture = makeTaskShapeFixture("001")
    let accounts = fixture.accounts
    let orphan = accounts.addOrphanTaskForTesting(channelId: fixture.channelId, title: "v0 task", taskNumber: 1)
    let shadowMessageId = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: shadowMessageId, channelId: fixture.channelId, senderId: fixture.ownerId, content: "backfilled task")
    let backfilled = accounts.addBackfilledTaskForTesting(
        channelId: fixture.channelId,
        title: "backfilled task",
        taskNumber: 2,
        messageId: shadowMessageId
    )
    let v14 = accounts.addTask(channelId: fixture.channelId, title: "v14 task", description: nil)
    let token = accounts.mintAccessTokenForTesting(userId: fixture.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let headers = taskShapeHeaders(token, fixture.serverId)
            #expect(try await listedTaskNumbers(client, fixture) == [1, 2, 3])

            var remaining = [1, 2, 3]
            for (shape, id, number) in [("v0", orphan, 1), ("backfilled", backfilled, 2), ("v14", v14, 3)] {
                let deleted = try await client.send(.delete, headers: headers, to: URI(string: "/api/tasks/\(id)"))
                #expect(deleted.status == .ok, "\(shape): delete should succeed")
                remaining.removeAll { $0 == number }
                let listed = try await listedTaskNumbers(client, fixture)
                #expect(!listed.contains(number), "\(shape): deleted task #\(number) came back on the board")
                #expect(listed == remaining, "\(shape): delete must remove exactly one task")
            }
        }
    }
}

@Test func messageOnlyTaskRowsStayInert() async throws {
    let fixture = makeTaskShapeFixture("002")
    let accounts = fixture.accounts
    let strayMessageId = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: strayMessageId, channelId: fixture.channelId, senderId: fixture.ownerId, content: "stray task")
    accounts.setHumanMessageTask(
        messageId: strayMessageId,
        status: "todo",
        number: 100,
        assigneeType: "user",
        assigneeId: fixture.ownerId,
        claimedAt: "2026-07-31T01:03:00.000Z",
        completedAt: "2026-07-31T01:04:00.000Z"
    )
    _ = accounts.addTask(channelId: fixture.channelId, title: "canonical task", description: nil)
    let token = accounts.mintAccessTokenForTesting(userId: fixture.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            #expect(try await listedTaskNumbers(client, fixture) == [1], "only the canonical task may be listed")
            let deleted = try await client.send(
                .delete,
                headers: taskShapeHeaders(token, fixture.serverId),
                to: URI(string: "/api/tasks/\(strayMessageId)")
            )
            #expect(deleted.status == .notFound, "a message-only row must not resolve as a task")
        }
    }
}

@Test func deletingBackfilledTaskClearsTheMessageShadow() async throws {
    let fixture = makeTaskShapeFixture("003")
    let accounts = fixture.accounts
    let shadowMessageId = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: shadowMessageId, channelId: fixture.channelId, senderId: fixture.ownerId, content: "backfilled task")
    let taskId = accounts.addBackfilledTaskForTesting(
        channelId: fixture.channelId,
        title: "backfilled task",
        taskNumber: 1,
        messageId: shadowMessageId
    )
    #expect(accounts.messageTaskShadowForTesting(messageId: shadowMessageId)?.number == 1)
    let token = accounts.mintAccessTokenForTesting(userId: fixture.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let deleted = try await client.send(
                .delete,
                headers: taskShapeHeaders(token, fixture.serverId),
                to: URI(string: "/api/tasks/\(taskId)")
            )
            #expect(deleted.status == .ok)
            #expect(accounts.messageTaskShadowForTesting(messageId: shadowMessageId) == nil, "message-side task columns must be cleared")
            #expect(try await listedTaskNumbers(client, fixture).isEmpty)
        }
    }
}

@Test func agentTaskEndpointsCannotReachAV0Orphan() async throws {
    let fixture = makeTaskShapeFixture("004")
    let accounts = fixture.accounts
    let agent = accounts.oauth.createAgent(serverId: fixture.serverId, name: "ShapeBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: fixture.channelId, agentId: agent)
    let orphan = accounts.addOrphanTaskForTesting(channelId: fixture.channelId, title: "v0 task", taskNumber: 1)
    let shadowMessageId = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: shadowMessageId, channelId: fixture.channelId, senderId: fixture.ownerId, content: "reachable task")
    let reachable = accounts.addBackfilledTaskForTesting(
        channelId: fixture.channelId,
        title: "reachable task",
        taskNumber: 2,
        messageId: shadowMessageId
    )
    let machine = accounts.registerMachine(serverId: fixture.serverId, userId: fixture.ownerId, name: "shape-machine")
    let machineKey = try #require(accounts.machineAPIKey(machineId: machine))

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(machineKey)"
            headers[.contentType] = "application/json"

            let claimed = try await client.send(
                .post,
                headers: headers,
                to: URI(string: "/internal/agent/\(agent)/tasks/claim")
            ) { request in
                request.body = .init(string: "{\"channel\":\"#\(fixture.channelName)\",\"task_numbers\":[1,2]}")
            }
            #expect(claimed.status == .ok)
            let results = try taskShapeJSON(claimed)["results"] as? [[String: Any]] ?? []
            let orphanResult = results.first { $0["taskNumber"] as? Int == 1 }
            #expect(orphanResult?["success"] as? Bool == false)
            #expect(orphanResult?["reason"] as? String == "task not found")
            let reachableResult = results.first { $0["taskNumber"] as? Int == 2 }
            #expect(reachableResult?["success"] as? Bool == true)
            #expect(accounts.taskAssigneeForTesting(taskId: orphan) == nil, "a rejected claim must not write the orphan")

            let status = try await client.send(
                .post,
                headers: headers,
                to: URI(string: "/internal/agent/\(agent)/tasks/update-status")
            ) { request in
                request.body = .init(string: "{\"channel\":\"#\(fixture.channelName)\",\"task_number\":1,\"status\":\"in_review\"}")
            }
            #expect(status.status == .notFound, "agent status update on an orphan must 404")
            #expect(accounts.taskAssigneeForTesting(taskId: reachable) == agent)
        }
    }
}
