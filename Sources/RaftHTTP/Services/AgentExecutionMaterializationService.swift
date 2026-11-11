import Foundation
import RaftShared

/// Materializes transport objects from retained business owners. It never reads
/// the process environment, calls a model, sends a frame or authorizes an ACK.
public struct AgentExecutionMaterializationService: Sendable {
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let oauth: OAuthLedger
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let profiles: AuthProfileStore
    private let tasks: TasksAndRemindersStore
    private let persistence: BusinessPersistenceRuntime?
    private let serverURL: String

    init(agents: AgentsRuntimeStore, machines: MachinesAndComputersStore, oauth: OAuthLedger,
         channels: ServersAndChannelsStore, messages: MessagesAndThreadsStore, profiles: AuthProfileStore,
         tasks: TasksAndRemindersStore, persistence: BusinessPersistenceRuntime, serverURL: String) {
        self.init(retainedAgents: agents, machines: machines, oauth: oauth, channels: channels,
                  messages: messages, profiles: profiles, tasks: tasks, persistence: persistence, serverURL: serverURL)
    }

    /// Pending-UoW unit binding. This cannot pretend to commit: the public async
    /// entry refuses without a genuine BusinessPersistenceRuntime.
    init(transactionAgents: AgentsRuntimeStore, machines: MachinesAndComputersStore, oauth: OAuthLedger,
         channels: ServersAndChannelsStore, messages: MessagesAndThreadsStore, profiles: AuthProfileStore,
         tasks: TasksAndRemindersStore, serverURL: String) {
        self.init(retainedAgents: transactionAgents, machines: machines, oauth: oauth, channels: channels,
                  messages: messages, profiles: profiles, tasks: tasks, persistence: nil, serverURL: serverURL)
    }

    private init(retainedAgents: AgentsRuntimeStore, machines: MachinesAndComputersStore, oauth: OAuthLedger,
                 channels: ServersAndChannelsStore, messages: MessagesAndThreadsStore, profiles: AuthProfileStore,
                 tasks: TasksAndRemindersStore, persistence: BusinessPersistenceRuntime?, serverURL: String) {
        self.agents = retainedAgents
        self.machines = machines
        self.oauth = oauth
        self.channels = channels
        self.messages = messages
        self.profiles = profiles
        self.tasks = tasks
        self.persistence = persistence
        self.serverURL = serverURL
    }

    /// Returns only after COMMIT. A credential minted for a start and its launch
    /// binding share that commit; an ambiguous commit never exposes a new key.
    public func materialize(command: AgentExecutionCommand) async throws -> AgentExecutionMaterializedPayload {
        guard let persistence else { throw AgentExecutionError.durableTransactionRequired }
        return try await persistence.execute { try self.materializeInTransaction(command: command) }
    }

    func materializeInTransaction(command: AgentExecutionCommand) throws -> AgentExecutionMaterializedPayload {
        do {
            do { try DeferredEffects.requireDurableTransaction(in: .shared) }
            catch { throw AgentExecutionError.durableTransactionRequired }
            try agents.validateMaterialization(command: command)
            let domain = AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth, channels: channels, messages: messages)
            guard try domain.boundMachine(serverId: command.serverId, agentId: command.agentId) == command.machineId,
                  let agent = oauth.agentRuntimeInfo(id: command.agentId), agent.runtime == "codex" else {
                throw AgentExecutionMaterializationError.commandUnavailable
            }
            switch command.kind {
            case .start:
                let configuration = try start(command: command, agent: agent)
                // Upstream computes the resume catch-up only when the agent has
                // a session (a fresh session has no history to resume) and no
                // resume prompt already gives the start something to act on.
                var resumeMessages: [JSONValue] = []
                var unreadSummary: [String: Int]?
                if command.resumePrompt == nil, command.sessionId != nil {
                    let context = AgentResumeContext(messages: messages, channels: channels, oauth: oauth,
                                                     tasks: tasks, profiles: profiles)
                    let built = context.build(serverId: command.serverId, agentId: command.agentId)
                    resumeMessages = built.resumeMessages
                    unreadSummary = built.unreadSummary
                }
                return .start(configuration: configuration, resumeMessages: resumeMessages,
                              unreadSummary: unreadSummary)
            case .delivery: return try delivery(command: command, domain: domain)
            case .notice: return .notice(message: try bounded(notice(command: command)))
            case .stop: throw AgentExecutionMaterializationError.commandUnavailable
            }
        } catch {
            DeferredEffects.markRollbackOnly()
            throw error
        }
    }

    private func start(command: AgentExecutionCommand, agent: OAuthLedger.AgentRuntimeInfo) throws -> Data {
        guard let url = URLComponents(string: serverURL), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AgentExecutionMaterializationError.invalidServerURL
        }
        guard let raw = agent.runtimeConfigJSON,
              case .object(let config)? = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              config["runtime"] == .string("codex"),
              case .object(let model)? = config["model"],
              case .string(let modelKind)? = model["kind"], ["preset", "custom"].contains(modelKind),
              case .string(let modelName)? = model[modelKind == "custom" ? "name" : "id"],
              !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config["provider"] == nil || config["provider"] == .null,
              let machine = machines.machines.first(where: { $0.id == command.machineId && $0.serverId == command.serverId }),
              agents.state.agentRuntimeProfiles[command.agentId]?.pendingKind == nil else {
            // Pending runtime controls cannot be guessed: their opaque key/body
            // need a real control producer. Codex has no provider block upstream.
            throw AgentExecutionMaterializationError.configurationUnavailable
        }
        let effort: String?
        switch config["reasoningEffort"] {
        case .none, .null?: effort = nil
        case .string(let value)?: effort = value
        default: throw AgentExecutionMaterializationError.configurationUnavailable
        }
        let env: [String: String]
        if let value = config["envVars"] {
            env = try environment(value)
        } else if let rawEnv = agent.envVarsJSON {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(rawEnv.utf8)) else {
                throw AgentExecutionMaterializationError.configurationUnavailable
            }
            env = try environment(value)
        } else { env = [:] }
        let credential = try agents.materializationCredential(command: command)
        let version = machines.computers.first { $0.machineId == command.machineId && $0.revokedAt == nil }?.version
        let configBody = MaterializedCodexConfiguration(name: agent.name, displayName: agent.displayName,
            description: agent.description, model: modelName, runtimeConfig: .object(config), reasoningEffort: effort,
            envVars: env, sessionId: command.sessionId, serverURL: serverURL, credentialKey: credential.key,
            credentialId: credential.id, agentId: command.agentId, serverId: command.serverId,
            machineId: command.machineId, machineName: machine.name, machineDescription: machine.description,
            machineHostname: machine.hostname, daemonVersion: version)
        return try bounded(configBody.encoded())
    }

    private func environment(_ value: JSONValue) throws -> [String: String] {
        let checked = AgentRuntimeConfigDocument.validatedEnvVars(value)
        guard checked.error == nil else { throw AgentExecutionMaterializationError.configurationUnavailable }
        return checked.env ?? [:]
    }

    private func delivery(command: AgentExecutionCommand, domain: AgentExecutionDomain) throws -> AgentExecutionMaterializedPayload {
        guard let localId = command.channelId, let messageId = command.messageId,
              domain.deliveryIsAuthorized(serverId: command.serverId, agentId: command.agentId, channelId: localId, messageId: messageId) else {
            throw AgentExecutionMaterializationError.messageUnavailable
        }
        let snapshot = channels.deliveryAckChannelSnapshot()
        guard let local = snapshot.channels[localId], local.deletedAt == nil,
              local.serverId == command.serverId, ["channel", "private", "joint", "dm", "thread"].contains(local.kind) else {
            throw AgentExecutionMaterializationError.messageUnavailable
        }
        let links = snapshot.jointProjections.filter { $0.localChannelId == localId }
        let canonical: String
        if links.isEmpty { canonical = localId }
        else {
            let active = links.filter { $0.status == "active" && $0.serverId == command.serverId }
            guard active.count == 1 else { throw AgentExecutionMaterializationError.messageUnavailable }
            canonical = active[0].canonicalChannelId
        }
        let matching = messages.humanMessageRows.filter { $0.id == messageId && $0.channelId == canonical }
        guard matching.count == 1, let message = matching.first, message.externalMessageId == nil,
              ["user", "human", "agent", "system"].contains(message.senderType) else {
            throw AgentExecutionMaterializationError.messageUnavailable
        }
        let sequence = Int64(message.seq)
        guard sequence > 0, sequence <= 9_007_199_254_740_991 else { throw AgentExecutionMaterializationError.invalidSequence }
        let associated = tasks.taskRecords.filter { $0.messageId == messageId && $0.channelId == canonical }
        guard associated.count <= 1 else { throw AgentExecutionMaterializationError.messageUnavailable }
        let task = associated.first
        let sender: (name: String, description: String?)
        if message.messageType == "system" || message.senderId == "system" {
            sender = ("System", nil)
        } else {
            switch message.senderType {
            case "system": sender = ("System", nil)
            case "agent":
                let author = oauth.agentRuntimeInfo(id: message.senderId)
                sender = (author.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "Unknown", author?.description)
            default: sender = (humanName(message.senderId), nil)
            }
        }
        let assigneeId = task?.assigneeId ?? message.taskAssigneeId
        let assigneeType = task?.assigneeType ?? message.taskAssigneeType
        let assigneeName = assigneeId.map { id in
            assigneeType == "agent" ? oauth.agentRuntimeInfo(id: id).map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "Unknown" : humanName(id)
        }
        let attachments = try message.attachmentIds.map { id -> ChannelAttachment in
            guard let row = messages.attachmentDownloadRecord(attachmentId: id)?.attachment,
                  row.messageId == messageId, row.channelId == canonical, row.mimeType?.isEmpty == false else {
                throw AgentExecutionMaterializationError.messageUnavailable
            }
            return row
        }
        var parent: (id: String, name: String, type: String)?
        if local.kind == "thread" {
            guard let parentId = local.parentChannelId, let channel = snapshot.channels[parentId], channel.deletedAt == nil,
                  channel.serverId == command.serverId, ["channel", "private", "joint", "dm"].contains(channel.kind) else {
                throw AgentExecutionMaterializationError.messageUnavailable
            }
            parent = (parentId, oauth.channelInfo(id: parentId)?.name ?? channel.name, channel.kind)
        }
        let projected = MaterializedAgentDelivery(message: message, localChannelId: localId,
            channelName: oauth.channelInfo(id: localId)?.name ?? local.name, channelType: local.kind,
            senderName: sender.name, senderDescription: sender.description, recipientId: command.agentId,
            task: task, taskAssigneeName: assigneeName, attachments: attachments, parent: parent)
        let data = try bounded(projected.encoded())
        return .delivery(message: data, sequence: sequence,
                         mentionDelivery: try trackMentionDelivery(command: command, message: message,
                                                                   payloadJSON: String(decoding: data, as: UTF8.self)))
    }

    /// Upstream `applyDirectDelivery`'s tracked-mention spine, executed in the
    /// same business transaction that materializes the frame:
    ///
    /// 1. persist the exact payload on the occurrence (recovery requires it);
    /// 2. freeze the daemon identity (machine/launch/session) on a server
    ///    decision — only a decision that wins the CAS may send;
    /// 3. when the session identity is unavailable, abandon the occurrence
    ///    one-shot and fall back to the ordinary untracked delivery, so the
    ///    mention is delayed, never lost and never doubled.
    ///
    /// A nil return is the untracked frame; a thrown error means another path
    /// already owns the occurrence, so no second copy may be emitted.
    private func trackMentionDelivery(command: AgentExecutionCommand, message: StoredHumanMessage,
                                      payloadJSON: String) throws -> MentionDeliveryIdentitySnapshot? {
        guard let occurrenceId = command.mentionDeliveryOccurrenceId else { return nil }
        guard let sessionId = agents.state.execution.agents[command.agentId]?.sessionId else {
            guard messages.abandonMentionDeliveryWithoutInstrumentation(occurrenceId: occurrenceId) != nil else {
                throw AgentExecutionMaterializationError.messageUnavailable
            }
            return nil
        }
        let identity = MentionDeliveryOccurrenceEvaluation.Identity(
            machineId: command.machineId, launchId: command.launchId, sessionId: sessionId)
        guard messages.attachMentionDeliveryPayload(occurrenceId: occurrenceId, payloadJSON: payloadJSON),
              messages.recordMentionDeliveryServerDecision(
                occurrenceId: occurrenceId, payloadJSON: payloadJSON, messageId: message.id,
                identity: identity) != nil else {
            throw AgentExecutionMaterializationError.messageUnavailable
        }
        return MentionDeliveryIdentitySnapshot(
            occurrenceId: occurrenceId, messageId: command.messageId ?? message.id,
            machineId: identity.machineId, launchId: identity.launchId, sessionId: identity.sessionId)
    }

    /// A notice is materialized only from its own admitted command: no
    /// channel row, message row, task or attachment is read. The body is the
    /// exact upstream system-notice shape; the wire layer adds seq 0.
    private func notice(command: AgentExecutionCommand) throws -> Data {
        guard command.kind == .notice, let channelId = command.channelId,
              let messageId = command.messageId, let notice = command.notice,
              !channelId.isEmpty, !messageId.isEmpty,
              ["channel", "private", "joint", "dm", "thread"].contains(notice.channelType),
              !notice.channelName.isEmpty, !notice.content.isEmpty, !notice.timestamp.isEmpty else {
            throw AgentExecutionMaterializationError.messageUnavailable
        }
        return try MaterializedAgentNotice(channelId: channelId, messageId: messageId, notice: notice).encoded()
    }

    private func humanName(_ id: String) -> String {
        profiles.account(userId: id).map { ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.name } ?? "Unknown"
    }

    private func bounded(_ data: Data) throws -> Data {
        guard data.count <= 1024 * 1024 else { throw AgentExecutionMaterializationError.configurationUnavailable }
        return data
    }
}
