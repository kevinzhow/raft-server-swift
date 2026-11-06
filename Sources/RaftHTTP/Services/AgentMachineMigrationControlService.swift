import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Machine-migration control plane: migration seeding, control manifests,
/// the private agent surface and scopes, workspace/archive actions, the
/// runtime verbs and the machine migration dispatch.
///
/// These handlers were lifted from `EmailLogin+AgentMigrations1.swift`.

public struct AgentMachineMigrationControlService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    func hostedProviderConfigured() -> Bool {
        lock.lock()
        let override = hostedProviderTokenOverride
        lock.unlock()
        let token = override
            ?? ProcessInfo.processInfo.environment["ANTIPROTON_PROVISIONING_TOKEN"]
            ?? ""
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hostedProviderAvailable(serverId: String) -> Bool {
        lock.lock()
        let flagged = hostedRuntimeServers.contains(serverId)
        lock.unlock()
        return flagged && hostedProviderConfigured()
    }

    func migrationError(_ status: Int, _ code: String, _ message: String) -> HTTPReply {
        Self.json(status, "{\"error\":\(jsonString(message)),\"code\":\(jsonString(code)),\"details\":{\"failureReason\":\(jsonString(code))}}")
    }

    func migrationStatusJSON(_ migration: HostedMigrationRecord) -> String {
        let source = migration.sourceMachineId.map(jsonString) ?? "null"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let canceledAt = migration.canceledAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let cancelReason = migration.cancelReason.map(jsonString) ?? "null"
        let cancelLastDispatchAt = migration.cancelLastDispatchAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let cancelErrorCode = migration.cancelErrorCode.map(jsonString) ?? "null"
        return "{\"migrationRef\":\(jsonString(migration.supportRef)),\"agentId\":\(jsonString(migration.agentId)),\"state\":\(jsonString(migration.state)),\"revision\":\(migration.revision),\"sourceMachineId\":\(source),\"targetKind\":\"hosted\",\"targetMachineId\":null,\"provider\":\"antiproton\",\"failureReason\":null,\"abortReason\":null,\"transportErrorCode\":null,\"transportErrorMessage\":null,\"readyAt\":null,\"flippedAt\":null,\"arrivedAt\":null,\"completedAt\":null,\"abortedAt\":null,\"canceledAt\":\(canceledAt),\"cancelReason\":\(cancelReason),\"cancelNeedsAttention\":false,\"cancelDispatchAttempts\":\(migration.cancelDispatchAttempts),\"cancelLastDispatchAt\":\(cancelLastDispatchAt),\"cancelErrorCode\":\(cancelErrorCode),\"cancelErrorMessage\":null}"
    }

    func migrationUpdatedJSON(_ migration: HostedMigrationRecord) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = jsonString(formatter.string(from: Date()))
        return "{\"agentId\":\(jsonString(migration.agentId)),\"migrationRef\":\(jsonString(migration.supportRef)),\"state\":\(jsonString(migration.state)),\"revision\":\(migration.revision),\"authority\":\"source\",\"disposition\":null,\"needsAttention\":false,\"dispatchAttempts\":0,\"attentionDeadlineAt\":null,\"sourceAcknowledgedAt\":null,\"targetAcknowledgedAt\":null,\"targetOutcome\":null,\"canceledAt\":null,\"updatedAt\":\(now)}"
    }

    func migrationUpdatedJSON(_ migration: MachineMigrationRecord) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = jsonString(formatter.string(from: Date()))
        return "{\"agentId\":\(jsonString(migration.agentId)),\"migrationRef\":\(jsonString(migration.supportRef)),\"state\":\(jsonString(migration.state)),\"revision\":\(migration.revision),\"authority\":\"source\",\"disposition\":null,\"needsAttention\":false,\"dispatchAttempts\":0,\"attentionDeadlineAt\":null,\"sourceAcknowledgedAt\":null,\"targetAcknowledgedAt\":null,\"targetOutcome\":null,\"canceledAt\":null,\"updatedAt\":\(now)}"
    }

    public func confirmHostedMigration(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let migrationEnabled = agentMigrationServers.contains(serverId)
        let hostedEnabled = hostedMigrationServers.contains(serverId)
        lock.unlock()
        guard migrationEnabled else {
            return migrationError(403, "agent_migration_ui_disabled", "Agent migration UI is not enabled on this server")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return migrationError(404, "AGENT_NOT_FOUND", "Agent not found")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return migrationError(403, "not_supported", "The `migrateAgents` capability or human creator authority is required to confirm an agent migration")
        }
        guard hostedEnabled else {
            return migrationError(403, "HOSTED_TARGET_UNAVAILABLE", "Moving agents to the cloud is not enabled on this server")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let migrationRef = object["migrationRef"] as? String,
              migrationRef.range(of: "^mig_[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil
        else {
            return migrationError(400, "MIGRATION_REF_INVALID", "migrationRef is required")
        }
        guard let rawRevision = object["expectedRevision"] as? NSNumber,
              rawRevision.doubleValue.rounded() == rawRevision.doubleValue,
              rawRevision.intValue >= 1
        else {
            return migrationError(400, "MIGRATION_REVISION_INVALID", "expectedRevision must be a positive integer")
        }
        let expectedRevision = rawRevision.intValue
        lock.lock()
        let migration = hostedMigrations[agentId]
        let existingHosted = hostedRuntimes[agentId] != nil
        let assignedMachine = agentMachineIds[agentId]
        lock.unlock()
        guard let migration, migration.supportRef == migrationRef, migration.serverId == serverId else {
            return migrationError(404, "MIGRATION_NOT_FOUND", "Migration to the cloud not found")
        }
        guard migration.revision == expectedRevision else {
            return migrationError(409, "MIGRATION_REVISION_STALE", "The migration changed since this review was shown")
        }
        guard migration.state == "in_transit" else {
            return migrationError(409, "HOSTED_REVIEW_NOT_READY", "The move to the cloud is not waiting for confirmation")
        }
        guard !existingHosted else {
            return migrationError(409, "HOSTED_TARGET_ALREADY_USED", "This agent has already run in the cloud")
        }
        guard migration.sourceMachineId != nil, assignedMachine == migration.sourceMachineId else {
            return migrationError(409, "HOSTED_REVIEW_NOT_READY", "The agent is no longer on the migration's source computer")
        }
        var updated = migration
        updated.state = "arriving"
        updated.revision += 1
        lock.lock()
        hostedMigrations[agentId] = updated
        hostedRuntimes[agentId] = ("antiproton", nil, "provisioning", false, Date())
        lock.unlock()
        oauth.setAgentRuntime(id: agentId, runtime: "external")
        for member in oauth.memberIdsWithRoles(serverId: serverId) where member.role == "owner" || member.role == "admin" {
            emitRealtime("user:\(member.id)", "agent:migration-updated", migrationUpdatedJSON(updated))
        }
        return Self.json(200, "{\"migration\":\(migrationStatusJSON(updated))}")
    }

    public func agentDirectMessages(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let dms = postableChannels.filter { _, channel in
            channel.kind == "dm" && channel.serverId == serverId && channel.memberIds.contains(agentId)
                && channel.memberIds.contains { $0 != agentId && oauth.agentRuntimeInfo(id: $0) != nil }
        }
        let rows = dms.map { channelId, channel -> String in
            let peerAgentId = channel.memberIds.first { $0 != agentId && oauth.agentRuntimeInfo(id: $0) != nil } ?? ""
            let peerName = oauth.agentRuntimeInfo(id: peerAgentId)?.name ?? ""
            let preview = humanMessageRows.last { $0.channelId == channelId && $0.messageType != "system" }?.content
            let previewJSON = preview.map { jsonString($0) } ?? "null"
            return "{\"id\":\(jsonString(channelId)),\"peerId\":\(jsonString(peerAgentId)),\"peerName\":\(jsonString(peerName)),\"lastMessagePreview\":\(previewJSON)}"
        }.sorted()
        lock.unlock()
        return Self.json(200, "[\(rows.joined(separator: ","))]")
    }

    /// Hides where a turn came from when the viewer cannot see the source
    /// channel or DM. The trigger's own text must not survive the projection.
    func redactedAgentTurnSummaries(_ json: String, userId: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              var summaries = object["summaries"] as? [[String: Any]]
        else { return json }
        for index in summaries.indices {
            guard var trigger = summaries[index]["trigger"] as? [String: Any],
                  let channelId = trigger["channelId"] as? String
            else { continue }
            let target = trigger["target"] as? String ?? ""
            lock.lock()
            let kind = postableChannels[channelId]?.kind ?? oauth.channelType(id: channelId)
            let isMember = postableChannels[channelId]?.memberIds.contains(userId) ?? false
            lock.unlock()
            if kind == "dm" || target.hasPrefix("dm:") {
                summaries[index]["trigger"] = ["hidden": "dm"]
            } else if kind == "channel" {
                continue
            } else if kind == "private" || kind == "thread" {
                if !isMember {
                    summaries[index]["trigger"] = ["hidden": "private_channel"]
                }
            } else {
                summaries[index]["trigger"] = ["hidden": "private_channel"]
            }
            trigger = [:]
        }
        object["summaries"] = summaries
        return Self.serializeJSON(object) ?? json
    }

    func agentSurfaceFailureReply(_ result: AgentSurfaceResult, action: String) -> HTTPReply? {
        switch result {
        case .ok:
            return nil
        case .machineUnassigned:
            return Self.json(409, "{\"code\":\"machine_unassigned\",\"error\":\"Agent has no connected machine\"}")
        case .machineOffline:
            return Self.json(409, "{\"code\":\"machine_offline\",\"error\":\"Failed to send \(action) request to daemon\"}")
        case .machineTimeout:
            return Self.json(504, "{\"code\":\"daemon_timeout\",\"error\":\"\(action) request timed out\"}")
        }
    }

    public func agentPrivateSurface(
        authorization: String?,
        serverId: String,
        agentId: String,
        surface: String,
        query: String? = nil,
        hasReplayHeaders: Bool = false
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        switch surface {
        case "activity-log":
            guard let provider = agentActivityLogProvider else {
                return Self.json(200, "[]")
            }
            let result = provider(agentId, Self.agentSurfaceQueryInt(query, "limit"))
            if let failure = agentSurfaceFailureReply(result, action: "Activity log") { return failure }
            guard case .ok(let body) = result else { return Self.json(200, "[]") }
            return Self.json(200, body)
        case "activity-summaries":
            guard let provider = agentActivitySummariesProvider else {
                return Self.json(200, "{\"summaries\":[],\"next\":null}")
            }
            let limit = min(max(Self.agentSurfaceQueryInt(query, "limit") ?? 30, 1), 50)
            var beforeEndedAt: Int?
            var beforeId: String?
            if let before = Self.agentSurfaceQueryString(query, "before") {
                let parts = before.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                beforeEndedAt = Int(parts.count > 0 ? String(parts[0]) : "")
                beforeId = parts.count > 1 ? String(parts[1]) : nil
            }
            let result = provider(agentId, limit, beforeEndedAt, beforeId)
            if let failure = agentSurfaceFailureReply(result, action: "Activity summaries") { return failure }
            guard case .ok(let body) = result else {
                return Self.json(200, "{\"summaries\":[],\"next\":null}")
            }
            return Self.json(200, redactedAgentTurnSummaries(body, userId: userId))
        case "skills":
            if hasReplayHeaders {
                return Self.json(400, "{\"code\":\"invalid_replica_replay_signature\",\"machineAffinityRoute\":\"owner_not_local\",\"error\":\"Invalid internal replay signature\"}")
            }
            if let isLocal = agentHasMachineLocally, !isLocal(agentId) {
                return Self.json(409, "{\"code\":\"machine_offline\",\"machineAffinityRoute\":\"owner_missing\",\"error\":\"Machine is offline — the agent's Computer is not connected to this replica\"}")
            }
            guard let provider = agentSkillsProvider else {
                return Self.json(200, "{\"global\":[],\"workspace\":[]}")
            }
            let result = provider(agentId)
            if let failure = agentSurfaceFailureReply(result, action: "Skills list") { return failure }
            guard case .ok(let body) = result else {
                return Self.json(200, "{\"global\":[],\"workspace\":[]}")
            }
            return Self.json(200, body)
        case "activity":
            return Self.json(200, "{\"activity\":\"idle\",\"detail\":\"\"}")
        default:
            return Self.json(200, "{\"summaries\":[],\"next\":null}")
        }
    }

    public func agentScopesRoute(authorization: String?, serverId: String, agentId: String, method: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        let grants = ["attachment:upload", "message:send", "message:read", "channel:join", "channel:leave", "thread:unfollow", "channel:read", "channel:create", "channel:update", "channel:add_member", "channel:remove_member", "server:read", "server:update", "knowledge:read", "task:read", "task:write", "action:prepare"]
        if method == "PUT" {
            guard info.runtime == "external" else {
                return Self.json(422, "{\"code\":\"agent_scopes_unsupported\",\"error\":\"Agent scopes are managed for external agents only\"}")
            }
            let mode = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["mode"] as? String ?? "default"
            return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"mode\":\(jsonString(mode)),\"scopes\":[\("\(grants.map { jsonString($0) }.joined(separator: ","))")],\"revision\":1}")
        }
        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"mode\":\"default\",\"scopes\":[\("\(grants.map { jsonString($0) }.joined(separator: ","))")],\"revision\":0}")
    }

    func agentWorkspaceAuthority(
        authorization: String?,
        serverId: String,
        agentId: String
    ) -> (reply: HTTPReply?, info: OAuthLedger.AgentManagementInfo?) {
        guard let userId = sessionUserId(authorization: authorization) else {
            return (Self.json(401, "{\"error\":\"Unauthorized\"}"), nil)
        }
        let info = oauth.agentManagementInfo(id: agentId)
        let ownerServerId = info?.serverId ?? agentArchiveRecords[agentId]?.serverId
        guard ownerServerId == serverId else {
            return (Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}"), nil)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return (Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}"), nil)
        }
        guard role == "owner" || role == "admin" || info?.creatorUserId == userId else {
            return (Self.json(403, "{\"error\":\"Forbidden\"}"), nil)
        }
        return (nil, info)
    }

    public func agentWorkspaceFiles(
        authorization: String?,
        serverId: String,
        agentId: String,
        query: String? = nil
    ) -> HTTPReply {
        let authority = agentWorkspaceAuthority(authorization: authorization, serverId: serverId, agentId: agentId)
        if let reply = authority.reply { return reply }
        guard let provider = agentWorkspaceTreeProvider else {
            return Self.json(503, "{\"code\":\"daemon_offline\",\"error\":\"Agent has no connected machine\"}")
        }
        let dirPath = Self.agentSurfaceQueryString(query, "dirPath")
        let includeHidden = ["1", "true"].contains((Self.agentSurfaceQueryString(query, "includeHidden") ?? "").lowercased())
        switch provider(agentId, dirPath, includeHidden) {
        case .ok(let files):
            return Self.json(200, "{\"files\":\(files)}")
        case .machineUnassigned:
            return Self.json(409, "{\"code\":\"machine_unassigned\",\"error\":\"Agent has no connected machine\"}")
        case .machineOffline:
            return Self.json(409, "{\"error\":\"Agent has no connected machine\",\"code\":\"machine_offline\"}")
        case .machineTimeout:
            return Self.json(504, "{\"error\":\"Workspace file tree request timed out\",\"code\":\"daemon_timeout\"}")
        }
    }

    public func agentWorkspaceRead(
        authorization: String?,
        serverId: String,
        agentId: String,
        query: String? = nil
    ) -> HTTPReply {
        let authority = agentWorkspaceAuthority(authorization: authorization, serverId: serverId, agentId: agentId)
        if let reply = authority.reply { return reply }
        let path = Self.agentSurfaceQueryString(query, "path")
        guard let provider = agentWorkspaceReadProvider else {
            return Self.json(503, "{\"code\":\"daemon_offline\",\"error\":\"Agent has no connected machine\"}")
        }
        switch provider(agentId, path) {
        case .ok(let body):
            return Self.json(200, body)
        case .machineUnassigned:
            return Self.json(409, "{\"code\":\"machine_unassigned\",\"error\":\"Agent has no connected machine\"}")
        case .machineOffline:
            return Self.json(409, "{\"error\":\"Agent file read failed\",\"code\":\"machine_offline\"}")
        case .machineTimeout:
            return Self.json(504, "{\"error\":\"Workspace file read request timed out\",\"code\":\"daemon_timeout\"}")
        }
    }

    public func agentArchiveWorkspaceAction(authorization: String?, serverId: String, agentId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let record = agentArchiveRecords[agentId]
        lock.unlock()
        guard let record, record.serverId == serverId, oauth.agentManagementInfo(id: agentId)?.deleted == true else {
            return Self.json(404, "{\"error\":\"Archived agent not found\",\"code\":\"agent_not_archived\"}")
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        let archivedCreator = oauth.agentManagementInfo(id: agentId)?.creatorUserId == userId
        guard role != nil, role == "owner" || role == "admin" || archivedCreator else {
            return Self.json(403, "{\"error\":\"You cannot manage this archived agent's workspace\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let action = object["action"] as? String,
              action == "delete"
        else {
            return Self.json(400, "{\"error\":\"action must be delete\",\"code\":\"archive_workspace_action_invalid\"}")
        }
        lock.lock()
        guard record.workspaceState == "on_computer", record.machineId != nil else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"The workspace is not on a Computer.\",\"code\":\"archive_workspace_unavailable\"}")
        }
        guard record.pendingOp == nil else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Another workspace operation is still running.\",\"code\":\"archive_op_pending\"}")
        }
        var updated = record
        updated.pendingOp = "delete"
        updated.lastErrorCode = nil
        updated.lastErrorAt = nil
        agentArchiveRecords[agentId] = updated
        lock.unlock()
        emitRealtime("server:\(record.serverId)", "agent:archive:updated", "{\"agentId\":\(jsonString(agentId))}")
        return Self.json(200, "{\"archive\":\(archiveViewJSON(updated, agentId: agentId))}")
    }

    func archiveViewJSON(_ record: AgentArchiveRecord, agentId: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let machineOnline = record.machineId.map { self.machineOnline[$0] == true } ?? false
        lock.unlock()
        let waiting = record.pendingOp != nil && !machineOnline
        let lastErrorAt = record.lastErrorAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        return "{\"agentId\":\(jsonString(agentId)),\"archivedAt\":\(jsonString(formatter.string(from: record.archivedAt))),\"archivedByUserId\":\(jsonString(record.archivedByUserId)),\"machineId\":\(record.machineId.map(jsonString) ?? "null"),\"machineName\":\(record.machineName.isEmpty ? "null" : jsonString(record.machineName)),\"workspaceState\":\(jsonString(record.workspaceState)),\"pendingOp\":\(record.pendingOp.map(jsonString) ?? "null"),\"waitingForComputer\":\(waiting),\"lastErrorCode\":\(record.lastErrorCode.map(jsonString) ?? "null"),\"lastErrorAt\":\(lastErrorAt)}"
    }

    public func agentChannels(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let rows = oauth.channelsForServer(serverId: info.serverId, userId: userId).compactMap { channel -> String? in
            guard oauth.channelAgentIds(channelId: channel.id).contains(agentId) else { return nil }
            guard channel.name != "all" else { return nil }
            lock.lock()
            let postable = postableChannels[channel.id]
            lock.unlock()
            let agentPrefs = oauth.notificationPrefs(channelId: channel.id, userId: agentId)
            let agentMute = agentPrefs.activityMuted ? agentPrefs.muteFromSeq : nil
            if let postable, postable.kind == "thread" || postable.kind == "dm" { return nil }
            let type = oauth.channelType(id: channel.id) ?? "channel"
            guard type == "channel" || type == "private" || type == "joint" else { return nil }
            // Private and joint memberships are only listable to a viewer who is
            // in that channel too; a plain channel stays listable.
            if type != "channel", !oauth.channelHumanIds(channelId: channel.id).contains(userId) { return nil }
            let muteJSON = agentMute.map(String.init) ?? "null"
            return "{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"description\":\(oauth.channelInfo(id: channel.id)?.description.map { jsonString($0) } ?? "null"),\"type\":\(jsonString(type)),\"createdAt\":\(jsonString(createdAt)),\"archivedAt\":null,\"activityMuted\":\(agentMute != nil),\"muteFromSeq\":\(muteJSON)}"
        }
        return Self.json(200, "[\(rows.joined(separator: ","))]")
    }

    public func agentArchiveView(authorization: String?, agentId: String, serverId: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let record = agentArchiveRecords[agentId]
        lock.unlock()
        guard let record, serverId.isEmpty || record.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Archived agent not found\",\"code\":\"agent_not_archived\"}")
        }
        guard let role = oauth.memberRole(serverId: record.serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"You cannot manage this archived agent's workspace\"}")
        }
        let isCreator = oauth.agentManagementInfo(id: agentId)?.creatorUserId == userId
        guard role == "owner" || role == "admin" || isCreator else {
            return Self.json(403, "{\"error\":\"You cannot manage this archived agent's workspace\"}")
        }
        return Self.json(200, "{\"archive\":\(archiveViewJSON(record, agentId: agentId))}")
    }

    public func deleteAgentRoute(authorization: String?, agentId: String, body: String = "", serverId: String = "") -> HTTPReply {
        let resolved = agentLifecycleActor(
            authorization,
            agentId: agentId,
            serverId: serverId,
            capability: .deleteAgent
        )
        if let reply = resolved.reply { return reply }
        guard let actor = resolved.actor else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        var workspaceChoice = "keep"
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           let workspace = object["workspace"] as? String {
            guard workspace == "keep" || workspace == "delete" else {
                return Self.json(400, "{\"error\":\"workspace must be keep or delete\",\"code\":\"archive_workspace_choice_invalid\"}")
            }
            workspaceChoice = workspace
        }
        lock.lock()
        let machineId = agentMachineIds[agentId]
        let machineName = machineId.flatMap { id in machines.first { $0.id == id }?.name } ?? ""
        let hosted = hostedRuntimes[agentId] != nil
        let terminalMigrationStates: Set<String> = ["canceled_pre_flip", "canceled", "completed", "arrived", "aborted", "failed"]
        let hasActiveMigration = activeAgentMigrations.values.contains {
            $0.agentId == agentId && !terminalMigrationStates.contains($0.state)
        } || machineMigrations.values.contains {
            $0.agentId == agentId && !terminalMigrationStates.contains($0.state)
        } || (hostedMigrations[agentId].map { !terminalMigrationStates.contains($0.state) } ?? false)
        lock.unlock()
        if workspaceChoice == "delete", machineId == nil || actor.info.runtime == "external" || hosted {
            return Self.json(409, "{\"error\":\"This agent has no workspace on a Computer.\",\"code\":\"archive_workspace_unavailable\"}")
        }
        guard !hasActiveMigration else {
            return Self.json(409, "{\"error\":\"This agent is being migrated. Wait for the migration to finish or cancel it first.\",\"code\":\"archive_migration_active\"}")
        }
        lock.lock()
        let onComputer = machineId != nil && actor.info.runtime != "external" && !hosted
        let record = AgentArchiveRecord(
            serverId: actor.info.serverId,
            machineId: onComputer ? machineId : nil,
            machineName: onComputer ? machineName : "",
            archivedAt: Date(),
            archivedByUserId: actor.userId,
            workspaceState: onComputer ? "on_computer" : (machineId == nil ? "deleted" : "unknown"),
            pendingOp: workspaceChoice == "delete" ? "delete" : nil,
            lastErrorCode: nil,
            lastErrorAt: nil
        )
        agentArchiveRecords[agentId] = record
        reminderRecords.removeAll { $0.ownerAgentId == agentId }
        for index in taskRecords.indices where
            taskRecords[index].assigneeType == "agent" && taskRecords[index].assigneeId == agentId {
            taskRecords[index].assigneeId = nil
            taskRecords[index].assigneeType = nil
            taskRecords[index].claimedAt = nil
            taskRecords[index].revision += 1
        }
        lock.unlock()
        lock.lock()
        recordServerMemberEvent(
            serverId: actor.info.serverId, eventType: "server.member_removed", subjectType: "agent", subjectId: agentId,
            provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"agent\",\"reason\":\"removed\",\"role\":\"member\",\"source\":\"server_service\"}"
        )
        lock.unlock()
        oauth.deleteAgent(id: agentId)
        emitRealtime("server:\(actor.info.serverId)", "agent:archive:updated", "{\"agentId\":\(jsonString(agentId))}")
        emitRealtime("server:\(actor.info.serverId)", "agent:deleted", "{\"agentId\":\(jsonString(agentId))}")
        return Self.json(200, "{\"ok\":true}")
    }

    public func agentRuntimeAction(authorization: String?, agentId: String, action: String, body: String = "", serverId: String = "") -> HTTPReply {
        if action == "migrate" {
            guard let userId = sessionUserId(authorization: authorization) else {
                return Self.json(401, "{\"error\":\"Unauthorized\"}")
            }
            guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
                  serverId.isEmpty || info.serverId == serverId
            else {
                return Self.json(404, "{\"error\":\"Agent not found\"}")
            }
            guard oauth.memberRole(serverId: info.serverId, userId: userId) != nil else {
                return Self.json(403, "{\"error\":\"Not a member of this server\"}")
            }
            if info.runtime == "external" {
                return Self.json(400, "{\"error\":\"External agents do not use Raft-managed runtime lifecycle\"}")
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            if let target = object?["target"] as? [String: Any], target["kind"] as? String == "hosted" {
                return startHostedMigration(info: info, userId: userId, serverId: info.serverId, target: target)
            }
            if let targetComputer = object?["targetComputer"] as? String {
                return startMachineMigration(info: info, userId: userId, serverId: info.serverId, targetMachineId: targetComputer)
            }
            return Self.json(202, "{\"ok\":true,\"status\":\"accepted\"}")
        }
        let resolved = agentLifecycleActor(
            authorization,
            agentId: agentId,
            serverId: serverId,
            capability: .controlRuntime
        )
        if let reply = resolved.reply { return reply }
        guard let actor = resolved.actor else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let info = actor.info
        if action == "start" {
            if info.runtime == "external" {
                return Self.json(400, "{\"error\":\"External agents do not use Raft-managed runtime lifecycle\"}")
            }
            lock.lock()
            let machineId = agentMachineIds[agentId]
            let online = machineId.map { machineOnline[$0] == true } ?? false
            lock.unlock()
            guard let machineId else {
                return Self.json(409, "{\"error\":\"No machine assigned. Please assign a machine to this agent first.\",\"code\":\"machine_unassigned\"}")
            }
            guard online else {
                return Self.json(409, "{\"error\":\"Machine is offline\",\"code\":\"machine_offline\",\"machineAffinityRoute\":\"owner_missing\"}")
            }
            agentStartControlDispatch?(agentId, "human_start")
            return Self.json(200, "{\"ok\":true}")
        }
        if action == "stop" {
            if info.runtime == "external" {
                return Self.json(400, "{\"error\":\"External agents do not use Raft-managed runtime lifecycle\"}")
            }
            return Self.json(200, "{\"ok\":true}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let requestedMode = object?["mode"] as? String
        var mode: String
        if let requestedMode, ["restart", "session", "full"].contains(requestedMode) {
            mode = requestedMode
        } else if object?["clearWorkspace"] as? Bool == true {
            mode = "full"
        } else {
            mode = "session"
        }
        if mode == "full" {
            let mayResetWorkspace = actor.role == "owner" || actor.role == "admin" || info.creatorUserId == actor.userId
            guard mayResetWorkspace else {
                return Self.json(403, "{\"error\":\"The `resetAgentWorkspace` capability or human creator authority is required to reset agent workspaces\"}")
            }
        }
        if info.runtime == "external" {
            return Self.json(400, "{\"error\":\"External agents do not use Raft-managed runtime lifecycle\"}")
        }
        agentResetDispatch?(agentId, mode, "human_reset")
        return Self.json(202, "{\"ok\":true,\"status\":\"accepted\"}")
    }

    func startMachineMigration(
        info: OAuthLedger.AgentManagementInfo,
        userId: String,
        serverId: String,
        targetMachineId: String
    ) -> HTTPReply {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role == "owner" || role == "admin" || info.creatorUserId == userId
        else {
            return Self.json(403, "{\"code\":\"not_supported\",\"error\":\"Agent migration requires creator or server admin authority\"}")
        }
        lock.lock()
        let sourceMachineId = agentMachineIds[info.id]
        let active = machineMigrations.values.contains {
            $0.agentId == info.id && !["canceled_pre_flip", "completed", "aborted", "failed"].contains($0.state)
        } || hostedMigrations[info.id] != nil
        let sourceMachine = machines.first { $0.id == sourceMachineId }
        let targetMachine = machines.first { $0.id == targetMachineId && $0.serverId == serverId }
        let targetOnline = machineOnline[targetMachineId] == true
        let sourceCapabilities = machineMigrationCapabilities[sourceMachineId ?? ""]
        let targetCapabilities = machineMigrationCapabilities[targetMachineId]
        let detection = machineRuntimeDetections[targetMachineId]
        let plan = serverPlans[serverId] ?? "pro"
        let provisioner = machineMigrationProvisioner
        lock.unlock()
        guard let sourceMachineId else {
            return Self.json(409, "{\"code\":\"AGENT_HAS_NO_SOURCE_MACHINE\",\"error\":\"Agent has no source computer\"}")
        }
        guard !active else {
            return Self.json(409, "{\"code\":\"MIGRATION_ALREADY_IN_PROGRESS\",\"error\":\"Agent already has an active migration\"}")
        }
        guard let targetMachine else {
            return Self.json(404, "{\"code\":\"TARGET_COMPUTER_NOT_FOUND\",\"error\":\"Target computer not found\"}")
        }
        let sourceCapable = sourceCapabilities?.contains("migration/v3") ?? true
        let targetCapable = targetCapabilities?.contains("migration/v3") ?? true
        if !sourceCapable || !targetCapable {
            let side = !sourceCapable && !targetCapable ? "both" : (!sourceCapable ? "source" : "target")
            return Self.json(422, "{\"error\":\"Both source and target computers must run a Raft Computer that supports migration/v3; upgrade the \(side == "both" ? "source and target" : side) computer\",\"code\":\"MIGRATION_RESUMABLE_CAPABILITY_REQUIRED\",\"details\":{\"side\":\"\(side)\",\"reason\":\"capability_missing\",\"failureReason\":\"MIGRATION_RESUMABLE_CAPABILITY_REQUIRED\"}}")
        }
        var failures: [String] = []
        if !(sourceMachine?.runtimes.contains(info.runtime) ?? false) {
            failures.append("{\"side\":\"source\",\"reason\":\"\(sourceMachine?.runtimes.isEmpty == true ? "runtime_unconfirmed" : "runtime_missing")\",\"runtime\":\(jsonString(info.runtime))}")
        }
        if !targetMachine.runtimes.contains(info.runtime) {
            failures.append("{\"side\":\"target\",\"reason\":\"\(targetMachine.runtimes.isEmpty ? "runtime_unconfirmed" : "runtime_missing")\",\"runtime\":\(jsonString(info.runtime))}")
        }
        if !failures.isEmpty {
            return Self.json(422, "{\"error\":\"Both source and target computers must support the agent's runtime\",\"code\":\"COMPUTER_CAPABILITY_INSUFFICIENT\",\"details\":{\"failureReason\":\"COMPUTER_CAPABILITY_INSUFFICIENT\",\"failures\":[\(failures.joined(separator: ","))]}}")
        }
        guard targetOnline else {
            return Self.json(409, "{\"error\":\"Target computer is not online\",\"code\":\"TARGET_COMPUTER_OFFLINE\",\"details\":{\"failureReason\":\"TARGET_COMPUTER_OFFLINE\"}}")
        }
        if let detection,
           detection.status == "pending" || (detection.status == "incomplete" && detection.unfinished.contains(info.runtime)) {
            return Self.json(409, "{\"error\":\"The target computer is still detecting its runtimes; try again in a moment\",\"code\":\"TARGET_RUNTIME_DETECTION_PENDING\",\"details\":{\"failureReason\":\"TARGET_RUNTIME_DETECTION_PENDING\",\"side\":\"target\",\"runtime\":\(jsonString(info.runtime)),\"detectionStatus\":\(jsonString(detection.status)),\"retryable\":true}}")
        }
        guard plan != "free" else {
            return Self.json(403, "{\"error\":\"Agent migration requires the Pro plan.\",\"code\":\"MIGRATION_PRO_PLAN_REQUIRED\",\"details\":{\"failureReason\":\"MIGRATION_PRO_PLAN_REQUIRED\"}}")
        }
        let migrationConfig = info.runtimeConfigJSON.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8))
        } as? [String: Any] ?? [:]
        if builtinModelCheck(machineId: targetMachineId, config: migrationConfig) == .catalogUnavailable {
            return builtinCatalogFailureReply()
        }
        let sessionId: String
        if let provisioner {
            guard let provided = provisioner(sourceMachineId, targetMachineId) else {
                return Self.json(422, "{\"code\":\"MIGRATION_TRANSPORT_PROVISION_FAILED\",\"error\":\"Migration transport provisioning failed\"}")
            }
            sessionId = provided
        } else {
            sessionId = "session-" + UUID().uuidString.lowercased()
        }
        let supportRef = "mig_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(22))
        var record = MachineMigrationRecord(
            agentId: info.id,
            serverId: serverId,
            supportRef: supportRef,
            revision: 1,
            state: "provisioning",
            sourceMachineId: sourceMachineId,
            targetMachineId: targetMachineId,
            transportGeneration: "generation-" + UUID().uuidString.lowercased()
        )
        record.transportSessionId = sessionId
        record.sourceTokenHash = "sha256:" + UUID().uuidString.lowercased()
        record.targetTokenHash = "sha256:" + UUID().uuidString.lowercased()
        record.manifestJSON = "{\"schemaVersion\":1,\"identity\":{\"migrationRef\":\(jsonString(supportRef)),\"agentId\":\(jsonString(info.id))}}"
        lock.lock()
        machineMigrations[supportRef] = record
        lock.unlock()
        machineMigrationLeaseDispatch?(sourceMachineId, "source", supportRef)
        machineMigrationLeaseDispatch?(targetMachineId, "target", supportRef)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let deadline = jsonString(formatter.string(from: Date().addingTimeInterval(3600)))
        return Self.json(200, "{\"migrationRef\":\(jsonString(supportRef)),\"state\":\"provisioning\",\"sourceMachineId\":\(jsonString(sourceMachineId)),\"targetMachineId\":\(jsonString(targetMachineId)),\"targetKind\":\"computer\",\"prepDeadlineAt\":\(deadline),\"transferDeadlineAt\":\(deadline),\"arrivalDeadlineAt\":\(deadline)}")
    }

    public func putMigrationControlManifest(authorization: String?, migrationRef: String, body: String) -> HTTPReply {
        guard computerCredentialValid(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        // The manifest budget is 512 KB of manifest, not of transport padding: the
        // request envelope allows 64 KB headroom on top of it.
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 512 * 1024 else {
            return Self.json(413, "{\"code\":\"migration_control_manifest_too_large\",\"error\":\"Migration control manifest exceeds its fixed budget\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let bundle = object["bundle"] as? [String: Any],
              let chunks = bundle["chunks"] as? [[String: Any]]
        else {
            return Self.json(400, "{\"code\":\"migration_control_manifest_invalid\",\"error\":\"Migration control manifest is invalid\"}")
        }
        var parsed: [Int: (sha256: String, sizeBytes: Int)] = [:]
        for chunk in chunks {
            guard let index = chunk["index"] as? Int, index >= 0,
                  let size = chunk["sizeBytes"] as? Int, size > 0,
                  let sha = chunk["sha256"] as? String,
                  sha.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
                  parsed[index] == nil
            else {
                return Self.json(400, "{\"code\":\"migration_control_manifest_invalid\",\"error\":\"Migration control manifest is invalid\"}")
            }
            parsed[index] = (sha.lowercased(), size)
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef] else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        if let existing = record.manifestJSON, existing != body {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_control_manifest_conflict\",\"error\":\"Migration control manifest conflicts with the active generation\"}")
        }
        record.manifestJSON = body
        record.manifestChunks = parsed
        if record.chunkReceipts.isEmpty { record.chunkReceipts = [:] }
        machineMigrations[migrationRef] = record
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"manifest\":\(body)}")
    }

}
