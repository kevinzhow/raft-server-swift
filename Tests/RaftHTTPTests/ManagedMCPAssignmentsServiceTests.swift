import Foundation
import Synchronization
import Testing
import TestSupport
@testable import RaftHTTP

/// The assignment service owns the published channel-membership, thread and
/// task replies. The HTTP tests lock status codes and parsed JSON; these tests
/// lock the exact bytes, the typed refusals, and every store critical section
/// the retired handlers used to hold the directory lock for.

private struct AssignmentsFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let memberId: String
    let outsiderId: String
    let ownerToken: String
    let memberToken: String
    let channelId: String
    let agentId: String

    var ownerAuthorization: String { "Bearer \(ownerToken)" }
    var memberAuthorization: String { "Bearer \(memberToken)" }
    var service: ManagedMCPAssignmentsService { accounts.channelAssignments() }
}

private func makeFixture(_ suffix: String) -> AssignmentsFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000997\(suffix)"
    let ownerId = "11111111-1111-4111-8111-000000997\(suffix)"
    let memberId = "11111111-1111-4111-8111-000000998\(suffix)"
    let outsiderId = "11111111-1111-4111-8111-000000999\(suffix)"
    for (id, email) in [
        (ownerId, "assign-owner-\(suffix)@slock.test"),
        (memberId, "assign-member-\(suffix)@slock.test"),
        (outsiderId, "assign-outsider-\(suffix)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "assign-\(suffix)", name: "Assign \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "assign-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "assign-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "atlas-\(suffix)", runtime: "codex")
    return AssignmentsFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        memberId: memberId,
        outsiderId: outsiderId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        channelId: channelId,
        agentId: agentId
    )
}

private func body(_ error: any DomainError) -> String {
    error.publishedErrorBody.render()
}

// MARK: - DTO bytes

@Test func assignmentResponsesRenderThePublishedMemberOrder() {
    #expect(ChannelMembersBatchResponse(
        addedUserIds: ["u1"], addedAgentIds: [], alreadyUserIds: [], alreadyAgentIds: ["a1", "a2"]
    ).jsonBody.render() == """
    {"ok":true,"added":{"userIds":["u1"],"agentIds":[]},"alreadyMembers":{"userIds":[],"agentIds":["a1","a2"]}}
    """)

    #expect(ChannelThreadResponse.existing(
        threadChannelId: "t1", replyCount: 2, lastReplyAt: "2026-01-01T00:00:00Z", participantIds: ["a", "b"]
    ).jsonBody.render() == """
    {"threadChannelId":"t1","replyCount":2,"lastReplyAt":"2026-01-01T00:00:00Z","participantIds":["a","b"]}
    """)
    #expect(ChannelThreadResponse.existing(
        threadChannelId: "t1", replyCount: 0, lastReplyAt: nil, participantIds: []
    ).jsonBody.render() == """
    {"threadChannelId":"t1","replyCount":0,"lastReplyAt":null,"participantIds":[]}
    """)
    #expect(ChannelThreadResponse.created(threadChannelId: "t2", messageId: "m2").jsonBody.render() == """
    {"threadChannelId":"t2","messageId":"m2","replyCount":0,"lastReplyAt":null,"participantIds":[]}
    """)
    #expect(ChannelThreadResponse.created(threadChannelId: "t2", messageId: nil).jsonBody.render() == """
    {"threadChannelId":"t2","messageId":null,"replyCount":0,"lastReplyAt":null,"participantIds":[]}
    """)

    let agent = ChannelAgentRowDTO(id: "a1", name: "Atlas \"One\"", activity: "online", activityDetail: "")
    #expect(ChannelAgentsResponse(agents: [agent]).jsonBody.render() == """
    {"agents":[{"id":"a1","name":"Atlas \\"One\\"","activity":"online","activityDetail":""}]}
    """)
    #expect(ChannelAgentsResponse(agents: []).jsonBody.render() == #"{"agents":[]}"#)

    let humans = [
        ChannelHumanRowDTO(
            id: "h1", name: "Owner", serverRole: "owner", effectiveChannelRole: "admin",
            channelAdminBasis: "server_role", canChangeChannelRole: false
        ),
        ChannelHumanRowDTO(
            id: "h2", name: "Member", serverRole: "member", effectiveChannelRole: "member",
            channelAdminBasis: nil, canChangeChannelRole: true
        ),
    ]
    #expect(ChannelMembersResponse(agents: [agent], humans: humans).jsonBody.render() == """
    {"agents":[{"id":"a1","name":"Atlas \\"One\\"","activity":"online","activityDetail":""}],"humans":[{"id":"h1","name":"Owner","serverRole":"owner","effectiveChannelRole":"admin","channelAdminBasis":"server_role","canChangeChannelRole":false},{"id":"h2","name":"Member","serverRole":"member","effectiveChannelRole":"member","channelAdminBasis":null,"canChangeChannelRole":true}]}
    """)

    #expect(ChannelRoleUpdateResponse(authorityRevision: 3).jsonBody.render() == #"{"ok":true,"authorityRevision":3}"#)
    #expect(TaskConvertResponse(taskIds: ["t1"]).jsonBody.render() == #"{"taskIds":["t1"]}"#)
}

@Test func serverTasksResponseKeepsFragmentsAndPublishesItsByteLength() {
    let plain = ServerTasksResponse(taskFragments: [#"{"id":"1","z":1,"a":2}"#, #"{"id":"2"}"#], paginated: false, nextCursor: nil)
    #expect(plain.jsonBody.render() == #"{"tasks":[{"id":"1","z":1,"a":2},{"id":"2"}]}"#)
    #expect(plain.responseBytes == 45)
    #expect(plain.headers == .standard(extra: ["x-response-bytes": "45"]))

    let more = ServerTasksResponse(taskFragments: [#"{"id":"1"}"#], paginated: true, nextCursor: "abc")
    #expect(more.jsonBody.render() == #"{"tasks":[{"id":"1"}],"next_cursor":"abc"}"#)
    let last = ServerTasksResponse(taskFragments: [], paginated: true, nextCursor: nil)
    #expect(last.jsonBody.render() == #"{"tasks":[],"next_cursor":null}"#)
    let empty = ServerTasksResponse(taskFragments: [], paginated: false, nextCursor: nil)
    #expect(empty.jsonBody.render() == #"{"tasks":[]}"#)
}

// MARK: - Typed refusals

@Test func assignmentRefusalsCarryTheirPublishedStatusAndBody() {
    let plain: [(ManagedMCPAssignmentsError, UInt, String)] = [
        (.unauthorized, 401, #"{"error":"Unauthorized"}"#),
        (.invalidChannelMembers, 400, #"{"error":"Invalid channel members"}"#),
        (.parentMessageIdRequired, 400, #"{"error":"parentMessageId is required"}"#),
        (.parentMessageNotFound, 404, #"{"error":"Parent message not found"}"#),
        (.invalidChannelMember, 400, #"{"error":"Invalid channel member"}"#),
        (.invalidAgent, 400, #"{"error":"Invalid agent"}"#),
        (.invalidMember, 400, #"{"error":"Invalid member"}"#),
        (.jointChannelAdminLimited, 403, #"{"error":"Only a server admin can remove joint channel members","code":"joint_channel_admin_limited"}"#),
        (.invalidChannelRole, 400, #"{"error":"Invalid channel role"}"#),
        (.memberNotFound, 404, #"{"error":"Member not found"}"#),
        (.protectedServerRole, 403, #"{"error":"Server role is managed separately","code":"protected_server_role"}"#),
        (.channelAdminSelfDemote, 409, #"{"error":"A channel admin cannot demote themselves","code":"channel_admin_self_demote_forbidden"}"#),
        (.taskNotFound, 404, #"{"error":"Task not found"}"#),
        (.joinChannelToChangeTasks, 403, #"{"error":"You must join this channel to modify tasks"}"#),
        (.onlyCreatorCanDeleteTask, 403, #"{"error":"Only the task creator can delete it"}"#),
        (.channelDeletedClaimForbidden, 409, #"{"error":"This channel was deleted; the task can only be closed","code":"channel_deleted_terminal_only"}"#),
        (.channelDeletedTerminalOnly, 409, #"{"error":"This channel was deleted; only terminal task statuses are allowed","code":"channel_deleted_terminal_only"}"#),
        (.onlyAssigneeCanReturnToTodo, 409, #"{"error":"Only the current assignee can return this task to todo"}"#),
        (.invalidTaskStatus, 400, #"{"error":"Invalid task status"}"#),
        (.messageNotFound, 404, #"{"error":"Message not found"}"#),
        (.repeatedQueryParameter, 400, #"{"error":"Repeated query parameter"}"#),
        (.detailMustBeFullOrSummary, 400, #"{"error":"detail must be full or summary"}"#),
        (.limitOutOfRange, 400, #"{"error":"limit must be between 1 and 500"}"#),
        (.cursorRequiresLimit, 400, #"{"error":"cursor requires limit"}"#),
        (.invalidCursor, 400, #"{"error":"Invalid cursor"}"#),
    ]
    for (error, status, expected) in plain {
        #expect(error.status == status, "\(error)")
        #expect(body(error) == expected, "\(error)")
    }
    #expect(ManagedMCPAssignmentsError.usersNotInServer(invalidUserIds: ["x", "y"]).status == 400)
    #expect(body(ManagedMCPAssignmentsError.usersNotInServer(invalidUserIds: ["x", "y"])) == """
    {"error":"One or more users are not members of this server","code":"users_not_in_server","invalidUserIds":["x","y"]}
    """)
    // The assistant-channel refusal prints `code` before `error`.
    #expect(ManagedMCPAssignmentsError.assistantChannelForbidden.status == 403)
    #expect(body(ManagedMCPAssignmentsError.assistantChannelForbidden) == """
    {"code":"assistant_channel_forbidden","error":"An assistant can only be in its DM with its owner"}
    """)
}

// MARK: - Request leniency

@Test func assignmentRequestsReadAWrongTypedMemberAsAbsent() throws {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    #expect(try decode(ChannelMembersBatchRequest.self, #"{"userIds":["a",1,"b",null],"agentIds":"x"}"#)
        == ChannelMembersBatchRequest(userIds: ["a", "b"], agentIds: []))
    #expect(try decode(ChannelMemberRequest.self, #"{"agentId":7,"userId":"u"}"#) == ChannelMemberRequest(agentId: nil, userId: "u"))
    #expect(try decode(ChannelThreadRequest.self, #"{"parentMessageId":"p","content":false}"#)
        == ChannelThreadRequest(parentMessageId: "p", content: nil))
    #expect(try decode(ChannelRoleRequest.self, #"{"role":null}"#) == ChannelRoleRequest(role: nil))
    #expect(try decode(TaskStatusRequest.self, #"{"status":["done"]}"#) == TaskStatusRequest(status: nil))
    #expect(try decode(TaskConvertRequest.self, #"{"messageId":"m"}"#) == TaskConvertRequest(messageId: "m"))
    // A body that is not a JSON object does not decode: the route answers its 400/404.
    #expect(throws: (any Error).self) { try decode(TaskStatusRequest.self, "[1]") }
}

// MARK: - Service flows

@Test func batchAddPublishesAddedThenAlreadyMembersAndAnnouncesEach() throws {
    let f = makeFixture("001")
    let service = f.service
    let request = ChannelMembersBatchRequest(userIds: [f.memberId, f.memberId], agentIds: [f.agentId, "no-such-agent"])

    let first = try service.addChannelMembersBatch(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: request
    )
    #expect(first.jsonBody.render() == """
    {"ok":true,"added":{"userIds":["\(f.memberId)"],"agentIds":["\(f.agentId)"]},"alreadyMembers":{"userIds":[],"agentIds":[]}}
    """)
    #expect(f.accounts.systemMessageContents(channelId: f.channelId).count == 2)

    let second = try service.addChannelMembersBatch(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: request
    )
    #expect(second.jsonBody.render() == """
    {"ok":true,"added":{"userIds":[],"agentIds":[]},"alreadyMembers":{"userIds":["\(f.memberId)"],"agentIds":["\(f.agentId)"]}}
    """)
    #expect(f.accounts.systemMessageContents(channelId: f.channelId).count == 2, "already-members are not announced again")
}

@Test func batchAddRefusalsAreTypedAndOrdered() {
    let f = makeFixture("002")
    let service = f.service

    #expect(throws: ChannelMembershipError.self) {
        try service.addChannelMembersBatch(authorization: nil, serverId: f.serverId, channelId: f.channelId, body: .init())
    }
    do {
        _ = try service.addChannelMembersBatch(
            authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: nil
        )
        Issue.record("a body that is not a JSON object must be refused")
    } catch let error as ManagedMCPAssignmentsError {
        #expect(error == .invalidChannelMembers)
    } catch {
        Issue.record("unexpected \(error)")
    }
    do {
        _ = try service.addChannelMembersBatch(
            authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
            body: .init(userIds: [f.memberId, f.outsiderId, "ghost"])
        )
        Issue.record("users outside the server must be refused")
    } catch let error as ManagedMCPAssignmentsError {
        #expect(error == .usersNotInServer(invalidUserIds: [f.outsiderId, "ghost"]))
    } catch {
        Issue.record("unexpected \(error)")
    }
    // The refused batch added nobody.
    #expect(!f.accounts.oauth.channelHumanIds(channelId: f.channelId).contains(f.memberId))
}

@Test func channelRolePatchWritesTheRoleAndBumpsTheAuthorityRevisionTogether() throws {
    let f = makeFixture("003")
    let service = f.service
    f.accounts.oauth.addChannelHuman(channelId: f.channelId, userId: f.memberId)

    let first = try service.updateChannelHumanRole(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
        memberId: f.memberId, body: ChannelRoleRequest(role: "admin")
    )
    #expect(first.jsonBody.render() == #"{"ok":true,"authorityRevision":2}"#)
    #expect(f.accounts.serversAndChannelsStore.channelHumanRole(channelId: f.channelId, userId: f.memberId) == "admin")
    let second = try service.updateChannelHumanRole(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
        memberId: f.memberId, body: ChannelRoleRequest(role: "member")
    )
    #expect(second.jsonBody.render() == #"{"ok":true,"authorityRevision":3}"#)

    for (request, expected) in [
        (ChannelRoleRequest(role: "owner"), ManagedMCPAssignmentsError.invalidChannelRole),
        (ChannelRoleRequest(role: nil), ManagedMCPAssignmentsError.invalidChannelRole),
    ] {
        do {
            _ = try service.updateChannelHumanRole(
                authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
                memberId: f.memberId, body: request
            )
            Issue.record("an invalid role must be refused")
        } catch let error as ManagedMCPAssignmentsError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
    #expect(f.accounts.serversAndChannelsStore.channelAuthorityRevision(channelId: f.channelId) == 3, "a refusal writes nothing")
}

@Test func threadCreationIsIdempotentPerParentMessage() throws {
    let f = makeFixture("004")
    let service = f.service
    let parent = f.accounts.addChannelMessageForTesting(channelId: f.channelId, content: "parent", senderId: f.ownerId)

    let created = try service.createThreadFromChannel(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
        body: ChannelThreadRequest(parentMessageId: parent, content: "first reply")
    )
    guard case .created(let threadId, let messageId) = created else {
        Issue.record("the first call creates the thread")
        return
    }
    #expect(messageId != nil)
    #expect(created.jsonBody.render() == """
    {"threadChannelId":"\(threadId)","messageId":"\(messageId ?? "")","replyCount":0,"lastReplyAt":null,"participantIds":[]}
    """)
    // The creator follows the thread.
    #expect(f.accounts.messagesAndThreadsStore.threadFollows["\(f.serverId)\n\(f.ownerId)\n\(threadId)"] != nil)

    let again = try service.createThreadFromChannel(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
        body: ChannelThreadRequest(parentMessageId: parent, content: "ignored")
    )
    guard case .existing(let existingId, let replyCount, _, let participants) = again else {
        Issue.record("the second call reuses the thread")
        return
    }
    #expect(existingId == threadId)
    #expect(replyCount == 1)
    #expect(participants == [f.ownerId])

    do {
        _ = try service.createThreadFromChannel(
            authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
            body: ChannelThreadRequest(parentMessageId: "nope")
        )
        Issue.record("an unknown parent must be refused")
    } catch let error as ManagedMCPAssignmentsError {
        #expect(error == .parentMessageNotFound)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func taskRoutesRefuseInTheirPublishedOrder() throws {
    let f = makeFixture("005")
    let service = f.service
    let ids = f.accounts.taskCatalog.addTasks(channelId: f.channelId, titles: ["one"], creatorId: f.ownerId)
    let taskId = try #require(ids.first)

    func expect(_ expected: ManagedMCPAssignmentsError, _ block: () throws -> Void) {
        do {
            try block()
            Issue.record("expected \(expected)")
        } catch let error as ManagedMCPAssignmentsError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
    expect(.unauthorized) { _ = try service.claimTask(authorization: nil, serverId: f.serverId, taskId: taskId) }
    expect(.taskNotFound) { _ = try service.claimTask(authorization: f.ownerAuthorization, serverId: f.serverId, taskId: "ghost") }
    expect(.invalidTaskStatus) {
        _ = try service.updateTaskStatus(
            authorization: f.ownerAuthorization, serverId: f.serverId, taskId: taskId, body: TaskStatusRequest(status: "weird")
        )
    }
    expect(.invalidTaskStatus) {
        _ = try service.updateTaskStatus(authorization: f.ownerAuthorization, serverId: f.serverId, taskId: taskId, body: nil)
    }
    expect(.messageNotFound) {
        _ = try service.convertMessageToTask(authorization: f.ownerAuthorization, serverId: f.serverId, body: nil)
    }
    expect(.messageNotFound) {
        _ = try service.convertMessageToTask(
            authorization: f.ownerAuthorization, serverId: f.serverId, body: TaskConvertRequest(messageId: "ghost")
        )
    }

    let claimed = try service.claimTask(authorization: f.ownerAuthorization, serverId: f.serverId, taskId: taskId)
    #expect(claimed.task.status == "in_progress")
    #expect(claimed.task.claimedById == f.ownerId)
    #expect(claimed.task.revision == 1)
    expect(.onlyAssigneeCanReturnToTodo) {
        f.accounts.oauth.addChannelHuman(channelId: f.channelId, userId: f.memberId)
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: f.channelId, memberId: f.memberId, name: "assign-005")
        _ = try service.updateTaskStatus(
            authorization: f.memberAuthorization, serverId: f.serverId, taskId: taskId, body: TaskStatusRequest(status: "todo")
        )
    }
    let unclaimed = try service.unclaimTask(authorization: f.ownerAuthorization, serverId: f.serverId, taskId: taskId)
    #expect(unclaimed.task.claimedById == nil)
    #expect(unclaimed.task.revision == 2)
    #expect(f.accounts.tasksAndRemindersStore.assigneeChangeEvents.count == 1)

    let converted = try service.convertMessageToTask(
        authorization: f.ownerAuthorization, serverId: f.serverId,
        body: TaskConvertRequest(messageId: f.accounts.addChannelMessageForTesting(
            channelId: f.channelId, content: "make me a task", senderId: f.ownerId
        ))
    )
    #expect(converted.task.id != converted.task.messageId)
    let convertedObject = try #require(try JSONSerialization.jsonObject(with: Data(converted.jsonBody.render().utf8)) as? [String: Any])
    #expect(Set(convertedObject.keys) == ["task"])
    let convertedTask = try #require(f.accounts.tasksAndRemindersStore.task(id: converted.task.id))
    #expect(convertedTask.title == "make me a task")
    #expect(convertedTask.taskNumber == 2)
    #expect(convertedTask.creatorId == f.ownerId)

    #expect(try service.deleteTask(authorization: f.ownerAuthorization, serverId: f.serverId, taskId: taskId) == OkResponse())
    #expect(f.accounts.tasksAndRemindersStore.task(id: taskId) == nil)
}

@Test func serverTaskListValidatesQueryBeforeReadingAndPublishesPages() throws {
    let f = makeFixture("006")
    let service = f.service
    _ = f.accounts.taskCatalog.addTasks(channelId: f.channelId, titles: ["a", "b", "c"], creatorId: f.ownerId)

    func refusal(_ query: String?) -> ManagedMCPAssignmentsError? {
        do {
            _ = try service.listServerTasks(authorization: f.ownerAuthorization, serverId: f.serverId, rawQuery: query)
            return nil
        } catch let error as ManagedMCPAssignmentsError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }
    #expect(refusal("limit=1&limit=2") == .repeatedQueryParameter)
    #expect(refusal("detail=nope") == .detailMustBeFullOrSummary)
    #expect(refusal("limit=0") == .limitOutOfRange)
    #expect(refusal("limit=501") == .limitOutOfRange)
    #expect(refusal("cursor=abc") == .cursorRequiresLimit)
    #expect(refusal("limit=1&cursor=!!") == .invalidCursor)

    let legacy = try service.listServerTasks(authorization: f.ownerAuthorization, serverId: f.serverId, rawQuery: nil)
    #expect(!legacy.paginated)
    #expect(legacy.taskFragments.count == 3)
    #expect(legacy.jsonBody.render().hasPrefix(#"{"tasks":["#))

    let page = try service.listServerTasks(authorization: f.ownerAuthorization, serverId: f.serverId, rawQuery: "limit=2&detail=summary")
    #expect(page.paginated)
    #expect(page.taskFragments.count == 2)
    let cursor = try #require(page.nextCursor)
    let rest = try service.listServerTasks(
        authorization: f.ownerAuthorization, serverId: f.serverId, rawQuery: "limit=2&cursor=\(cursor)"
    )
    #expect(rest.taskFragments.count == 1)
    #expect(rest.nextCursor == nil)
    #expect(rest.jsonBody.render().hasSuffix(#""next_cursor":null}"#))
}

@Test func memberRosterRendersThePublishedRows() throws {
    let f = makeFixture("007")
    let service = f.service
    f.accounts.oauth.addChannelAgent(channelId: f.channelId, agentId: f.agentId)
    f.accounts.oauth.addChannelHuman(channelId: f.channelId, userId: f.memberId)

    let members = try service.channelMembers(authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId)
    let rendered = members.jsonBody.render()
    #expect(rendered.hasPrefix(#"{"agents":[{"id":"\#(f.agentId)","name":"atlas-007","activity":"offline","activityDetail":""}],"humans":["#))
    #expect(rendered.contains(#""serverRole":"owner","effectiveChannelRole":"admin","channelAdminBasis":"server_role","canChangeChannelRole":false"#))
    #expect(rendered.contains(#""serverRole":"member","effectiveChannelRole":"member","channelAdminBasis":null,"canChangeChannelRole":true"#))

    let agents = try service.channelAgents(authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId)
    #expect(agents.jsonBody.render() == """
    {"agents":[{"id":"\(f.agentId)","name":"atlas-007","activity":"offline","activityDetail":""}]}
    """)
}

// MARK: - Atomic store sections

@Test func concurrentClaimsAdmitOneOwnerWithoutStealing() {
    let store = TasksAndRemindersStore()
    let channels = ServersAndChannelsStore()
    channels.addPostableChannel(serverId: "s", channelId: "c", memberId: "owner")
    let channelDeletion = TaskChannelDeletionQuery(channels: channels)
    let ids = store.appendTasks(channelId: "c", titles: ["t"], descriptions: nil, creatorId: "owner")
    let taskId = ids[0]
    let writers = 64
    DispatchQueue.concurrentPerform(iterations: writers) { index in
        _ = store.claimForUser(taskId: taskId, userId: "user-\(index)", channelDeletion: channelDeletion, now: Date())
    }
    let task = store.task(id: taskId)
    #expect(task?.revision == 1, "one claim wins; rejected contenders do not steal or burn revisions")
    #expect(task?.status == "in_progress")
    #expect(task?.assigneeType == "user")
    #expect(task?.claimedAt != nil)
}

@Test func claimRefusesADeletedChannelWithoutWriting() {
    let store = TasksAndRemindersStore()
    let channels = ServersAndChannelsStore()
    channels.addPostableChannel(serverId: "s", channelId: "c", memberId: "owner")
    channels.markChannelDeleted(channelId: "c", now: Date())
    let channelDeletion = TaskChannelDeletionQuery(channels: channels)
    let taskId = store.appendTasks(channelId: "c", titles: ["t"], descriptions: nil, creatorId: "owner")[0]
    switch store.claimForUser(taskId: taskId, userId: "u", channelDeletion: channelDeletion, now: Date()) {
    case .channelDeleted: break
    default: Issue.record("a deleted channel refuses the claim")
    }
    switch store.claimForUser(taskId: "ghost", userId: "u", channelDeletion: channelDeletion, now: Date()) {
    case .notFound: break
    default: Issue.record("an unknown task is not found")
    }
    let task = store.task(id: taskId)
    #expect(task?.revision == 0)
    #expect(task?.assigneeId == nil)
    #expect(task?.assigneeType == nil)
    #expect(task?.claimedAt == nil)
    #expect(task?.updatedAt == nil)
    #expect(task?.completedAt == nil)
    #expect(task?.closedAt == nil)
    #expect(task?.status == "todo")
    #expect(store.taskEvents.isEmpty)
    #expect(store.assigneeChangeEvents.isEmpty)
}

@Test func taskDeletionQueriesUseTheLiveOwnerAndPreserveMissingAndArchivedRows() {
    let store = TasksAndRemindersStore()
    let channels = ServersAndChannelsStore()
    channels.addPostableChannel(serverId: "s", channelId: "c", memberId: "u")
    let channelDeletion = TaskChannelDeletionQuery(channels: channels)
    let taskId = store.appendTasks(channelId: "c", titles: ["live owner"], descriptions: nil, creatorId: "u")[0]
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    switch store.claimForUser(taskId: taskId, userId: "u", channelDeletion: channelDeletion, now: now) {
    case .claimed(let task):
        #expect(task.status == "in_progress")
        #expect(task.claimedAt == now)
        #expect(task.revision == 1)
    default: Issue.record("the actual live channel allows the claim")
    }

    channels.markChannelDeleted(channelId: "c", now: now)
    switch store.claimForUser(taskId: taskId, userId: "other", channelDeletion: channelDeletion, now: now.addingTimeInterval(1)) {
    case .channelDeleted: break
    default: Issue.record("the same query must see a deletion committed after its construction")
    }
    switch store.applyHumanStatus(taskId: taskId, status: "todo", userId: "other", channelDeletion: channelDeletion, now: now) {
    case .channelDeletedTerminalOnly: break
    default: Issue.record("the deletion refusal keeps its precedence over the assignee refusal")
    }
    #expect(store.task(id: taskId)?.assigneeId == "u")
    #expect(store.task(id: taskId)?.claimedAt == now)
    #expect(store.task(id: taskId)?.status == "in_progress")
    #expect(store.task(id: taskId)?.revision == 1)
    #expect(store.taskEvents.isEmpty)
    #expect(store.assigneeChangeEvents.isEmpty)
    switch store.applyHumanStatus(taskId: taskId, status: "done", userId: "u", channelDeletion: channelDeletion, now: now) {
    case .updated(let task):
        #expect(task.completedAt == now)
        #expect(task.claimedAt == now)
        #expect(task.revision == 2)
    default: Issue.record("a deleted channel still permits a terminal transition")
    }

    channels.addPostableChannel(serverId: "s", channelId: "archived", memberId: "u")
    channels.setArchivedFlag(channelId: "archived", archived: true)
    for channelId in ["missing", "archived"] {
        let id = store.appendTasks(channelId: channelId, titles: [channelId], descriptions: nil, creatorId: "u")[0]
        switch store.claimForUser(taskId: id, userId: "u", channelDeletion: channelDeletion, now: now) {
        case .claimed(let task):
            #expect(task.status == "in_progress")
            #expect(task.revision == 1)
        default: Issue.record("missing rows and archived rows are not soft-deleted channels")
        }
    }
}

@Test func concurrentUnclaimsRecordOnlyTheSuccessfulClear() {
    let store = TasksAndRemindersStore()
    let channels = ServersAndChannelsStore()
    channels.addPostableChannel(serverId: "s", channelId: "c", memberId: "owner")
    let channelDeletion = TaskChannelDeletionQuery(channels: channels)
    let taskId = store.appendTasks(channelId: "c", titles: ["t"], descriptions: nil, creatorId: "owner")[0]
    _ = store.claimForUser(taskId: taskId, userId: "first", channelDeletion: channelDeletion, now: Date())
    let writers = 48
    DispatchQueue.concurrentPerform(iterations: writers) { index in
        _ = store.unclaimForUser(taskId: taskId, userId: "user-\(index)")
    }
    let task = store.task(id: taskId)
    #expect(task?.revision == 2)
    #expect(task?.assigneeId == nil)
    #expect(store.assigneeChangeEvents.count == 1, "the one real clear and its event are one section")
    #expect(store.assigneeChangeEvents.filter { $0.previousAssigneeId == "first" }.count == 1)
}

@Test func humanStatusWriteAppliesStampsAndRefusalsInOneSection() {
    let store = TasksAndRemindersStore()
    let channels = ServersAndChannelsStore()
    channels.addPostableChannel(serverId: "s", channelId: "c", memberId: "owner")
    let channelDeletion = TaskChannelDeletionQuery(channels: channels)
    let deletedChannels = ServersAndChannelsStore()
    deletedChannels.addPostableChannel(serverId: "s", channelId: "c", memberId: "owner")
    deletedChannels.markChannelDeleted(channelId: "c", now: Date())
    let deletedChannelQuery = TaskChannelDeletionQuery(channels: deletedChannels)
    let taskId = store.appendTasks(channelId: "c", titles: ["t"], descriptions: nil, creatorId: "owner")[0]
    let now = Date(timeIntervalSince1970: 1_767_225_600)

    switch store.applyHumanStatus(taskId: taskId, status: "in_progress", userId: "u", channelDeletion: channelDeletion, now: now) {
    case .updated(let task):
        #expect(task.claimedAt == now)
        #expect(task.revision == 1)
    default: Issue.record("in_progress is applied")
    }
    switch store.applyHumanStatus(taskId: taskId, status: "todo", userId: "other", channelDeletion: channelDeletion, now: now) {
    case .onlyAssigneeCanReturnToTodo: break
    default: Issue.record("only the assignee returns an in-progress task to todo")
    }
    switch store.applyHumanStatus(taskId: taskId, status: "in_review", userId: "u", channelDeletion: deletedChannelQuery, now: now) {
    case .channelDeletedTerminalOnly: break
    default: Issue.record("a deleted channel only takes terminal statuses")
    }
    #expect(store.task(id: taskId)?.revision == 1, "refusals write nothing")
    switch store.applyHumanStatus(taskId: taskId, status: "done", userId: "u", channelDeletion: deletedChannelQuery, now: now) {
    case .updated(let task):
        #expect(task.completedAt == now)
        #expect(task.revision == 2)
    default: Issue.record("done is terminal")
    }
    switch store.applyHumanStatus(taskId: taskId, status: "closed", userId: "u", channelDeletion: channelDeletion, now: now) {
    case .updated(let task): #expect(task.closedAt == now)
    default: Issue.record("closed is applied")
    }
    switch store.applyHumanStatus(taskId: "ghost", status: "done", userId: "u", channelDeletion: channelDeletion, now: now) {
    case .notFound: break
    default: Issue.record("an unknown task is not found")
    }
}

@Test func concurrentConversionsNumberTasksWithoutGaps() {
    let store = TasksAndRemindersStore()
    let writers = 64
    DispatchQueue.concurrentPerform(iterations: writers) { index in
        _ = store.appendConvertedMessageTask(channelId: "c", messageId: "m-\(index)",
            title: "conversion-\(index)", creatorId: "u", legacyMessageMaxNumber: 0,
            now: Date(timeIntervalSince1970: 0))
    }
    let rows = store.taskRecords
    #expect(rows.count == writers)
    #expect(rows.map(\.taskNumber).sorted() == Array(1...writers), "the number scan and the append are one section")
    #expect(Set(rows.map(\.id)).count == writers)
    #expect(Set(rows.map(\.messageId)) == Set((0..<writers).map { "m-\($0)" }))
}

@Test func removeTaskDropsExactlyTheNamedRow() {
    let store = TasksAndRemindersStore()
    let ids = store.appendTasks(channelId: "c", titles: ["a", "b", "c"], descriptions: nil, creatorId: nil)
    #expect(store.removeTask(id: ids[1])?.title == "b")
    #expect(store.removeTask(id: ids[1]) == nil)
    #expect(store.taskRecords.map(\.title) == ["a", "c"])
}

@Test func concurrentThreadCreationForOneParentCreatesOneThread() throws {
    let channels = ServersAndChannelsStore()
    let oauth = OAuthLedger()
    oauth.addOwnedServer(id: "s", slug: "thread-once", name: "Thread Once", ownerId: "u-0")
    let threadChannels = ThreadChannelCommand(oauth: oauth)
    let parent = oauth.createChannel(serverId: "s", name: "parent", creatorUserId: "u-0")
    channels.addPostableChannel(serverId: "s", channelId: parent, memberId: "u-0")
    let outcomes = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 32) { index in
        let outcome = channels.findOrCreateThread(
            serverId: "s", parentChannelId: parent, parentMessageId: "m", creatorId: "u-\(index)",
            threadChannels: threadChannels
        )
        switch outcome {
        case .created(let id): outcomes.withLock { $0.append("created:\(id)") }
        case .existing(let id): outcomes.withLock { $0.append("existing:\(id)") }
        }
    }
    let rows = oauth.state.withLock { state in
        state.channelRecords.filter {
            $0.type == "thread" && $0.parentChannelId == parent && $0.parentMessageId == "m"
        }
    }
    #expect(rows.count == 1, "the lookup and the actual OAuth creation are one section")
    let row = try #require(rows.first)
    #expect(row.serverId == "s")
    #expect(row.parentChannelId == parent)
    #expect(row.parentMessageId == "m")
    #expect(row.name == "")
    let all = outcomes.withLock { $0 }
    #expect(all.count == 32)
    #expect(all.filter { $0.hasPrefix("created:") }.count == 1)
    #expect(Set(all.map { $0.split(separator: ":")[1] }).count == 1)
    #expect(Set(all.map { String($0.split(separator: ":")[1]) }) == [row.id])
    #expect(channels.threadOrder == [row.id])
    let local = try #require(channels.postableChannel(id: row.id))
    #expect(local.serverId == "s")
    #expect(local.kind == "thread")
    #expect(local.name == "thread")
    #expect(local.parentChannelId == parent)
    #expect(local.parentMessageId == "m")
    #expect(local.memberIds.count == 1)
    #expect(local.memberIds.isSubset(of: Set((0..<32).map { "u-\($0)" })))

    let deletion = channels.softDeleteChannel(
        channelId: row.id, serverId: "s", userId: "u-0", memberRole: "owner", now: Date()
    )
    #expect(deletion == .deleted)
    let replacement = channels.findOrCreateThread(
        serverId: "s", parentChannelId: parent, parentMessageId: "m", creatorId: "u-0",
        threadChannels: threadChannels
    )
    guard case .created(let replacementId) = replacement else {
        Issue.record("normal thread creation must skip the soft-deleted row")
        return
    }
    #expect(replacementId != row.id)
    #expect(channels.threadOrder == [row.id, replacementId])
    let remaining = oauth.state.withLock { state in
        state.channelRecords.filter {
            $0.type == "thread" && $0.parentChannelId == parent && $0.parentMessageId == "m"
        }
    }
    #expect(Set(remaining.map(\.id)) == [row.id, replacementId])
    #expect(remaining.allSatisfy { $0.parentChannelId == parent && $0.parentMessageId == "m" })
    channels.mutex.withLock { $0.postableChannels[replacementId]?.serverId = "server-2" }
    let matchingServer = channels.findOrCreateThread(
        serverId: "s", parentChannelId: parent, parentMessageId: "m", creatorId: "u-0",
        threadChannels: threadChannels
    )
    guard case .created(let matchingId) = matchingServer else {
        Issue.record("normal thread creation must skip a row from another server")
        return
    }
    #expect(matchingId != replacementId)
    #expect(channels.postableChannel(id: matchingId)?.serverId == "s")
    #expect(oauth.channelServerId(channelId: matchingId) == "s")
    #expect(channels.threadOrder == [row.id, replacementId, matchingId])
    let finalIds = oauth.state.withLock { state in
        state.channelRecords.filter { $0.parentChannelId == parent && $0.parentMessageId == "m" }.map(\.id)
    }
    #expect(Set(finalIds) == [row.id, replacementId, matchingId])
}

@Test func concurrentChannelRoleWritesBumpTheRevisionOncePerWrite() {
    let channels = ServersAndChannelsStore()
    let writers = 64
    let revisions = Mutex<[Int]>([])
    DispatchQueue.concurrentPerform(iterations: writers) { index in
        let revision = channels.setChannelHumanRole(channelId: "c", memberId: "m-\(index)", role: "admin")
        revisions.withLock { $0.append(revision) }
    }
    #expect(revisions.withLock { $0 }.sorted() == Array(2...(writers + 1)), "each write sees a distinct revision")
    #expect(channels.channelAuthorityRevision(channelId: "c") == writers + 1)
    #expect(channels.channelAuthorityRevision(channelId: "never-changed") == 1)
}

@Test func postableMemberWritesCreateTheRowOnceAndRemoveByMember() {
    let channels = ServersAndChannelsStore()
    channels.insertPostableMember(serverId: "s", channelId: "c", memberId: "a")
    channels.insertPostableMember(serverId: "s", channelId: "c", memberId: "b")
    #expect(channels.postableChannel(id: "c")?.memberIds == ["a", "b"])
    #expect(channels.postableChannel(id: "c")?.serverId == "s")
    channels.removePostableMember(channelId: "c", memberId: "a")
    #expect(channels.postableChannel(id: "c")?.memberIds == ["b"])
    channels.removePostableMember(channelId: "missing", memberId: "a")
    #expect(channels.postableChannel(id: "missing") == nil)
}

@Test func concurrentAgentReadAllsAdvanceTheCursorAndVersionTogether() {
    let messages = MessagesAndThreadsStore()
    let writers = 64
    let advances = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: writers) { index in
        let result = messages.advanceAgentChannelRead(channelId: "c", agentId: "a", latestSeq: index + 1)
        if result.advanced { advances.withLock { $0 += 1 } }
    }
    let advanced = advances.withLock { $0 }
    #expect(messages.agentChannelReadSeq(channelId: "c", agentId: "a") == writers)
    #expect(messages.agentChannelReadCursors["c\na"]?.version == advanced, "one version bump per real advance")
    let stale = messages.advanceAgentChannelRead(channelId: "c", agentId: "a", latestSeq: 1)
    #expect(stale == MessagesAndThreadsStore.AgentReadAdvance(seq: writers, version: advanced, advanced: false))
}

@Test func channelReadCompareAndBumpIsOneSection() {
    let messages = MessagesAndThreadsStore()
    let frontier = Mutex(0)
    let first = messages.advanceChannelRead(channelId: "c", userId: "u", seq: 5, maxReadSeq: { frontier.withLock { $0 } })
    #expect(first == .advanced(version: 1))
    frontier.withLock { $0 = 5 }
    let covered = messages.advanceChannelRead(channelId: "c", userId: "u", seq: 5, maxReadSeq: { frontier.withLock { $0 } })
    #expect(covered == .unchanged(maxReadSeq: 5, version: 1))
    #expect(messages.channelReadVersion(channelId: "c", userId: "u") == 1)
    #expect(messages.bumpChannelReadVersion(channelId: "c", userId: "u") == 2)

    let writers = 48
    DispatchQueue.concurrentPerform(iterations: writers) { _ in
        _ = messages.markInboxScopeDone(channelId: "c2", userId: "u", at: Date())
    }
    #expect(messages.channelReadVersion(channelId: "c2", userId: "u") == writers)
}

@Test func followCreatedThreadWritesCreatorAndParentAuthorTogether() {
    let messages = MessagesAndThreadsStore()
    messages.followCreatedThread(serverId: "s", userId: "creator", threadChannelId: "t", parentMessageId: "m", parentAuthorId: "author")
    #expect(messages.threadFollows["s\ncreator\nt"]?.parentMessageId == "m")
    #expect(messages.threadFollows["s\nauthor\nt"]?.parentMessageId == "m")
    messages.followCreatedThread(serverId: "s", userId: "creator", threadChannelId: "t2", parentMessageId: "m2", parentAuthorId: nil)
    #expect(messages.threadFollows.count == 3)
}
