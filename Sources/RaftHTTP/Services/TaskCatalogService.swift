import Foundation
import RaftShared

public struct TaskCatalogService: Sendable {
    private let tasks: TasksAndRemindersStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let producer: AgentExecutionTaskProducer

    init(tasks: TasksAndRemindersStore, profiles: AuthProfileStore, oauth: OAuthLedger,
         messages: MessagesAndThreadsStore, channels: ServersAndChannelsStore, flags: AgentsRuntimeStore, execution: AgentExecutionService? = nil) {
        self.tasks = tasks
        self.profiles = profiles
        self.oauth = oauth
        self.producer = AgentExecutionTaskProducer(messages: messages, channels: channels, profiles: profiles, oauth: oauth, flags: flags, execution: execution)
    }

    public func bindingExecution(_ execution: AgentExecutionService?) -> Self {
        Self(tasks: tasks, profiles: profiles, oauth: oauth, messages: producer.messages,
             channels: producer.channels, flags: producer.flags, execution: execution)
    }

    func isThread(channelId: String) -> Bool { oauth.channelType(id: channelId) == "thread" }

    func createCanonicalTasks(serverId: String, channelId: String, creatorId: String, drafts: [TaskDraft]) throws -> TaskExecutionCreatedBatch {
        let surfaces = producer.surfaces(for: channelId)
        try producer.requireDeliveryTransaction(surfaces: surfaces)
        let storageId = producer.storageChannelId(channelId)
        let now = Date()
        let hosts = drafts.map { draft in
            StoredHumanMessage(id: UUID().uuidString.lowercased(), channelId: storageId,
                               senderId: creatorId, content: draft.title ?? "", randomId: nil, createdAt: now)
        }
        let legacyMax = producer.messages.humanMessageRows.filter { $0.channelId == storageId }.compactMap(\.taskNumber).max() ?? 0
        let created = tasks.appendCanonicalTasks(channelId: storageId, drafts: drafts, hostMessageIds: hosts.map(\.id),
                                                creatorId: creatorId, legacyMessageMaxNumber: legacyMax, now: now)
        do {
            var committed = hosts.map { producer.append($0) }
            let list = created.map { "#\($0.taskNumber) \"\(AgentExecutionTaskProducer.summarize($0.title))\"" }.joined(separator: ", ")
            let content = "📋 \(created.count) new task\(created.count > 1 ? "s" : "") created: \(list)"
            let summary = producer.append(StoredHumanMessage(
                id: UUID().uuidString.lowercased(), channelId: storageId, senderId: "system", content: content,
                randomId: nil, messageType: "system", senderType: "user", createdAt: now,
                systemSubtype: "task.created_summary", causalActorType: "user", causalActorId: creatorId))
            committed.append(summary)
            for message in committed { try producer.deliver(message, surfaces: surfaces) }
            return TaskExecutionCreatedBatch(tasks: created, messages: committed, surfaces: surfaces, creatorName: producer.userName(creatorId))
        } catch {
            DeferredEffects.markRollbackOnly()
            if let failure = error as? AgentExecutionError {
                throw AgentExecutionProducerError(operation: "create tasks", underlying: failure)
            }
            throw error
        }
    }

    func taskChannelAccess(serverId: String, channelId: String, userId: String) -> TaskChannelAccess {
        TasksAndLabsService.channelAccess(oauth: oauth, channels: producer.channels, messages: producer.messages, flags: producer.flags,
            serverId: serverId, channelId: channelId, userId: userId)
    }

    /// The canonical task for an `asTask` send. The plain host message is
    /// already committed in the same request transaction; this is the
    /// idempotent link upstream `ensureTaskForMessage` performs in the send
    /// transaction.
    ///
    /// A pre-existing canonical task always wins. A message that still carries
    /// the frozen legacy `messages.task_*` shadow is left alone, matching
    /// upstream's `already converted` result, so no second representation is
    /// fabricated. Returns `nil` when no canonical task exists or is created.
    func ensureSentTask(
        channelId: String,
        messageId: String,
        title: String,
        creatorId: String,
        hasLegacyTask: Bool,
        now: Date
    ) -> (task: TaskRecord, created: Bool)? {
        if let existing = tasks.task(messageId: messageId) {
            return (existing, false)
        }
        guard !hasLegacyTask else { return nil }
        let legacyMax = producer.messages.humanMessageRows
            .filter { $0.channelId == channelId }.compactMap(\.taskNumber).max() ?? 0
        switch tasks.ensureMessageTask(channelId: channelId, messageId: messageId, title: title,
                                       creatorId: creatorId, legacyMessageMaxNumber: legacyMax, now: now) {
        case .created(let task):
            return (task, true)
        case .existing(let task):
            return (task, false)
        }
    }

    /// Publish `task:created` for an `asTask` send on the requested local
    /// channel room. The task-board frame is staged through the same durable
    /// publication boundary the task routes use, so a failed commit cannot
    /// leave a task the board never saw or announce one that rolled back.
    func publishSentTask(_ task: TaskRecord, channelId: String, serverId: String) throws {
        let stored = producer.channels.postableChannel(id: channelId)
        let surface = TaskExecutionSurface(
            channelId: channelId,
            serverId: serverId,
            name: producer.oauth.channelInfo(id: channelId)?.name ?? stored?.name,
            type: producer.oauth.channelType(id: channelId) ?? stored?.kind ?? "channel"
        )
        let projected = producer.project(task, to: surface)
        try AgentExecutionPublication.publish(
            room: "channel:\(channelId)", event: "task:created", identity: task.id,
            payloadJSON: OrderedJSON.object([
                .init("channelId", channelId),
                .init("tasks", .array([projected.createdEventBody])),
            ]).render(),
            emit: { RealtimeRelayService(messages: producer.messages).emit($0, $1, $2) }
        )
    }

    func canReadChannel(serverId: String, channelId: String, userId: String) -> Bool {
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: false
        case .readOnly, .write: true
        }
    }

    public func channelTaskAccess(serverId: String, channelId: String, userId: String) -> ChannelTaskAccess {
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: .missing
        case .readOnly: .readOnly
        case .write: .write
        }
    }

    public func addTasks(
        channelId: String, titles: [String], descriptions: [String?]? = nil,
        creatorId: String? = nil, creatorType: String = "user"
    ) -> [String] {
        // This legacy writer has no retained creator-type column/history proof.
        tasks.appendTasks(channelId: channelId, titles: titles, descriptions: descriptions, creatorId: creatorId)
    }

    func orderedTasks(serverId: String, userId: String, status: String?)
        -> [(task: TaskRecord, channelId: String, channelName: String, channelType: String)] {
        let reads = HumanChannelReadAccessQuery(channels: producer.channels, messages: producer.messages, oauth: oauth, flags: producer.flags)
        let visible = oauth.channelsForServer(serverId: serverId, userId: userId).filter {
            ($0.type == "channel" || $0.type == "joint") && oauth.channelArchivedAt(id: $0.id) == nil
                && reads.authority(channelId: $0.id, serverId: serverId, userId: userId) != nil
        }
        return visible.flatMap { channel in
            tasks.tasks(channelId: producer.storageChannelId(channel.id), status: status).map {
                (task: $0, channelId: channel.id, channelName: channel.name, channelType: channel.type)
            }
        }.sorted {
            if $0.channelName != $1.channelName { return $0.channelName < $1.channelName }
            if $0.channelId != $1.channelId { return $0.channelId < $1.channelId }
            if $0.task.taskNumber != $1.task.taskNumber { return $0.task.taskNumber < $1.task.taskNumber }
            return $0.task.id < $1.task.id
        }
    }

    func taskSurface(_ task: TaskRecord, serverId: String, userId: String) -> TaskExecutionSurface? {
        producer.readableTaskSurface(task, serverId: serverId, userId: userId)
    }

    func conversionSurface(channelId: String, serverId: String, userId: String) -> TaskExecutionSurface? {
        guard let local = producer.surfaces(for: channelId).first(where: { $0.serverId == serverId }),
              HumanChannelReadAccessQuery(channels: producer.channels, messages: producer.messages, oauth: oauth, flags: producer.flags)
                .authority(channelId: local.channelId, serverId: serverId, userId: userId) != nil else { return nil }
        return local
    }

    func taskUpdateProjections(_ task: TaskRecord) -> [TaskReadProjection] {
        producer.activeTaskSurfaces(for: task.channelId).map { producer.project(task, to: $0).projection }
    }

    func publishConvertedTask(_ task: TaskRecord, surface: TaskExecutionSurface) throws {
        let relay = RealtimeRelayService(messages: producer.messages)
        for target in producer.surfaces(for: task.channelId) {
            let payload = producer.project(task, to: target)
            try AgentExecutionPublication.publish(room: "channel:\(target.channelId)", event: "task:created",
                identity: task.id, payloadJSON: OrderedJSON.object([.init("channelId", target.channelId),
                    .init("tasks", .array([payload.jsonBody]))]).render(), emit: { relay.emit($0, $1, $2) })
        }
    }

    /// The projection surface is retained OAuth/channel state, never the request
    /// header substituted for an absent resource. Admission remains with callers.
    func readProjection(_ task: TaskRecord, channelId: String? = nil) throws -> TaskReadProjection {
        let localId = channelId ?? task.channelId
        guard let surface = producer.surfaces(for: task.channelId).first(where: { $0.channelId == localId }) else {
            throw ManagedMCPAssignmentsError.taskNotFound
        }
        return producer.project(task, to: surface).projection
    }

    func fullTaskJSON(_ task: TaskRecord, channelName: String, channelType: String, channelId: String? = nil) throws -> String {
        let projection = try readProjection(task, channelId: channelId)
        // Node's server-wide list intentionally omits the duplicate current-text
        // projection. Channel/number/mutation bodies retain it.
        guard case .object(let fields) = projection.jsonBody else { return projection.jsonBody.render() }
        return OrderedJSON.object(fields.filter { $0.key != "taskCurrentProjection" }).render()
    }

    func summaryTaskJSON(_ task: TaskRecord, channelName: String, channelType: String, channelId: String? = nil) throws -> String {
        let p = try readProjection(task, channelId: channelId)
        return OrderedJSON.object([
            .init("channelId", p.channelId), .init("channelName", optional: p.channelName),
            .init("channelType", optional: p.channelType), .init("claimedAt", optional: p.claimedAt),
            .init("claimedById", optional: p.claimedById), .init("claimedByName", optional: p.claimedByName),
            .init("claimedByType", optional: p.claimedByType), .init("completedAt", optional: p.completedAt),
            .init("createdAt", p.createdAt), .init("createdById", optional: p.createdById),
            .init("createdByName", optional: p.createdByName), .init("createdByType", optional: p.createdByType),
            .init("descriptionBytes", task.description.map { Data($0.utf8).count } ?? 0),
            .init("hasDescription", !(task.description ?? "").isEmpty), .init("id", p.id), .init("isLegacy", p.isLegacy),
            .init("messageId", optional: p.messageId), .init("readOnlyReason", .null), .init("revision", p.revision),
            .init("source", "tasks"), .init("status", p.status), .init("taskNumber", p.taskNumber),
            .init("title", p.title), .init("updatedAt", optional: p.updatedAt),
        ]).render()
    }
}
