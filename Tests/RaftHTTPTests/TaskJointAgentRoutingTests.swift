import Foundation
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

@Suite(.serialized) struct TaskJointAgentRoutingTests {
    @Test(arguments: [false, true])
    func peerCodexAssignmentKeepsTheOwningProjectionAndRealStoppedDelivery(_ commit: Bool) async throws {
        let accounts = EmailLoginDirectory()
        let ownerA = UUID().uuidString.lowercased()
        let ownerB = UUID().uuidString.lowercased()
        let serverA = UUID().uuidString.lowercased()
        let serverB = UUID().uuidString.lowercased()
        for (user, prefix) in [(ownerA, "routing-a"), (ownerB, "routing-b")] {
            accounts.addAccount(id: user, email: "\(prefix)-\(user)@slock.test", password: "password123")
            accounts.markEmailVerified(userId: user)
        }
        accounts.oauth.addOwnedServer(id: serverA, slug: "routing-a", name: "Routing A", ownerId: ownerA)
        accounts.oauth.addOwnedServer(id: serverB, slug: "routing-b", name: "Routing B", ownerId: ownerB)
        let canonical = accounts.oauth.createChannel(serverId: serverA, name: "routing-storage", creatorUserId: ownerA)
        accounts.addPostableChannel(serverId: serverA, channelId: canonical, memberId: ownerA, name: "routing-storage")
        let localA = accounts.oauth.createChannel(serverId: serverA, name: "routing-a", creatorUserId: ownerA, type: "joint")
        let localB = accounts.oauth.createChannel(serverId: serverB, name: "routing-b", creatorUserId: ownerB, type: "joint")
        for (local, server, owner) in [(localA, serverA, ownerA), (localB, serverB, ownerB)] {
            accounts.addPostableChannel(serverId: server, channelId: local, memberId: owner, kind: "joint", name: "routing")
            accounts.oauth.addChannelHuman(channelId: local, userId: owner)
            accounts.addJointChannelProjection(localChannelId: local, canonicalChannelId: canonical, serverId: server)
        }
        let agent = accounts.oauth.createAgent(serverId: serverB, name: "Actual B Codex", creatorUserId: ownerB, runtime: "codex")
        let machine = accounts.registerMachine(serverId: serverB, userId: ownerB, name: "Actual B machine binding")
        accounts.agentsRuntimeStore.bindMachine(agentId: agent, machineId: machine)
        accounts.oauth.addChannelAgent(channelId: localB, agentId: agent)
        accounts.addPostableChannel(serverId: serverB, channelId: localB, memberId: agent, kind: "joint", name: "routing")
        let execution = AgentExecutionService(producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        let catalog = accounts.taskCatalog.bindingExecution(execution)
        let writer = ChannelMessagingService(dependencies: ChannelMessagingDependencies(auth: accounts.authCore, oauth: accounts.oauth, catalog: catalog))
        let labs = accounts.tasksAndLabs.bindingExecution(execution)
        let token = accounts.mintAccessTokenForTesting(userId: ownerA)
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            // Real retained Stop intent: no synthetic connectionReady/online,
            // provider result, daemon ACK or process execution is used.
            let stopped = try execution.requestStop(.init(serverId: serverB, agentId: agent))
            #expect(stopped.requiresMachineDispatch)
            let created = try writer.createChannelTasks(authorization: "Bearer \(token)", serverId: serverA,
                channelId: localA, body: #"{"tasks":[{"title":"Route the B agent under B"}]}"#)
            let taskId = try #require(created.tasks.first?.id)
            let hostId = try #require(accounts.tasksAndRemindersStore.task(id: taskId)?.messageId)
            let hostBefore = try #require(accounts.messagesAndThreadsStore.humanMessageRows.first { $0.id == hostId })
            let assigned = try labs.assignTask(authorization: "Bearer \(token)", serverId: serverA, taskId: taskId,
                body: TaskAssigneePatchRequest(assignee: .set(type: "agent", id: agent), expectedRevision: .value(0)))
            let assignedJSON = try #require(try JSONSerialization.jsonObject(
                with: Data(assigned.task.jsonBody.render().utf8)) as? [String: Any])
            #expect(assignedJSON["channelId"] as? String == localA)
            #expect(assignedJSON["claimedById"] as? String == agent)
            #expect(assignedJSON["revision"] as? Int == 1)
            #expect(accounts.tasksAndRemindersStore.task(id: taskId)?.assigneeId == agent)
            let notices = accounts.messagesAndThreadsStore.humanMessageRows.filter { $0.systemSubtype == "task.lifecycle_thread" }
            let notice = try #require(notices.last)
            #expect(notice.causalActorId == ownerA)
            let thread = try #require(accounts.serversAndChannelsStore.postableChannel(id: notice.channelId))
            #expect(thread.serverId == serverB)
            #expect(thread.parentChannelId == localB)
            #expect(thread.parentMessageId == hostId)
            #expect(!thread.memberIds.contains(ownerA))
            #expect(thread.memberIds.contains(agent))
            #expect(accounts.oauth.channelInfo(id: notice.channelId)?.serverId == serverB)
            #expect(!accounts.oauth.isChannelParticipant(channelId: notice.channelId, userId: ownerA))
            #expect(accounts.oauth.memberRole(serverId: serverB, userId: ownerA) == nil)
            #expect(!accounts.messagesAndThreadsStore.threadFollowSnapshot().follows.contains("\(serverB)\n\(ownerA)\n\(notice.channelId)"))
            let held = Array((accounts.agentsRuntimeStore.state.execution.heldDeliveries ?? [:]).values)
            let routed = try #require(held.first { $0.messageId == notice.id })
            #expect(routed.serverId == serverB)
            #expect(routed.agentId == agent)
            #expect(routed.channelId == notice.channelId)
            #expect(held.allSatisfy { $0.serverId == serverB && $0.agentId == agent })
            #expect(accounts.agentsRuntimeStore.agentMachineIds[agent] == machine)
            #expect(accounts.machinesAndComputersStore.machines.contains { $0.id == machine && $0.serverId == serverB })
            let commands = accounts.agentsRuntimeStore.state.execution.commands
            #expect(commands.values.allSatisfy { $0.kind == .stop })
            let hostAfter = try #require(accounts.messagesAndThreadsStore.humanMessageRows.first { $0.id == hostId })
            #expect(hostAfter.channelId == canonical)
            #expect(hostAfter.content == hostBefore.content)
            #expect(hostAfter.createdAt == hostBefore.createdAt)
            #expect(hostAfter.taskStatus == hostBefore.taskStatus)
            try transaction.prepareCommit()
            let effects = try transaction.preparedDurableEffects()
            #expect(effects.filter { $0.kind == "agent.execution" }.count == 1)
            for effect in effects where effect.kind == "agent.execution" {
                let reference = try JSONDecoder().decode(AgentExecutionIntentReference.self, from: effect.payload)
                let command = try #require(commands[reference.commandId.uuidString])
                #expect(command.serverId == serverB)
                #expect(command.machineId == machine)
                #expect(command.agentId == agent)
                #expect(command.kind == .stop)
            }
            if commit { transaction.publishCommitted(); transaction.flushDeferredEffects() }
            else { transaction.discard() }
        }
        if commit {
            #expect(accounts.tasksAndRemindersStore.taskRecords.count == 1)
            #expect(accounts.agentsRuntimeStore.state.execution.heldDeliveries?.isEmpty == false)
        } else {
            #expect(accounts.tasksAndRemindersStore.taskRecords.isEmpty)
            #expect(accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
            #expect(accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
            #expect(accounts.agentsRuntimeStore.state.execution.heldDeliveries?.isEmpty ?? true)
        }
    }
}
