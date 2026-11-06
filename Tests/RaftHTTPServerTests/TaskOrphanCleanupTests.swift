import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct OrphanFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let serverId: String
    let channelId: String
    let ownerToken: String
}

private func makeOrphanFixture(_ suffix: String) -> OrphanFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001046\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001046\(suffix)"
    accounts.addAccount(id: ownerId, email: "orphan-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "orphan-\(suffix)", name: "Orphan \(suffix)", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "orphan-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "orphan-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    return OrphanFixture(
        accounts: accounts,
        ownerId: ownerId,
        serverId: serverId,
        channelId: channelId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId)
    )
}

private func orphanHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func orphanObject(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func channelDeleteAutoClosesOpenTasks() async throws {
    let f = makeOrphanFixture("001")
    let accounts = f.accounts
    let todo = accounts.addTask(channelId: f.channelId, title: "todo task", description: nil)
    let inProgress = accounts.addTask(channelId: f.channelId, title: "in progress task", description: nil)
    let inReview = accounts.addTask(channelId: f.channelId, title: "in review task", description: nil)
    let done = accounts.addTask(channelId: f.channelId, title: "done task", description: nil)
    for (task, status) in [(inProgress, "in_progress"), (inReview, "in_review"), (done, "done")] {
        _ = try accounts.channelAssignments().updateTaskStatus(
            authorization: "Bearer \(f.ownerToken)",
            serverId: f.serverId,
            taskId: task,
            body: TaskStatusRequest(status: status)
        )
    }

    _ = try accounts.searchMentions.deleteChannel(channelId: f.channelId, authorization: "Bearer \(f.ownerToken)", serverId: f.serverId)

    #expect(accounts.taskStatusForTesting(taskId: todo) == "closed")
    #expect(accounts.taskCompletedAtForTesting(taskId: todo) != nil)
    #expect(accounts.taskClosedAtForTesting(taskId: todo) != nil)
    #expect(accounts.taskStatusForTesting(taskId: inProgress) == "closed")
    #expect(accounts.taskStatusForTesting(taskId: inReview) == "closed")
    #expect(accounts.taskStatusForTesting(taskId: done) == "done")
    #expect(accounts.taskEventTypesForTesting(taskId: todo).contains { $0.eventType == "closed" && $0.actorType == "system" })
}

@Test func agentDeleteReleasesTaskClaims() async throws {
    let f = makeOrphanFixture("002")
    let accounts = f.accounts
    let agent = accounts.oauth.createAgent(serverId: f.serverId, name: "atlas-002", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: f.channelId, agentId: agent)
    let task = accounts.addTask(channelId: f.channelId, title: "agent claimed task", description: nil)
    accounts.setTaskAssigneeForTesting(taskId: task, type: "agent", id: agent)
    accounts.reopenTaskForTesting(taskId: task, status: "in_progress")

    let deleted = try accounts.agentMachineMigrationControl.deleteAgent(
        authorization: "Bearer \(f.ownerToken)",
        agentId: agent,
        serverId: "",
        request: AgentDeleteRequest()
    )
    #expect(deleted == OkResponse())
    #expect(accounts.taskAssigneeForTesting(taskId: task) == nil)
    #expect(accounts.taskStatusForTesting(taskId: task) == "in_progress")
}

@Test func orphanTaskCanBeClosedByAdminWithTerminalStatus() async throws {
    let f = makeOrphanFixture("003")
    let accounts = f.accounts
    let task = accounts.addTask(channelId: f.channelId, title: "orphan to close", description: nil)
    _ = try accounts.channelAssignments().updateTaskStatus(
        authorization: "Bearer \(f.ownerToken)",
        serverId: f.serverId,
        taskId: task,
        body: TaskStatusRequest(status: "in_review")
    )
    _ = try accounts.searchMentions.deleteChannel(channelId: f.channelId, authorization: "Bearer \(f.ownerToken)", serverId: f.serverId)
    accounts.reopenTaskForTesting(taskId: task, status: "in_review")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let close = try await client.send(.patch, headers: orphanHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/tasks/\(task)/status")) { request in
                request.body = .init(string: "{\"status\":\"done\"}")
            }
            #expect(close.status == .ok)
            #expect(accounts.taskStatusForTesting(taskId: task) == "done")
        }
    }
}

@Test func orphanTaskRejectsNonTerminalTransitionsAndClaims() async throws {
    let f = makeOrphanFixture("004")
    let accounts = f.accounts
    let task = accounts.addTask(channelId: f.channelId, title: "orphan no reopen", description: nil)
    _ = try accounts.searchMentions.deleteChannel(channelId: f.channelId, authorization: "Bearer \(f.ownerToken)", serverId: f.serverId)
    accounts.reopenTaskForTesting(taskId: task, status: "in_review")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let before = try await client.get(URI(string: "/api/tasks/channel/\(f.channelId)"), headers: orphanHeaders(f.ownerToken, f.serverId))
            #expect(before.status == .ok)
            let reject = try await client.send(.patch, headers: orphanHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/tasks/\(task)/status")) { request in
                request.body = .init(string: "{\"status\":\"in_progress\"}")
            }
            #expect(reject.status == .conflict)
            #expect(reject.body.string == #"{"error":"This channel was deleted; only terminal task statuses are allowed","code":"channel_deleted_terminal_only"}"#)

            let claim = try await client.send(.patch, headers: orphanHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/tasks/\(task)/claim"))
            #expect(claim.status == .conflict)
            #expect(claim.body.string == #"{"error":"This channel was deleted; the task can only be closed","code":"channel_deleted_terminal_only"}"#)
            let after = try await client.get(URI(string: "/api/tasks/channel/\(f.channelId)"), headers: orphanHeaders(f.ownerToken, f.serverId))
            #expect(after.status == .ok)
            #expect(after.body.string == before.body.string, "both refusals preserve the public task row including revision and claim stamps")
        }
    }
}

@Test func orphanTaskCanBeDeletedByAdmin() async throws {
    let f = makeOrphanFixture("005")
    let accounts = f.accounts
    let task = accounts.addTask(channelId: f.channelId, title: "orphan to delete", description: nil)
    _ = try accounts.searchMentions.deleteChannel(channelId: f.channelId, authorization: "Bearer \(f.ownerToken)", serverId: f.serverId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let deleted = try await client.send(.delete, headers: orphanHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/tasks/\(task)"))
            #expect(deleted.status == .ok)
        }
    }
}

@Test func orphanTaskDeleteRejectsNonCreatorNonAdmin() async throws {
    let f = makeOrphanFixture("006")
    let accounts = f.accounts
    let memberId = "11111111-1111-4111-8111-000001047006"
    accounts.addAccount(id: memberId, email: "orphan-member-006@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addMember(serverId: f.serverId, userId: memberId, role: "member")
    accounts.addPostableChannel(serverId: f.serverId, channelId: f.channelId, memberId: memberId, name: "orphan-006")
    accounts.oauth.addChannelHuman(channelId: f.channelId, userId: memberId)
    let task = accounts.addTask(channelId: f.channelId, title: "owner orphan", description: nil)
    _ = try accounts.searchMentions.deleteChannel(channelId: f.channelId, authorization: "Bearer \(f.ownerToken)", serverId: f.serverId)
    let memberToken = accounts.mintAccessTokenForTesting(userId: memberId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let deleted = try await client.send(.delete, headers: orphanHeaders(memberToken, f.serverId), to: URI(string: "/api/tasks/\(task)"))
            #expect(deleted.status == .forbidden)
        }
    }
}
