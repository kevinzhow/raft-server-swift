import Foundation
@testable import RaftHTTP
import Testing
import TestSupport

private struct ExecuteStoreFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let agentKey: String
    let channelId: String
}

private func makeExecuteStoreFixture(_ suffix: String) -> ExecuteStoreFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001151\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001151\(suffix)"
    accounts.addAccount(id: ownerId, email: "execute-store-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "execute-store-\(suffix)", name: "Execute Store \(suffix)", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "StoreBot\(suffix)",
        creatorUserId: ownerId,
        runtime: "claude"
    )
    let channelId = accounts.oauth.createChannel(
        serverId: serverId,
        name: "store-\(suffix)",
        creatorUserId: ownerId,
        type: "channel"
    )
    accounts.seedPostableChannelForTesting(
        serverId: serverId,
        channelId: channelId,
        name: "store-\(suffix)",
        humanIds: [ownerId],
        agentIds: [agentId]
    )
    return ExecuteStoreFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read", "tasks"], name: "store-\(suffix)"),
        channelId: channelId
    )
}

private final class ClaimCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [AgentTaskClaimOutcome] = []

    func append(_ outcome: AgentTaskClaimOutcome) {
        lock.lock()
        rows.append(outcome)
        lock.unlock()
    }

    func all() -> [AgentTaskClaimOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }
}

@Test func concurrentClaimsChooseOneOwnerInOneStoreSection() async throws {
    let f = makeExecuteStoreFixture("001")
    let taskId = f.accounts.addTaskWithDescriptionForTesting(
        channelId: f.channelId,
        title: "one owner",
        description: "body"
    )
    let collector = ClaimCollector()
    let service = f.accounts.actionCardExecute
    DispatchQueue.concurrentPerform(iterations: 2) { _ in
        if let outcome = try? service.agentTaskClaim(
            authorization: "Bearer \(f.agentKey)",
            legacyAgentId: nil,
            body: AgentTaskClaimRequest(channel: "#store-001", taskNumbers: [1])
        ) {
            collector.append(outcome)
        }
    }
    let outcomes = collector.all()
    #expect(outcomes.count == 2)
    var claimedResults: [AgentTaskClaimResult] = []
    for outcome in outcomes {
        guard case .claimed(let response) = outcome else { continue }
        claimedResults.append(contentsOf: response.results)
    }
    #expect(claimedResults.filter {
        if case .claimed = $0 { return true } else { return false }
    }.count == 1)
    #expect(claimedResults.filter {
        if case .alreadyClaimedByYou = $0 { return true } else { return false }
    }.count == 1)
    #expect(f.accounts.taskAssigneeForTesting(taskId: taskId) == f.agentId)
    #expect(f.accounts.taskRevisionForTesting(taskId: taskId) == 1)
}

@Test func claimThenStatusWriteRevisionsStayOrdered() async throws {
    let f = makeExecuteStoreFixture("002")
    let taskId = f.accounts.addTaskWithDescriptionForTesting(
        channelId: f.channelId,
        title: "claim then finish",
        description: "body"
    )
    let service = f.accounts.actionCardExecute
    _ = try service.agentTaskClaim(
        authorization: "Bearer \(f.agentKey)",
        legacyAgentId: nil,
        body: AgentTaskClaimRequest(channel: "#store-002", taskNumbers: [1])
    )
    let update: AgentTaskStatusUpdateOutcome = try service.agentTaskUpdateStatus(
        authorization: "Bearer \(f.agentKey)",
        legacyAgentId: nil,
        body: AgentTaskStatusUpdateRequest(channel: "#store-002", taskNumber: 1, status: "done")
    )
    guard case .updated = update else {
        Issue.record("expected the status write to land")
        return
    }
    #expect(f.accounts.taskStatusForTesting(taskId: taskId) == "done")
    #expect(f.accounts.taskRevisionForTesting(taskId: taskId) == 2)
}

@Test func taskWriteHoldRecordsOnceAndClearsOnTheSameBoundary() async throws {
    let f = makeExecuteStoreFixture("003")
    _ = f.accounts.addHumanMessageForTesting(
        channelId: f.channelId,
        senderId: f.ownerId,
        content: "unseen"
    )
    let service = f.accounts.actionCardExecute
    let first = service.taskWriteHold(
        agentId: f.agentId,
        channelId: f.channelId,
        seenUpToSeq: 0,
        actionKey: "claim:1"
    )
    #expect(first?.newMessageCount == 1)
    let boundary = first?.seenUpToSeq ?? 0
    let cleared = service.taskWriteHold(
        agentId: f.agentId,
        channelId: f.channelId,
        seenUpToSeq: boundary,
        actionKey: "claim:1"
    )
    #expect(cleared == nil)
}

private final class BoolCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func all() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Test func firstAgentPostHintIsClaimedOnce() async throws {
    let f = makeExecuteStoreFixture("004")
    let collector = BoolCollector()
    let store = f.accounts.agentsRuntimeStore
    DispatchQueue.concurrentPerform(iterations: 2) { _ in
        collector.append(store.claimFirstAgentPost(channelId: f.channelId, agentId: f.agentId))
    }
    #expect(collector.all().filter { $0 }.count == 1)
}
