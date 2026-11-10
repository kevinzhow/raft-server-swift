import Foundation
import RaftShared
import Testing
import TestSupport
@testable import RaftHTTP

/// Real retained-owner/UoW tests. Publication here exercises the Shared domain,
/// not PostgreSQL commit, a socket write, or daemon execution.
@Suite(.serialized) struct AgentExecutionStopTests {
    private func fixture() -> (AgentExecutionDomain, String, String, String) {
        let agents = AgentsRuntimeStore()
        let machines = MachinesAndComputersStore()
        let oauth = OAuthLedger()
        let server = "stop-server"
        let machine = "stop-machine"
        oauth.addOwnedServer(id: server, slug: "stop", name: "Stop", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Executor", runtime: "codex")
        agents.agentMachineIds = [agent: machine]
        agents.serverAgents = [agent: ServerAgent(id: agent, serverId: server, name: "Executor", status: "active")]
        machines.machines = [MachineRecord(id: machine, serverId: server, userId: "owner", name: "Computer", description: nil, apiKey: nil)]
        return (AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth,
                                    channels: ServersAndChannelsStore(), messages: MessagesAndThreadsStore()), server, machine, agent)
    }

    private func publish<Value: Sendable>(_ operation: @Sendable () throws -> Value) async throws -> Value {
        let transaction = TransactionContext()
        return try await withTransactionContext(transaction) {
            let value = try operation()
            try transaction.prepareCommit()
            transaction.publishCommitted()
            transaction.flushDeferredEffects()
            return value
        }
    }

    private func ready(_ domain: AgentExecutionDomain, server: String, machine: String) async throws -> AgentExecutionMachineContext {
        let context = AgentExecutionMachineContext(machineId: machine, serverId: server, connectionEpochId: "stop-epoch")
        try await publish {
            try domain.connectionOpened(context)
            try domain.connectionReady(context, daemonInstanceId: "stop-daemon", runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
        }
        return context
    }

    private func channel(_ domain: AgentExecutionDomain, server: String, agent: String) -> String {
        let id = domain.oauth.createChannel(serverId: server, name: "stop-messages", creatorUserId: "owner")
        domain.channels.addPostableChannel(serverId: server, channelId: id, memberId: agent)
        return id
    }

    private func append(_ domain: AgentExecutionDomain, channel: String, content: String) -> String {
        let message = domain.oauth.createMessageRecord(channelId: channel, content: content, senderId: "owner")
        domain.messages.withState {
            $0.humanMessageRows.append(StoredHumanMessage(id: message.id, channelId: channel, senderId: "owner", content: content, seq: $0.humanMessageRows.count + 1))
        }
        return message.id
    }

    @Test func stopBeforeFirstLaunchKeepsTheCanonicalMessageAndHoldsDelivery() async throws {
        let (domain, server, machine, agent) = fixture()
        let conversation = channel(domain, server: server, agent: agent)
        _ = try await ready(domain, server: server, machine: machine)
        let stop = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            let message = append(domain, channel: conversation, content: "Keep this real message")
            let request = AgentExecutionDeliveryRequest(serverId: server, agentId: agent, channelId: conversation, messageId: message)
            #expect(try domain.requestDelivery(request) == nil)
            #expect(try domain.requestDelivery(request) == nil)
            #expect(domain.oauth.agentRuntimeInfo(id: agent)?.status == "stopped")
            #expect(domain.agents.state.serverAgents[agent]?.status == "stopped")
            #expect(domain.agents.state.execution.agents[agent]?.currentLaunchId == nil)
            #expect(domain.agents.state.execution.agents[agent]?.launches.isEmpty == true)
            #expect(domain.agents.state.execution.commands.values.allSatisfy { $0.kind == .stop })
            let queued = try #require(domain.agents.state.execution.heldDeliveries?[request.commandId.uuidString])
            #expect(queued.messageId == message)
            #expect(queued.releasedCommandId == nil)
            #expect(domain.agents.state.execution.heldDeliveries?.count == 1)
            #expect(domain.messages.humanMessageRows.contains { $0.id == message && $0.content == "Keep this real message" })
            #expect(domain.agents.state.execution.stopIntents?[stop.commandId.uuidString]?.clearedByHumanStart == nil)
            #expect(try domain.requestAutomaticStartIfReady(.init(serverId: server, agentId: agent)) == nil)
            try transaction.prepareCommit()
            #expect(try transaction.preparedDurableEffects().isEmpty)
            transaction.publishCommitted()
            transaction.flushDeferredEffects()
        }
        #expect(domain.messages.humanMessageRows.count == 1)
        await #expect(throws: AgentExecutionError.manuallyStopped) {
            try await publish { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        }
    }

    @Test func stoppedTaskCreationKeepsItsHostNoticeAndDeliveryFacts() async throws {
        let accounts = EmailLoginDirectory()
        let user = UUID().uuidString.lowercased()
        let server = UUID().uuidString.lowercased()
        accounts.addAccount(id: user, email: "stop-task@slock.test", password: "password123")
        accounts.markEmailVerified(userId: user)
        accounts.oauth.addOwnedServer(id: server, slug: "stop-task", name: "Stop Task", ownerId: user)
        let agent = accounts.oauth.createAgent(serverId: server, name: "Stopped executor", creatorUserId: user, runtime: "codex")
        let conversation = accounts.oauth.createChannel(serverId: server, name: "stop-task", creatorUserId: user)
        accounts.seedPostableChannelForTesting(serverId: server, channelId: conversation, name: "stop-task", humanIds: [user], agentIds: [agent])
        accounts.oauth.addChannelAgent(channelId: conversation, agentId: agent)
        let token = accounts.mintAccessTokenForTesting(userId: user)
        let execution = AgentExecutionService(producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        let catalog = accounts.taskCatalog.bindingExecution(execution)
        let writer = ChannelMessagingService(dependencies: ChannelMessagingDependencies(auth: accounts.authCore, oauth: accounts.oauth, catalog: catalog))
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            _ = try execution.requestStop(.init(serverId: server, agentId: agent))
            let reply = try writer.createChannelTasks(authorization: "Bearer \(token)", serverId: server, channelId: conversation,
                body: "{\"tasks\":[{\"title\":\"Keep the stopped agent's task\"}]}")
            let taskId = try #require(reply.tasks.first?.id)
            let task = try #require(accounts.tasksAndRemindersStore.taskRecords.first { $0.id == taskId })
            #expect(task.status == "todo")
            #expect(task.claimedAt == nil)
            let messages = accounts.messagesAndThreadsStore.humanMessageRows
            #expect(messages.count == 2)
            #expect(messages.contains { $0.id == task.messageId && $0.content == task.title })
            let held = Array((accounts.agentsRuntimeStore.state.execution.heldDeliveries ?? [:]).values)
            #expect(held.count == 2)
            #expect(Set(held.map(\.messageId)) == Set(messages.map(\.id)))
            #expect(accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
            #expect(accounts.oauth.agentRuntimeInfo(id: agent)?.status == "stopped")
            try transaction.prepareCommit()
            let effects = try transaction.preparedDurableEffects()
            #expect(effects.filter { $0.kind == "agent.execution" }.isEmpty)
            #expect(effects.filter { $0.kind == "realtime.publish" }.count == 3)
            transaction.publishCommitted()
            transaction.flushDeferredEffects()
        }
        #expect(accounts.tasksAndRemindersStore.taskRecords.count == 1)
        #expect(accounts.messagesAndThreadsStore.humanMessageRows.count == 2)
    }

    @Test func restoringStoppedIntentDoesNotPermitAutomaticLaunchAndHumanStartReleasesHeldWork() async throws {
        let (domain, server, machine, agent) = fixture()
        let conversation = channel(domain, server: server, agent: agent)
        _ = try await ready(domain, server: server, machine: machine)
        let stopRequest = AgentExecutionStopRequest(serverId: server, agentId: agent)
        _ = try await publish { try domain.requestStop(stopRequest) }
        let queuedId = try await publish {
            let message = append(domain, channel: conversation, content: "Resume only after human Start")
            let request = AgentExecutionDeliveryRequest(serverId: server, agentId: agent, channelId: conversation, messageId: message)
            let admission = try domain.requestDelivery(request)
            #expect(admission == nil)
            return request.commandId
        }
        let restoredAgents = AgentsRuntimeStore()
        try restoredAgents.restorePersistenceData(domain.agents.exportPersistenceData())
        let restored = AgentExecutionDomain(agents: restoredAgents, machines: domain.machines, oauth: domain.oauth,
                                            channels: domain.channels, messages: domain.messages)
        #expect(restoredAgents.state.execution.stopIntents?[stopRequest.commandId.uuidString]?.clearedByHumanStart == nil)
        #expect(restoredAgents.state.execution.heldDeliveries?[queuedId.uuidString]?.releasedCommandId == nil)
        #expect(restoredAgents.state.execution.connections[machine]?.ready == false)
        #expect(try await publish { try restored.requestAutomaticStartIfReady(.init(serverId: server, agentId: agent)) } == nil)
        let reconnected = AgentExecutionMachineContext(machineId: machine, serverId: server, connectionEpochId: "stop-restored-epoch")
        let capabilities = ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"]
        // This is controlled domain/protocol input. Restore invalidated the old
        // connection; recovery needs a newly opened epoch and matching inventory.
        try await publish {
            try restored.connectionOpened(reconnected)
            try restored.observeReady(reconnected, daemonInstanceId: "stop-daemon", capabilities: capabilities,
                runtimes: ["codex"], runningAgentIds: [], detectionComplete: true, unreliableAgentIds: [])
        }
        #expect(restoredAgents.state.execution.connections[machine]?.ready == true)
        #expect(restored.oauth.agentRuntimeInfo(id: agent)?.status == "stopped")
        #expect(restoredAgents.state.execution.heldDeliveries?[queuedId.uuidString]?.releasedCommandId == nil)
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            let human = try restored.requestStart(.init(serverId: server, agentId: agent, control: .humanStart))
            #expect(restored.oauth.agentRuntimeInfo(id: agent)?.status == "active")
            #expect(restoredAgents.state.serverAgents[agent]?.status == "active")
            #expect(restoredAgents.state.execution.stopIntents?[stopRequest.commandId.uuidString]?.clearedByHumanStart == human.commandId)
            let release = try #require(restoredAgents.state.execution.heldDeliveries?[queuedId.uuidString]?.releasedCommandId)
            #expect(release != queuedId)
            let command = try #require(restoredAgents.state.execution.commands[release.uuidString])
            #expect(command.kind == .delivery)
            #expect(command.launchId == human.launchId)
            #expect(command.connectionEpochId == reconnected.connectionEpochId)
            #expect(restoredAgents.state.execution.dispatches?[release.uuidString] == nil)
            #expect(restoredAgents.state.execution.agents[agent]?.processes.isEmpty == true)
            #expect(restoredAgents.state.execution.agents[agent]?.launches[human.launchId]?.startAccepted == false)
            _ = try restored.requestStop(stopRequest)
            #expect(restored.oauth.agentRuntimeInfo(id: agent)?.status == "active")
            try transaction.prepareCommit()
            let effects = try transaction.preparedDurableEffects()
            #expect(effects.count == 2)
            #expect(Set(effects.map(\.effectID)) == [human.commandId, release])
            transaction.publishCommitted()
            transaction.flushDeferredEffects()
        }
    }

    @Test func pendingDeliveryWaitsWhileStoppedAndAnAttemptedDeliveryIsNeverReissued() async throws {
        let (domain, server, machine, agent) = fixture()
        let conversation = channel(domain, server: server, agent: agent)
        let context = try await ready(domain, server: server, machine: machine)
        let first = try await publish {
            let message = append(domain, channel: conversation, content: "Not sent yet")
            return try #require(try domain.requestDelivery(.init(serverId: server, agentId: agent, channelId: conversation, messageId: message)))
        }
        let launch = try #require(domain.agents.state.execution.agents[agent]?.launches[first.launchId])
        let ack = try JSONSerialization.data(withJSONObject: ["type": "agent:start:ack", "agentId": agent, "launchId": launch.launchId,
            "startDispatchId": launch.startDispatchId, "queueState": "queued", "queueDepth": 0, "queueAgeMs": 0])
        _ = try await publish { try domain.stageIngress(context: context, type: "agent:start:ack", payload: ack) }
        let second = try await publish {
            let message = append(domain, channel: conversation, content: "Attempt already persisted")
            let admission = try #require(try domain.requestDelivery(.init(serverId: server, agentId: agent, channelId: conversation, messageId: message)))
            _ = try domain.beginDispatch(reference: .init(commandId: admission.commandId), context: context, deliverySequence: 2)
            return admission
        }
        _ = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        #expect(domain.resolveDispatch(reference: .init(commandId: first.commandId)) == .wait(reason: "agent_manually_stopped"))
        #expect(domain.agents.state.execution.heldDeliveries?[first.commandId.uuidString] != nil)
        #expect(domain.agents.state.execution.heldDeliveries?[second.commandId.uuidString] == nil)
        #expect(domain.agents.state.execution.dispatches?[second.commandId.uuidString]?.phase == .attempting)
        await #expect(throws: AgentExecutionError.manuallyStopped) {
            try await publish { try domain.beginDispatch(reference: .init(commandId: first.commandId), context: context, deliverySequence: 1) }
        }
        _ = try await publish { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        let release = try #require(domain.agents.state.execution.heldDeliveries?[first.commandId.uuidString]?.releasedCommandId)
        #expect(domain.agents.state.execution.commands[first.commandId.uuidString]?.status == .superseded)
        #expect(domain.agents.state.execution.commands[release.uuidString]?.deliveryId != first.deliveryId)
        #expect(domain.agents.state.execution.commands[second.commandId.uuidString]?.status == .superseded)
        #expect(domain.agents.state.execution.dispatches?[second.commandId.uuidString]?.phase == .attempting)
        #expect(domain.agents.state.execution.heldDeliveries?.count == 1)
    }

    @Test func noMachineStopUsesThePublishedServiceResponseAndRefusesNonmembers() async throws {
        let accounts = EmailLoginDirectory()
        let server = UUID().uuidString.lowercased()
        let owner = UUID().uuidString.lowercased()
        let member = UUID().uuidString.lowercased()
        let outsider = UUID().uuidString.lowercased()
        for (id, email) in [(owner, "stop-owner@slock.test"), (member, "stop-member@slock.test"), (outsider, "stop-outsider@slock.test")] {
            accounts.addAccount(id: id, email: email, password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: server, slug: "unassigned-stop", name: "Unassigned Stop", ownerId: owner)
        accounts.oauth.addMember(serverId: server, userId: member, role: "member")
        let agent = accounts.oauth.createAgent(serverId: server, name: "No machine", creatorUserId: owner, runtime: "codex")
        let token = accounts.mintAccessTokenForTesting(userId: member)
        let outsiderToken = accounts.mintAccessTokenForTesting(userId: outsider)
        let execution = AgentExecutionService(producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        let controls = accounts.agentMachineMigrationControl.bindingExecution(execution)
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            let response = try controls.stopAgent(authorization: "Bearer \(token)", agentId: agent, serverId: server)
            #expect(response.jsonBody.render() == "{\"ok\":true}")
            #expect(accounts.oauth.agentRuntimeInfo(id: agent)?.status == "stopped")
            let state = accounts.agentsRuntimeStore.state.execution
            #expect(state.stopIntents?.count == 1)
            #expect(state.stopIntents?.values.first?.machineId == nil)
            #expect(state.agents.isEmpty)
            #expect(state.commands.isEmpty)
            #expect(state.dispatches?.isEmpty ?? true)
            #expect(state.receipts.isEmpty && state.watermarks.isEmpty)
            do {
                _ = try controls.stopAgent(authorization: "Bearer \(outsiderToken)", agentId: agent, serverId: server)
                Issue.record("A nonmember must not stop an owned agent")
            } catch let error as any DomainError {
                #expect(error.status == 403)
            }
            try transaction.prepareCommit()
            #expect(try transaction.preparedDurableEffects().isEmpty)
            transaction.publishCommitted()
            transaction.flushDeferredEffects()
        }
        let restored = AgentsRuntimeStore()
        try restored.restorePersistenceData(accounts.agentsRuntimeStore.exportPersistenceData())
        #expect(restored.state.execution.stopIntents?.count == 1)
        #expect(restored.state.execution.agents.isEmpty)
    }

    @Test func humanStartReplayDoesNotClearANewerStop() async throws {
        let (domain, server, machine, agent) = fixture()
        _ = try await ready(domain, server: server, machine: machine)
        let human = AgentExecutionStartRequest(serverId: server, agentId: agent, control: .humanStart)
        let first = try await publish { try domain.requestStart(human) }
        let stop = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        let replay = try await publish { try domain.requestStart(human) }
        #expect(replay == first)
        #expect(domain.oauth.agentRuntimeInfo(id: agent)?.status == "stopped")
        #expect(domain.agents.state.execution.stopIntents?[stop.commandId.uuidString]?.clearedByHumanStart == nil)
        #expect(domain.agents.state.execution.agents[agent]?.launches.count == 1)
        _ = try domain.agents.exportPersistenceData()
    }

    @Test func resumingRechecksHeldDeliveryAuthorityWithoutLosingTheMessage() async throws {
        let (domain, server, machine, agent) = fixture()
        let conversation = channel(domain, server: server, agent: agent)
        _ = try await ready(domain, server: server, machine: machine)
        _ = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        let request = try await publish {
            let message = append(domain, channel: conversation, content: "Keep after access is revoked")
            let request = AgentExecutionDeliveryRequest(serverId: server, agentId: agent, channelId: conversation, messageId: message)
            let admission = try domain.requestDelivery(request)
            #expect(admission == nil)
            return request
        }
        domain.channels.mutex.withLock { $0.postableChannels[conversation]?.memberIds.remove(agent) }
        _ = try await publish { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        #expect(domain.agents.state.execution.heldDeliveries?[request.commandId.uuidString]?.cancelled == true)
        #expect(domain.agents.state.execution.heldDeliveries?[request.commandId.uuidString]?.releasedCommandId == nil)
        #expect(domain.agents.state.execution.commands.values.filter { $0.kind == .delivery }.isEmpty)
        #expect(domain.messages.humanMessageRows.contains { $0.id == request.messageId })
        #expect(domain.oauth.agentRuntimeInfo(id: agent)?.status == "active")
        _ = try domain.agents.exportPersistenceData()
    }

    private struct BindingServiceFixture: Sendable {
        let accounts: EmailLoginDirectory
        let domain: AgentExecutionDomain
        let execution: AgentExecutionService
        let controls: AgentMachineMigrationControlService
        let server: String
        let owner: String
        let agent: String
        let first: String
        let second: String
        let authorization: String
    }

    private func bindingServiceFixture() throws -> BindingServiceFixture {
        let accounts = EmailLoginDirectory()
        let owner = UUID().uuidString.lowercased()
        let server = UUID().uuidString.lowercased()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        accounts.addAccount(id: owner, email: "stop-binding@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "stop-binding", name: "Stop Binding", ownerId: owner)
        let agent = accounts.oauth.createAgent(serverId: server, name: "Binding executor", creatorUserId: owner, runtime: "codex")
        accounts.machinesAndComputersStore.machines = [first, second].map {
            MachineRecord(id: $0, serverId: server, userId: owner, name: "Computer", description: nil, apiKey: nil)
        }
        accounts.machinesAndComputersStore.machineOnline = [first: true, second: true]
        let authorization = "Bearer \(accounts.mintAccessTokenForTesting(userId: owner))"
        _ = try accounts.agentHostedMigration.assignAgentMachine(authorization: authorization, agentId: agent,
            request: .init(machineId: .machine(first)))
        let domain = AgentExecutionDomain(agents: accounts.agentsRuntimeStore, machines: accounts.machinesAndComputersStore,
            oauth: accounts.oauth, channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        let execution = AgentExecutionService(producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        return BindingServiceFixture(accounts: accounts, domain: domain, execution: execution,
            controls: accounts.agentMachineMigrationControl.bindingExecution(execution), server: server,
            owner: owner, agent: agent, first: first, second: second, authorization: authorization)
    }

    // This supplies controlled ready protocol input to the real retained domain;
    // it is not PostgreSQL, a Computer process, or actual Codex execution proof.
    private func readyBinding(_ f: BindingServiceFixture, machine: String) async throws -> AgentExecutionMachineContext {
        let context = AgentExecutionMachineContext(machineId: machine, serverId: f.server, connectionEpochId: UUID().uuidString)
        try await publish {
            try f.domain.connectionOpened(context)
            try f.domain.observeReady(context, daemonInstanceId: "binding-daemon-\(machine)",
                capabilities: ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"],
                runtimes: ["codex"], runningAgentIds: [], detectionComplete: true, unreliableAgentIds: [])
        }
        return context
    }

    @Test(arguments: [false, true])
    func publishedStopWithoutOwnedMachinePersistsOnlyLocalIntent(foreign: Bool) async throws {
        let f = try bindingServiceFixture()
        if foreign {
            f.accounts.oauth.addOwnedServer(id: "another-server", slug: "other-stop", name: "Other", ownerId: f.owner)
            f.accounts.machinesAndComputersStore.machines = [
                MachineRecord(id: f.first, serverId: "another-server", userId: f.owner, name: "Foreign", description: nil, apiKey: nil)
            ]
        } else {
            _ = try await publish {
                try f.accounts.computersFleet.deleteServerMachine(authorization: f.authorization, serverId: f.server, machineId: f.first)
            }
        }
        #expect(f.accounts.agentsRuntimeStore.agentMachineIds[f.agent] == f.first)
        let response = try await publish {
            try f.controls.stopAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server)
        }
        #expect(response.jsonBody.render() == "{\"ok\":true}")
        #expect(f.accounts.oauth.agentRuntimeInfo(id: f.agent)?.status == "stopped")
        let state = f.accounts.agentsRuntimeStore.state.execution
        #expect(state.stopIntents?.count == 1)
        #expect(state.stopIntents?.values.first?.machineId == nil)
        #expect(state.agents.isEmpty && state.commands.isEmpty)
        #expect(state.dispatches?.isEmpty ?? true)
        #expect(state.receipts.isEmpty && state.watermarks.isEmpty)
        let restored = AgentsRuntimeStore()
        try restored.restorePersistenceData(f.accounts.agentsRuntimeStore.exportPersistenceData())
        #expect(restored.state.execution.stopIntents?.count == 1)
        #expect(restored.state.execution.commands.isEmpty)
    }

    @Test func publicAssignmentBeforeAnyLaunchRetainsStopHistoryAndHumanStartReleasesHeldTasks() async throws {
        let f = try bindingServiceFixture()
        _ = try await publish { try f.controls.stopAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server) }
        let old = try #require(f.accounts.agentsRuntimeStore.state.execution.commands.values.first)
        let conversation = f.accounts.oauth.createChannel(serverId: f.server, name: "held-binding", creatorUserId: f.owner)
        f.accounts.seedPostableChannelForTesting(serverId: f.server, channelId: conversation, name: "held-binding", humanIds: [f.owner], agentIds: [f.agent])
        f.accounts.oauth.addChannelAgent(channelId: conversation, agentId: f.agent)
        let catalog = f.accounts.taskCatalog.bindingExecution(f.execution)
        let writer = ChannelMessagingService(dependencies: ChannelMessagingDependencies(auth: f.accounts.authCore, oauth: f.accounts.oauth, catalog: catalog))
        _ = try await publish {
            try writer.createChannelTasks(authorization: f.authorization, serverId: f.server, channelId: conversation,
                body: "{\"tasks\":[{\"title\":\"Preserve this stopped task\"}]}")
        }
        let originalMessages = Set(f.accounts.messagesAndThreadsStore.humanMessageRows.map(\.id))
        let originalHeld = Set((f.accounts.agentsRuntimeStore.state.execution.heldDeliveries ?? [:]).keys)
        #expect(originalHeld.count == 2)
        #expect(f.accounts.agentsRuntimeStore.assignMachine(agentId: f.agent, machineId: f.second) == false)
        #expect(f.accounts.agentsRuntimeStore.agentMachineIds[f.agent] == f.first)
        let assigned = try await publish {
            try f.accounts.agentHostedMigration.assignAgentMachine(authorization: f.authorization, agentId: f.agent,
                request: .init(machineId: .machine(f.second)))
        }
        #expect(assigned == OkResponse())
        let moved = f.accounts.agentsRuntimeStore.state.execution
        #expect(f.accounts.agentsRuntimeStore.agentMachineIds[f.agent] == f.second)
        #expect(moved.agents[f.agent]?.machineId == f.second)
        #expect(moved.agents[f.agent]?.takeoverEpoch == 1)
        #expect(moved.agents[f.agent]?.launches.isEmpty == true)
        #expect(moved.commands[old.commandId.uuidString]?.status == .superseded)
        #expect(moved.stopIntents?[old.commandId.uuidString]?.machineId == f.first)
        #expect(moved.stopIntents?[old.commandId.uuidString]?.retiredByAssignmentEpoch == 1)
        #expect(moved.stopIntents?[old.commandId.uuidString]?.clearedByHumanStart == nil)
        #expect(moved.dispatches?.isEmpty ?? true)
        try f.accounts.agentsRuntimeStore.restorePersistenceData(f.accounts.agentsRuntimeStore.exportPersistenceData())
        let context = try await readyBinding(f, machine: f.second)
        let automatic = try await publish {
            try f.execution.requestAutomaticStartIfReady(.init(serverId: f.server, agentId: f.agent))
        }
        #expect(automatic == nil)
        _ = try await publish { try f.controls.startAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server) }
        let resumed = f.accounts.agentsRuntimeStore.state.execution
        let start = try #require(resumed.commands.values.first { $0.kind == .start })
        #expect(start.machineId == f.second && start.connectionEpochId == context.connectionEpochId)
        #expect(start.takeoverEpoch == 2)
        #expect(resumed.commands[old.commandId.uuidString]?.machineId == f.first)
        #expect(resumed.stopIntents?[old.commandId.uuidString]?.clearedByHumanStart == start.commandId)
        for key in originalHeld {
            let held = try #require(resumed.heldDeliveries?[key])
            let released = try #require(held.releasedCommandId)
            let delivery = try #require(resumed.commands[released.uuidString])
            #expect(released.uuidString != key)
            #expect(delivery.machineId == f.second && delivery.launchId == start.launchId)
            #expect(delivery.messageId == held.messageId)
        }
        #expect(Set(f.accounts.messagesAndThreadsStore.humanMessageRows.map(\.id)) == originalMessages)
        #expect(f.accounts.tasksAndRemindersStore.taskRecords.first?.status == "todo")
        _ = try await publish { try f.execution.requestStop(.init(commandId: old.commandId, serverId: f.server, agentId: f.agent)) }
        #expect(f.accounts.oauth.agentRuntimeInfo(id: f.agent)?.status == "active")
        if case .obsolete = f.domain.resolveDispatch(reference: .init(commandId: old.commandId)) {} else {
            Issue.record("Retired stop must not dispatch to either machine")
        }
        var corrupt = resumed
        corrupt.dispatches = [old.commandId.uuidString: AgentExecutionDispatch(connectionEpochId: "old-attempt", deliverySequence: nil, phase: .attempting)]
        #expect(throws: RuntimePersistenceError.invalidSnapshot) { try corrupt.validate() }
        var missingProof = resumed
        missingProof.stopIntents?[old.commandId.uuidString]?.retiredByAssignmentEpoch = nil
        #expect(throws: RuntimePersistenceError.invalidSnapshot) { try missingProof.validate() }
        var wrongEpoch = resumed
        wrongEpoch.stopIntents?[old.commandId.uuidString]?.retiredByAssignmentEpoch = old.takeoverEpoch
        #expect(throws: RuntimePersistenceError.invalidSnapshot) { try wrongEpoch.validate() }
        _ = try f.accounts.agentsRuntimeStore.exportPersistenceData()
    }

    @Test(arguments: ["launch", "attempt", "unreliable", "foreign"])
    func publishedAssignmentRefusesUnprovenHistoryWithoutAnyWrite(history: String) async throws {
        let f = try bindingServiceFixture()
        if history == "foreign" {
            f.accounts.oauth.addOwnedServer(id: "another-server", slug: "other-stop", name: "Other", ownerId: f.owner)
            f.accounts.machinesAndComputersStore.machines = [
                MachineRecord(id: f.first, serverId: f.server, userId: f.owner, name: "First", description: nil, apiKey: nil),
                MachineRecord(id: f.second, serverId: "another-server", userId: f.owner, name: "Foreign", description: nil, apiKey: nil)
            ]
        }
        let context = try await readyBinding(f, machine: f.first)
        if history == "launch" {
            _ = try await publish { try f.controls.startAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server) }
        } else if history == "unreliable" {
            try await publish {
                try f.domain.observeReady(context, daemonInstanceId: "binding-daemon-\(f.first)",
                    capabilities: ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"],
                    runtimes: ["codex"], runningAgentIds: [], detectionComplete: true, unreliableAgentIds: [f.agent])
            }
        }
        _ = try await publish { try f.controls.stopAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server) }
        if history == "attempt" {
            let stop = try #require(f.accounts.agentsRuntimeStore.state.execution.commands.values.first { $0.kind == .stop })
            _ = try await publish { try f.domain.beginDispatch(reference: .init(commandId: stop.commandId), context: context, deliverySequence: nil) }
        }
        let before = try JSONDecoder().decode(JSONValue.self, from: f.accounts.agentsRuntimeStore.exportPersistenceData())
        try await publish {
            #expect(throws: AgentMigrationControlError.assignmentExecutionRequiresRecovery) {
                try f.accounts.agentHostedMigration.assignAgentMachine(authorization: f.authorization, agentId: f.agent,
                    request: .init(machineId: .machine(f.second)))
            }
            #expect(f.accounts.agentsRuntimeStore.assignMachine(agentId: f.agent, machineId: f.second) == false)
        }
        let after = try JSONDecoder().decode(JSONValue.self, from: f.accounts.agentsRuntimeStore.exportPersistenceData())
        #expect(before == after)
        #expect(f.accounts.agentsRuntimeStore.agentMachineIds[f.agent] == f.first)
    }

    @Test func publicAssignmentRollbackKeepsBindingAndStopProofTogether() async throws {
        let f = try bindingServiceFixture()
        _ = try await publish { try f.controls.stopAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server) }
        let old = try #require(f.accounts.agentsRuntimeStore.state.execution.commands.values.first)
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            _ = try f.accounts.agentHostedMigration.assignAgentMachine(authorization: f.authorization, agentId: f.agent,
                request: .init(machineId: .machine(f.second)))
            #expect(f.accounts.agentsRuntimeStore.agentMachineIds[f.agent] == f.second)
            try transaction.prepareCommit()
            transaction.discard()
        }
        let state = f.accounts.agentsRuntimeStore.state.execution
        #expect(f.accounts.agentsRuntimeStore.agentMachineIds[f.agent] == f.first)
        #expect(state.agents[f.agent]?.machineId == f.first)
        #expect(state.agents[f.agent]?.takeoverEpoch == 0)
        #expect(state.commands[old.commandId.uuidString] == old)
        #expect(state.stopIntents?[old.commandId.uuidString]?.retiredByAssignmentEpoch == nil)
    }

    @Test func legacyExecutionSnapshotsDoNotRequireTheNewControlFields() throws {
        let legacy = Data("{\"connections\":{},\"agents\":{},\"commands\":{},\"receipts\":{},\"watermarks\":{}}".utf8)
        let state = try JSONDecoder().decode(AgentExecutionState.self, from: legacy)
        try state.validate()
        #expect(state.stopIntents == nil)
        #expect(state.heldDeliveries == nil)
    }

    @Test func stopIntentAndCanonicalStatusRollbackTogether() async throws {
        let (domain, server, _, agent) = fixture()
        domain.agents.agentMachineIds = [:]
        let original = domain.oauth.agentRuntimeInfo(id: agent)?.status
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            _ = try domain.requestStop(.init(serverId: server, agentId: agent))
            #expect(domain.oauth.agentRuntimeInfo(id: agent)?.status == "stopped")
            try transaction.prepareCommit()
            transaction.discard()
        }
        #expect(domain.oauth.agentRuntimeInfo(id: agent)?.status == original)
        #expect(domain.agents.state.execution.stopIntents?.isEmpty ?? true)
        #expect(domain.agents.state.execution.commands.isEmpty)
    }
}
