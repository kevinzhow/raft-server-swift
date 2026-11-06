import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AssigneeFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001090001"
    let ownerId = "11111111-1111-4111-8111-000001090001"
    let memberId = "11111111-1111-4111-8111-000001090002"
    let outsiderId = "11111111-1111-4111-8111-000001090003"
    var agentId = ""

    init() throws {
        for (id, email) in [(ownerId, "owner"), (memberId, "member"), (outsiderId, "outsider")] {
            accounts.addAccount(id: id, email: "\(email)-assignee@task.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "assignee", name: "Assignee", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
        accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
        accounts.oauth.addMember(serverId: serverId, userId: ownerId, role: "owner")
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "assignee-agent", creatorUserId: ownerId, runtime: "claude")
    }
}

private func headers(_ fixture: AssigneeFixture, _ userId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.accounts.mintAccessTokenForTesting(userId: userId))"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
    return headers
}

@Test func taskAssignmentCoversMemberAssignSelfWithdrawAuditAndOCC() async throws {
    let fixture = try AssigneeFixture()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let ownerHeaders = headers(fixture, fixture.ownerId)
            let memberHeaders = headers(fixture, fixture.memberId)
            let outsiderHeaders = headers(fixture, fixture.outsiderId)

            let channel = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/channels")) { request in
                request.body = .init(string: "{\"name\":\"assignee-channel\",\"type\":\"channel\"}")
            }
            #expect(channel.status == .ok || channel.status == .created)
            let channelBody = try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let channelId = try #require(channelBody["id"] as? String)
            accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.ownerId)
            accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.memberId)
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: fixture.agentId)

            let created = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/tasks/channel/\(channelId)")) { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"assignee task\"}]}")
            }
            #expect(created.status == .ok || created.status == .created, Comment(rawValue: created.body.string ?? ""))
            let createdBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let taskId = try #require((createdBody["taskIds"] as? [String])?.first)
            #expect(fixture.accounts.taskStatusForTesting(taskId: taskId) == "todo")
            let initialRevision = try #require(fixture.accounts.taskRevisionForTesting(taskId: taskId))

            func assign(_ body: String, _ actor: HTTPFields) async throws -> (HTTPResponse.Status, [String: Any]) {
                let response = try await client.send(.patch, headers: actor, to: URI(string: "/api/tasks/\(taskId)/assignee")) { request in
                    request.body = .init(string: body)
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }

            let toOwner = try await assign("{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.ownerId)\"}}", memberHeaders)
            #expect(toOwner.0 == .ok, Comment(rawValue: String(describing: toOwner.1)))
            #expect(fixture.accounts.taskAssigneeForTesting(taskId: taskId) == fixture.ownerId)
            #expect(fixture.accounts.taskStatusForTesting(taskId: taskId) == "todo", "assign must not start the task")
            #expect(fixture.accounts.taskClaimedAtForTesting(taskId: taskId) == nil)
            #expect(fixture.accounts.taskRevisionForTesting(taskId: taskId) == initialRevision + 1)

            let noop = try await assign("{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.ownerId)\"}}", memberHeaders)
            #expect(noop.0 == .ok)
            #expect(fixture.accounts.taskRevisionForTesting(taskId: taskId) == initialRevision + 1, "a no-op must not burn a revision")

            let stale = try await assign("{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.memberId)\"},\"expectedRevision\":\(initialRevision)}", memberHeaders)
            #expect(stale.0 == .conflict)
            #expect(stale.1["currentRevision"] as? Int == initialRevision + 1)

            let outsider = try await assign("{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.outsiderId)\"}}", memberHeaders)
            #expect(outsider.0 == .conflict)
            #expect(fixture.accounts.taskAssigneeForTesting(taskId: taskId) == fixture.ownerId)
            #expect(fixture.accounts.taskRevisionForTesting(taskId: taskId) == initialRevision + 1)

            for malformed in ["{}", "{\"assignee\":{\"type\":\"robot\",\"id\":\"x\"}}", "{\"assignee\":{\"type\":\"user\"}}", "{\"assignee\":null,\"expectedRevision\":1.5}"] {
                let rejected = try await assign(malformed, memberHeaders)
                #expect(rejected.0 == .badRequest, Comment(rawValue: malformed))
            }
            #expect(fixture.accounts.taskRevisionForTesting(taskId: taskId) == initialRevision + 1)

            let agentAssign = try await assign("{\"assignee\":{\"type\":\"agent\",\"id\":\"\(fixture.agentId)\"}}", memberHeaders)
            #expect(agentAssign.0 == .ok)
            #expect(fixture.accounts.taskAssigneeForTesting(taskId: taskId) == fixture.agentId)
            #expect(fixture.accounts.taskStatusForTesting(taskId: taskId) == "todo")

            let withdraw = try await assign("{\"assignee\":null}", memberHeaders)
            #expect(withdraw.0 == .ok)
            #expect(fixture.accounts.taskAssigneeForTesting(taskId: taskId) == nil)
            #expect(fixture.accounts.taskStatusForTesting(taskId: taskId) == "todo")

            let events = fixture.accounts.assigneeChangeEventsForTesting(taskId: taskId)
            #expect(events.count == 3)
            #expect(events[0].previousAssigneeId == nil)
            #expect(events[0].assigneeId == fixture.ownerId)
            #expect(events[1].previousAssigneeId == fixture.ownerId)
            #expect(events[1].assigneeId == fixture.agentId)
            #expect(events[2].previousAssigneeId == fixture.agentId)
            #expect(events[2].assigneeId == nil)

            fixture.accounts.setTaskStatusForTesting(taskId: taskId, status: "done")
            let done = try await assign("{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.memberId)\"}}", memberHeaders)
            #expect(done.0 == .conflict)
            _ = outsiderHeaders
        }
    }
}

@Test func taskClaimStatusUnclaimDeleteAndInReviewUnlock() async throws {
    let fixture = try AssigneeFixture()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let ownerHeaders = headers(fixture, fixture.ownerId)
            let memberHeaders = headers(fixture, fixture.memberId)

            let channel = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/channels")) { request in
                request.body = .init(string: "{\"name\":\"assignee-flow\",\"type\":\"channel\"}")
            }
            let channelBody = try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let channelId = try #require(channelBody["id"] as? String)
            accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.ownerId)
            accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.memberId)
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: fixture.agentId)

            func createTask() async throws -> String {
                let created = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/tasks/channel/\(channelId)")) { request in
                    request.body = .init(string: "{\"tasks\":[{\"title\":\"flow task\"}]}")
                }
                let body = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                return try #require((body["taskIds"] as? [String])?.first)
            }
            func assign(_ taskId: String, _ body: String) async throws -> HTTPResponse.Status {
                let response = try await client.send(.patch, headers: memberHeaders, to: URI(string: "/api/tasks/\(taskId)/assignee")) { request in
                    request.body = .init(string: body)
                }
                return response.status
            }
            func patchTask(_ taskId: String, _ suffix: String, _ body: String?) async throws -> HTTPResponse.Status {
                let path = "/api/tasks/\(taskId)/\(suffix)"
                if let body {
                    let response = try await client.send(.patch, headers: memberHeaders, to: URI(string: path)) { request in
                        request.body = .init(string: body)
                    }
                    return response.status
                }
                return try await client.send(.patch, headers: memberHeaders, to: URI(string: path)).status
            }

            let claimTask = try await createTask()
            #expect(try await patchTask(claimTask, "claim", nil) == .ok)
            #expect(accounts.taskStatusForTesting(taskId: claimTask) == "in_progress")
            #expect(accounts.taskClaimedAtForTesting(taskId: claimTask) != nil)
            #expect(accounts.taskAssigneeForTesting(taskId: claimTask) == fixture.memberId)

            let selfTask = try await createTask()
            #expect(try await assign(selfTask, "{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.memberId)\"}}") == .ok)
            #expect(accounts.taskClaimedAtForTesting(taskId: selfTask) == nil)
            #expect(try await patchTask(selfTask, "status", "{\"status\":\"in_progress\"}") == .ok)
            #expect(accounts.taskStatusForTesting(taskId: selfTask) == "in_progress")
            #expect(accounts.taskClaimedAtForTesting(taskId: selfTask) != nil)
            #expect(accounts.taskAssigneeForTesting(taskId: selfTask) == fixture.memberId)

            let undoTask = try await createTask()
            #expect(try await patchTask(undoTask, "claim", nil) == .ok)
            #expect(try await patchTask(undoTask, "status", "{\"status\":\"todo\"}") == .ok)
            #expect(accounts.taskStatusForTesting(taskId: undoTask) == "todo")
            #expect(accounts.taskAssigneeForTesting(taskId: undoTask) == fixture.memberId)
            #expect(accounts.taskClaimedAtForTesting(taskId: undoTask) == nil)

            let unclaimTask = try await createTask()
            #expect(try await assign(unclaimTask, "{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.ownerId)\"}}") == .ok)
            #expect(try await patchTask(unclaimTask, "unclaim", nil) == .ok)
            #expect(accounts.taskAssigneeForTesting(taskId: unclaimTask) == nil)
            let unclaimEvents = accounts.assigneeChangeEventsForTesting(taskId: unclaimTask)
            let lastUnclaim = try #require(unclaimEvents.last)
            #expect(lastUnclaim.assigneeId == nil)
            #expect(lastUnclaim.previousAssigneeId == fixture.ownerId)
            #expect(lastUnclaim.actorType == "user")
            #expect(lastUnclaim.actorId == fixture.memberId)

            let inReviewTask = try await createTask()
            #expect(try await assign(inReviewTask, "{\"assignee\":{\"type\":\"agent\",\"id\":\"\(fixture.agentId)\"}}") == .ok)
            #expect(try await patchTask(inReviewTask, "status", "{\"status\":\"in_review\"}") == .ok)
            #expect(try await assign(inReviewTask, "{\"assignee\":null}") == .ok)
            #expect(accounts.taskStatusForTesting(taskId: inReviewTask) == "in_review")
            #expect(accounts.taskAssigneeForTesting(taskId: inReviewTask) == nil)
            #expect(try await patchTask(inReviewTask, "claim", nil) == .ok)
            #expect(accounts.taskAssigneeForTesting(taskId: inReviewTask) == fixture.memberId)

            let deleteTask = try await createTask()
            let denied = try await client.send(.delete, headers: memberHeaders, to: URI(string: "/api/tasks/\(deleteTask)"))
            #expect(denied.status == .forbidden)
            #expect(accounts.taskStatusForTesting(taskId: deleteTask) != nil)
        }
    }
}
