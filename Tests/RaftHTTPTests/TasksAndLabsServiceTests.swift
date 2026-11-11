import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The service/store contract behind the server task, channel membership and
/// agent channel management routes. The HTTP byte tests lock the wire shape;
/// these lock the single critical section each decision now runs in.

private func tasksFixture(slug: String, suffix: String) -> (
    directory: EmailLoginDirectory, ownerId: String, serverId: String, channelId: String
) {
    let directory = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-00000121\(suffix)"
    let serverId = "33333333-3333-4333-8333-00000121\(suffix)"
    directory.addAccount(id: ownerId, email: "\(slug)@slock.test", password: "password123")
    directory.markEmailVerified(userId: ownerId)
    directory.oauth.addOwnedServer(id: serverId, slug: slug, name: slug, ownerId: ownerId)
    let channelId = directory.oauth.createChannel(serverId: serverId, name: slug, creatorUserId: ownerId)
    directory.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: slug)
    directory.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    return (directory, ownerId, serverId, channelId)
}

@Test func assigneeWriteAcceptsExactlyOneConcurrentExpectedRevision() async {
    let fixture = tasksFixture(slug: "tl-occ", suffix: "0001")
    let store = fixture.directory.tasksAndRemindersStore
    let taskId = fixture.directory.taskCatalog.addTasks(channelId: fixture.channelId, titles: ["occ"]).first ?? ""

    let outcomes = await withTaskGroup(of: TasksAndRemindersStore.ReassignOutcome.self) { group in
        for writer in 0..<8 {
            group.addTask {
                store.reassign(
                    taskId: taskId,
                    assigneeId: "assignee-\(writer)",
                    assigneeType: "user",
                    expectedRevision: 0,
                    actorId: fixture.ownerId
                )
            }
        }
        var collected: [TasksAndRemindersStore.ReassignOutcome] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }

    let reassigned = outcomes.filter { if case .reassigned = $0 { return true } else { return false } }
    let conflicts = outcomes.filter {
        if case .conflict(let current) = $0 { return current == 1 } else { return false }
    }
    #expect(reassigned.count == 1)
    #expect(conflicts.count == 7)
    #expect(store.assigneeChangeEvents.count == 1)
    #expect(store.task(id: taskId)?.revision == 1)
}

@Test func assigneeWriteDecidesDoneUnchangedAndMissingInOneSection() {
    let fixture = tasksFixture(slug: "tl-outcomes", suffix: "0002")
    let store = fixture.directory.tasksAndRemindersStore
    let ids = fixture.directory.taskCatalog.addTasks(channelId: fixture.channelId, titles: ["a", "b"])

    // Clearing an unassigned task is the unchanged short circuit: no revision bump, no event.
    if case .unchanged(let task) = store.reassign(
        taskId: ids[0], assigneeId: nil, assigneeType: nil, expectedRevision: nil, actorId: fixture.ownerId
    ) {
        #expect(task.revision == 0)
    } else {
        Issue.record("expected the unchanged outcome")
    }
    #expect(store.assigneeChangeEvents.isEmpty)

    var rows = store.taskRecords
    rows[1].status = "done"
    store.taskRecords = rows
    if case .done = store.reassign(
        taskId: ids[1], assigneeId: "x", assigneeType: "user", expectedRevision: 99, actorId: fixture.ownerId
    ) {
    } else {
        Issue.record("a done task is refused before the revision check")
    }
    if case .notFound = store.reassign(
        taskId: "missing", assigneeId: "x", assigneeType: "user", expectedRevision: nil, actorId: fixture.ownerId
    ) {
    } else {
        Issue.record("expected the not-found outcome")
    }
}

@Test func amendWriteIsOneCriticalSectionPerRow() async {
    let fixture = tasksFixture(slug: "tl-amend", suffix: "0003")
    let store = fixture.directory.tasksAndRemindersStore
    _ = fixture.directory.taskCatalog.addTasks(channelId: fixture.channelId, titles: ["first"])

    await withTaskGroup(of: Void.self) { group in
        for writer in 0..<16 {
            group.addTask {
                _ = store.amendTask(
                    channelId: fixture.channelId,
                    taskNumber: 1,
                    title: "amended-\(writer)",
                    description: nil,
                    actorId: "bot-id",
                    amendedByName: "bot",
                    now: Date()
                )
            }
        }
    }

    let task = store.task(channelId: fixture.channelId, taskNumber: 1)
    #expect(task?.revision == 16)
    #expect(task?.superseded == true)
    #expect(task?.amendedByType == "agent")
    #expect(store.amendTask(
        channelId: fixture.channelId, taskNumber: 9, title: "x", description: nil,
        actorId: "bot-id", amendedByName: "bot", now: Date()
    ) == nil)
}

@Test func taskStatusFilterKeepsTheLegacyQueryRules() {
    #expect(TasksAndLabsService.statusFilter(nil) == .valid(nil))
    #expect(TasksAndLabsService.statusFilter("other=1") == .valid(nil))
    #expect(TasksAndLabsService.statusFilter("status=done") == .valid("done"))
    #expect(TasksAndLabsService.statusFilter("status=in_progress&x=1") == .valid("in_progress"))
    #expect(TasksAndLabsService.statusFilter("status=done&status=todo") == .invalid)
    #expect(TasksAndLabsService.statusFilter("status=bogus") == .invalid)
}

@Test func channelArchiveCascadesToThreadsInOneSection() {
    let fixture = tasksFixture(slug: "tl-archive", suffix: "0004")
    let store = fixture.directory.serversAndChannelsStore
    let threadId = "44444444-4444-4444-8444-000001210004"
    store.addThreadChannel(
        serverId: fixture.serverId, threadChannelId: threadId, parentChannelId: fixture.channelId,
        parentMessageId: "message", memberId: fixture.ownerId
    )

    store.setArchived(channelId: fixture.channelId, archived: true)
    #expect(store.postableChannel(id: fixture.channelId)?.archived == true)
    #expect(store.postableChannel(id: threadId)?.archived == true)
    store.setArchived(channelId: fixture.channelId, archived: false)
    #expect(store.postableChannel(id: fixture.channelId)?.archived == false)
    #expect(store.postableChannel(id: threadId)?.archived == false)

    // The single-projection flag leaves the thread alone.
    store.setArchivedFlag(channelId: fixture.channelId, archived: true)
    #expect(store.postableChannel(id: threadId)?.archived == false)
}

@Test func bornReadCursorAdvancesMonotonicallyUnderContention() async {
    let fixture = tasksFixture(slug: "tl-cursor", suffix: "0005")
    let store = fixture.directory.messagesAndThreadsStore

    await withTaskGroup(of: Void.self) { group in
        for seq in 1...40 {
            group.addTask {
                store.markBornRead(channelId: fixture.channelId, agentId: "agent", seq: seq)
            }
        }
    }

    let cursor = store.agentChannelReadCursors["\(fixture.channelId)\nagent"]
    #expect(cursor?.seq == 40)
    #expect(cursor?.version == 40)
}

@Test func agentJoinPostsABornReadNoticeForTheJoiningAgent() throws {
    let fixture = tasksFixture(slug: "tl-join", suffix: "0006")
    let directory = fixture.directory
    let agentId = directory.oauth.createAgent(
        serverId: fixture.serverId, name: "JoinBot", creatorUserId: fixture.ownerId, runtime: "claude"
    )

    _ = try directory.channelMembership.joinPublicChannel(
        agentId: agentId, serverId: fixture.serverId, channelId: fixture.channelId
    )

    let notices = directory.messagesAndThreadsStore.humanMessageRows.filter {
        $0.channelId == fixture.channelId && $0.messageType == "system"
    }
    #expect(notices.map(\.content) == ["@JoinBot joined this channel."])
    let cursor = directory.messagesAndThreadsStore.agentChannelReadCursors["\(fixture.channelId)\n\(agentId)"]
    #expect(cursor?.seq == notices.first?.seq)
    #expect(cursor?.version == 1)

    // A second join is the idempotent no-op: no second notice.
    _ = try directory.channelMembership.joinPublicChannel(
        agentId: agentId, serverId: fixture.serverId, channelId: fixture.channelId
    )
    #expect(directory.messagesAndThreadsStore.humanMessageRows.filter {
        $0.channelId == fixture.channelId && $0.messageType == "system"
    }.count == 1)
}

@Test func agentLeaveSoftDeletesAnEmptiedPrivateChannel() throws {
    let fixture = tasksFixture(slug: "tl-leave", suffix: "0007")
    let directory = fixture.directory
    let agentId = directory.oauth.createAgent(
        serverId: fixture.serverId, name: "LeaveBot", creatorUserId: fixture.ownerId, runtime: "claude"
    )
    let privateId = directory.oauth.createChannel(
        serverId: fixture.serverId, name: "tl-leave-private", creatorUserId: fixture.ownerId, type: "private"
    )
    directory.addPostableChannel(
        serverId: fixture.serverId, channelId: privateId, memberId: agentId, kind: "private", name: "tl-leave-private"
    )
    directory.oauth.removeChannelHuman(channelId: privateId, userId: fixture.ownerId)
    directory.oauth.addChannelAgent(channelId: privateId, agentId: agentId)

    _ = try directory.channelMembership.leaveChannel(
        agentId: agentId, serverId: fixture.serverId, channelId: privateId
    )

    let row = directory.serversAndChannelsStore.postableChannel(id: privateId)
    #expect(row?.deletedAt != nil)
    #expect(row?.memberIds.contains(agentId) == false)

    // The virtual #all audience cannot be left.
    if let allChannel = directory.oauth.allChannelId(serverId: fixture.serverId) {
        #expect(throws: ChannelMembershipError.cannotLeaveAllChannel) {
            try directory.channelMembership.leaveChannel(
                agentId: agentId, serverId: fixture.serverId, channelId: allChannel
            )
        }
    }
}

@Test func agentMemberWriteAddsOnceAndReportsTheRepeat() throws {
    let fixture = tasksFixture(slug: "tl-member", suffix: "0008")
    let directory = fixture.directory
    let agentId = directory.oauth.createAgent(
        serverId: fixture.serverId, name: "MemberBot", creatorUserId: fixture.ownerId, runtime: "claude"
    )
    directory.oauth.setAgentRole(serverId: fixture.serverId, agentId: agentId, role: "admin")
    let key = directory.mintAgentCredential(agentId: agentId, scopes: ["channels"], name: "member")
    let humanId = "11111111-1111-4111-8111-000001210099"
    directory.addAccount(id: humanId, email: "tl-member-human@slock.test", password: "password123")
    directory.markEmailVerified(userId: humanId)
    directory.oauth.addMember(serverId: fixture.serverId, userId: humanId, role: "member")

    let first = try directory.agentChannels.writeChannelMember(
        authorization: "Bearer \(key)",
        channelId: fixture.channelId,
        body: AgentChannelMemberRequest(user: humanId),
        remove: false
    )
    #expect(first.change == .added(alreadyMember: false))
    let second = try directory.agentChannels.writeChannelMember(
        authorization: "Bearer \(key)",
        channelId: fixture.channelId,
        body: AgentChannelMemberRequest(user: humanId),
        remove: false
    )
    #expect(second.change == .added(alreadyMember: true))
    // One notice for the one add, born read for the acting agent.
    let notices = directory.messagesAndThreadsStore.humanMessageRows.filter {
        $0.channelId == fixture.channelId && $0.messageType == "system"
    }
    #expect(notices.count == 1)
    #expect(directory.messagesAndThreadsStore
        .agentChannelReadCursors["\(fixture.channelId)\n\(agentId)"]?.seq == notices.first?.seq)

    let removed = try directory.agentChannels.writeChannelMember(
        authorization: "Bearer \(key)",
        channelId: fixture.channelId,
        body: AgentChannelMemberRequest(user: humanId),
        remove: true
    )
    #expect(removed.change == .removed(wasMember: true))
    #expect(directory.oauth.channelHumanIds(channelId: fixture.channelId).contains(humanId) == false)
}
