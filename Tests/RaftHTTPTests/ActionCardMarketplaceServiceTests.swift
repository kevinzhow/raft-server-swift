import Foundation
import RaftHTTP
import Testing
import TestSupport

/// A thread-safe deterministic id sequence for the service factory.
private final class MarketplaceFixedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return "fixed-id-\(value)"
    }
}

private struct MarketplaceServiceFixture {
    let accounts: EmailLoginDirectory
    let service: ActionCardMarketplaceService
    let serverId: String
    let ownerId: String
    let ownerName: String
    let channelId: String
    let channelName: String
    let agentId: String
    let peerId: String
    let key: String
    let now: Date
}

private func makeMarketplaceServiceFixture(_ suffix: String, fixedNow: Bool = true) -> MarketplaceServiceFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-0000010510\(suffix)"
    let ownerId = "11111111-1111-4111-8111-0000010510\(suffix)"
    let ownerName = "market-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "market-\(suffix)", name: "Market \(suffix)", ownerId: ownerId)
    let channelName = "market-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "MarketBot\(suffix)", runtime: "codex")
    let peerId = accounts.oauth.createAgent(serverId: serverId, name: "PeerBot\(suffix)", runtime: "codex")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, name: channelName)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: peerId, name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: peerId)
    accounts.setAgentGrantsForTesting(agentId: agentId, scopes: ["task:write"])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "tasks"], name: "market-\(suffix)")
    let now = fixedNow ? Date(timeIntervalSince1970: 1_800_000_000) : Date()
    let ids = MarketplaceFixedIDs()
    let service = makeActionCardMarketplaceService(
        directory: accounts,
        now: { now },
        makeId: { ids.next() }
    )
    return MarketplaceServiceFixture(
        accounts: accounts,
        service: service,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        channelId: channelId,
        channelName: channelName,
        agentId: agentId,
        peerId: peerId,
        key: key,
        now: now
    )
}

private func createBody(
    _ fixture: MarketplaceServiceFixture,
    titles: [String],
    assignee: String? = nil
) throws -> ActionCardTaskCreateResponse {
    try fixture.service.createTasks(
        authorization: "Bearer \(fixture.key)",
        body: AgentTaskCreateRequest(
            channel: "#\(fixture.channelName)",
            tasks: titles.map { AgentTaskCreateItem(title: $0) },
            assignee: assignee
        ),
        rawBody: "{}"
    )
}

@Test func taskCreatePrintsThePublishedMemberOrder() throws {
    let fixture = makeMarketplaceServiceFixture("01")
    let response = try createBody(fixture, titles: ["do it"])
    let task = try #require(response.tasks.first)
    let expected = """
    {"taskIds":["\(task.id)"],"tasks":[{"id":"\(task.id)","channelId":"\(fixture.channelId)","messageId":"\(task.messageId)","title":"do it","status":"todo","taskNumber":1,"claimedById":null,"claimedByType":null,"claimedAt":null,"revision":0}],"assignmentReceipt":null}
    """
    #expect(response.jsonBody.render() == expected)
    #expect(response.headers == ResponseHeaders.standard())
}

@Test func taskCreateAssignmentReceiptAndInboxFactsArePublished() throws {
    let fixture = makeMarketplaceServiceFixture("02")
    let response = try createBody(fixture, titles: ["directed work"], assignee: "@PeerBot02")
    let task = try #require(response.tasks.first)
    #expect(task.claimedById == fixture.peerId)
    #expect(task.claimedByType == "agent")
    #expect(task.revision == 1)
    let receipt = try #require(response.assignmentReceipt)
    #expect(receipt.messageId == "fixed-id-0")
    #expect(receipt.content == "@PeerBot02 assigned you: directed work")
    let expectedReceipt = """
    {"messageId":"fixed-id-0","content":"@PeerBot02 assigned you: directed work","assignee":"@PeerBot02","state":"assigned"}
    """
    #expect(receipt.jsonBody.render() == expectedReceipt)
    let facts = fixture.accounts.inboxFactsForTesting(messageId: task.messageId)
    #expect(facts.contains { $0.receiverId == fixture.peerId && $0.personalMention && $0.unreadEligible })
    let receiptFacts = fixture.accounts.inboxFactsForTesting(messageId: "fixed-id-0")
    #expect(receiptFacts.count == 1)
}

@Test func convertDeleteAndAssignKeepTheirExactBodies() throws {
    let fixture = makeMarketplaceServiceFixture("03")
    let messageId = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "convert me",
        senderId: fixture.ownerId
    )
    let converted = try fixture.service.convertTask(
        authorization: "Bearer \(fixture.key)",
        body: AgentTaskConvertRequest(channel: "#\(fixture.channelName)", messageId: messageId)
    )
    let task = converted.task
    let expectedConvert = """
    {"task":{"id":"\(task.id)","channelId":"\(fixture.channelId)","messageId":"\(messageId)","title":"Converted message","status":"todo","taskNumber":1,"claimedById":null,"claimedByType":null,"claimedAt":null,"revision":0}}
    """
    #expect(converted.jsonBody.render() == expectedConvert)

    let deleted = try fixture.service.deleteTask(
        authorization: "Bearer \(fixture.key)",
        body: AgentTaskDeleteRequest(channel: "#\(fixture.channelName)", taskNumber: task.taskNumber)
    )
    #expect(deleted.jsonBody.render() == "{\"ok\":true}")

    do {
        _ = try fixture.service.deleteTask(
            authorization: "Bearer \(fixture.key)",
            body: AgentTaskDeleteRequest(channel: "#\(fixture.channelName)", taskNumber: task.taskNumber)
        )
        Issue.record("a second delete must be the published 404")
    } catch let error as ActionCardMarketplaceError {
        #expect(error == .taskNotFound)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Task not found\"}")
    }

    let created = try createBody(fixture, titles: ["assign me"])
    let createdTask = try #require(created.tasks.first)
    let assigned = try fixture.service.assignTask(
        authorization: "Bearer \(fixture.key)",
        body: AgentTaskAssignRequest(
            channel: "#\(fixture.channelName)",
            taskNumber: createdTask.taskNumber,
            assignee: "@PeerBot03"
        )
    )
    let expectedAssign = """
    {"id":"\(assigned.id)","channelId":"\(fixture.channelId)","messageId":"\(assigned.messageId)","title":"assign me","status":"todo","taskNumber":1,"claimedById":"\(fixture.peerId)","claimedByType":"agent","claimedAt":null,"revision":1}
    """
    #expect(assigned.jsonBody.render() == expectedAssign)
}

@Test func unknownAssigneePublishesTheExactRefusal() throws {
    let fixture = makeMarketplaceServiceFixture("04")
    let created = try createBody(fixture, titles: ["something"])
    let task = try #require(created.tasks.first)
    do {
        _ = try fixture.service.assignTask(
            authorization: "Bearer \(fixture.key)",
            body: AgentTaskAssignRequest(
                channel: "#\(fixture.channelName)",
                taskNumber: task.taskNumber,
                assignee: "@nobody"
            )
        )
        Issue.record("unknown assignee must fail")
    } catch let error as ActionCardMarketplaceError {
        #expect(error.status == 404)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Assignee is not assignable\",\"code\":\"assignee_not_assignable\"}")
    }
}

@Test func inboxPrintsThePublishedMemberOrderAndMilliseconds() throws {
    let fixture = makeMarketplaceServiceFixture("05")
    _ = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "hello",
        senderId: fixture.ownerId,
        createdAt: fixture.now
    )
    let response = try fixture.service.inboxConversations(
        authorization: "Bearer \(fixture.key)",
        limit: nil,
        beforeSeq: nil,
        view: nil
    )
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expected = """
    {"view":"unread","items":[{"target":"#market-room-05","kind":"channel","unread":1,"mentions":0,"lastReadSeq":0,"activitySeq":1,"latestSenderName":"market-owner-05","latestAt":"\(formatter.string(from: fixture.now))"}],"totals":{"conversations":1,"dms":0,"mentions":0},"hasMore":false,"nextBeforeSeq":null}
    """
    #expect(response.jsonBody.render() == expected)
}

@Test func idempotentReplayUsesTheStoredBodyAndLegacyHeaders() throws {
    let fixture = makeMarketplaceServiceFixture("06")
    let replayed = "{\"taskIds\":[\"stored\"],\"tasks\":[],\"assignmentReceipt\":null}"
    let service = makeActionCardMarketplaceService(
        directory: fixture.accounts,
        idempotency: ActionCardTaskIdempotency(
            lookup: { _, _, _ in .replay(body: replayed) },
            store: { _, _, _, _ in }
        ),
        now: { fixture.now }
    )
    let response = try service.createTasks(
        authorization: "Bearer \(fixture.key)",
        body: AgentTaskCreateRequest(channel: "#\(fixture.channelName)", tasks: [AgentTaskCreateItem(title: "x")]),
        rawBody: "{\"idempotencyKey\":\"replay\"}"
    )
    #expect(response.jsonBody.render() == replayed)
    #expect(response.headers == .exact([
        "Content-Type": AppFallback.jsonContentType,
        "Cache-Control": "no-store",
    ]))
}

@Test func idempotencyConflictPublishesTheStored409Body() throws {
    let fixture = makeMarketplaceServiceFixture("07")
    let conflict = "{\"error\":\"This idempotencyKey was already used for a different request\",\"code\":\"idempotency_key_reused\",\"mismatch\":\"request\",\"suggestedNextAction\":\"Retry with a new idempotencyKey.\"}"
    let service = makeActionCardMarketplaceService(
        directory: fixture.accounts,
        idempotency: ActionCardTaskIdempotency(
            lookup: { _, _, _ in .conflict(body: conflict) },
            store: { _, _, _, _ in }
        ),
        now: { fixture.now }
    )
    do {
        _ = try service.createTasks(
            authorization: "Bearer \(fixture.key)",
            body: AgentTaskCreateRequest(channel: "#\(fixture.channelName)", tasks: [AgentTaskCreateItem(title: "x")]),
            rawBody: "{\"idempotencyKey\":\"reused\"}"
        )
        Issue.record("a reused key must be the published 409")
    } catch let error as ActionCardMarketplaceError {
        #expect(error.status == 409)
        #expect(error.publishedErrorBody.render() == conflict)
    }
}

// MARK: - Atomic sections

@Test func concurrentDeletesHaveExactlyOneWinner() async throws {
    let fixture = makeMarketplaceServiceFixture("08")
    let created = try createBody(fixture, titles: ["race"])
    let task = try #require(created.tasks.first)
    let service = fixture.service
    let key = fixture.key
    let channel = "#\(fixture.channelName)"
    let number = task.taskNumber
    let outcomes = await withTaskGroup(of: String.self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    _ = try service.deleteTask(
                        authorization: "Bearer \(key)",
                        body: AgentTaskDeleteRequest(channel: channel, taskNumber: number)
                    )
                    return "deleted"
                } catch {
                    return "missing"
                }
            }
        }
        var results: [String] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(outcomes.sorted() == ["deleted", "missing"])
}

@Test func concurrentConvertsHaveExactlyOneWinner() async throws {
    let fixture = makeMarketplaceServiceFixture("09")
    let messageId = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "race convert",
        senderId: fixture.ownerId
    )
    let service = fixture.service
    let key = fixture.key
    let channel = "#\(fixture.channelName)"
    let outcomes = await withTaskGroup(of: String.self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    _ = try service.convertTask(
                        authorization: "Bearer \(key)",
                        body: AgentTaskConvertRequest(channel: channel, messageId: messageId)
                    )
                    return "converted"
                } catch {
                    return "duplicate"
                }
            }
        }
        var results: [String] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(outcomes.sorted() == ["converted", "duplicate"])
}

@Test func concurrentTaskBatchesGetUniqueNumbers() async throws {
    let fixture = makeMarketplaceServiceFixture("10")
    let service = fixture.service
    let key = fixture.key
    let channel = "#\(fixture.channelName)"
    let numbers = await withTaskGroup(of: [Int].self) { group in
        for offset in 0..<2 {
            group.addTask {
                let body = AgentTaskCreateRequest(
                    channel: channel,
                    tasks: [
                        AgentTaskCreateItem(title: "batch-\(offset)-a"),
                        AgentTaskCreateItem(title: "batch-\(offset)-b"),
                    ]
                )
                let response = try? service.createTasks(
                    authorization: "Bearer \(key)",
                    body: body,
                    rawBody: "{}"
                )
                return response?.tasks.map(\.taskNumber) ?? []
            }
        }
        var results: [Int] = []
        for await batch in group { results.append(contentsOf: batch) }
        return results.sorted()
    }
    #expect(numbers == [1, 2, 3, 4])
}
