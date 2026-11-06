import Foundation
import Testing
@testable import RaftHTTP

private struct RefusedEdit: Error {}

private func serverRecord(id: String, serverId: String = "s1") -> ManagedMCPServerRecord {
    ManagedMCPServerRecord(
        id: id, serverId: serverId, name: "name-\(id)", provider: nil, authMode: nil, oauthStatus: nil,
        endpointUrl: "https://example.com/mcp", toolCatalogJSON: "[]", catalogVersion: 1
    )
}

@Test func managedMCPServerEditKeepsTheMembersWrittenBeforeARefusal() throws {
    let store = ManagedMCPAndCardsStore()
    store.appendManagedMCPServer(serverRecord(id: "a"))
    #expect(throws: RefusedEdit.self) {
        _ = try store.updateManagedMCPServer(serverId: "s1", id: "a") { record in
            record.name = "renamed"
            throw RefusedEdit()
        }
    }
    #expect(store.managedMCPServer(id: "a", serverId: "s1")?.name == "renamed")
    #expect(try store.updateManagedMCPServer(serverId: "s1", id: "missing") { $0.name = "x" } == nil)
    #expect(try store.updateManagedMCPServer(serverId: "other", id: "a") { $0.name = "x" } == nil)
}

@Test func managedMCPServerAppendsAndRemovalsFromManyThreadsAreAtomic() async {
    let store = ManagedMCPAndCardsStore()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask { store.appendManagedMCPServer(serverRecord(id: "id-\(index)")) }
        }
    }
    #expect(store.managedMCPServers(serverId: "s1").count == 100)
    let removed = await withTaskGroup(of: Bool.self) { group -> Int in
        for _ in 0..<10 { group.addTask { store.removeManagedMCPServer(serverId: "s1", id: "id-7") } }
        var count = 0
        for await result in group where result { count += 1 }
        return count
    }
    #expect(removed == 1)
    #expect(store.managedMCPServers(serverId: "s1").count == 99)
}

@Test func managedMCPAssignmentWritesRefuseAnUnknownServerWithoutPartialState() {
    let store = ManagedMCPAndCardsStore()
    store.appendManagedMCPServer(serverRecord(id: "a"))
    #expect(store.replaceManagedMCPAssignments(
        serverId: "s1", agentId: "agent", entries: [("a", true, ["tool"])]
    ) == .stored)
    #expect(store.managedMCPAssignments["agent"]?["a"]?.allowedTools == ["tool"])

    #expect(store.replaceManagedMCPAssignments(
        serverId: "s1", agentId: "agent", entries: [("a", false, nil), ("ghost", true, nil)]
    ) == .unknownServer)
    // The refused write left the earlier set untouched.
    #expect(store.managedMCPAssignments["agent"]?["a"]?.enabled == true)
    #expect(store.replaceManagedMCPAssignments(
        serverId: "s1", agentId: "agent", entries: [(nil, true, nil)]
    ) == .unknownServer)

    #expect(store.setManagedMCPAssignment(
        serverId: "s1", agentId: "agent", mcpServerId: "ghost", enabled: true, allowedTools: nil
    ) == .unknownServer)
    #expect(store.setManagedMCPAssignment(
        serverId: "s1", agentId: "agent", mcpServerId: "a", enabled: false, allowedTools: nil
    ) == .stored)
    #expect(store.managedMCPAssignments["agent"]?["a"]?.enabled == false)
}

@Test func agentReadCursorMovesBumpTheVersionOncePerWrite() async {
    let store = MessagesAndThreadsStore()
    await withTaskGroup(of: Void.self) { group in
        for index in 1...100 {
            group.addTask { store.setAgentReadCursor(channelId: "c", agentId: "a", seq: index) }
        }
    }
    #expect(store.agentChannelReadCursors["c\na"]?.version == 100)
    #expect(store.agentReadSeq(channelId: "c", agentId: "a") == store.agentChannelReadCursors["c\na"]?.seq)
    #expect(store.agentReadSeq(channelId: "c", agentId: "other") == 0)
}

@Test func deferredUnreadAdvanceCommitMovesTheCursorAndClearsTheMarkTogether() {
    let store = MessagesAndThreadsStore()
    store.deferUnreadAdvance(channelId: "c", agentId: "a", seq: 9)
    var position = store.agentUnreadPosition(channelId: "c", agentId: "a")
    #expect(position.pendingDeferred == 9)
    #expect(position.priorSeq == 0)
    store.commitDeferredUnreadAdvance(channelId: "c", agentId: "a", seq: 7)
    position = store.agentUnreadPosition(channelId: "c", agentId: "a")
    #expect(position.pendingDeferred == nil)
    #expect(position.priorSeq == 7)
    #expect(store.agentChannelReadCursors["c\na"]?.version == 1)
    store.deferUnreadAdvance(channelId: "c", agentId: "a", seq: 11)
    store.clearDeferredUnreadAdvance(channelId: "c", agentId: "a")
    #expect(store.agentUnreadPosition(channelId: "c", agentId: "a").pendingDeferred == nil)
}
