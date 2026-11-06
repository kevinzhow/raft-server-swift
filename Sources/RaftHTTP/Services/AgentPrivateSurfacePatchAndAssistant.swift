import Foundation
import RaftShared

/// The profile patch, the assistant-owner link and its reads, and the wake-hint
/// stream, continued from `AgentPrivateSurfaceService.swift` (pure split: the
/// types are one service).
extension AgentPrivateSurfaceService {
    // MARK: - PATCH /api/agents/:id

    /// Applies the profile and runtime-config patch.
    ///
    /// The refusals run in the published order: the server scope, the actor's
    /// authority, the body shape, the restart mode, the external immutability,
    /// the role transition, and only then the first write.
    public func patchAgent(
        authorization: String?,
        agentId: String,
        body: LegacyJSONObjectBody?,
        serverId: String
    ) throws -> AgentPatchResponse {
        if !serverId.isEmpty,
           let info = dependencies.oauth.agentManagementInfo(id: agentId),
           info.serverId != serverId || info.deleted {
            throw AgentPrivateSurfaceError.agentNotFound
        }
        let actor = try authorizedActor(authorization: authorization, agentId: agentId)
        let info = actor.info
        guard let fields = body?.members else { throw AgentPrivateSurfaceError.invalidAgentUpdate }
        let oauth = dependencies.oauth
        let previousConfig = AgentRuntimeConfigDocument(storedJSON: info.runtimeConfigJSON)
        let previousModelValue = AgentRuntimeConfigDocument.agentModel(
            from: info.runtimeConfigJSON, external: info.runtime == "external"
        )
        let previousEffortValue = previousConfig.reasoningEffort
        let previousRuntimeValue = info.runtime
        if let restartMode = fields["restartMode"]?.legacyString,
           restartMode != "restart", restartMode != "session" {
            throw AgentPrivateSurfaceError.invalidRestartMode(restartMode)
        }
        // External agents run on their own machine; Raft-managed runtime
        // fields are immutable for them (descriptions still update).
        if info.runtime == "external",
           ["runtime", "runtimeConfig", "model", "reasoningEffort", "envVars"].contains(where: { fields[$0] != nil }) {
            throw AgentPrivateSurfaceError.externalRuntimeImmutable
        }
        if fields["serverRole"] != nil {
            try applyAgentServerRole(actor: actor, fields: fields)
        }
        var description: String?
        if let value = fields["description"]?.legacyString {
            oauth.updateAgentDescription(id: agentId, description: value)
            description = value
        }
        var displayName: String?
        if let value = fields["displayName"]?.legacyString {
            oauth.updateAgentDisplayName(id: agentId, displayName: value)
            displayName = value
        }
        var avatarUrl: String?
        if let value = fields["avatarUrl"]?.legacyString {
            oauth.updateAgentAvatar(id: agentId, avatarUrl: value)
            avatarUrl = value
        }
        var runtimeConfigJSON = info.runtimeConfigJSON
        var envVarsJSON = info.envVarsJSON
        var replacedRuntime: String?
        if let legacyRuntime = fields["runtime"]?.legacyString {
            if MachineMigrationPolicy.deprecatedAgentRuntimes.contains(legacyRuntime), legacyRuntime != info.runtime {
                throw AgentPrivateSurfaceError.deprecatedRuntime(legacyRuntime)
            }
            replacedRuntime = legacyRuntime
        }
        var configChanged = false
        var config = AgentRuntimeConfigDocument(storedJSON: runtimeConfigJSON)
        if let rawConfig = AgentRuntimeConfigDocument(request: fields["runtimeConfig"]) {
            if let configRuntime = rawConfig.runtime,
               MachineMigrationPolicy.deprecatedAgentRuntimes.contains(configRuntime), configRuntime != info.runtime {
                throw AgentPrivateSurfaceError.deprecatedRuntime(configRuntime)
            }
            try Self.checkStructure(rawConfig)
            var normalized = rawConfig.normalized()
            normalized.preserveProviderAPIKey(from: config)
            if let unsupported = normalized.unsupportedCommandRuntime {
                throw AgentPrivateSurfaceError.commandNotSupported(runtime: unsupported)
            }
            config = normalized
            configChanged = true
            replacedRuntime = normalized.runtime
        } else {
            if let model = fields["model"]?.legacyString {
                config.setPresetModel(id: model)
                configChanged = true
            }
            if let effort = fields["reasoningEffort"] {
                config.setReasoningEffort(effort)
                configChanged = true
            }
        }
        if fields["envVars"] != nil {
            let validation = AgentRuntimeConfigDocument.validatedEnvVars(fields["envVars"])
            if let error = validation.error { throw AgentPrivateSurfaceError.invalidEnvVars(error) }
            var userEnv: [String: String] = [:]
            for (key, value) in validation.env ?? [:] where !key.hasPrefix("ANTHROPIC_") {
                userEnv[key] = value
            }
            config.setEnv(userEnv)
            configChanged = true
        }
        if let replacedRuntime {
            config.setRuntime(replacedRuntime)
            configChanged = true
        }
        if configChanged {
            if let machineId = dependencies.agents.agentMachineIds[info.id] {
                try checkBuiltinCatalog(machineId: machineId, config: config)
            }
            config.fillDefaults()
            let env = config.derivedEnvVars(userEnv: config.userEnv)
            runtimeConfigJSON = config.serialized()
            envVarsJSON = AgentRuntimeConfigDocument.serializedEnv(env)
            oauth.updateAgentRuntime(id: agentId, runtimeConfigJSON: runtimeConfigJSON, envVarsJSON: envVarsJSON)
            if let replacedRuntime { oauth.updateAgentRuntimeId(id: agentId, runtime: replacedRuntime) }
        }
        let latest = oauth.agentRuntimeInfo(id: agentId)
        let runtimeForResponse = latest?.runtime ?? info.runtime
        let configForModel = runtimeConfigJSON ?? latest?.runtimeConfigJSON ?? info.runtimeConfigJSON
        let model = AgentRuntimeConfigDocument.agentModel(
            from: configForModel, external: runtimeForResponse == "external"
        )
        // RFC 071 §5: only a real runtime value change lifts the terminal breaker.
        let runtimeValuesChanged = model != previousModelValue
            || runtimeForResponse != previousRuntimeValue
            || config.reasoningEffort != previousEffortValue
        dependencies.agents.agentConfigLiftDispatch?(agentId, runtimeValuesChanged)
        return AgentPatchResponse(
            id: info.id,
            name: info.name,
            displayName: displayName,
            model: model,
            runtime: runtimeForResponse,
            reasoningEffort: config.publishedReasoningEffort,
            description: description,
            avatarUrl: avatarUrl,
            serverRole: oauth.agentRole(serverId: info.serverId, agentId: info.id) ?? "member",
            runtimeConfigJSON: AgentRuntimeConfigDocument.redactedConfigJSON(
                runtimeConfigJSON ?? latest?.runtimeConfigJSON
            ),
            envVarsJSON: envVarsJSON
        )
    }

    /// Human role-transition policy for `serverRole` on an agent: the owner may
    /// promote and demote, an admin may only promote an agent they created, and
    /// `owner` itself is never assignable to an agent. A real change posts a
    /// system notice into the actor's DM with the agent.
    private func applyAgentServerRole(actor: AgentActor, fields: [String: JSONValue]) throws {
        guard let targetRole = fields["serverRole"]?.legacyString else {
            throw AgentPrivateSurfaceError.serverRoleMustBeString
        }
        guard targetRole == "member" || targetRole == "admin" else {
            throw AgentPrivateSurfaceError.invalidServerRole
        }
        guard actor.role == "owner" || actor.role == "admin" else { throw AgentPrivateSurfaceError.forbidden }
        let info = actor.info
        let currentRole = dependencies.oauth.agentRole(serverId: info.serverId, agentId: info.id) ?? "member"
        if targetRole == currentRole { return }
        if targetRole == "member", currentRole == "admin", actor.role != "owner" {
            throw AgentPrivateSurfaceError.onlyOwnerCanDemoteAdmin
        }
        if targetRole == "admin", actor.role == "admin", info.creatorUserId != actor.userId {
            throw AgentPrivateSurfaceError.onlyOwnerCanPromote
        }
        dependencies.oauth.setAgentRole(serverId: info.serverId, agentId: info.id, role: targetRole)
        dependencies.postAgentRoleNotice(
            info.serverId, actor.userId, info.id, info.name, currentRole, targetRole
        )
    }

    // MARK: - Assistant ownership

    /// The assistant link is live only while the flag is on and the owner is
    /// still a member of the agent's Server.
    public func assistantOwner(agentId: String, serverId: String) -> String? {
        guard let owner = dependencies.agents.assistantOwner(agentId: agentId),
              dependencies.oauth.memberRole(serverId: serverId, userId: owner) != nil
        else { return nil }
        guard dependencies.agents.featureFlagEnabled(key: "identity_borrowing", serverId: serverId) else {
            return nil
        }
        return owner
    }

    /// The stored link, without the membership and flag checks.
    public func assistantOwnerRaw(agentId: String) -> String? {
        dependencies.agents.assistantOwner(agentId: agentId)
    }

    private func assistantIsInRegularChannel(serverId: String, agentId: String) -> Bool {
        let channelMembers = dependencies.agents.channelAgentMembers
        for (id, channel) in dependencies.channels.postableChannels {
            guard channel.serverId == serverId, channel.deletedAt == nil,
                  channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
            else { continue }
            if channel.memberIds.contains(agentId)
                || channelMembers[id]?.contains(agentId) == true
                || dependencies.oauth.channelAgentIds(channelId: id).contains(agentId) {
                return true
            }
        }
        return false
    }

    /// `PUT`/`DELETE /api/agents/:id/assistant-owner`.
    public func agentAssistantOwner(
        authorization: String?,
        serverId: String,
        agentId: String,
        remove: Bool
    ) throws -> AgentAssistantOwnerResponse {
        let oauth = dependencies.oauth
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.authRequired
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            throw AgentPrivateSurfaceError.agentMissing
        }
        guard info.creatorUserId == userId else { throw AgentPrivateSurfaceError.assistantRequiresCreator }
        guard dependencies.agents.featureFlagEnabled(key: "identity_borrowing", serverId: serverId) else {
            throw AgentPrivateSurfaceError.assistantNotEnabled
        }
        if remove {
            dependencies.agents.clearAssistantOwner(agentId: agentId)
            return AgentAssistantOwnerResponse(ownerUserId: nil)
        }
        if assistantOwnerRaw(agentId: agentId) == userId {
            return AgentAssistantOwnerResponse(ownerUserId: userId)
        }
        let isLive: (String) -> Bool = { candidate in
            guard let other = oauth.agentRuntimeInfo(id: candidate) else { return false }
            return other.serverId == serverId && !other.deleted
        }
        guard !dependencies.agents.hasAssistantConflict(userId: userId, agentId: agentId, isLive: isLive) else {
            throw AgentPrivateSurfaceError.assistantAlreadySet
        }
        guard !assistantIsInRegularChannel(serverId: serverId, agentId: agentId) else {
            throw AgentPrivateSurfaceError.assistantHasChannels
        }
        let existingDM = dependencies.directChannelId(serverId, agentId, userId)
        let dmId = existingDM ?? oauth.createDirectChannel(serverId: serverId, firstUserId: agentId, secondUserId: userId)
        dependencies.channels.addPostableChannel(serverId: serverId, channelId: dmId, memberId: agentId, kind: "dm", name: "dm")
        dependencies.channels.addPostableChannel(serverId: serverId, channelId: dmId, memberId: userId, kind: "dm", name: "dm")
        oauth.addChannelHuman(channelId: dmId, userId: userId)
        // The conflict check and the link are one critical section, so two
        // concurrent claims by the same owner cannot both link an assistant.
        guard dependencies.agents.claimAssistantOwner(agentId: agentId, userId: userId, isLive: isLive) else {
            throw AgentPrivateSurfaceError.assistantAlreadySet
        }
        return AgentAssistantOwnerResponse(ownerUserId: userId)
    }

    private struct AssistantReadContext {
        var serverId: String
        var ownerId: String
    }

    private func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    private func assistantReadOwner(_ authorization: String?) throws -> AssistantReadContext {
        guard let token = bearerToken(authorization),
              let credential = dependencies.agents.useAgentCredential(token: token, now: Date()),
              let agent = dependencies.oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              let owner = assistantOwner(agentId: agent.id, serverId: agent.serverId)
        else { throw AgentPrivateSurfaceError.assistantReadNotEnabled }
        return AssistantReadContext(serverId: agent.serverId, ownerId: owner)
    }

    private func ownerCanSeeChannel(ownerId: String, channel: PostableChannel) -> Bool {
        if channel.kind == "channel" || channel.kind == "joint" { return true }
        return channel.memberIds.contains(ownerId)
    }

    /// `GET /internal/agent-api/assistant/owner-inbox`.
    public func agentAssistantOwnerInbox(
        authorization: String?,
        rawQuery: String?
    ) throws -> AssistantOwnerInboxResponse {
        let context = try assistantReadOwner(authorization)
        var limit = 50
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "limit", let value = Int(parts[1]), value > 0 {
                limit = min(value, 100)
            }
        }
        let channels = dependencies.channels.postableChannels
        let messageRows = dependencies.messages.humanMessageRows
        var items: [AssistantOwnerInboxResponse.Item] = []
        for (id, channel) in channels {
            guard channel.serverId == context.serverId, channel.deletedAt == nil else { continue }
            guard ownerCanSeeChannel(ownerId: context.ownerId, channel: channel) else { continue }
            var kind = "channel"
            var parentChannelId: String?
            if channel.kind == "thread" {
                guard let parentId = channel.parentChannelId,
                      let parent = channels[parentId],
                      parent.kind != "dm",
                      ownerCanSeeChannel(ownerId: context.ownerId, channel: parent)
                else { continue }
                kind = "thread"
                parentChannelId = parentId
            } else if channel.kind == "dm" {
                continue
            } else if channel.kind != "channel" && channel.kind != "private" && channel.kind != "joint" {
                continue
            }
            let cursor = dependencies.oauth.channelReadCursor(channelId: id, userId: context.ownerId)
            let unread = messageRows.filter { message in
                message.channelId == id && message.seq > cursor && message.senderId != context.ownerId
            }.count
            guard unread > 0 else { continue }
            items.append(AssistantOwnerInboxResponse.Item(
                kind: kind, channelId: id, unreadCount: unread, parentChannelId: parentChannelId
            ))
            if items.count >= limit { break }
        }
        return AssistantOwnerInboxResponse(ownerUserId: context.ownerId, items: items)
    }

    /// `GET /internal/agent-api/assistant/owner-messages`.
    public func agentAssistantOwnerMessages(
        authorization: String?,
        channelId: String
    ) throws -> AssistantOwnerMessagesResponse {
        let context = try assistantReadOwner(authorization)
        let channels = dependencies.channels.postableChannels
        guard let channel = channels[channelId], channel.serverId == context.serverId,
              channel.deletedAt == nil
        else {
            throw AgentPrivateSurfaceError.channelNotVisible
        }
        if channel.kind == "dm" { throw AgentPrivateSurfaceError.channelNotVisible }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = channels[parentId], parent.kind != "dm",
                  ownerCanSeeChannel(ownerId: context.ownerId, channel: parent)
            else {
                throw AgentPrivateSurfaceError.channelNotVisible
            }
        } else if !ownerCanSeeChannel(ownerId: context.ownerId, channel: channel) {
            throw AgentPrivateSurfaceError.channelNotVisible
        }
        let messages = dependencies.messages.humanMessageRows
            .filter { $0.channelId == channelId }
            .map {
                AssistantOwnerMessagesResponse.Message(
                    id: $0.id, content: $0.content, senderId: $0.senderId, senderType: $0.senderType
                )
            }
        return AssistantOwnerMessagesResponse(ownerUserId: context.ownerId, channelId: channelId, messages: messages)
    }

    // MARK: - Wake-hint stream

    private static func wakeHintFrame(id: String, json: String) -> String {
        "event: wake-hint\nid: \(id)\ndata: \(json)\n\n"
    }

    /// Opens `GET /internal/agent-api/wake-hints/stream`. The stream is the SSE
    /// projection of the same content-free peek: pending hints replay first,
    /// later hints arrive on the next tick, and nothing drains the inbox.
    public func beginAgentWakeHintsStream(
        authorization: String?,
        since: String?
    ) throws -> AgentWakeStreamStart {
        guard let token = bearerToken(authorization) else {
            throw AgentPrivateSurfaceError.missingAuthorizationHeader
        }
        guard let credential = dependencies.agents.agentCredential(token: token),
              credential.revokedAt == nil, credential.scopes.contains("read"),
              let agent = dependencies.oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentPrivateSurfaceError.invalidToken
        }
        let raw = (since ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var cursorSeq: Int?
        var latestOnly = false
        if !raw.isEmpty {
            if raw == "latest" {
                latestOnly = true
            } else {
                guard let value = Int(raw), value >= 0 else { throw AgentPrivateSurfaceError.sinceInvalid }
                cursorSeq = value
            }
        }
        recordAgentCredentialUse(token: token)
        let pending = dependencies.pendingWakeHints(credential.agentId, agent, cursorSeq, 500)
        let thirdParty = dependencies.oauth.pendingThirdPartyEventMessages(agentId: credential.agentId)
        var frames = ": connected\n\n"
        if latestOnly {
            cursorSeq = pending.last?.seq
        } else {
            for row in pending {
                frames += Self.wakeHintFrame(id: "\(row.seq)", json: row.json)
                cursorSeq = row.seq
            }
            for event in thirdParty {
                let data = OrderedJSON.object([
                    OrderedJSONField("event_id", "wake-hint:\(event.id)"),
                    OrderedJSONField("seq", .null),
                    OrderedJSONField("message_id", event.id),
                    OrderedJSONField("target", .null),
                    OrderedJSONField("wake_reason", "message_pending"),
                ]).render()
                frames += Self.wakeHintFrame(id: "null", json: data)
            }
        }
        return AgentWakeStreamStart(token: token, cursorSeq: cursorSeq, firstFrame: frames)
    }

    /// One poll tick. `nil` means the credential or agent is gone: the stream
    /// must close.
    public func agentWakeStreamBatch(token: String, after: Int?) -> AgentWakeStreamBatch? {
        guard let credential = dependencies.agents.agentCredential(token: token),
              credential.revokedAt == nil, credential.scopes.contains("read"),
              let agent = dependencies.oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return nil }
        let pending = dependencies.pendingWakeHints(credential.agentId, agent, after, 500)
        guard let last = pending.last else { return AgentWakeStreamBatch(frames: "", cursorSeq: after) }
        let frames = pending.map { Self.wakeHintFrame(id: "\($0.seq)", json: $0.json) }.joined()
        return AgentWakeStreamBatch(frames: frames, cursorSeq: last.seq)
    }
}
