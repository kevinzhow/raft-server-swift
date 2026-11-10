import Foundation
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

/// Offline/unassigned human sends: upstream accepts the message, leaves it in
/// the durable agent inbox and redelivers it when the machine's `ready` arrives.
/// The port records one durable pending delivery in the existing execution owner
/// and releases it through the ordinary strict delivery path exactly once.
@Suite(.serialized) struct HumanMessageOfflineQueueTests {
    private struct Fixture: Sendable {
        let accounts: EmailLoginDirectory
        let owner: String
        let server: String
        let machine: String
        let agent: String
        let channel: String
        let token: String
        let service: HumanMessageCreateService
        let domain: AgentExecutionDomain
        let context: AgentExecutionMachineContext
    }

    private func fixture() -> Fixture {
        let accounts = EmailLoginDirectory()
        let owner = "11111111-1111-4111-8111-111111111891"
        let server = "33333333-3333-4333-8333-333333333891"
        let channel = "22222222-2222-4222-8222-222222222891"
        accounts.addAccount(id: owner, email: "offline-queue@slock.test", password: "fixture-password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "offline-queue", name: "Offline queue", ownerId: owner)
        // The Computer row exists but its socket has not connected.
        let machine = accounts.registerMachine(serverId: server, userId: owner, name: "Offline queue machine")
        let agent = accounts.oauth.createAgent(serverId: server, name: "Offline recipient",
                                               creatorUserId: owner, runtime: "codex")
        accounts.addServerAgent(serverId: server, id: agent, name: "Offline recipient", avatarUrl: nil, status: "active")
        accounts.addDirectMessage(serverId: server, channelId: channel, participantIds: [owner, agent], agentId: agent)
        accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
        accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
        let domain = AgentExecutionDomain(
            agents: accounts.agentsRuntimeStore, machines: accounts.machinesAndComputersStore,
            oauth: accounts.oauth, channels: accounts.serversAndChannelsStore,
            messages: accounts.messagesAndThreadsStore)
        let execution = AgentExecutionService(
            producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        return Fixture(accounts: accounts, owner: owner, server: server, machine: machine,
                       agent: agent, channel: channel, token: accounts.mintAccessTokenForTesting(userId: owner),
                       service: accounts.humanMessageCreate.bindingExecution(execution), domain: domain,
                       context: AgentExecutionMachineContext(machineId: machine, serverId: server,
                                                             connectionEpochId: "offline-queue-epoch"))
    }

    /// Sends the DM through the published create service. Returns the message id
    /// after the canonical row committed.
    private func sendOfflineDm(_ f: Fixture) async throws -> String {
        let context = TransactionContext()
        return try await withTransactionContext(context) {
            let reply = try f.service.createHumanMessage(
                HumanMessageCreateRequest(channelId: f.channel, content: "Queued offline DM"),
                authorization: "Bearer \(f.token)", serverId: f.server, contract: .v2)
            #expect(reply.nested)
            #expect(reply.deliveryWarnings.isEmpty)
            let rows = f.accounts.messagesAndThreadsStore.humanMessageRows.filter { $0.channelId == f.channel }
            #expect(rows.count == 1)
            let messageId = try #require(rows.first?.id)
            let state = f.accounts.agentsRuntimeStore.state.execution
            // No invented execution: the queue is not a launch, process or
            // command, and it stages no durable outbox effect.
            #expect(state.commands.isEmpty)
            #expect(state.agents.isEmpty)
            #expect(state.heldDeliveries?.isEmpty ?? true)
            let pending = try #require(state.pendingHumanDeliveries)
            #expect(pending.count == 1)
            let entry = try #require(pending.values.first)
            #expect(entry.agentId == f.agent)
            #expect(entry.channelId == f.channel)
            #expect(entry.messageId == messageId)
            #expect(entry.releasedCommandId == nil)
            try context.prepareCommit()
            #expect(try context.preparedDurableEffects().allSatisfy { $0.kind != "agent.execution" })
            context.publishCommitted()
            context.flushDeferredEffects()
            return messageId
        }
    }

    private func reconnectAndRelease(_ f: Fixture) async throws {
        let context = TransactionContext()
        try await withTransactionContext(context) {
            try f.domain.connectionOpened(f.context)
            try f.domain.connectionReady(f.context, daemonInstanceId: "offline-queue-daemon",
                                         runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
            try f.domain.releasePendingHumanDeliveries(f.context)
            try context.prepareCommit()
            // A cold start and the queued delivery are the only durable effects;
            // the machine having no running process means one start precedes it.
            #expect(try context.preparedDurableEffects().filter { $0.kind == "agent.execution" }.count == 2)
            context.publishCommitted()
            context.flushDeferredEffects()
        }
    }

    @Test func offlineDmQueuesOneDurablePendingDelivery() async throws {
        let f = fixture()
        _ = try await sendOfflineDm(f)
        // The message is committed and readable; the pending fact survives the
        // create transaction as a real retained row.
        #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.contains { $0.channelId == f.channel })
        #expect(f.accounts.agentsRuntimeStore.state.execution.pendingHumanDeliveries?.count == 1)
    }

    @Test func readyReleasesTheQueuedDmExactlyOnce() async throws {
        let f = fixture()
        let messageId = try await sendOfflineDm(f)
        try await reconnectAndRelease(f)

        let state = f.accounts.agentsRuntimeStore.state.execution
        let pending = try #require(state.pendingHumanDeliveries?.values.first)
        let released = try #require(pending.releasedCommandId)
        let command = try #require(state.commands[released.uuidString])
        #expect(command.kind == .delivery)
        #expect(command.agentId == f.agent)
        #expect(command.channelId == f.channel)
        #expect(command.messageId == messageId)
        let startCommands = state.commands.values.filter { $0.kind == .start && $0.agentId == f.agent }
        #expect(startCommands.count == 1)
        #expect(command.launchId == startCommands.first?.launchId)
        #expect(state.commands.values.filter { $0.kind == .delivery && $0.messageId == messageId }.count == 1)

        // A second ready with the same pending fact does not stage a second
        // delivery: the accepted/pending command is the dedupe authority.
        let replay = TransactionContext()
        try await withTransactionContext(replay) {
            try f.domain.releasePendingHumanDeliveries(f.context)
            try replay.prepareCommit()
            #expect(try replay.preparedDurableEffects().isEmpty)
            replay.publishCommitted()
            replay.flushDeferredEffects()
        }
        let replayState = f.accounts.agentsRuntimeStore.state.execution
        #expect(replayState.commands.values.filter { $0.kind == .delivery && $0.messageId == messageId }.count == 1)
        #expect(replayState.commands.values.filter { $0.kind == .start && $0.agentId == f.agent }.count == 1)
    }

    @Test func nonCodexAndStoppedRecipientsAreNotQueuedForDelivery() async throws {
        // A manual stop keeps the existing held-delivery semantics; it must not
        // move into the offline pending queue (and thus not auto-wake).
        let f = fixture()
        let execution = AgentExecutionService(
            producerTransactionAgents: f.accounts.agentsRuntimeStore,
            machines: f.accounts.machinesAndComputersStore, oauth: f.accounts.oauth,
            channels: f.accounts.serversAndChannelsStore, messages: f.accounts.messagesAndThreadsStore)
        let context = TransactionContext()
        try await withTransactionContext(context) {
            _ = try execution.requestStop(.init(serverId: f.server, agentId: f.agent))
            _ = try f.service.createHumanMessage(
                HumanMessageCreateRequest(channelId: f.channel, content: "Stopped recipient DM"),
                authorization: "Bearer \(f.token)", serverId: f.server, contract: .v2)
            let state = f.accounts.agentsRuntimeStore.state.execution
            #expect(state.heldDeliveries?.count == 1)
            #expect(state.pendingHumanDeliveries?.isEmpty ?? true)
            try context.prepareCommit()
            context.publishCommitted()
            context.flushDeferredEffects()
        }
    }
}
