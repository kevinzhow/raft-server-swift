import Foundation
import Testing
@testable import RaftHTTP

@Test func cardsStateRegistrationCommitKeepsOneResultUnderContention() async {
    let store = ManagedMCPAndCardsStore()
    store.insertIntegrationRegisterCard(IntegrationRegisterCard(
        messageId: "register", serverId: "server", agentId: "agent", agentName: "Agent",
        storageChannelId: "storage", localCarrierChannelId: "storage", name: "App", clientKey: nil,
        homepageUrl: nil, returnUrl: "https://rp.test/callback", agentManifestUrl: nil,
        setupUrl: nil, setupDescription: nil, scopes: ["openid"], state: "prepared",
        executedByUserId: nil, resultJSON: nil
    ))
    let rows = await withTaskGroup(of: IntegrationRegisterCard?.self) { group in
        for index in 0..<32 {
            group.addTask {
                store.markIntegrationRegisterCardExecuted(messageId: "register", userId: "user-\(index)", resultJSON: "result-\(index)")
            }
        }
        var rows: [IntegrationRegisterCard] = []
        for await row in group { if let row { rows.append(row) } }
        return rows
    }
    #expect(rows.count == 32)
    #expect(Set(rows.compactMap(\.executedByUserId)).count == 1)
    #expect(Set(rows.compactMap(\.resultJSON)).count == 1)
    #expect(rows.allSatisfy { $0.state == "executed" })
    let winner = store.integrationRegisterCard(messageId: "register")
    #expect(winner?.executedByUserId == rows.first?.executedByUserId)
    #expect(winner?.resultJSON == rows.first?.resultJSON)
}

@Test func cardsStateAppConfigCASNeverPublishesAnUnpairedRevision() async {
    let store = ManagedMCPAndCardsStore()
    for revision in 0..<8 {
        let outcomes = await withTaskGroup(of: AppConfigPatchResult.self) { group in
            for index in 0..<32 {
                group.addTask {
                    store.patchAppConfig(agentId: "agent", appId: "system.cleaner", expectedRevision: revision,
                        set: ["winner": .integer(index), "revision": .integer(revision + 1)], unset: [])
                }
            }
            var outcomes: [AppConfigPatchResult] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        let accepted = outcomes.compactMap { outcome -> AppConfigSnapshot? in
            if case .applied(let snapshot) = outcome { snapshot } else { nil }
        }
        #expect(accepted.count == 1)
        #expect(outcomes.filter { $0 == .revisionStale(current: revision + 1) }.count == 31)
        let snapshot = store.appConfigSnapshot(agentId: "agent", appId: "system.cleaner")
        #expect(snapshot == accepted.first)
        #expect(snapshot.revision == revision + 1)
        #expect(snapshot.overrides["revision"] == .integer(revision + 1))
    }
}

@Test func cardsStateConcurrentDrainsDeliverEachQueuedEventOnce() async {
    let store = ManagedMCPAndCardsStore()
    for index in 0..<64 {
        store.appendPendingActionMessageEvent(agentId: "agent", messageId: "message-\(index)", content: "content-\(index)")
    }
    store.appendPendingActionMessageEvent(agentId: "other", messageId: "other", content: "other")
    let batches = await withTaskGroup(of: [String].self) { group in
        for _ in 0..<32 {
            group.addTask { store.takePendingActionMessageEvents(agentId: "agent").map(\.messageId) }
        }
        var batches: [[String]] = []
        for await batch in group { batches.append(batch) }
        return batches
    }
    #expect(batches.filter { !$0.isEmpty }.count == 1)
    #expect(batches.flatMap { $0 }.count == 64)
    #expect(Set(batches.flatMap { $0 }).count == 64)
    #expect(batches.first { !$0.isEmpty } == (0..<64).map { "message-\($0)" })
    #expect(store.takePendingActionMessageEvents(agentId: "other").map(\.messageId) == ["other"])
}

@Test func cardsStateSendCommitBarrierAllowsReceiptAccessWithoutReentry() async {
    let store = ManagedMCPAndCardsStore()
    let outcomes = await withTaskGroup(of: Bool.self) { group in
        for index in 0..<32 {
            group.addTask {
                store.withSendCommit {
                    if store.sendReceipt(key: "server\nagent\nkey") != nil { return false }
                    store.setSendReceipt(AgentApiSendReceipt(messageId: "message-\(index)", messageSeq: index,
                        target: "channel", content: "body-\(index)", attachmentIds: []), key: "server\nagent\nkey")
                    return true
                }
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(store.sendReceipt(key: "server\nagent\nkey") != nil)
    #expect(store.sendReceipt(key: "other") == nil)
}
