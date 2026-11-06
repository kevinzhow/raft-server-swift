import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The search/mentions service owns five published operations. The HTTP tests
/// lock status codes and parsed JSON; these tests lock the exact published
/// bytes, the special-order error bodies, and the two store critical sections
/// the channel soft-delete writes.

private struct SearchMentionsFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let channelId: String
    let agentId: String
    let machineKey: String
    let agentKey: String
    let ownerToken: String
    let messageId: String
    let contextMessageId: String

    var service: SearchMentionsService { SearchMentionsService(directory: accounts) }
    var ownerAuthorization: String { "Bearer \(ownerToken)" }
}

private func makeSearchMentionsFixture() -> SearchMentionsFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001470001"
    let serverId = "33333333-3333-4333-8333-000001470001"
    let ownerName = "search-service-owner"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "search-service", name: "Search Service", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "search-service-bot",
        creatorUserId: ownerId,
        runtime: "codex"
    )
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let messageId = "aaaaaaaa-1111-4111-8111-000001470001"
    accounts.insertHumanMessage(
        id: messageId,
        channelId: channelId,
        senderId: ownerId,
        content: "needle body"
    )
    let contextMessageId = "bbbbbbbb-1111-4111-8111-000001470001"
    accounts.insertHumanMessage(
        id: contextMessageId,
        channelId: channelId,
        senderId: ownerId,
        content: "context body"
    )
    return SearchMentionsFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        channelId: channelId,
        agentId: agentId,
        machineKey: accounts.registerMachineForAgent(serverId: serverId, agentId: agentId),
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "search"),
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        messageId: messageId,
        contextMessageId: contextMessageId
    )
}

// MARK: - Byte-exact bodies

@Test func humanMessageSearchRendersThePublishedBytes() throws {
    let fixture = makeSearchMentionsFixture()
    let response = try fixture.service.searchHumanMessages(
        query: "needle",
        sort: nil,
        limit: "10",
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId
    )
    #expect(response.jsonBody.render() == """
    {"results":[{"id":"\(fixture.messageId)","senderId":"\(fixture.ownerId)","senderType":"user","channelId":"\(fixture.channelId)","parentChannelId":"\(fixture.channelId)","content":"needle body","snippet":"needle body","channelArchivedAt":null}],"hasMore":false}
    """)
}

@Test func machineKeyedAgentSearchRendersThePublishedBytes() throws {
    let fixture = makeSearchMentionsFixture()
    let response = try fixture.service.searchAgentMessages(
        agentId: fixture.agentId,
        query: "needle",
        limit: "10",
        authorization: "Bearer \(fixture.machineKey)"
    )
    #expect(response.jsonBody.render() == """
    {"results":[{"id":"\(fixture.messageId)","senderId":"\(fixture.ownerId)","senderName":"\(fixture.ownerName)","senderType":"human","channelId":"\(fixture.channelId)","channelType":"channel","channelName":"room","parentChannelId":"\(fixture.channelId)","threadId":null,"parentMessageId":null,"parentMessageContent":null,"content":"needle body","snippet":"needle body","channelArchivedAt":null}],"hasMore":false}
    """)
}

@Test func agentApiSearchRendersThePublishedBytes() throws {
    let fixture = makeSearchMentionsFixture()
    let response = try fixture.service.agentApiSearch(
        authorization: "Bearer \(fixture.agentKey)",
        query: "needle",
        channelRef: nil,
        senderRef: nil,
        sort: nil,
        limit: "10"
    )
    #expect(response.jsonBody.render() == """
    {"results":[{"id":"\(fixture.messageId)","content":"needle body","senderName":"\(fixture.ownerName)","senderType":"human","senderId":"\(fixture.ownerId)","channelId":"\(fixture.channelId)","channelName":"room","parentChannelId":"\(fixture.channelId)","snippet":"needle body"}],"hasMore":false}
    """)
}

@Test func storedMessageContextRendersThePublishedBytes() throws {
    let fixture = makeSearchMentionsFixture()
    let seq = try #require(
        fixture.accounts.messagesAndThreadsStore.humanMessageRow(id: fixture.contextMessageId)?.seq
    )
    let response = try #require(fixture.service.humanMessageContext(
        messageId: fixture.contextMessageId,
        channelId: fixture.channelId,
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        before: "0",
        after: "0"
    ))
    #expect(response.jsonBody.render() == """
    {"channelId":"\(fixture.channelId)","targetMessageId":"\(fixture.contextMessageId)","hasOlder":true,"hasNewer":false,"messages":[{"id":"\(fixture.contextMessageId)","channelId":"\(fixture.channelId)","content":"context body","seq":\(seq),"attachments":[]}],"threadSummariesByParentMessageId":{},"historyLimited":false,"channelArchived":false}
    """)
}

@Test func threadReplyContextOmitsAttachmentsAndRendersTheCanonicalTarget() throws {
    let fixture = makeSearchMentionsFixture()
    let parentId = "cccccccc-1111-4111-8111-000001470001"
    fixture.accounts.insertHumanMessage(
        id: parentId,
        channelId: fixture.channelId,
        senderId: fixture.ownerId,
        content: "thread parent"
    )
    let threadId = "dddddddd-1111-4111-8111-000001470001"
    fixture.accounts.addThreadChannel(
        serverId: fixture.serverId,
        threadChannelId: threadId,
        parentChannelId: fixture.channelId,
        parentMessageId: parentId,
        memberId: fixture.ownerId
    )
    let replyId = "eeeeeeee-1111-4111-8111-000001470001"
    fixture.accounts.insertHumanMessage(
        id: replyId,
        channelId: threadId,
        senderId: fixture.ownerId,
        content: "thread reply"
    )
    let response = try #require(fixture.service.humanMessageContext(
        messageId: replyId,
        channelId: fixture.channelId,
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId
    ))
    #expect(response.jsonBody.render() == """
    {"channelId":"\(threadId)","targetMessageId":"\(replyId)","hasOlder":false,"hasNewer":false,"messages":[{"id":"\(replyId)","channelId":"\(threadId)","content":"thread reply","seq":1}],"canonicalTarget":{"kind":"thread","channelId":"\(fixture.channelId)","messageId":"\(replyId)","threadParentMessageId":"\(parentId)","threadChannelId":"\(threadId)"},"threadSummariesByParentMessageId":{},"historyLimited":false,"channelArchived":false}
    """)
}

// MARK: - Special-order error bodies

@Test func searchRefusalsKeepTheirPublishedErrorBodies() {
    #expect(SearchMentionsError.memberNotFound.publishedErrorBody.render() == """
    {"error":"Member not found","errorCode":"member_not_found"}
    """)
    #expect(SearchMentionsError.ambiguousMemberReference.publishedErrorBody.render() == """
    {"error":"Member reference is ambiguous","errorCode":"ambiguous_member_ref"}
    """)
    #expect(SearchMentionsError.agentSearchMissingOffset(label: "after").publishedErrorBody.render() == """
    {"error":"after filter is missing a timezone offset; add an explicit offset such as +08:00 (raft CLI adds it automatically)","errorCode":"INVALID_DATE_FILTER"}
    """)
    #expect(SearchMentionsError.agentApiMissingOffset(label: "before").publishedErrorBody.render() == """
    {"error":"The before filter is missing a timezone offset (for example +08:00); pass one from the raft CLI","errorCode":"INVALID_DATE_FILTER"}
    """)
    #expect(SearchMentionsError.invalidAccessToken.publishedErrorBody.render() == """
    {"error":"Invalid or expired token","code":"auth_required"}
    """)
}

// MARK: - Atomic sections

@Test func channelDeleteIsOneStoreCriticalSection() async throws {
    let fixture = makeSearchMentionsFixture()
    let taskId = fixture.accounts.addTask(channelId: fixture.channelId, title: "orphan", description: nil)
    let service = fixture.service
    let channelId = fixture.channelId
    let authorization = fixture.ownerAuthorization
    let serverId = fixture.serverId

    enum Outcome: Sendable { case deleted, refused }
    let outcomes = try await withThrowingTaskGroup(of: Outcome.self) { group in
        for _ in 0..<24 {
            group.addTask {
                do {
                    _ = try service.deleteChannel(
                        channelId: channelId,
                        authorization: authorization,
                        serverId: serverId
                    )
                    return .deleted
                } catch SearchMentionsError.channelNotFound {
                    return .refused
                }
            }
        }
        var results: [Outcome] = []
        for try await outcome in group { results.append(outcome) }
        return results
    }

    // The row read, the role branch and the `deletedAt` write are one locked
    // value: exactly one caller may observe the live row.
    #expect(outcomes.filter { $0 == .deleted }.count == 1)
    #expect(outcomes.filter { $0 == .refused }.count == 23)
    #expect(fixture.accounts.serversAndChannelsStore.postableChannel(id: channelId)?.deletedAt != nil)
    // The orphan-task closure is one locked task-store value and runs once.
    #expect(fixture.accounts.tasksAndRemindersStore.task(id: taskId)?.status == "closed")
    #expect(fixture.accounts.tasksAndRemindersStore.taskEvents.filter {
        $0.taskId == taskId && $0.eventType == "closed" && $0.actorType == "system"
    }.count == 1)
}

@Test func concurrentMemberMentionRegistrationIsVisibleOnceThroughMentionSearch() throws {
    let fixture = makeSearchMentionsFixture()
    let registrar = fixture.accounts.messageMentions
    let messageId = fixture.messageId
    let channelId = fixture.channelId
    let member = MentionInput(type: "user", id: fixture.ownerId, name: fixture.ownerName)
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
        registrar.register(messageId: messageId, channelId: channelId, mentions: [member, member])
    }
    let rows = fixture.accounts.messageMentionRows(messageId: messageId)
    #expect(rows.count == 1)
    #expect(rows.first?.notifiableAtSend == true)
    let response = try fixture.service.searchHumanMessages(
        query: "needle", sort: nil, limit: "10", authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId, mentionTarget: "self"
    )
    #expect(response.results.map(\.id) == [messageId])
}
