import Foundation
import RaftShared

/// The not-yet-migrated session lookup and realtime emitter the control plane
/// still takes from the ledger composition root.
public struct AgentMachineMigrationControlDependencies: Sendable {
    public var sessionUserId: @Sendable (String?) -> String?
    public var emitRealtime: @Sendable (_ room: String, _ event: String, _ payload: String?) -> Void

    public init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        emitRealtime: @escaping @Sendable (String, String, String?) -> Void
    ) {
        self.sessionUserId = sessionUserId
        self.emitRealtime = emitRealtime
    }
}

/// The Built-in model catalog admission the migration and assignment routes
/// share. Anything but a Built-in runtime is not ours to judge; a Built-in model
/// whose target Computer cannot answer for its catalog refuses.
enum BuiltinModelCatalogAdmission {
    /// The two members of a runtime config the check reads.
    private struct RuntimeConfig: Decodable {
        var runtime: String?
        var modelId: String?

        init(from decoder: any Decoder) throws {
            let object = LegacyJSONObject(decoder)
            runtime = object.string("runtime")
            modelId = object.object("model")?.string("id")
        }
    }

    static func catalogUnavailable(
        machines: MachinesAndComputersStore,
        machineId: String,
        runtimeConfigJSON: String?
    ) -> Bool {
        let config = runtimeConfigJSON.flatMap {
            try? JSONDecoder().decode(RuntimeConfig.self, from: Data($0.utf8))
        }
        guard config?.runtime == "builtin",
              let modelId = config?.modelId,
              let check = machines.builtinModelCatalogCheck
        else { return false }
        return check(machineId, modelId) == .catalogUnavailable
    }
}

/// Machine- and hosted-migration control plane plus the agent routes that
/// share its authority rules: migrating an agent, the hosted confirmation, the
/// private agent surfaces, scopes, the workspace tree/read, the archived
/// workspace actions, the agent channel list, delete and the runtime verbs.
///
/// The service owns authorization and projection and returns typed DTOs or
/// throws `AgentMigrationControlError`. The migration, binding and archive rows
/// are decided inside `AgentsRuntimeStore`; the service never holds a lock.
public struct AgentMachineMigrationControlService: Sendable {
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let tasks: TasksAndRemindersStore
    private let oauth: OAuthLedger
    private let dependencies: AgentMachineMigrationControlDependencies
    private let now: @Sendable () -> Date
    private let newGeneration: @Sendable () -> String

    init(
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        tasks: TasksAndRemindersStore,
        oauth: OAuthLedger,
        dependencies: AgentMachineMigrationControlDependencies,
        now: @escaping @Sendable () -> Date = { Date() },
        newGeneration: @escaping @Sendable () -> String = { "generation-" + UUID().uuidString.lowercased() }
    ) {
        self.agents = agents
        self.machines = machines
        self.channels = channels
        self.messages = messages
        self.tasks = tasks
        self.oauth = oauth
        self.dependencies = dependencies
        self.now = now
        self.newGeneration = newGeneration
    }

    // MARK: - Authority

    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentMigrationControlError.unauthorized
        }
        return userId
    }

    /// A live agent of `serverId` the session user may manage (owner, admin or
    /// the human creator).
    private func managedAgent(
        _ authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> (userId: String, info: OAuthLedger.AgentManagementInfo) {
        let userId = try requireUser(authorization)
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else { throw AgentMigrationControlError.agentMissing }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            throw AgentMigrationControlError.forbidden
        }
        return (userId, info)
    }

    private enum LifecycleCapability {
        case controlRuntime
        case deleteAgent

        func granted(role: String, isCreator: Bool) -> Bool {
            switch self {
            case .controlRuntime: role != "guest" || isCreator
            case .deleteAgent: role == "owner" || role == "admin" || isCreator
            }
        }

        var denial: AgentMigrationControlError {
            switch self {
            case .controlRuntime: .controlRuntimeDenied
            case .deleteAgent: .deleteAgentDenied
            }
        }
    }

    private struct LifecycleActor {
        var userId: String
        var role: String
        var info: OAuthLedger.AgentManagementInfo
    }

    /// The caller against a live agent of `serverId` (any server when empty), or
    /// the refusal the upstream route answers before it touches runtime state.
    private func lifecycleActor(
        _ authorization: String?,
        agentId: String,
        serverId: String,
        capability: LifecycleCapability
    ) throws -> LifecycleActor {
        let userId = try requireUser(authorization)
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted else {
            throw AgentMigrationControlError.agentNotFound
        }
        guard serverId.isEmpty || info.serverId == serverId else {
            throw AgentMigrationControlError.agentNotFound
        }
        guard let role = oauth.memberRole(serverId: info.serverId, userId: userId) else {
            throw AgentMigrationControlError.notAMember
        }
        guard capability.granted(role: role, isCreator: info.creatorUserId == userId) else {
            throw capability.denial
        }
        return LifecycleActor(userId: userId, role: role, info: info)
    }

    // MARK: - Hosted migration confirmation

    /// The retired parser read `expectedRevision` through `as? NSNumber`: any
    /// JSON number whose value is integral and `>= 1` passed, and a JSON
    /// boolean bridged to 1/0. An out-of-`Int` magnitude saturated to `Int.min`
    /// there, which fails the same `>= 1` gate.
    private static func expectedRevision(_ raw: Double?) -> Int? {
        guard let raw, raw.rounded() == raw else { return nil }
        let value: Int
        if raw >= Double(Int.min), raw < Double(Int.max) {
            value = Int(raw)
        } else {
            value = Int.min
        }
        return value >= 1 ? value : nil
    }

    /// `agent:migration-updated` for every owner/administrator of the Server.
    private func emitMigrationUpdated(
        serverId: String,
        agentId: String,
        migrationRef: String,
        state: String,
        revision: Int
    ) {
        for member in oauth.memberIdsWithRoles(serverId: serverId) where member.role == "owner" || member.role == "admin" {
            let payload = AgentMigrationUpdatedPayload(
                agentId: agentId,
                migrationRef: migrationRef,
                state: state,
                revision: revision,
                updatedAt: now()
            )
            dependencies.emitRealtime("user:\(member.id)", "agent:migration-updated", payload.jsonBody.render())
        }
    }

    /// `POST /api/agents/:id/migration/confirm-hosted`.
    public func confirmHostedMigration(
        authorization: String?,
        serverId: String,
        agentId: String,
        request: AgentMigrationCancelRequest
    ) throws -> HostedMigrationConfirmedResponse {
        let userId = try requireUser(authorization)
        guard agents.agentMigrationEnabled(serverId: serverId) else {
            throw AgentMigrationControlError.agentMigrationUiDisabled
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else { throw AgentMigrationControlError.hostedAgentNotFound }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            throw AgentMigrationControlError.migrateAgentsNotSupported
        }
        guard agents.hostedMigrationEnabled(serverId: serverId) else {
            throw AgentMigrationControlError.hostedTargetDisabled
        }
        guard let migrationRef = request.migrationRef,
              migrationRef.range(of: "^mig_[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil
        else { throw AgentMigrationControlError.migrationRefInvalid }
        guard let expectedRevision = Self.expectedRevision(request.expectedRevision) else {
            throw AgentMigrationControlError.migrationRevisionInvalid
        }
        let updated: HostedMigrationRecord
        switch agents.confirmHostedMigration(
            agentId: agentId,
            serverId: serverId,
            migrationRef: migrationRef,
            expectedRevision: expectedRevision,
            now: now()
        ) {
        case .success(let record): updated = record
        case .failure(.notFound): throw AgentMigrationControlError.hostedMigrationNotFound
        case .failure(.revisionStale): throw AgentMigrationControlError.migrationRevisionStale
        case .failure(.reviewNotReady): throw AgentMigrationControlError.hostedReviewNotReady
        case .failure(.targetAlreadyUsed): throw AgentMigrationControlError.hostedTargetAlreadyUsed
        case .failure(.sourceMoved): throw AgentMigrationControlError.hostedReviewSourceMoved
        }
        oauth.setAgentRuntime(id: agentId, runtime: "external")
        emitMigrationUpdated(
            serverId: serverId,
            agentId: agentId,
            migrationRef: updated.supportRef,
            state: updated.state,
            revision: updated.revision
        )
        return HostedMigrationConfirmedResponse(migration: HostedAgentMigrationStatus(updated))
    }

    // MARK: - Agent DMs and channels

    /// `GET /api/agents/:id/agent-dms`.
    public func agentDirectMessages(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AgentDirectMessagesResponse {
        _ = try managedAgent(authorization, serverId: serverId, agentId: agentId)
        let postable = channels.postableChannels
        let rows = messages.humanMessageRows
        let agentPeers = { (memberIds: Set<String>) -> [String] in
            memberIds.filter { $0 != agentId && oauth.agentRuntimeInfo(id: $0) != nil }
        }
        let dms = postable.filter { _, channel in
            channel.kind == "dm" && channel.serverId == serverId && channel.memberIds.contains(agentId)
                && !agentPeers(channel.memberIds).isEmpty
        }
        let built = dms.map { channelId, channel -> AgentDirectMessageRow in
            let peerAgentId = channel.memberIds.first { $0 != agentId && oauth.agentRuntimeInfo(id: $0) != nil } ?? ""
            let peerName = oauth.agentRuntimeInfo(id: peerAgentId)?.name ?? ""
            let preview = rows.last { $0.channelId == channelId && $0.messageType != "system" }?.content
            return AgentDirectMessageRow(id: channelId, peerId: peerAgentId, peerName: peerName, lastMessagePreview: preview)
        }
        // The legacy projection sorted the printed rows.
        return AgentDirectMessagesResponse(rows: built.sorted { $0.jsonBody.render() < $1.jsonBody.render() })
    }

    /// `GET /api/agents/:id/channels`.
    public func agentChannels(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AgentChannelsResponse {
        let (userId, info) = try managedAgent(authorization, serverId: serverId, agentId: agentId)
        let createdAt = ISO8601DateFormatter().string(from: now())
        let postable = channels.postableChannels
        let rows = oauth.channelsForServer(serverId: info.serverId, userId: userId).compactMap { channel -> AgentChannelRow? in
            guard oauth.channelAgentIds(channelId: channel.id).contains(agentId) else { return nil }
            guard channel.name != "all" else { return nil }
            let agentPrefs = oauth.notificationPrefs(channelId: channel.id, userId: agentId)
            let agentMute = agentPrefs.activityMuted ? agentPrefs.muteFromSeq : nil
            if let channelRow = postable[channel.id], channelRow.kind == "thread" || channelRow.kind == "dm" {
                return nil
            }
            let type = oauth.channelType(id: channel.id) ?? "channel"
            guard type == "channel" || type == "private" || type == "joint" else { return nil }
            // Private and joint memberships are only listable to a viewer who is
            // in that channel too; a plain channel stays listable.
            if type != "channel", !oauth.channelHumanIds(channelId: channel.id).contains(userId) { return nil }
            return AgentChannelRow(
                id: channel.id,
                name: channel.name,
                description: oauth.channelInfo(id: channel.id)?.description,
                type: type,
                createdAt: createdAt,
                activityMuted: agentMute != nil,
                muteFromSeq: agentMute
            )
        }
        return AgentChannelsResponse(rows: rows)
    }

    // MARK: - Private surfaces

    private func surfaceFailure(_ result: AgentSurfaceResult, action: String) -> AgentMigrationControlError? {
        switch result {
        case .ok: nil
        case .machineUnassigned: .machineUnassigned
        case .machineOffline: .machineOffline(action: action)
        case .machineTimeout: .daemonTimeout(action: action)
        }
    }

    /// `GET /api/agents/:id/activity`.
    public func agentActivity(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AgentIdleActivityResponse {
        _ = try managedAgent(authorization, serverId: serverId, agentId: agentId)
        return AgentIdleActivityResponse()
    }

    /// `GET /api/agents/:id/activity-log`.
    public func agentActivityLog(
        authorization: String?,
        serverId: String,
        agentId: String,
        query: String?
    ) throws -> AgentSurfaceBodyResponse {
        _ = try managedAgent(authorization, serverId: serverId, agentId: agentId)
        guard let provider = agents.agentActivityLogProvider else { return AgentSurfaceBodyResponse(body: "[]") }
        let result = provider(agentId, AgentSurfaceQuery.agentSurfaceQueryInt(query, "limit"))
        if let failure = surfaceFailure(result, action: "Activity log") { throw failure }
        guard case .ok(let body) = result else { return AgentSurfaceBodyResponse(body: "[]") }
        return AgentSurfaceBodyResponse(body: body)
    }

    /// `GET /api/agents/:id/activity-summaries`.
    public func agentActivitySummaries(
        authorization: String?,
        serverId: String,
        agentId: String,
        query: String?
    ) throws -> AgentSurfaceBodyResponse {
        let (userId, _) = try managedAgent(authorization, serverId: serverId, agentId: agentId)
        let empty = AgentSurfaceBodyResponse(body: "{\"summaries\":[],\"next\":null}")
        guard let provider = agents.agentActivitySummariesProvider else { return empty }
        let limit = min(max(AgentSurfaceQuery.agentSurfaceQueryInt(query, "limit") ?? 30, 1), 50)
        var beforeEndedAt: Int?
        var beforeId: String?
        if let before = AgentSurfaceQuery.agentSurfaceQueryString(query, "before") {
            let parts = before.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            beforeEndedAt = Int(parts.count > 0 ? String(parts[0]) : "")
            beforeId = parts.count > 1 ? String(parts[1]) : nil
        }
        let result = provider(agentId, limit, beforeEndedAt, beforeId)
        if let failure = surfaceFailure(result, action: "Activity summaries") { throw failure }
        guard case .ok(let body) = result else { return empty }
        return AgentSurfaceBodyResponse(body: redactedAgentTurnSummaries(body, userId: userId))
    }

    /// `GET /api/agents/:id/skills`.
    public func agentSkills(
        authorization: String?,
        serverId: String,
        agentId: String,
        hasReplayHeaders: Bool
    ) throws -> AgentSurfaceBodyResponse {
        _ = try managedAgent(authorization, serverId: serverId, agentId: agentId)
        if hasReplayHeaders { throw AgentMigrationControlError.invalidReplicaReplaySignature }
        if let isLocal = agents.agentHasMachineLocally, !isLocal(agentId) {
            throw AgentMigrationControlError.machineOfflineOwnerNotLocal
        }
        let empty = AgentSurfaceBodyResponse(body: "{\"global\":[],\"workspace\":[]}")
        guard let provider = agents.agentSkillsProvider else { return empty }
        let result = provider(agentId)
        if let failure = surfaceFailure(result, action: "Skills list") { throw failure }
        guard case .ok(let body) = result else { return empty }
        return AgentSurfaceBodyResponse(body: body)
    }

    /// Hides where a turn came from when the viewer cannot see the source
    /// channel or DM. The trigger's own text must not survive the projection.
    /// A body that is not the expected shape is returned unchanged.
    private func redactedAgentTurnSummaries(_ json: String, userId: String) -> String {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              case .object(var object) = root,
              case .array(let elements)? = object["summaries"]
        else { return json }
        var summaries: [[String: JSONValue]] = []
        for element in elements {
            guard case .object(let row) = element else { return json }
            summaries.append(row)
        }
        let postable = channels.postableChannels
        for index in summaries.indices {
            guard case .object(let trigger)? = summaries[index]["trigger"],
                  case .string(let channelId)? = trigger["channelId"]
            else { continue }
            var target = ""
            if case .string(let text)? = trigger["target"] { target = text }
            let kind = postable[channelId]?.kind ?? oauth.channelType(id: channelId)
            let isMember = postable[channelId]?.memberIds.contains(userId) ?? false
            let hidden: (String) -> JSONValue = { .object(["hidden": .string($0)]) }
            if kind == "dm" || target.hasPrefix("dm:") {
                summaries[index]["trigger"] = hidden("dm")
            } else if kind == "channel" {
                continue
            } else if kind == "private" || kind == "thread" {
                if !isMember { summaries[index]["trigger"] = hidden("private_channel") }
            } else {
                summaries[index]["trigger"] = hidden("private_channel")
            }
        }
        object["summaries"] = .array(summaries.map(JSONValue.object))
        // The retired serializer printed this with sorted keys; so does the encoder.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(object)) else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Scopes

    private static let scopeGrants = [
        "attachment:upload", "message:send", "message:read", "channel:join", "channel:leave",
        "thread:unfollow", "channel:read", "channel:create", "channel:update", "channel:add_member",
        "channel:remove_member", "server:read", "server:update", "knowledge:read", "task:read",
        "task:write", "action:prepare",
    ]

    private func scopesMember(
        _ authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> OAuthLedger.AgentManagementInfo {
        let userId = try requireUser(authorization)
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else { throw AgentMigrationControlError.agentMissing }
        return info
    }

    /// `GET /api/agents/:id/scopes`.
    public func getAgentScopes(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AgentScopesResponse {
        _ = try scopesMember(authorization, serverId: serverId, agentId: agentId)
        return AgentScopesResponse(agentId: agentId, mode: "default", scopes: Self.scopeGrants, revision: 0)
    }

    /// `PUT /api/agents/:id/scopes`.
    public func putAgentScopes(
        authorization: String?,
        serverId: String,
        agentId: String,
        request: AgentScopesUpdateRequest
    ) throws -> AgentScopesResponse {
        let info = try scopesMember(authorization, serverId: serverId, agentId: agentId)
        guard info.runtime == "external" else { throw AgentMigrationControlError.agentScopesUnsupported }
        return AgentScopesResponse(
            agentId: agentId,
            mode: request.mode ?? "default",
            scopes: Self.scopeGrants,
            revision: 1
        )
    }

    // MARK: - Workspace tree and read

    /// The caller's authority over a live or archived agent's workspace.
    private func workspaceAuthority(
        _ authorization: String?,
        serverId: String,
        agentId: String
    ) throws {
        let userId = try requireUser(authorization)
        let info = oauth.agentManagementInfo(id: agentId)
        let ownerServerId = info?.serverId ?? agents.archiveRecord(agentId: agentId)?.serverId
        guard ownerServerId == serverId else { throw AgentMigrationControlError.agentMissing }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentMigrationControlError.agentMissing
        }
        guard role == "owner" || role == "admin" || info?.creatorUserId == userId else {
            throw AgentMigrationControlError.forbidden
        }
    }

    /// `GET /api/agents/:id/workspace-files`.
    public func agentWorkspaceFiles(
        authorization: String?,
        serverId: String,
        agentId: String,
        query: String?
    ) throws -> AgentWorkspaceFilesResponse {
        try workspaceAuthority(authorization, serverId: serverId, agentId: agentId)
        guard let provider = agents.agentWorkspaceTreeProvider else { throw AgentMigrationControlError.daemonOffline }
        let dirPath = AgentSurfaceQuery.agentSurfaceQueryString(query, "dirPath")
        let includeHidden = ["1", "true"].contains(
            (AgentSurfaceQuery.agentSurfaceQueryString(query, "includeHidden") ?? "").lowercased()
        )
        switch provider(agentId, dirPath, includeHidden) {
        case .ok(let files): return AgentWorkspaceFilesResponse(files: files)
        case .machineUnassigned: throw AgentMigrationControlError.machineUnassigned
        case .machineOffline: throw AgentMigrationControlError.workspaceFilesMachineOffline
        case .machineTimeout: throw AgentMigrationControlError.workspaceFilesTimeout
        }
    }

    /// `GET /api/agents/:id/workspace-files/read`.
    public func agentWorkspaceRead(
        authorization: String?,
        serverId: String,
        agentId: String,
        query: String?
    ) throws -> AgentSurfaceBodyResponse {
        try workspaceAuthority(authorization, serverId: serverId, agentId: agentId)
        let path = AgentSurfaceQuery.agentSurfaceQueryString(query, "path")
        guard let provider = agents.agentWorkspaceReadProvider else { throw AgentMigrationControlError.daemonOffline }
        switch provider(agentId, path) {
        case .ok(let body): return AgentSurfaceBodyResponse(body: body)
        case .machineUnassigned: throw AgentMigrationControlError.machineUnassigned
        case .machineOffline: throw AgentMigrationControlError.workspaceReadMachineOffline
        case .machineTimeout: throw AgentMigrationControlError.workspaceReadTimeout
        }
    }

    // MARK: - Archived workspace

    private func archiveView(_ record: AgentArchiveRecord, agentId: String) -> AgentArchiveView {
        let machineOnline = record.machineId.map { machines.machineOnline[$0] == true } ?? false
        return AgentArchiveView(
            agentId: agentId,
            archivedAt: AgentMigrationTimestamps.string(record.archivedAt) ?? "",
            archivedByUserId: record.archivedByUserId,
            machineId: record.machineId,
            machineName: record.machineName.isEmpty ? nil : record.machineName,
            workspaceState: record.workspaceState,
            pendingOp: record.pendingOp,
            waitingForComputer: record.pendingOp != nil && !machineOnline,
            lastErrorCode: record.lastErrorCode,
            lastErrorAt: AgentMigrationTimestamps.string(record.lastErrorAt)
        )
    }

    /// `POST /api/agents/:id/archive/workspace`.
    public func agentArchiveWorkspaceAction(
        authorization: String?,
        serverId: String,
        agentId: String,
        request: AgentArchiveWorkspaceRequest
    ) throws -> AgentArchiveResponse {
        let userId = try requireUser(authorization)
        guard let record = agents.archiveRecord(agentId: agentId), record.serverId == serverId,
              oauth.agentManagementInfo(id: agentId)?.deleted == true
        else { throw AgentMigrationControlError.archivedAgentNotFound }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        let archivedCreator = oauth.agentManagementInfo(id: agentId)?.creatorUserId == userId
        guard role != nil, role == "owner" || role == "admin" || archivedCreator else {
            throw AgentMigrationControlError.archivedWorkspaceForbidden
        }
        guard request.action == "delete" else { throw AgentMigrationControlError.archiveActionInvalid }
        let updated: AgentArchiveRecord
        switch agents.requestArchiveWorkspaceDelete(agentId: agentId) {
        case .success(let value): updated = value
        case .failure(.missing): throw AgentMigrationControlError.archivedAgentNotFound
        case .failure(.unavailable): throw AgentMigrationControlError.archiveWorkspaceUnavailable
        case .failure(.pending): throw AgentMigrationControlError.archiveOpPending
        }
        dependencies.emitRealtime(
            "server:\(record.serverId)", "agent:archive:updated",
            Self.agentPayload(agentId)
        )
        return AgentArchiveResponse(archive: archiveView(updated, agentId: agentId))
    }

    private static func agentPayload(_ agentId: String) -> String {
        OrderedJSON.object([OrderedJSONField("agentId", agentId)]).render()
    }

    /// `GET /api/agents/:id/archive`.
    public func agentArchiveView(
        authorization: String?,
        agentId: String,
        serverId: String
    ) throws -> AgentArchiveResponse {
        let userId = try requireUser(authorization)
        guard let record = agents.archiveRecord(agentId: agentId), serverId.isEmpty || record.serverId == serverId else {
            throw AgentMigrationControlError.archivedAgentNotFound
        }
        guard let role = oauth.memberRole(serverId: record.serverId, userId: userId) else {
            throw AgentMigrationControlError.archivedWorkspaceForbidden
        }
        let isCreator = oauth.agentManagementInfo(id: agentId)?.creatorUserId == userId
        guard role == "owner" || role == "admin" || isCreator else {
            throw AgentMigrationControlError.archivedWorkspaceForbidden
        }
        return AgentArchiveResponse(archive: archiveView(record, agentId: agentId))
    }

    // MARK: - Delete

    /// `DELETE /api/agents/:id`.
    public func deleteAgent(
        authorization: String?,
        agentId: String,
        serverId: String,
        request: AgentDeleteRequest
    ) throws -> OkResponse {
        let actor = try lifecycleActor(authorization, agentId: agentId, serverId: serverId, capability: .deleteAgent)
        var workspaceChoice = "keep"
        if let workspace = request.workspace {
            guard workspace == "keep" || workspace == "delete" else {
                throw AgentMigrationControlError.archiveWorkspaceChoiceInvalid
            }
            workspaceChoice = workspace
        }
        let facts = agents.agentDeleteFacts(agentId: agentId)
        let machineName = facts.machineId.flatMap { machines.machine(id: $0)?.name } ?? ""
        if workspaceChoice == "delete",
           facts.machineId == nil || actor.info.runtime == "external" || facts.hostedRuntime {
            throw AgentMigrationControlError.agentHasNoWorkspace
        }
        guard !facts.hasActiveMigration else { throw AgentMigrationControlError.archiveMigrationActive }
        let onComputer = facts.machineId != nil && actor.info.runtime != "external" && !facts.hostedRuntime
        agents.storeArchiveRecord(agentId: agentId, record: AgentArchiveRecord(
            serverId: actor.info.serverId,
            machineId: onComputer ? facts.machineId : nil,
            machineName: onComputer ? machineName : "",
            archivedAt: now(),
            archivedByUserId: actor.userId,
            workspaceState: onComputer ? "on_computer" : (facts.machineId == nil ? "deleted" : "unknown"),
            pendingOp: workspaceChoice == "delete" ? "delete" : nil,
            lastErrorCode: nil,
            lastErrorAt: nil
        ))
        tasks.releaseAgentWork(agentId: agentId)
        channels.appendServerMemberEvent(
            serverId: actor.info.serverId,
            eventType: "server.member_removed",
            subjectType: "agent",
            subjectId: agentId,
            provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"agent\",\"reason\":\"removed\",\"role\":\"member\",\"source\":\"server_service\"}"
        )
        oauth.deleteAgent(id: agentId)
        dependencies.emitRealtime("server:\(actor.info.serverId)", "agent:archive:updated", Self.agentPayload(agentId))
        dependencies.emitRealtime("server:\(actor.info.serverId)", "agent:deleted", Self.agentPayload(agentId))
        return OkResponse()
    }

    // MARK: - Runtime verbs

    /// `POST /api/agents/:id/start`.
    public func startAgent(
        authorization: String?,
        agentId: String,
        serverId: String
    ) throws -> OkResponse {
        let actor = try lifecycleActor(authorization, agentId: agentId, serverId: serverId, capability: .controlRuntime)
        if actor.info.runtime == "external" { throw AgentMigrationControlError.externalAgentsHaveNoRuntimeLifecycle }
        guard let machineId = agents.agentMachineIds[agentId] else { throw AgentMigrationControlError.noMachineAssigned }
        guard machines.machineOnline[machineId] == true else { throw AgentMigrationControlError.startMachineOffline }
        agents.agentStartControlDispatch?(agentId, "human_start")
        return OkResponse()
    }

    /// `POST /api/agents/:id/stop`.
    public func stopAgent(
        authorization: String?,
        agentId: String,
        serverId: String
    ) throws -> OkResponse {
        let actor = try lifecycleActor(authorization, agentId: agentId, serverId: serverId, capability: .controlRuntime)
        if actor.info.runtime == "external" { throw AgentMigrationControlError.externalAgentsHaveNoRuntimeLifecycle }
        return OkResponse()
    }

    /// `POST /api/agents/:id/reset`.
    public func resetAgent(
        authorization: String?,
        agentId: String,
        serverId: String,
        request: AgentResetRequest
    ) throws -> AgentAcceptedResponse {
        let actor = try lifecycleActor(authorization, agentId: agentId, serverId: serverId, capability: .controlRuntime)
        let mode: String
        if let requested = request.mode, ["restart", "session", "full"].contains(requested) {
            mode = requested
        } else if request.clearWorkspace == true {
            mode = "full"
        } else {
            mode = "session"
        }
        if mode == "full" {
            let mayReset = actor.role == "owner" || actor.role == "admin" || actor.info.creatorUserId == actor.userId
            guard mayReset else { throw AgentMigrationControlError.resetWorkspaceDenied }
        }
        if actor.info.runtime == "external" { throw AgentMigrationControlError.externalAgentsHaveNoRuntimeLifecycle }
        agents.agentResetDispatch?(agentId, mode, "human_reset")
        return AgentAcceptedResponse()
    }

    // MARK: - Migrate

    /// `POST /api/agents/:id/migrate`.
    public func migrateAgent(
        authorization: String?,
        agentId: String,
        serverId: String,
        request: AgentMigrateRequest
    ) throws -> AgentMigrateResponse {
        let userId = try requireUser(authorization)
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              serverId.isEmpty || info.serverId == serverId
        else { throw AgentMigrationControlError.agentNotFound }
        guard oauth.memberRole(serverId: info.serverId, userId: userId) != nil else {
            throw AgentMigrationControlError.notAMember
        }
        if info.runtime == "external" { throw AgentMigrationControlError.externalAgentsHaveNoRuntimeLifecycle }
        if let target = request.hostedTarget {
            return .hosted(try startHostedMigration(info: info, serverId: info.serverId, target: target))
        }
        if let targetComputer = request.targetComputer {
            return .computer(try startMachineMigration(
                info: info, userId: userId, serverId: info.serverId, targetMachineId: targetComputer
            ))
        }
        return .accepted
    }

    private func startHostedMigration(
        info: OAuthLedger.AgentManagementInfo,
        serverId: String,
        target: HostedMigrationTarget
    ) throws -> HostedMigrationStartedResponse {
        let facts = agents.hostedStartFacts(agentId: info.id, serverId: serverId)
        guard facts.hostedEnabled else { throw AgentMigrationControlError.hostedTargetDisabled }
        guard facts.runtimeEnabled else { throw AgentMigrationControlError.hostedRuntimeDisabled }
        guard (target.provider ?? "antiproton") == "antiproton" else {
            throw AgentMigrationControlError.hostedUnknownProvider
        }
        var hostedModel: String?
        switch target.hostedModel {
        case .absent:
            break
        case .invalid:
            throw AgentMigrationControlError.hostedModelInvalid
        case .value(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 200 else {
                throw AgentMigrationControlError.hostedModelInvalid
            }
            hostedModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard facts.machineId != nil else { throw AgentMigrationControlError.agentHasNoSourceMachine }
        guard !facts.hasHostedRuntime else { throw AgentMigrationControlError.hostedTargetAlreadyUsed }
        if let active = facts.activeMigration, active.state != "canceled" {
            throw AgentMigrationControlError.migrationAlreadyInProgress
        }
        if let hostedModel, hostedModel != HostedModelPolicy.hostedDefaultModel, !facts.modelPickerEnabled {
            throw AgentMigrationControlError.hostedModelPickerDisabled
        }
        let supportRef = Self.supportRef()
        let record = HostedMigrationRecord(
            agentId: info.id,
            serverId: serverId,
            supportRef: supportRef,
            revision: 1,
            state: "preparing",
            sourceMachineId: facts.machineId
        )
        guard agents.insertHostedMigrationIfIdle(record) else {
            throw AgentMigrationControlError.migrationAlreadyInProgress
        }
        emitMigrationUpdated(
            serverId: serverId,
            agentId: record.agentId,
            migrationRef: record.supportRef,
            state: record.state,
            revision: record.revision
        )
        return HostedMigrationStartedResponse(
            migrationRef: supportRef,
            state: record.state,
            sourceMachineId: record.sourceMachineId,
            deadlineAt: AgentMigrationTimestamps.string(now().addingTimeInterval(3600)) ?? ""
        )
    }

    private static func supportRef() -> String {
        "mig_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(22))
    }

    private func startMachineMigration(
        info: OAuthLedger.AgentManagementInfo,
        userId: String,
        serverId: String,
        targetMachineId: String
    ) throws -> MachineMigrationStartedResponse {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role == "owner" || role == "admin" || info.creatorUserId == userId
        else { throw AgentMigrationControlError.machineMigrationNotSupported }
        let snapshot = machines.state
        let sourceMachineId = agents.agentMachineIds[info.id]
        let active = agents.hasActiveMigration(agentId: info.id)
        let sourceMachine = snapshot.machines.first { $0.id == sourceMachineId }
        let targetMachine = snapshot.machines.first { $0.id == targetMachineId && $0.serverId == serverId }
        let targetOnline = snapshot.machineOnline[targetMachineId] == true
        let sourceCapabilities = snapshot.machineMigrationCapabilities[sourceMachineId ?? ""]
        let targetCapabilities = snapshot.machineMigrationCapabilities[targetMachineId]
        let detection = snapshot.machineRuntimeDetections[targetMachineId]
        let plan = channels.serverPlans[serverId] ?? "pro"
        guard let sourceMachineId else { throw AgentMigrationControlError.agentHasNoSourceComputer }
        guard !active else { throw AgentMigrationControlError.computerMigrationAlreadyInProgress }
        guard let targetMachine else { throw AgentMigrationControlError.targetComputerNotFound }
        let sourceCapable = sourceCapabilities?.contains("migration/v3") ?? true
        let targetCapable = targetCapabilities?.contains("migration/v3") ?? true
        if !sourceCapable || !targetCapable {
            let side = !sourceCapable && !targetCapable ? "both" : (!sourceCapable ? "source" : "target")
            throw AgentMigrationControlError.resumableCapabilityRequired(side: side)
        }
        var failures: [AgentMigrationControlError.CapabilityFailure] = []
        if !(sourceMachine?.runtimes.contains(info.runtime) ?? false) {
            failures.append(.init(
                side: .source,
                reasonRuntimeUnconfirmed: sourceMachine?.runtimes.isEmpty == true,
                runtime: info.runtime
            ))
        }
        if !targetMachine.runtimes.contains(info.runtime) {
            failures.append(.init(
                side: .target,
                reasonRuntimeUnconfirmed: targetMachine.runtimes.isEmpty,
                runtime: info.runtime
            ))
        }
        if !failures.isEmpty {
            throw AgentMigrationControlError.computerCapabilityInsufficient(failures: failures)
        }
        guard targetOnline else { throw AgentMigrationControlError.targetComputerOffline }
        if let detection,
           detection.status == "pending" || (detection.status == "incomplete" && detection.unfinished.contains(info.runtime)) {
            throw AgentMigrationControlError.targetRuntimeDetectionPending(
                runtime: info.runtime, detectionStatus: detection.status
            )
        }
        guard plan != "free" else { throw AgentMigrationControlError.migrationProPlanRequired }
        if BuiltinModelCatalogAdmission.catalogUnavailable(
            machines: machines, machineId: targetMachineId, runtimeConfigJSON: info.runtimeConfigJSON
        ) {
            throw AgentMigrationControlError.builtinCatalogUnavailable
        }
        let sessionId: String
        if let provisioner = snapshot.machineMigrationProvisioner {
            guard let provided = provisioner(sourceMachineId, targetMachineId) else {
                throw AgentMigrationControlError.transportProvisionFailed
            }
            sessionId = provided
        } else {
            sessionId = "session-" + UUID().uuidString.lowercased()
        }
        let supportRef = Self.supportRef()
        var record = MachineMigrationRecord(
            agentId: info.id,
            serverId: serverId,
            supportRef: supportRef,
            revision: 1,
            state: "provisioning",
            sourceMachineId: sourceMachineId,
            targetMachineId: targetMachineId,
            transportGeneration: newGeneration()
        )
        record.transportSessionId = sessionId
        record.sourceTokenHash = "sha256:" + UUID().uuidString.lowercased()
        record.targetTokenHash = "sha256:" + UUID().uuidString.lowercased()
        record.manifestJSON = OrderedJSON.object([
            OrderedJSONField("schemaVersion", 1),
            OrderedJSONField("identity", .object([
                OrderedJSONField("migrationRef", supportRef),
                OrderedJSONField("agentId", info.id),
            ])),
        ]).render()
        guard agents.insertMachineMigrationIfIdle(record) else {
            throw AgentMigrationControlError.computerMigrationAlreadyInProgress
        }
        machines.machineMigrationLeaseDispatch?(sourceMachineId, "source", supportRef)
        machines.machineMigrationLeaseDispatch?(targetMachineId, "target", supportRef)
        return MachineMigrationStartedResponse(
            migrationRef: supportRef,
            sourceMachineId: sourceMachineId,
            targetMachineId: targetMachineId,
            deadlineAt: AgentMigrationTimestamps.string(now().addingTimeInterval(3600)) ?? ""
        )
    }
}
