import Foundation
import Testing
import TestSupport
import RaftShared
@testable import RaftHTTP

// Pending transactions use the production shared domain. Run with --no-parallel.
// Discard is not evidence of a PostgreSQL commit, socket write or Codex execution.
private struct MaterializationFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let machineId: String
    let agentId: String
    let userId: String
    let channelId: String

    init() throws {
        let accounts = EmailLoginDirectory()
        let userId = UUID().uuidString.lowercased()
        let serverId = UUID().uuidString.lowercased()
        accounts.addAccount(id: userId, email: "materialization@slock.test", password: "password123")
        accounts.markEmailVerified(userId: userId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "materialization", name: "Materialization", ownerId: userId)
        let machineId = accounts.registerMachine(serverId: serverId, userId: userId, name: "Actual Computer")
        let token = accounts.mintAccessTokenForTesting(userId: userId)
        let body = try JSONDecoder().decode(LegacyJSONObjectBody.self, from: Data("{\"name\":\"materializer-agent\",\"description\":\"real configured agent\",\"machineId\":\"\(machineId)\",\"runtimeConfig\":{\"version\":1,\"runtime\":\"codex\",\"model\":{\"kind\":\"preset\",\"id\":\"gpt-5.3-codex\"},\"reasoningEffort\":\"high\",\"envVars\":{\"TASK74_AGENT_VALUE\":\"agent-only\"}}}".utf8))
        let created = try accounts.agentSurface.createAgent(authorization: "Bearer \(token)", serverId: serverId, body: body)
        let object = try JSONSerialization.jsonObject(with: Data(created.jsonBody.render().utf8)) as? [String: Any] ?? [:]
        let agentId = try #require(object["id"] as? String)
        let channelId = accounts.oauth.createChannel(serverId: serverId, name: "materialization", creatorUserId: userId)
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "materialization", humanIds: [userId], agentIds: [agentId])
        self.accounts = accounts
        self.userId = userId
        self.serverId = serverId
        self.machineId = machineId
        self.agentId = agentId
        self.channelId = channelId
    }

    var domain: AgentExecutionDomain {
        AgentExecutionDomain(agents: accounts.agentsRuntimeStore, machines: accounts.machinesAndComputersStore,
                             oauth: accounts.oauth, channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
    }

    func materializer(serverURL: String = "https://raft.example.test") -> AgentExecutionMaterializationService {
        AgentExecutionMaterializationService(transactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth, channels: accounts.serversAndChannelsStore,
            messages: accounts.messagesAndThreadsStore, profiles: accounts.authProfileStore,
            tasks: accounts.tasksAndRemindersStore, serverURL: serverURL)
    }

    func stageStart() throws -> AgentExecutionCommand {
        let machine = AgentExecutionMachineContext(machineId: machineId, serverId: serverId, connectionEpochId: "materialization-epoch")
        try domain.connectionOpened(machine)
        try domain.connectionReady(machine, daemonInstanceId: "materialization-daemon", runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
        let admission = try domain.requestStart(.init(serverId: serverId, agentId: agentId))
        return try #require(accounts.agentsRuntimeStore.state.execution.commands[admission.commandId.uuidString])
    }
}

private func materializationObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func agentExecutionMaterializationReusesOneScopedLaunchCredentialAndRollsItBack() async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    try await withTransactionContext(context) {
        defer { context.discard() }
        let command = try fixture.stageStart()
        guard case .start(let first) = try service.materializeInTransaction(command: command),
              case .start(let retry) = try service.materializeInTransaction(command: command) else { Issue.record("Expected start configuration"); return }
        let body = try materializationObject(first)
        let again = try materializationObject(retry)
        let key = try #require(body["agentCredentialKey"] as? String)
        let credentialId = try #require(body["agentCredentialId"] as? String)
        #expect(key.hasPrefix("sk_agent_"))
        #expect(again["agentCredentialKey"] as? String == key)
        #expect(again["agentCredentialId"] as? String == credentialId)
        #expect(body["runtime"] as? String == "codex")
        #expect(body["model"] as? String == "gpt-5.3-codex")
        #expect(body["reasoningEffort"] as? String == "high")
        #expect(body["serverUrl"] as? String == "https://raft.example.test")
        #expect(body["authToken"] as? String == "")
        let storedConfig = try #require(fixture.accounts.oauth.agentRuntimeInfo(id: fixture.agentId)?.runtimeConfigJSON)
        let storedValue = try JSONDecoder().decode(JSONValue.self, from: Data(storedConfig.utf8))
        let projectedConfig = try JSONSerialization.data(withJSONObject: try #require(body["runtimeConfig"]))
        let projectedValue = try JSONDecoder().decode(JSONValue.self, from: projectedConfig)
        #expect(projectedValue == storedValue)
        guard case .object(let runtimeConfig) = projectedValue else { Issue.record("Expected runtime config object"); return }
        #expect(runtimeConfig["version"] == .integer(1))
        #expect(body["sessionId"] is NSNull)
        #expect(body["description"] is NSNull || body["description"] is String)
        #expect(body["envVars"] as? [String: String] == ["TASK74_AGENT_VALUE": "agent-only"])
        let runtime = try #require(body["runtimeContext"] as? [String: Any])
        #expect(runtime["agentId"] as? String == fixture.agentId)
        #expect(runtime["serverId"] as? String == fixture.serverId)
        #expect(runtime["machineId"] as? String == fixture.machineId)
        #expect(runtime["machineName"] as? String == "Actual Computer")
        let store = fixture.accounts.agentsRuntimeStore
        #expect(store.agentCredential(token: key)?.agentId == fixture.agentId)
        #expect(store.agentCredential(token: key)?.scopes.contains("send") == true)
        #expect(store.credentials(agentId: fixture.agentId).count == 1)
        #expect(store.state.execution.agents[fixture.agentId]?.launches[command.launchId]?.runnerCredentialId == credentialId)
        try context.prepareCommit()
        let effects = try context.preparedDurableEffects()
        #expect(effects.count == 1)
        let reference = try #require(effects.first)
        #expect(try materializationObject(reference.payload).keys.sorted() == ["commandId"])
        #expect(!String(decoding: reference.payload, as: UTF8.self).contains(key))
    }
    #expect(fixture.accounts.agentsRuntimeStore.credentials(agentId: fixture.agentId).isEmpty)
    #expect(fixture.accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
}

@Test func agentExecutionMaterializationNeverRemintsARevokedLaunchCredential() async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    try await withTransactionContext(context) {
        defer { context.discard() }
        let command = try fixture.stageStart()
        guard case .start(let config) = try service.materializeInTransaction(command: command) else { Issue.record("Expected configuration"); return }
        let credentialId = try #require(try materializationObject(config)["agentCredentialId"] as? String)
        #expect(fixture.accounts.agentsRuntimeStore.revokeCredential(agentId: fixture.agentId, credentialId: credentialId, now: Date()))
        #expect(throws: AgentExecutionMaterializationError.credentialUnavailable) {
            try service.materializeInTransaction(command: command)
        }
        #expect(fixture.accounts.agentsRuntimeStore.credentials(agentId: fixture.agentId).count == 1)
    }
}

@Test func agentExecutionMaterializationProjectsRealCanonicalTaskMessageAndSequence() async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    try await withTransactionContext(context) {
        defer { context.discard() }
        _ = try fixture.stageStart()
        let exec = AgentExecutionService(producerTransactionAgents: fixture.accounts.agentsRuntimeStore,
            machines: fixture.accounts.machinesAndComputersStore, oauth: fixture.accounts.oauth,
            channels: fixture.accounts.serversAndChannelsStore, messages: fixture.accounts.messagesAndThreadsStore)
        let batch = try fixture.accounts.taskCatalog.bindingExecution(exec).createCanonicalTasks(
            serverId: fixture.serverId, channelId: fixture.channelId, creatorId: fixture.userId,
            drafts: [TaskDraft(title: "Original immutable title", description: "actual canonical description")])
        let host = try #require(batch.messages.first)
        let command = try #require(fixture.accounts.agentsRuntimeStore.state.execution.commands.values.first { $0.messageId == host.id })
        guard case .delivery(let data, let sequence) = try service.materializeInTransaction(command: command) else { Issue.record("Expected delivery"); return }
        let body = try materializationObject(data)
        #expect(body["channel_id"] as? String == fixture.channelId)
        #expect(body["message_id"] as? String == host.id)
        #expect(body["sender_id"] as? String == fixture.userId)
        #expect(body["sender_type"] as? String == "human")
        #expect(body["content"] as? String == host.content)
        #expect(sequence == Int64(host.seq))
        #expect(body["seq"] as? Int64 == Int64(host.seq))
        #expect(body["task_status"] as? String == "todo")
        #expect(body["task_number"] as? Int == batch.tasks.first?.taskNumber)
        let projection = try #require(body["task_current_projection"] as? [String: Any])
        #expect(projection["title"] as? String == "Original immutable title")
        #expect(projection["description"] as? String == "actual canonical description")
        #expect(projection["source"] as? String == "tasks_current_projection")
        let summary = try #require(batch.messages.last)
        #expect(summary.messageType == "system")
        #expect(summary.senderType == "user")
        #expect(summary.senderId == "system")
        #expect(summary.causalActorId == fixture.userId)
        #expect(fixture.accounts.authProfileStore.account(userId: "system") == nil)
        let summaryCommand = try #require(fixture.accounts.agentsRuntimeStore.state.execution.commands.values.first { $0.messageId == summary.id })
        guard case .delivery(let summaryData, let summarySeq) = try service.materializeInTransaction(command: summaryCommand) else { Issue.record("Expected system delivery"); return }
        let system = try materializationObject(summaryData)
        #expect(system["sender_type"] as? String == "system")
        #expect(system["sender_id"] as? String == "system")
        #expect(system["sender_name"] as? String == "System")
        #expect(system["message_id"] as? String == summary.id)
        #expect(summarySeq == Int64(summary.seq))
        let taskNumber = try #require(batch.tasks.first?.taskNumber)
        _ = try #require(fixture.accounts.tasksAndRemindersStore.amendTask(channelId: fixture.channelId, taskNumber: taskNumber,
            title: "Current amended task text", description: "current description", amendedByName: "materializer-agent", now: Date()))
        guard case .delivery(let updated, let sameSeq) = try service.materializeInTransaction(command: command) else { Issue.record("Expected amended projection"); return }
        let amended = try materializationObject(updated)
        #expect(amended["content"] as? String == "Original immutable title")
        let current = try #require(amended["task_current_projection"] as? [String: Any])
        #expect(current["title"] as? String == "Current amended task text")
        #expect(current["description"] as? String == "current description")
        #expect(current["revision"] as? Int == 1)
        #expect(sameSeq == sequence)
        #expect(fixture.accounts.messagesAndThreadsStore.humanMessageRows.count == 2)
    }
    #expect(fixture.accounts.messagesAndThreadsStore.humanMessageRows.isEmpty)
}

@Test func agentExecutionMaterializationRequiresTransactionAndExplicitValidServerURL() async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    let command = try await withTransactionContext(context) {
        defer { context.discard() }
        return try fixture.stageStart()
    }
    #expect(throws: AgentExecutionError.durableTransactionRequired) { try service.materializeInTransaction(command: command) }
    let invalidContext = TransactionContext()
    try await withTransactionContext(invalidContext) {
        defer { invalidContext.discard() }
        let command = try fixture.stageStart()
        for url in ["", "http://raft.example.test", "https://user:secret@raft.example.test", "https://raft.example.test?credential=secret"] {
            #expect(throws: AgentExecutionMaterializationError.invalidServerURL) {
                try fixture.materializer(serverURL: url).materializeInTransaction(command: command)
            }
        }
        #expect(fixture.accounts.agentsRuntimeStore.credentials(agentId: fixture.agentId).isEmpty)
    }
}

@Test func agentExecutionMaterializationProjectsJointStorageToLocalSurfaceAndRejectsRevocation() async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    try await withTransactionContext(context) {
        defer { context.discard() }
        _ = try fixture.stageStart()
        let localId = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "local-joint", creatorUserId: fixture.userId, type: "joint")
        fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: localId, memberId: fixture.agentId, kind: "joint", name: "local-joint")
        fixture.accounts.oauth.addChannelAgent(channelId: localId, agentId: fixture.agentId)
        fixture.accounts.addJointChannelProjection(localChannelId: localId, canonicalChannelId: fixture.channelId, serverId: fixture.serverId)
        let producer = AgentExecutionService(producerTransactionAgents: fixture.accounts.agentsRuntimeStore,
            machines: fixture.accounts.machinesAndComputersStore, oauth: fixture.accounts.oauth,
            channels: fixture.accounts.serversAndChannelsStore, messages: fixture.accounts.messagesAndThreadsStore)
        let batch = try fixture.accounts.taskCatalog.bindingExecution(producer).createCanonicalTasks(
            serverId: fixture.serverId, channelId: localId, creatorId: fixture.userId,
            drafts: [TaskDraft(title: "Actual canonical joint task")])
        let host = try #require(batch.messages.first)
        #expect(host.channelId == fixture.channelId)
        let command = try #require(fixture.accounts.agentsRuntimeStore.state.execution.commands.values.first { $0.messageId == host.id })
        guard case .delivery(let data, let seq) = try service.materializeInTransaction(command: command) else { Issue.record("Expected delivery"); return }
        let body = try materializationObject(data)
        #expect(body["channel_id"] as? String == localId)
        #expect(body["channel_name"] as? String == "local-joint")
        #expect(body["channel_type"] as? String == "joint")
        #expect(body["message_id"] as? String == host.id)
        #expect(body["content"] as? String == "Actual canonical joint task")
        #expect(seq == Int64(host.seq))
        fixture.accounts.setJointProjectionStatusForTesting(localChannelId: localId, serverId: fixture.serverId, status: "revoked")
        #expect(throws: AgentExecutionMaterializationError.messageUnavailable) { try service.materializeInTransaction(command: command) }
    }
}

@Test func agentExecutionMaterializationRetainsCredentialForCompletedTurnUntilKnownProcessExit() async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    try await withTransactionContext(context) {
        defer { context.discard() }
        let command = try fixture.stageStart()
        guard case .start(let config) = try service.materializeInTransaction(command: command) else { Issue.record("Expected configuration"); return }
        let key = try #require(try materializationObject(config)["agentCredentialKey"] as? String)
        let machine = AgentExecutionMachineContext(machineId: fixture.machineId, serverId: fixture.serverId, connectionEpochId: command.connectionEpochId)
        func ingress(_ type: String, sequence: Int64, fields: [String: JSONValue]) throws {
            var body = fields
            body["type"] = .string(type)
            body["agentId"] = .string(fixture.agentId)
            body["daemonInstanceId"] = .string("materialization-daemon")
            body["clientSeq"] = .integer(sequence)
            body["launchId"] = .string(command.launchId)
            let pending = try fixture.domain.stageIngress(context: machine, type: type, payload: JSONValue.object(body).data())
            guard case .committed = pending else { Issue.record("Expected pending ingress decision"); return }
        }
        try ingress("agent:process_spawned", sequence: 1, fields: ["processInstanceId": .string("materialization-process")])
        try ingress("agent:runtime:outcome", sequence: 2, fields: ["v": .integer(1), "outcome": .object(["kind": .string("turn_completed")])])
        #expect(fixture.accounts.agentsRuntimeStore.agentCredential(token: key)?.revokedAt == nil)
        let exited: [String: JSONValue] = ["processInstanceId": .string("materialization-process"), "spawnLaunchId": .string(command.launchId)]
        try ingress("agent:process_exited", sequence: 3, fields: exited)
        let revokedAt = try #require(fixture.accounts.agentsRuntimeStore.agentCredential(token: key)?.revokedAt)
        try ingress("agent:process_exited", sequence: 3, fields: exited)
        #expect(fixture.accounts.agentsRuntimeStore.agentCredential(token: key)?.revokedAt == revokedAt)
    }
    #expect(fixture.accounts.agentsRuntimeStore.credentials(agentId: fixture.agentId).isEmpty)
}

@Test func agentExecutionMaterializationPendingBindingCannotPretendToCommit() async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    let command = try await withTransactionContext(context) {
        defer { context.discard() }
        return try fixture.stageStart()
    }
    await #expect(throws: AgentExecutionError.durableTransactionRequired) { try await service.materialize(command: command) }
    #expect(fixture.accounts.agentsRuntimeStore.credentials(agentId: fixture.agentId).isEmpty)
}

@Test(arguments: ["none", "attempting", "ambiguous"])
func agentExecutionMaterializationOnlyRevokesCancelledStartsWithoutDispatchAttempt(attempt: String) async throws {
    let fixture = try MaterializationFixture()
    let service = fixture.materializer()
    let context = TransactionContext()
    try await withTransactionContext(context) {
        defer { context.discard() }
        let command = try fixture.stageStart()
        guard case .start(let config) = try service.materializeInTransaction(command: command) else { Issue.record("Expected configuration"); return }
        let key = try #require(try materializationObject(config)["agentCredentialKey"] as? String)
        let machine = AgentExecutionMachineContext(machineId: fixture.machineId, serverId: fixture.serverId, connectionEpochId: command.connectionEpochId)
        let reference = AgentExecutionIntentReference(commandId: command.commandId)
        if attempt != "none" {
            #expect(try fixture.domain.beginDispatch(reference: reference, context: machine, deliverySequence: nil) == .granted)
            if attempt == "ambiguous" {
                #expect(try fixture.domain.noteAmbiguousDispatch(reference: reference, context: machine) == .uncertain)
            }
        }
        _ = try fixture.domain.requestStop(.init(serverId: fixture.serverId, agentId: fixture.agentId))
        let credential = try #require(fixture.accounts.agentsRuntimeStore.agentCredential(token: key))
        #expect((credential.revokedAt != nil) == (attempt == "none"))
    }
}

/// `POST /api/v2/messages {asTask:true}` links the canonical task before agent
/// delivery is staged, so the existing human-message delivery producer
/// materializes the same task facts the task board sees. No new deliverer is
/// introduced for the task link itself.
@Test func asTaskHumanSendMaterializesCanonicalTaskFactsForTheRecipient() async throws {
    let fixture = try MaterializationFixture()
    let context = TransactionContext()
    try await withTransactionContext(context) {
        defer { context.discard() }
        _ = try fixture.stageStart()
        let exec = AgentExecutionService(producerTransactionAgents: fixture.accounts.agentsRuntimeStore,
            machines: fixture.accounts.machinesAndComputersStore, oauth: fixture.accounts.oauth,
            channels: fixture.accounts.serversAndChannelsStore, messages: fixture.accounts.messagesAndThreadsStore)
        let service = fixture.accounts.humanMessageCreate.bindingExecution(exec)
        let response = try service.createHumanMessage(
            HumanMessageCreateRequest(channelId: .string(fixture.channelId), content: .string("asTask agent delivery"),
                                      asTask: .bool(true)),
            authorization: "Bearer \(fixture.accounts.mintAccessTokenForTesting(userId: fixture.userId))",
            serverId: fixture.serverId
        )
        let message = try #require(try materializationObject(Data(response.messageJSON.utf8)))
        let messageId = try #require(message["id"] as? String)
        #expect(message["taskStatus"] as? String == "todo")
        let task = try #require(fixture.accounts.tasksAndRemindersStore.task(messageId: messageId))
        #expect(task.title == "asTask agent delivery")
        let command = try #require(fixture.accounts.agentsRuntimeStore.state.execution.commands.values
            .first { $0.messageId == messageId })
        let materializer = fixture.materializer()
        guard case .delivery(let data, let sequence) = try materializer.materializeInTransaction(command: command) else {
            Issue.record("Expected a delivery command for the asTask host message")
            return
        }
        let body = try materializationObject(data)
        #expect(body["message_id"] as? String == messageId)
        #expect(body["sender_type"] as? String == "human")
        #expect(body["task_status"] as? String == "todo")
        #expect(body["task_number"] as? Int == task.taskNumber)
        #expect(body["task_assignee_id"] is NSNull)
        #expect(body["task_assignee_type"] is NSNull)
        let projection = try #require(body["task_current_projection"] as? [String: Any])
        #expect(projection["title"] as? String == "asTask agent delivery")
        #expect(projection["source"] as? String == "tasks_current_projection")
        #expect(sequence > 0)
        try context.prepareCommit()
    }
    #expect(fixture.accounts.tasksAndRemindersStore.taskRecords.isEmpty)
}
