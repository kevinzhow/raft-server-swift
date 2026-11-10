import Foundation
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

// Pending Shared UoW coverage only. No ready/process/ACK fixtures and no claim
// of a PG commit, official runtime execution, or a delivered daemon frame.
@Suite(.serialized) struct HumanMessageExecutionPendingTests {
    private struct Fixture: Sendable {
        let accounts: EmailLoginDirectory
        let owner: String
        let server: String
        let channel: String
        let agent: String
        let token: String
        let service: HumanMessageCreateService
    }
    private func fixture(assigned: Bool, joined: Bool) -> Fixture {
        let accounts = EmailLoginDirectory()
        let owner = UUID().uuidString.lowercased()
        let server = UUID().uuidString.lowercased()
        accounts.addAccount(id: owner, email: "human-execution-\(owner)@slock.test", password: "fixture-password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "human-execution-\(server)", name: "Human execution", ownerId: owner)
        let channel = accounts.oauth.createChannel(serverId: server, name: "ordinary-human-room", creatorUserId: owner)
        let agent = accounts.oauth.createAgent(serverId: server, name: "Ordinary recipient", creatorUserId: owner, runtime: "codex")
        accounts.seedPostableChannelForTesting(serverId: server, channelId: channel, name: "ordinary-human-room",
            humanIds: [owner], agentIds: joined ? [agent] : [])
        if assigned {
            let machine = accounts.registerMachine(serverId: server, userId: owner, name: "Not connected")
            accounts.agentsRuntimeStore.bindMachine(agentId: agent, machineId: machine)
        }
        let execution = AgentExecutionService(producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        return Fixture(accounts: accounts, owner: owner, server: server, channel: channel, agent: agent,
            token: accounts.mintAccessTokenForTesting(userId: owner), service: accounts.humanMessageCreate.bindingExecution(execution))
    }
    private func request(_ f: Fixture, randomID: String? = nil) throws -> HumanMessageCreateRequest {
        var fields: [String: JSONValue] = ["channelId": .string(f.channel), "content": .string("Ordinary human clarification")]
        if let randomID { fields["randomId"] = .string(randomID) }
        return try JSONDecoder().decode(HumanMessageCreateRequest.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }

    @Test func unassignedAndOfflineRecipientsKeepReadableMessagesWithoutInventingExecution() async throws {
        for assigned in [false, true] {
            let f = fixture(assigned: assigned, joined: true)
            let context = TransactionContext()
            try await withTransactionContext(context) {
                defer { context.discard() }
                _ = try f.service.createHumanMessage(try request(f), authorization: "Bearer \(f.token)", serverId: f.server)
                let rows = f.accounts.messagesAndThreadsStore.humanMessageRows.filter { $0.channelId == f.channel }
                #expect(rows.count == 1)
                #expect(rows.first?.content == "Ordinary human clarification")
                #expect(f.accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
                #expect(f.accounts.agentsRuntimeStore.state.execution.agents.isEmpty)
                #expect(f.accounts.agentsRuntimeStore.state.execution.heldDeliveries?.isEmpty ?? true)
                // Accepted while the recipient is not deliverable: the durable
                // message row plus one pending-delivery fact, still no launch,
                // process or command.
                #expect(f.accounts.agentsRuntimeStore.state.execution.pendingHumanDeliveries?.count == 1)
                try context.prepareCommit()
                #expect(try context.preparedDurableEffects().allSatisfy { $0.kind != "agent.execution" })
            }
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
        }
    }

    @Test func manuallyStoppedHumanMessageAndReplayShareOneHeldFactAndDiscardTogether() async throws {
        let f = fixture(assigned: false, joined: true)
        let execution = AgentExecutionService(producerTransactionAgents: f.accounts.agentsRuntimeStore,
            machines: f.accounts.machinesAndComputersStore, oauth: f.accounts.oauth,
            channels: f.accounts.serversAndChannelsStore, messages: f.accounts.messagesAndThreadsStore)
        let context = TransactionContext()
        try await withTransactionContext(context) {
            defer { context.discard() }
            _ = try execution.requestStop(.init(serverId: f.server, agentId: f.agent))
            let body = try request(f, randomID: "held-human-once")
            let first = try f.service.createHumanMessage(body, authorization: "Bearer \(f.token)", serverId: f.server)
            let replay = try f.service.createHumanMessage(body, authorization: "Bearer \(f.token)", serverId: f.server)
            #expect(first.messageJSON == replay.messageJSON)
            let rows = f.accounts.messagesAndThreadsStore.humanMessageRows.filter { $0.channelId == f.channel }
            #expect(rows.count == 1)
            let state = f.accounts.agentsRuntimeStore.state.execution
            let held = Array((state.heldDeliveries ?? [:]).values)
            #expect(held.count == 1)
            #expect(held.first?.messageId == rows.first?.id)
            #expect(state.commands.isEmpty)
            #expect(state.agents.isEmpty)
            try context.prepareCommit()
        }
        #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
        #expect(f.accounts.agentsRuntimeStore.state.execution.heldDeliveries?.isEmpty ?? true)
        #expect(f.accounts.oauth.agentRuntimeInfo(id: f.agent)?.status != "stopped")
    }

    @Test func nonmemberAndMutedJoinedAgentDoNotAcquireHeldDeliveryFacts() async throws {
        for joined in [false, true] {
            let f = fixture(assigned: false, joined: joined)
            let execution = AgentExecutionService(producerTransactionAgents: f.accounts.agentsRuntimeStore,
                machines: f.accounts.machinesAndComputersStore, oauth: f.accounts.oauth,
                channels: f.accounts.serversAndChannelsStore, messages: f.accounts.messagesAndThreadsStore)
            let context = TransactionContext()
            try await withTransactionContext(context) {
                defer { context.discard() }
                _ = try execution.requestStop(.init(serverId: f.server, agentId: f.agent))
                if joined { _ = f.accounts.oauth.setActivityMuted(channelId: f.channel, receiverId: f.agent, muted: true, muteFromSeq: 0) }
                _ = try f.service.createHumanMessage(try request(f), authorization: "Bearer \(f.token)", serverId: f.server)
                #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == 1)
                #expect(f.accounts.agentsRuntimeStore.state.execution.heldDeliveries?.isEmpty ?? true)
                #expect(f.accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
                try context.prepareCommit()
            }
        }
    }
}
