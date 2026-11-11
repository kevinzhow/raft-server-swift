import Foundation
import RaftShared

struct TaskExecutionSurface: Sendable {
    let channelId: String
    let serverId: String
    let name: String?
    let type: String
}

struct TaskExecutionCreatedBatch: Sendable {
    let tasks: [TaskRecord]
    let messages: [StoredHumanMessage]
    let surfaces: [TaskExecutionSurface]
    let creatorName: String

    func project(to surface: TaskExecutionSurface) -> [CanonicalTaskPayload] {
        tasks.map { CanonicalTaskPayload($0, channelId: surface.channelId, channelName: surface.name,
                                        channelType: surface.type, creatorType: "user", creatorName: creatorName) }
    }
}

/// Task writers append ordinary host/notice messages before requesting delivery.
/// This producer never converts model trajectory/outcome text into a message.
struct AgentExecutionTaskProducer: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let profiles: AuthProfileStore
    let oauth: OAuthLedger
    let flags: AgentsRuntimeStore
    let execution: AgentExecutionService?

    func storageChannelId(_ localId: String) -> String {
        channels.jointProjections.first { $0.localChannelId == localId && $0.status == "active" }?.canonicalChannelId ?? localId
    }

    func surfaces(for channelId: String) -> [TaskExecutionSurface] {
        let storageId = storageChannelId(channelId)
        let joints = channels.jointProjections.filter { $0.canonicalChannelId == storageId && $0.status == "active" }
        let ids = joints.isEmpty ? [channelId] : joints.map(\.localChannelId)
        return ids.compactMap { id in
            guard let channel = oauth.channelInfo(id: id) else { return nil }
            return TaskExecutionSurface(channelId: id, serverId: channel.serverId, name: channel.name,
                                        type: oauth.channelType(id: id) ?? "channel")
        }
    }

    /// Live outbound/eligibility targets. Keep read/orphan resolution separate.
    func activeTaskSurfaces(for channelId: String) -> [TaskExecutionSurface] {
        let storageId = storageChannelId(channelId)
        let links = channels.jointProjections.filter { $0.canonicalChannelId == storageId }
        guard !links.isEmpty else { return surfaces(for: channelId) }
        var seen: Set<String> = []
        return links.filter { $0.status == "active" }.compactMap { link in
            guard let row = channels.postableChannel(id: link.localChannelId), row.deletedAt == nil,
                  row.serverId == link.serverId,
                  let channel = oauth.channelInfo(id: link.localChannelId), channel.serverId == link.serverId,
                  seen.insert(link.localChannelId).inserted
            else { return nil }
            return TaskExecutionSurface(channelId: link.localChannelId, serverId: link.serverId,
                name: channel.name, type: oauth.channelType(id: link.localChannelId) ?? row.kind)
        }
    }

    /// Canonical joint tasks use the actual active projection participant union.
    /// Ordinary tasks retain their existing server-local eligibility checks.
    func assigneeEligible(type: String, id: String, taskChannelId: String, local: TaskExecutionSurface) -> Bool {
        let storageId = storageChannelId(taskChannelId)
        if channels.jointProjections.contains(where: { $0.canonicalChannelId == storageId }) {
            let targets = activeTaskSurfaces(for: taskChannelId)
            if type == "user" {
                guard profiles.account(userId: id) != nil else { return false }
                return targets.contains { oauth.isChannelParticipant(channelId: $0.channelId, userId: id) }
            }
            guard let agent = oauth.agentRuntimeInfo(id: id), !agent.deleted else { return false }
            return targets.contains {
                $0.serverId == agent.serverId && oauth.channelAgentIds(channelId: $0.channelId).contains(id)
            }
        }
        if type == "user" {
            return oauth.isChannelParticipant(channelId: local.channelId, userId: id)
                && oauth.memberRole(serverId: local.serverId, userId: id) != nil
        }
        guard let agent = oauth.agentRuntimeInfo(id: id), !agent.deleted, agent.serverId == local.serverId else { return false }
        return oauth.channelAgentIds(channelId: local.channelId).contains(id)
    }

    /// Resolve execution notices through the assigned agent's real owning
    /// projection before the task write. Human/clear notices keep caller scope.
    func assignmentNoticeSurface(taskChannelId: String, assigneeType: String?, assigneeId: String?,
        caller: TaskExecutionSurface) -> TaskExecutionSurface? {
        guard assigneeType == "agent", let assigneeId else { return caller }
        guard let agent = oauth.agentRuntimeInfo(id: assigneeId), !agent.deleted else { return nil }
        return activeTaskSurfaces(for: taskChannelId).first {
            $0.serverId == agent.serverId && oauth.channelAgentIds(channelId: $0.channelId).contains(assigneeId)
        }
    }

    func userName(_ userId: String) -> String {
        profiles.account(userId: userId).map { $0.displayName ?? $0.name } ?? "Unknown"
    }

    func deliveryRecipients(_ surface: TaskExecutionSurface) -> [String] {
        oauth.channelAgentIds(channelId: surface.channelId).filter { id in
            guard let agent = oauth.agentRuntimeInfo(id: id) else { return false }
            return !agent.deleted && agent.serverId == surface.serverId && agent.runtime == "codex"
        }.sorted()
    }

    func requireDeliveryTransaction(surfaces: [TaskExecutionSurface], assigneeId: String? = nil) throws {
        guard assigneeId != nil || surfaces.contains(where: { !deliveryRecipients($0).isEmpty }) else { return }
        guard execution != nil else { throw AgentExecutionProducerError(operation: "deliver tasks", underlying: .dispatchUnavailable) }
        do { try DeferredEffects.requireDurableTransaction(in: .shared) }
        catch { throw AgentExecutionProducerError(operation: "deliver tasks", underlying: .durableTransactionRequired) }
    }

    @discardableResult
    func append(_ message: StoredHumanMessage) -> StoredHumanMessage {
        var committed = message
        committed.seq = messages.appendMessage(message, ledger: MessageLedgerPort(oauth: oauth), mirrorSystemMetadata: true)
        return committed
    }

    func deliver(_ message: StoredHumanMessage, surfaces: [TaskExecutionSurface], onlyAgentId: String? = nil) throws {
        do {
            for surface in surfaces {
                let recipients = onlyAgentId.map { [$0] } ?? deliveryRecipients(surface)
                for agentId in recipients {
                    guard let execution else { throw AgentExecutionError.dispatchUnavailable }
                    _ = try execution.requestDelivery(.init(serverId: surface.serverId, agentId: agentId,
                                                             channelId: surface.channelId, messageId: message.id))
                }
            }
        } catch {
            DeferredEffects.markRollbackOnly()
            throw error
        }
    }

    /// Resolve an existing task through a real local surface before projection.
    /// Ordinary orphan cleanup is deliberately narrower than the live read query.
    func readableTaskSurface(_ task: TaskRecord, serverId: String, userId: String) -> TaskExecutionSurface? {
        guard let local = surfaces(for: task.channelId).first(where: { $0.serverId == serverId }) else { return nil }
        if channels.postableChannel(id: local.channelId)?.deletedAt != nil {
            guard oauth.memberRole(serverId: serverId, userId: userId) != "guest",
                  local.type == "channel" || oauth.isChannelParticipant(channelId: local.channelId, userId: userId)
            else { return nil }
        } else {
            let reads = HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: flags)
            guard reads.authority(channelId: local.channelId, serverId: serverId, userId: userId) != nil else { return nil }
        }
        return local
    }

    func project(_ task: TaskRecord, to surface: TaskExecutionSurface) -> CanonicalTaskPayload {
        let creatorAgent = task.creatorId.flatMap { oauth.agentRuntimeInfo(id: $0) }
        let creatorUser = task.creatorId.flatMap { profiles.account(userId: $0) }
        let creatorType: String? = creatorAgent != nil ? "agent" : (creatorUser != nil ? "user" : nil)
        let creatorName = creatorAgent.map { $0.displayName.isEmpty ? $0.name : $0.displayName }
            ?? creatorUser.map { $0.displayName ?? $0.name }
        let membership: String?
        let jointSurfaces = channels.jointProjections.filter {
            $0.canonicalChannelId == storageChannelId(task.channelId) && $0.status == "active"
        }
        if !jointSurfaces.isEmpty, let creatorId = task.creatorId, let creatorType {
            // Node membership for a canonical joint task is the union of real
            // active local participants, not membership in the viewing server.
            let participates = jointSurfaces.contains { local in
                creatorType == "agent"
                    ? oauth.channelAgentIds(channelId: local.localChannelId).contains(creatorId)
                    : oauth.isChannelParticipant(channelId: local.localChannelId, userId: creatorId)
            }
            membership = participates && creatorAgent?.deleted != true ? "active" : "removed"
        } else if let creatorAgent {
            membership = !creatorAgent.deleted && creatorAgent.serverId == surface.serverId ? "active" : "removed"
        } else if let creatorId = task.creatorId, creatorUser != nil {
            if oauth.memberRole(serverId: surface.serverId, userId: creatorId) != nil {
                membership = "active"
            } else {
                membership = channels.state.serverMemberStatuses["\(surface.serverId)\n\(creatorId)"] ?? "removed"
            }
        } else { membership = nil }
        let assigneeName = task.assigneeId.flatMap { id -> String? in
            task.assigneeType == "agent" ? oauth.agentRuntimeInfo(id: id)?.name
                : profiles.account(userId: id)?.name
        }
        return CanonicalTaskPayload(task, channelId: surface.channelId, channelName: surface.name, channelType: surface.type,
            creatorType: creatorType, creatorName: creatorName, creatorMembershipStatus: membership, assigneeName: assigneeName)
    }

    func assignmentNotice(task: TaskRecord, surface: TaskExecutionSurface, actorId: String) throws {
        guard task.hasHostMessage, messages.humanMessageRows.contains(where: { $0.id == task.messageId }) else { return }
        let actorCanFollow = oauth.activeRegularServerMember(serverId: surface.serverId, userId: actorId)
            && oauth.isChannelParticipant(channelId: surface.channelId, userId: actorId)
        let threadParticipant: String
        if actorCanFollow { threadParticipant = actorId }
        else {
            guard task.assigneeType == "agent", let agentId = task.assigneeId,
                  let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
                  agent.serverId == surface.serverId,
                  oauth.channelAgentIds(channelId: surface.channelId).contains(agentId)
            else { throw AgentExecutionError.ownershipMismatch }
            threadParticipant = agentId
        }
        let outcome = channels.findOrCreateThread(serverId: surface.serverId, parentChannelId: surface.channelId,
            parentMessageId: task.messageId, creatorId: threadParticipant, threadChannels: ThreadChannelCommand(oauth: oauth))
        let threadId: String
        switch outcome {
        case .existing(let id), .created(let id): threadId = id
        }
        if actorCanFollow {
            messages.followCreatedThread(serverId: surface.serverId, userId: actorId, threadChannelId: threadId,
                parentMessageId: task.messageId, parentAuthorId: nil)
        }
        let actor = userName(actorId)
        let title = Self.summarize(task.title)
        let content: String
        if let assigneeId = task.assigneeId {
            let name = task.assigneeType == "agent"
                ? oauth.agentRuntimeInfo(id: assigneeId).map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "an agent"
                : userName(assigneeId)
            content = "📌 \(actor) assigned #\(task.taskNumber) \"\(title)\" to \(name)"
        } else {
            content = "🔓 \(actor) unassigned #\(task.taskNumber) \"\(title)\""
        }
        let notice = append(StoredHumanMessage(id: UUID().uuidString.lowercased(), channelId: threadId,
            senderId: "system", content: content, randomId: nil, messageType: "system", senderType: "user",
            systemSubtype: "task.lifecycle_thread", causalActorType: "user", causalActorId: actorId))
        // Upstream `broadcastSystemMessage` through the same persisted-frontend
        // publisher the other system producers use: it joins the thread's human
        // followers before its `message:new`, chooses the public-parent room or
        // the private follower user rooms, and publishes the canonical system
        // row (no storage-only causal columns).
        let relay = RealtimeRelayService(messages: messages)
        let realtime = MessageRealtimeService(
            messages: messages, channels: channels, profiles: profiles, oauth: oauth
        )
        for frame in realtime.systemFrames(for: notice) {
            try AgentExecutionPublication.publish(room: frame.room, event: frame.event, identity: notice.id,
                payloadJSON: frame.payload, emit: { relay.emit($0, $1, $2) })
        }
        if task.assigneeType == "agent", let agentId = task.assigneeId,
           oauth.agentRuntimeInfo(id: agentId)?.runtime == "codex" {
            try deliver(notice, surfaces: [TaskExecutionSurface(channelId: threadId, serverId: surface.serverId, name: "thread", type: "thread")], onlyAgentId: agentId)
        }
    }

    static func summarize(_ title: String) -> String {
        let single = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let units = Array(single.utf16)
        guard units.count > 80 else { return single }
        return String(decoding: units.prefix(79), as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Refusals describe admission, never infer daemon execution from an HTTP 200.
struct AgentExecutionProducerError: DomainError {
    let operation: String
    let underlying: AgentExecutionError
    var status: UInt {
        switch underlying {
        case .machineNotReady, .staleConnection: 409
        case .ownershipMismatch: 404
        default: 500
        }
    }
    var errorMessage: String {
        switch underlying {
        case .machineNotReady, .staleConnection: "Machine is offline"
        case .ownershipMismatch: "Agent not found"
        default: "Failed to \(operation)"
        }
    }
    var errorBody: OrderedJSON? {
        if operation == "start agent" {
            return .object([.init("error", errorMessage), .init("code", status == 409 ? "machine_offline" : "internal_error")])
        }
        return nil
    }
}
