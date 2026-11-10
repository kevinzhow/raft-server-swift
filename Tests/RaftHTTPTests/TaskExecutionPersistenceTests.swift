// These real pending-UoW tests use the production shared transaction domain.
// Run this filter and the complete suite with --no-parallel. They do not stand
// in for PostgreSQL commit, daemon receipt, execution or task completion.
import Foundation
@testable import RaftHTTP
import RaftShared
import Testing
import TestSupport

@Test func taskExecutionAgentSendCoStagesOneRealMessageReceiptAndPublicationOnReplay() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "task-outbox@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-outbox", name: "Outbox", ownerId: userId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "outbox-agent", creatorUserId: userId, runtime: "codex")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "outbox-room", creatorUserId: userId)
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "outbox-room", humanIds: [userId], agentIds: [agentId])
    let credential = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "outbox")
    let service = accounts.actionCardExecute
    let context = TransactionContext()
    let publication = try await withTransactionContext(context) {
        let request = AgentSendMessageRequest(target: "#outbox-room", content: "A real CLI send", idempotencyKey: "task68-send")
        let first = try service.agentSendMessage(authorization: "Bearer \(credential)", body: request, v2: false)
        let replay = try service.agentSendMessage(authorization: "Bearer \(credential)", body: request, v2: false)
        let firstBody = try JSONSerialization.jsonObject(with: Data(first.jsonBody.render().utf8)) as? [String: Any] ?? [:]
        let replayBody = try JSONSerialization.jsonObject(with: Data(replay.jsonBody.render().utf8)) as? [String: Any] ?? [:]
        let messageId = try #require(firstBody["messageId"] as? String)
        #expect(replayBody["messageId"] as? String == messageId)
        let messages = accounts.messagesAndThreadsStore.humanMessageRows.filter { $0.channelId == channelId }
        #expect(messages.count == 1)
        #expect(messages.first?.id == messageId)
        #expect(messages.first?.content == "A real CLI send")
        let receipt = accounts.managedMCPAndCardsStore.sendReceipt(key: "\(serverId)\n\(agentId)\ntask68-send")
        #expect(receipt?.messageId == messageId)
        #expect(receipt?.messageSeq == messages.first?.seq)
        try context.prepareCommit()
        let effects = try context.preparedDurableEffects()
        #expect(effects.count == 1)
        let effect = try #require(effects.first)
        #expect(effect.kind == "realtime.publish")
        let publication = try JSONDecoder().decode(RealtimePublication.self, from: effect.payload)
        #expect(effect.effectID == publication.eventId)
        #expect(publication.codec == "raft-realtime-publication-v1")
        #expect(publication.room == "channel:\(channelId)")
        #expect(publication.event == "message:new")
        let frame = try JSONSerialization.jsonObject(with: Data(publication.payloadJSON.utf8)) as? [String: Any] ?? [:]
        #expect(frame["id"] as? String == messageId)
        #expect(frame["content"] as? String == "A real CLI send")
        #expect(frame["seq"] as? Int == receipt?.messageSeq)
        // A pending transaction is not a database commit or a sent socket frame.
        context.discard()
        return publication
    }
    #expect(publication.event == "message:new")
    #expect(accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
    #expect(accounts.managedMCPAndCardsStore.sendReceipt(key: "\(serverId)\n\(agentId)\ntask68-send") == nil)
}

@Test func taskExecutionCanonicalRowsHostsSummaryAndPublicationsShareThePendingTransaction() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "task-atomic@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-atomic", name: "Atomic", ownerId: userId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "task-atomic", creatorUserId: userId)
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "task-atomic", humanIds: [userId], agentIds: [])
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let service = ChannelMessagingService(dependencies: ChannelMessagingDependencies(auth: accounts.authCore, oauth: accounts.oauth, catalog: accounts.taskCatalog))
    let context = TransactionContext()
    try await withTransactionContext(context) {
        let response = try service.createChannelTasks(authorization: "Bearer \(token)", serverId: serverId, channelId: channelId,
            body: "{\"tasks\":[{\"title\":\"first\"},{\"title\":\"second\"}]}")
        #expect(response.tasks.count == 2)
        let tasks = accounts.tasksAndRemindersStore.taskRecords
        let rows = accounts.messagesAndThreadsStore.humanMessageRows
        #expect(tasks.count == 2)
        #expect(rows.count == 3)
        for task in tasks {
            let host = try #require(rows.first { $0.id == task.messageId })
            #expect(host.content == task.title)
            #expect(host.messageType == "chat")
            #expect(host.taskStatus == nil)
            #expect(host.taskNumber == nil)
        }
        #expect(rows.last?.content == "📋 2 new tasks created: #1 \"first\", #2 \"second\"")
        try context.prepareCommit()
        let effects = try context.preparedDurableEffects()
        #expect(effects.count == 4)
        #expect(Set(effects.map(\.effectID)).count == 4)
        let publications = try effects.map { try JSONDecoder().decode(RealtimePublication.self, from: $0.payload) }
        #expect(publications.map(\.event) == ["message:new", "message:new", "task:created", "message:new"])
        let messageIds = try publications.filter { $0.event == "message:new" }.map { publication in
            let payload = try JSONSerialization.jsonObject(with: Data(publication.payloadJSON.utf8)) as? [String: Any] ?? [:]
            return try #require(payload["id"] as? String)
        }
        #expect(messageIds == rows.map(\.id))
        context.discard()
    }
    #expect(accounts.tasksAndRemindersStore.taskRecords.isEmpty)
    #expect(accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
}

@Test func taskExecutionPublicProducersStageStartDeliveryAssignmentAndStopWithoutClaimingRunning() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "task-producers@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-producers", name: "Producers", ownerId: userId)
    let machineId = accounts.registerMachine(serverId: serverId, userId: userId, name: "Codex Computer")
    accounts.setMachineOnline(machineId: machineId, online: true)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "task-producers", creatorUserId: userId)
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "task-producers", humanIds: [userId], agentIds: [])
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let execution = AgentExecutionService(producerTransactionAgents: accounts.agentsRuntimeStore,
        machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
        channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
    let surface = accounts.agentSurface.bindingExecution(execution)
    let catalog = accounts.taskCatalog.bindingExecution(execution)
    let writer = ChannelMessagingService(dependencies: ChannelMessagingDependencies(auth: accounts.authCore, oauth: accounts.oauth, catalog: catalog))
    let labs = accounts.tasksAndLabs.bindingExecution(execution)
    let controls = accounts.agentMachineMigrationControl.bindingExecution(execution)
    let domain = AgentExecutionDomain(agents: accounts.agentsRuntimeStore, machines: accounts.machinesAndComputersStore,
        oauth: accounts.oauth, channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
    let context = TransactionContext()
    try await withTransactionContext(context) {
        // Unit admission preconditions; no actual daemon process or ACK is claimed.
        let machine = AgentExecutionMachineContext(machineId: machineId, serverId: serverId, connectionEpochId: "task68-epoch")
        try domain.connectionOpened(machine)
        try domain.connectionReady(machine, daemonInstanceId: "task68-daemon", runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
        let body = try JSONDecoder().decode(LegacyJSONObjectBody.self, from: Data("{\"name\":\"task-producer-agent\",\"machineId\":\"\(machineId)\",\"runtimeConfig\":{\"version\":2,\"runtime\":\"codex\"}}".utf8))
        let created = try surface.createAgent(authorization: "Bearer \(token)", serverId: serverId, body: body)
        let createdJSON = try JSONSerialization.jsonObject(with: Data(created.jsonBody.render().utf8)) as? [String: Any] ?? [:]
        let agentId = try #require(createdJSON["id"] as? String)
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, name: "task-producers")
        let taskReply = try writer.createChannelTasks(authorization: "Bearer \(token)", serverId: serverId, channelId: channelId,
            body: "{\"tasks\":[{\"title\":\"Execute real shared work\"}]}")
        let taskId = try #require(taskReply.tasks.first?.id)
        _ = try labs.assignTask(authorization: "Bearer \(token)", serverId: serverId, taskId: taskId,
                               body: TaskAssigneePatchRequest(assignee: .set(type: "agent", id: agentId), expectedRevision: .value(0)))
        let beforeControl = accounts.agentsRuntimeStore.state.execution.commands.values
        #expect(beforeControl.filter { $0.kind == .start }.count == 1)
        #expect(beforeControl.filter { $0.kind == .delivery }.count == 3)
        #expect(beforeControl.filter { $0.kind == .start }.allSatisfy { !$0.humanStart })
        let messages = accounts.messagesAndThreadsStore.humanMessageRows
        for delivery in beforeControl where delivery.kind == .delivery {
            #expect(messages.contains { $0.id == delivery.messageId })
            #expect(delivery.deliveryId != nil)
        }
        _ = try controls.startAgent(authorization: "Bearer \(token)", agentId: agentId, serverId: serverId)
        let stopped = try controls.stopAgent(authorization: "Bearer \(token)", agentId: agentId, serverId: serverId)
        #expect(stopped.jsonBody.render() == "{\"ok\":true,\"appliesOnReconnect\":true}")
        let state = accounts.agentsRuntimeStore.state.execution
        let commands = state.commands.values
        #expect(commands.filter { $0.kind == .start && $0.humanStart }.count == 1)
        #expect(commands.filter { $0.kind == .stop }.count == 1)
        let agent = try #require(state.agents[agentId])
        #expect(agent.launches.values.allSatisfy { $0.processInstanceId == nil && !$0.startAccepted })
        let task = try #require(accounts.tasksAndRemindersStore.taskRecords.first { $0.id == taskId })
        #expect(task.status == "todo")
        #expect(task.claimedAt == nil)
        #expect(task.assigneeId == agentId)
        try context.prepareCommit()
        let effects = try context.preparedDurableEffects()
        #expect(effects.filter { $0.kind == "agent.execution" }.count == 6)
        for effect in effects where effect.kind == "agent.execution" {
            let reference = try JSONDecoder().decode(AgentExecutionIntentReference.self, from: effect.payload)
            #expect(state.commands[reference.commandId.uuidString]?.commandId == effect.effectID)
        }
        context.discard()
    }
    #expect(accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
    #expect(accounts.tasksAndRemindersStore.taskRecords.isEmpty)
    #expect(accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
}
