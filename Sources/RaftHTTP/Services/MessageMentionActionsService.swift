import Foundation
import RaftShared

/// Mention actions coordinate existing owners. All writes and typed execution
/// staging remain in the caller's retained BPR; this value owns no mutable state.
struct MessageMentionActionsService: Sendable {
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let agents: AgentsRuntimeStore
    let profiles: AuthProfileStore
    let oauth: OAuthLedger
    let machines: MachinesAndComputersStore?
    let execution: AgentExecutionService?
    let now: @Sendable () -> Date

    private struct Row {
        var mention: StoredMention
        var host: StoredHumanMessage
        var channel: PostableChannel
    }

    func pending(serverId: String, agentId: String, limit: String? = nil) -> AgentPendingMentionActionsResponse {
        let state = messages.state
        let current = now()
        var rows = state.storedMentions.compactMap { mention -> Row? in
            guard !mention.notifiableAtSend, mention.notifiedAt == nil,
                  current.timeIntervalSince(mention.createdAt) < MessageMentionRules.pendingLifetime,
                  let row = known(mention, serverId: serverId, actorType: "agent", actorId: agentId),
                  row.channel.deletedAt == nil else { return nil }
            return row
        }
        rows.sort { $0.mention.createdAt > $1.mention.createdAt }
        let pageLimit = pendingPageLimit(limit)
        let page = rows.prefix(pageLimit).map { row in
            AgentPendingMentionAction(resolutionId: row.mention.id, messageId: row.host.id,
                channelId: row.mention.channelId, channelName: row.channel.name,
                targetType: row.mention.targetType, targetId: row.mention.targetId,
                targetHandle: row.mention.handle,
                messageSeq: row.host.seq, createdAt: timestamp(row.mention.createdAt),
                expiresAt: MessageMentionRules.expiry(row.mention.createdAt), reason: "not_member",
                availableActions: !row.channel.archived && ["channel", "thread"].contains(row.channel.kind) ? ["notify"] : [])
        }
        return AgentPendingMentionActionsResponse(pendingMentionActions: page, hasMore: rows.count > pageLimit)
    }

    /// The published query uses JavaScript Number(string), not Swift's broader
    /// infinity spellings. Non-decimal integer prefixes do not accept a sign.
    private func pendingPageLimit(_ raw: String?) -> Int {
        let text = MessageMentionRules.trimmingJavaScriptWhitespace(raw ?? "")
        let number: Double?
        if text == "Infinity" || text == "+Infinity" { number = .infinity }
        else if text == "-Infinity" { number = -.infinity }
        else if text.hasPrefix("0x") || text.hasPrefix("0X") || text.hasPrefix("0b") || text.hasPrefix("0B")
                    || text.hasPrefix("0o") || text.hasPrefix("0O") {
            let prefix = text.lowercased().prefix(2)
            let radix = prefix == "0x" ? 16 : prefix == "0b" ? 2 : 8
            var value = 0
            var valid = text.utf8.count > 2
            for byte in text.utf8.dropFirst(2) {
                let digit: Int
                switch byte {
                case 48...57: digit = Int(byte - 48)
                case 65...70: digit = Int(byte - 65) + 10
                case 97...102: digit = Int(byte - 97) + 10
                default: digit = radix
                }
                if digit >= radix { valid = false; break }
                value = min(100, value * radix + digit)
            }
            number = valid ? Double(value) : nil
        } else if text.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#,
                             options: .regularExpression) != nil { number = Double(text) }
        else { number = nil }
        let requested = number.flatMap { !$0.isNaN && $0 != 0 ? $0 : nil } ?? 50
        return Int(min(100, max(1, requested)))
    }

    func execute(ids: [String], action: String, serverId: String, actorType: String,
                 actorId: String) throws -> [MentionActionResult] {
        var results: [MentionActionResult] = []
        for input in ids {
            let normalized = MessageMentionRules.trimmingJavaScriptWhitespace(input).lowercased()
            let valid = ServerScope.isUUID(normalized)
                || normalized.range(of: #"^[0-9a-f]{8}$"#, options: .regularExpression) != nil
            let matches = valid ? messages.state.storedMentions.compactMap { mention -> Row? in
                let same = normalized.count == 8 ? mention.id.hasPrefix(normalized) : mention.id == normalized
                return same ? known(mention, serverId: serverId, actorType: actorType, actorId: actorId) : nil
            } : []
            guard matches.count == 1, let row = matches.first else {
                results.append(MentionActionResult(resolutionId: input, action: action,
                    status: matches.count > 1 ? "ambiguous" : "not_found"))
                continue
            }
            results.append(try execute(row, action: action, serverId: serverId, actorType: actorType, actorId: actorId))
        }
        return results
    }

    private func known(_ mention: StoredMention, serverId: String, actorType: String, actorId: String) -> Row? {
        guard let channel = channels.state.postableChannels[mention.channelId], channel.serverId == serverId else { return nil }
        let hosts = messages.humanMessageRows.filter { $0.id == mention.messageId }
        guard hosts.count == 1, let host = hosts.first, host.channelId == mention.channelId,
              host.senderType == actorType, host.senderId == actorId else { return nil }
        return Row(mention: mention, host: host, channel: channel)
    }

    private func execute(_ row: Row, action: String, serverId: String, actorType: String,
                         actorId: String) throws -> MentionActionResult {
        let mention = row.mention
        func result(_ status: String, _ reason: String? = nil, _ ids: [String]? = nil) -> MentionActionResult {
            MentionActionResult(resolutionId: mention.id, action: action, status: status, reason: reason,
                deduped: ids, messageId: row.host.id, channelId: mention.channelId,
                targetType: mention.targetType, targetId: mention.targetId)
        }
        if mention.notifiedAction == "add" || mention.notifiedAction == "invite"
            || (mention.notifiedAt != nil && (action == "notify" || mention.notifiedAction != "notify_only")) {
            return result(action == "notify" ? "queued" : "delivered",
                          action == "notify" ? "already_queued" : "already_delivered", [mention.id])
        }
        if mention.notifiableAtSend || row.channel.archived || row.channel.deletedAt != nil {
            return result("stale", "no_longer_pending")
        }
        let current = now()
        if current.timeIntervalSince(mention.createdAt) > MessageMentionRules.pendingLifetime { return result("expired") }
        guard let authorityId = authorityChannel(row), actorIsMember(actorType, actorId, channelId: authorityId) else {
            return result("no_permission", "sender_lacks_channel_access")
        }
        guard targetExists(mention, serverId: serverId) else { return result("stale", "target_unavailable") }
        if targetIsMember(row, serverId: serverId) { return result("stale", "target_already_member") }
        if action == "notify" {
            guard ["channel", "thread"].contains(row.channel.kind), targetCanRead(row, serverId: serverId) else {
                return result("no_permission", "target_lacks_read_access")
            }
        } else {
            guard actorType == "user" else { return result("no_permission", "add_requires_human_member_authority") }
            guard ["channel", "thread"].contains(row.channel.kind) else { return result("no_permission", "add_not_allowed_for_surface") }
            guard canManageMembers(actorId, serverId: serverId, channelId: authorityId) else {
                return result("no_permission", "add_requires_member_management_authority")
            }
        }
        if action == "notify", mention.targetType == "agent",
           let reason = executionDropReason(mention, serverId: serverId) { return result("dropped", reason) }
        guard let claim = messages.claimMentionGroup(resolutionId: mention.id, action: action,
            actorType: actorType, actorId: actorId, now: current) else {
            return MentionActionResult(resolutionId: mention.id, action: action, status: "not_found")
        }
        guard claim.newlyClaimed else { return claim.result }
        if action == "add" {
            grantMembership(row, serverId: serverId, authorityId: authorityId, at: current)
        }
        if mention.targetType == "agent" {
            if action == "notify" {
                try stageDelivery(mention, serverId: serverId)
            } else if executionDropReason(mention, serverId: serverId) == nil {
                // Node's after-add delivery is best effort. A mutating typed
                // staging failure remains rollback-only, never partial COMMIT.
                try stageDelivery(mention, serverId: serverId)
            }
        }
        return claim.result
    }

    private func authorityChannel(_ row: Row) -> String? {
        guard row.channel.kind == "thread" else { return row.mention.channelId }
        guard let parentId = row.channel.parentMessageId else { return nil }
        let parents = messages.humanMessageRows.filter { $0.id == parentId }
        guard parents.count == 1, let parent = parents.first else { return nil }
        return MessageMentionScopeQuery(messages: messages, channels: channels, oauth: oauth)
            .localChannel(parent.channelId, serverId: row.channel.serverId)
    }

    private func actorIsMember(_ type: String, _ id: String, channelId: String) -> Bool {
        type == "agent" ? oauth.channelAgentIds(channelId: channelId).contains(id)
            : oauth.isChannelParticipant(channelId: channelId, userId: id)
    }

    private func targetExists(_ mention: StoredMention, serverId: String) -> Bool {
        if mention.targetType == "agent" {
            return oauth.agentRuntimeInfo(id: mention.targetId).map { !$0.deleted && $0.serverId == serverId } == true
        }
        return mention.targetType == "user" && profiles.account(userId: mention.targetId) != nil
            && oauth.memberRole(serverId: serverId, userId: mention.targetId) != nil
    }

    private func targetIsMember(_ row: Row, serverId: String) -> Bool {
        if row.channel.kind == "thread" {
            let snapshot = messages.threadFollowSnapshot()
            let key = "\(serverId)\n\(row.mention.targetId)\n\(row.mention.channelId)"
            return messages.followsActiveThread(serverId: serverId, userId: row.mention.targetId,
                threadChannelId: row.mention.channelId) && !snapshot.unfollows.contains(key)
        }
        return actorIsMember(row.mention.targetType, row.mention.targetId, channelId: row.mention.channelId)
    }

    private func targetCanRead(_ row: Row, serverId: String) -> Bool {
        if row.mention.targetType == "agent" {
            return MessageMentionScopeQuery(messages: messages, channels: channels, oauth: oauth)
                .agentCanRead(channelId: row.mention.channelId, serverId: serverId, agentId: row.mention.targetId)
        }
        return HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: agents)
            .authority(channelId: row.mention.channelId, serverId: serverId, userId: row.mention.targetId) != nil
    }

    private func canManageMembers(_ userId: String, serverId: String, channelId: String) -> Bool {
        guard let channel = channels.state.postableChannels[channelId], channel.serverId == serverId,
              !channel.archived, channel.deletedAt == nil,
              ["channel", "private", "joint"].contains(channel.kind), channel.name != "all" else { return false }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        return role == "owner" || role == "admin"
            || (role == "member" && oauth.isChannelParticipant(channelId: channelId, userId: userId))
    }

    private func grantMembership(_ row: Row, serverId: String, authorityId: String, at date: Date) {
        let mention = row.mention
        let isAgent = mention.targetType == "agent"
        let joined = actorIsMember(mention.targetType, mention.targetId, channelId: authorityId)
        if !joined {
            if isAgent {
                oauth.addChannelAgent(channelId: authorityId, agentId: mention.targetId)
            } else {
                oauth.addChannelHuman(channelId: authorityId, userId: mention.targetId)
            }
            channels.addChannelMember(channelId: authorityId, userId: mention.targetId)
            if isAgent { agents.recordMentionMembership(channelId: authorityId, agentId: mention.targetId) }
            let links = channels.state.jointProjections.filter {
                $0.localChannelId == authorityId && $0.serverId == serverId && $0.status == "active"
            }
            let storageId = links.count == 1 ? links[0].canonicalChannelId : authorityId
            let seq = row.channel.kind == "thread"
                ? (messages.humanMessageRows.filter { $0.channelId == storageId }.map(\.seq).max() ?? 0)
                : max(0, row.host.seq - 1)
            raiseReadPosition(channelId: authorityId, targetType: mention.targetType, targetId: mention.targetId, seq: seq)
        }
        if row.channel.kind == "thread", let parentId = row.channel.parentMessageId {
            let seq = max(0, row.host.seq - 1)
            raiseReadPosition(channelId: mention.channelId, targetType: mention.targetType, targetId: mention.targetId, seq: seq)
            messages.completeMentionThreadJoin(serverId: serverId, targetId: mention.targetId,
                threadChannelId: mention.channelId, parentMessageId: parentId, at: date)
        }
    }

    /// Node raises join boundaries monotonically, creates no cursor for seq0,
    /// and never turns historical older messages into new unread on rejoin.
    private func raiseReadPosition(channelId: String, targetType: String, targetId: String, seq: Int) {
        guard seq > 0 else { return }
        if targetType == "agent" {
            _ = messages.advanceAgentChannelRead(channelId: channelId, agentId: targetId, latestSeq: seq)
        } else if seq > oauth.channelReadCursor(channelId: channelId, userId: targetId) {
            oauth.setChannelReadCursor(channelId: channelId, userId: targetId, seq: seq)
            _ = messages.bumpChannelReadVersion(channelId: channelId, userId: targetId)
        }
    }

    private func executionDropReason(_ mention: StoredMention, serverId: String) -> String? {
        guard execution != nil, let machines,
              oauth.agentRuntimeInfo(id: mention.targetId)?.runtime == "codex" else { return "delivery_unavailable" }
        do { try DeferredEffects.requireDurableTransaction(in: .shared) }
        catch { return "delivery_unavailable" }
        return AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth, channels: channels, messages: messages)
            .mentionDeliveryDropReason(serverId: serverId, agentId: mention.targetId)
    }

    private func stageDelivery(_ mention: StoredMention, serverId: String) throws {
        guard let execution, let commandId = UUID(uuidString: mention.id) else {
            DeferredEffects.markRollbackOnly()
            throw AgentExecutionError.dispatchUnavailable
        }
        do {
            let receipt = try execution.requestHumanMessageDelivery(.init(commandId: commandId, serverId: serverId,
                agentId: mention.targetId, channelId: mention.channelId, messageId: mention.messageId))
            switch receipt {
            case .staged:
                break
            case .readableOnly(.launchInProgress):
                // Tracked mention delivery defers to the runtime's `agent:session`
                // when its wake start has just been admitted: the durable
                // occurrence and pending fact own the obligation, so the action
                // is a successful queue, not a failed dispatch.
                break
            case .held, .readableOnly:
                DeferredEffects.markRollbackOnly()
                throw AgentExecutionError.dispatchUnavailable
            }
        } catch {
            DeferredEffects.markRollbackOnly()
            throw error
        }
    }

    private func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}
