import Foundation
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

/// A DM whose wake the execution owner refused must reach the v2 sender as the
/// upstream `agent_stopped` warning. The canonical message stays committed; no
/// delivery receipt is invented.
@Suite(.serialized) struct HumanMessageRecoveryWarningTests {
    private struct Fixture: Sendable {
        let accounts: EmailLoginDirectory
        let owner: String
        let server: String
        let machine: String
        let agent: String
        let channel: String
        let token: String
        let service: HumanMessageCreateService
    }

    private func fixture() throws -> Fixture {
        let accounts = EmailLoginDirectory()
        let owner = "11111111-1111-4111-8111-111111111881"
        let server = "33333333-3333-4333-8333-333333333881"
        let channel = "22222222-2222-4222-8222-222222222881"
        accounts.addAccount(id: owner, email: "recovery-warning-\(owner)@slock.test", password: "fixture-password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "recovery-warning", name: "Recovery warning", ownerId: owner)
        let machine = accounts.registerMachine(serverId: server, userId: owner, name: "Recovery warning machine")
        let agent = accounts.oauth.createAgent(serverId: server, name: "Recovering recipient",
                                               creatorUserId: owner, runtime: "codex")
        accounts.addServerAgent(serverId: server, id: agent, name: "Recovering recipient", avatarUrl: nil, status: "active")
        accounts.addDirectMessage(serverId: server, channelId: channel, participantIds: [owner, agent], agentId: agent)
        accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
        accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
        accounts.agentsRuntimeStore.withState { state in
            state.execution.connections[machine] = AgentExecutionConnection(
                serverId: server, connectionEpochId: "recovery-warning-epoch", online: true, ready: true,
                daemonInstanceId: "recovery-warning-daemon", runtimes: ["codex"], capabilities: nil)
            var executionAgent = AgentExecutionAgent(serverId: server, machineId: machine)
            executionAgent.needsManual = "connection_lost_with_unsettled_execution"
            state.execution.agents[agent] = executionAgent
        }
        let execution = AgentExecutionService(
            producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore,
            oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore,
            messages: accounts.messagesAndThreadsStore)
        return Fixture(accounts: accounts, owner: owner, server: server, machine: machine, agent: agent,
                       channel: channel, token: accounts.mintAccessTokenForTesting(userId: owner),
                       service: accounts.humanMessageCreate.bindingExecution(execution))
    }

    @Test func recoveryGatedDmReportsWakeSuppressedWarningAndKeepsTheMessage() async throws {
        let f = try fixture()
        #expect(f.accounts.oauth.channelAgentIds(channelId: f.channel) == [f.agent])
        #expect(f.accounts.agentsRuntimeStore.agentMachineIds[f.agent] == f.machine)
        let machineRows = f.accounts.machinesAndComputersStore.machines
        #expect(machineRows.contains(where: { $0.id == f.machine && $0.serverId == f.server }))
        #expect(f.accounts.agentsRuntimeStore.state.execution.connections[f.machine]?.ready == true)
        #expect(f.accounts.agentsRuntimeStore.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")
        let context = TransactionContext()
        try await withTransactionContext(context) {
            defer { context.discard() }
            let reply = try f.service.createHumanMessage(
                HumanMessageCreateRequest(channelId: f.channel, content: "Recovery-gated DM"),
                authorization: "Bearer \(f.token)", serverId: f.server, contract: .v2)
            #expect(reply.nested)
            #expect(f.accounts.agentsRuntimeStore.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")
            #expect(reply.deliveryWarnings == [MessageDeliveryWarning(agentId: f.agent)])
            let rows = f.accounts.messagesAndThreadsStore.humanMessageRows.filter { $0.channelId == f.channel }
            #expect(rows.count == 1)
            #expect(rows.first?.content == "Recovery-gated DM")
            #expect(f.accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
            #expect(f.accounts.agentDeliveries(agentId: f.agent) == [rows.first?.id].compactMap { $0 })
            #expect(f.accounts.agentDeliveryChannelTypes(agentId: f.agent) == ["dm"])
            try context.prepareCommit()
            #expect(try context.preparedDurableEffects().allSatisfy { $0.kind != "agent.execution" })
        }
        #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
        #expect(f.accounts.agentDeliveries(agentId: f.agent).isEmpty)
    }

    @Test func deliverableDmAndOrdinaryChannelKeepTheEmptyWarningList() async throws {
        let f = try fixture()
        let context = TransactionContext()
        try await withTransactionContext(context) {
            defer { context.discard() }
            f.accounts.agentsRuntimeStore.withState { state in
                state.execution.agents[f.agent]?.needsManual = nil
            }
            let delivered = try f.service.createHumanMessage(
                HumanMessageCreateRequest(channelId: f.channel, content: "Deliverable DM"),
                authorization: "Bearer \(f.token)", serverId: f.server, contract: .v2)
            #expect(delivered.deliveryWarnings.isEmpty)
            #expect(f.accounts.agentDeliveries(agentId: f.agent).isEmpty)
            try context.prepareCommit()
        }
    }
}
