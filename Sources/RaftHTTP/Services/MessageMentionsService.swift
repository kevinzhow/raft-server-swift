import Foundation

struct ResolvedMentionRegistration: Sendable {
    var mention: MentionInput
    var notifiableAtSend: Bool
}

struct MessageMentionFacts: Sendable {
    struct Target: Sendable {
        var type: String
        var id: String
        var name: String
        var notifiableAtSend: Bool
    }
    var targets: [Target]
}

/// One canonical identity decision, before the message is committed. A rejected
/// typed entity claims its visible handle, so raw text cannot rebind it.
enum MessageMentionPolicy {
    static func resolve(surface: MessageMentionSurface, typed: [MentionInput], warnUnresolved: Bool, facts: MessageMentionFacts) -> ResolvedMentions {
        var rows: [ResolvedMentionRegistration] = []
        var seen = Set<String>()
        var claimed = Set<String>()
        var bound: [String: String] = [:]
        var conflict = false
        func append(_ target: MessageMentionFacts.Target, handle: String) {
            guard seen.insert("\(target.type):\(target.id)").inserted else { return }
            rows.append(.init(mention: MentionInput(type: target.type, id: target.id, name: handle),
                              notifiableAtSend: target.notifiableAtSend))
        }
        for mention in typed {
            let handle = MessageMentionRules.trimmingJavaScriptWhitespace(mention.name)
            guard MessageMentionRules.structuredMentionStillAppears(surface, handle: handle) else { continue }
            claimed.insert(handle)
            guard ServerScope.isUUID(mention.id), mention.type == "user" || mention.type == "agent",
                  let target = facts.targets.first(where: {
                      $0.id == mention.id && $0.type == mention.type && $0.name == handle
                  }) else { continue }
            let key = "\(target.type):\(target.id)"
            if warnUnresolved, let prior = bound[handle], prior != key { conflict = true }
            bound[handle] = key
            append(target, handle: handle)
        }
        let known = Set(facts.targets.map(\.name))
        let tokens = MessageMentionRules.mentionHandlesOutsideCode(surface)
        for token in tokens where !claimed.contains(token) {
            guard let handle = MessageMentionRules.resolvedHandle(token, known: known), !claimed.contains(handle) else { continue }
            let matches = facts.targets.filter { $0.name == handle }
            if warnUnresolved, matches.count > 1 { continue }
            for target in matches { append(target, handle: handle) }
        }
        // Node's sender warning considers authored structured names as well as
        // resolved facts. A claimed CJK-suffixed handle is not unresolved merely
        // because it was correctly kept out of the raw-name fallback.
        let warningNames = Set(rows.map(\.mention.name)
            + typed.map { MessageMentionRules.trimmingJavaScriptWhitespace($0.name) })
        let unresolved = warnUnresolved ? tokens.filter {
            MessageMentionRules.resolvedHandle($0, known: warningNames) == nil
        }.map { "@" + $0 } : []
        return ResolvedMentions(mentions: rows.map(\.mention), unresolved: unresolved,
                                registrations: rows, bindingConflict: conflict)
    }
}

/// A stateless query over the existing owners. It resolves real parent messages
/// and active local projections; postable memberIds never grant OAuth authority.
struct MessageMentionScopeQuery: Sendable {
    struct Scope: Sendable {
        var id: String
        var channel: PostableChannel
        var memberChannelIds: [String]
    }
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let oauth: OAuthLedger

    func localChannel(_ id: String, serverId: String) -> String? {
        let state = channels.state
        let related = state.jointProjections.filter { $0.localChannelId == id || $0.canonicalChannelId == id }
        if !related.isEmpty {
            let canonical = Set(related.map(\.canonicalChannelId))
            guard canonical.count == 1, let canonicalId = canonical.first else { return nil }
            let active = state.jointProjections.filter {
                $0.canonicalChannelId == canonicalId && $0.serverId == serverId && $0.status == "active"
            }
            guard active.count == 1, let link = active.first,
                  let local = state.postableChannels[link.localChannelId],
                  local.serverId == serverId, local.deletedAt == nil else { return nil }
            return link.localChannelId
        }
        guard let row = state.postableChannels[id], row.serverId == serverId, row.deletedAt == nil else { return nil }
        return id
    }

    func effectiveScope(channelId: String, serverId: String) -> Scope? {
        let state = channels.state
        let rows = messages.humanMessageRows
        var next = channelId
        var visited = Set<String>()
        while visited.count < 64 {
            guard let id = localChannel(next, serverId: serverId), visited.insert(id).inserted,
                  var channel = state.postableChannels[id] else { return nil }
            if id == oauth.allChannelId(serverId: serverId), let type = oauth.channelType(id: id) { channel.kind = type }
            if channel.kind == "thread" {
                guard let parentId = channel.parentMessageId else { return nil }
                let parents = rows.filter { $0.id == parentId }
                guard parents.count == 1, let parent = parents.first else { return nil }
                next = parent.channelId
                continue
            }
            let links = state.jointProjections.filter { $0.localChannelId == id && $0.status == "active" }
            if channel.kind == "joint" || !links.isEmpty {
                guard links.count == 1, let canonical = links.first?.canonicalChannelId else { return nil }
                let members = state.jointProjections.filter { projection in
                    guard projection.status == "active", projection.canonicalChannelId == canonical,
                          let local = state.postableChannels[projection.localChannelId] else { return false }
                    return local.serverId == projection.serverId && local.deletedAt == nil
                }.map(\.localChannelId)
                return Scope(id: id, channel: channel, memberChannelIds: members)
            }
            return Scope(id: id, channel: channel, memberChannelIds: [id])
        }
        return nil
    }

    func agentCanRead(channelId: String, serverId: String, agentId: String) -> Bool {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId,
              let scope = effectiveScope(channelId: channelId, serverId: serverId) else { return false }
        if scope.channel.kind == "channel" {
            return scope.channel.name != "all" || oauth.channelType(id: scope.id) == "channel"
        }
        return scope.memberChannelIds.contains { oauth.channelAgentIds(channelId: $0).contains(agentId) }
    }
}

/// Acquires the facts once and hands prepared immutable registrations to the
/// existing Messages owner. It never changes a profile or a recipient's access.
struct MessageMentionsService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let profiles: AuthProfileStore
    let agents: AgentsRuntimeStore
    let oauth: OAuthLedger

    func resolve(serverId: String, channelId: String, senderId: String, content: String,
                 typed: [MentionInput], warnUnresolved: Bool,
                 surface: MessageMentionSurface? = nil) throws -> ResolvedMentions {
        let parsed: MessageMentionSurface
        if let surface {
            guard surface.source == content else { throw MessageMentionParsingError.unavailable }
            parsed = surface
        } else {
            parsed = try MessageMentionMarkdown.parse(content)
        }
        let query = MessageMentionScopeQuery(messages: messages, channels: channels, oauth: oauth)
        guard let scope = query.effectiveScope(channelId: channelId, serverId: serverId) else {
            return ResolvedMentions(mentions: [], unresolved: [])
        }
        let state = channels.state
        let roles = Dictionary(uniqueKeysWithValues: oauth.memberRoles(serverId: serverId).map { ($0.userId, $0.role) })
        var humanMembers = Set(scope.memberChannelIds.flatMap { oauth.channelHumanIds(channelId: $0) })
        var agentMembers = Set(scope.memberChannelIds.flatMap { oauth.channelAgentIds(channelId: $0) })
        // Node's enabled system #all has a real virtual audience. This explicit
        // special case is not a public-channel server-roster eligibility fallback.
        if scope.id == oauth.allChannelId(serverId: serverId), scope.channel.kind == "channel" {
            humanMembers = Set(roles.filter { $0.value != "guest" }.map(\.key))
            agentMembers = Set(oauth.serverAgents(serverId: serverId).map(\.id))
        }
        let privateScope = scope.channel.kind == "private" || scope.channel.kind == "joint"
            || state.jointProjections.contains(where: { $0.localChannelId == scope.id && $0.status == "active" })
        let senderAgent = oauth.agentRuntimeInfo(id: senderId).map { !$0.deleted && $0.serverId == serverId } == true
        let hidden = state.hideHumansFromMembers[serverId] == true && !privateScope
            && (senderAgent ? oauth.agentRole(serverId: serverId, agentId: senderId) != "admin" : roles[senderId] == "member")
        var shared = Set<String>()
        if hidden && !senderAgent {
            for (id, channel) in state.postableChannels
            where channel.serverId == serverId && channel.deletedAt == nil && channel.name != "all"
                && oauth.isChannelParticipant(channelId: id, userId: senderId) {
                shared.formUnion(oauth.channelHumanIds(channelId: id))
                if let joint = query.effectiveScope(channelId: id, serverId: serverId), joint.channel.kind == "joint" {
                    shared.formUnion(joint.memberChannelIds.flatMap { oauth.channelHumanIds(channelId: $0) })
                }
            }
        }
        let community = ["community", "community-cn"].contains(oauth.serverDetailsValue(id: serverId)?.slug ?? "")
        var targets: [MessageMentionFacts.Target] = []
        for profile in profiles.accounts.values {
            guard privateScope ? humanMembers.contains(profile.id) : roles[profile.id] != nil else { continue }
            if hidden {
                let privileged = community && (roles[profile.id] == "owner" || roles[profile.id] == "admin")
                guard privileged || (!senderAgent && (profile.id == senderId || shared.contains(profile.id))) else { continue }
            }
            targets.append(.init(type: "user", id: profile.id, name: profile.name,
                                 notifiableAtSend: humanMembers.contains(profile.id)))
        }
        let candidateServers = privateScope
            ? Set(scope.memberChannelIds.compactMap { state.postableChannels[$0]?.serverId }) : [serverId]
        var seen = Set<String>()
        for candidateServer in candidateServers {
            for agent in oauth.serverAgents(serverId: candidateServer) where seen.insert(agent.id).inserted {
                guard !privateScope || agentMembers.contains(agent.id) else { continue }
                targets.append(.init(type: "agent", id: agent.id, name: agent.name,
                                     notifiableAtSend: agentMembers.contains(agent.id)))
            }
        }
        return MessageMentionPolicy.resolve(surface: parsed, typed: typed, warnUnresolved: warnUnresolved,
                                             facts: MessageMentionFacts(targets: targets))
    }

    func recordThreadReplyFollows(messageId: String, channelId: String, serverId: String,
                                  senderId: String, resolution: ResolvedMentions) {
        guard let thread = channels.postableChannel(id: channelId), thread.kind == "thread",
              thread.serverId == serverId, let parentId = thread.parentMessageId,
              let host = messages.humanMessageRows.first(where: {
                  $0.id == messageId && $0.channelId == channelId && $0.senderId == senderId
              }), let parent = messages.humanMessageRows.first(where: { $0.id == parentId }),
              let scope = MessageMentionScopeQuery(messages: messages, channels: channels, oauth: oauth)
                .effectiveScope(channelId: channelId, serverId: serverId) else { return }
        let virtualAll = scope.id == oauth.allChannelId(serverId: serverId) && scope.channel.kind == "channel"
        if host.senderType == "agent", !virtualAll,
           !scope.memberChannelIds.contains(where: { oauth.channelAgentIds(channelId: $0).contains(senderId) }) { return }
        let targets = resolution.registrations.filter { $0.notifiableAtSend && $0.mention.id != senderId }
            .map { ThreadMentionFollowTarget(userId: $0.mention.id, isParentMember: true) }
        messages.applyThreadReplyFollows(serverId: serverId, threadChannelId: channelId,
            parentMessageId: parentId, senderId: senderId, mentioned: targets)
        let humanAuthor = parent.senderType == "user"
            && oauth.memberRole(serverId: serverId, userId: parent.senderId) != nil
        let agentAuthor = parent.senderType == "agent"
            && oauth.agentRuntimeInfo(id: parent.senderId).map { !$0.deleted && $0.serverId == serverId } == true
        if host.senderType == "agent", parent.messageType != "system", parent.senderId != "system",
           parent.senderId != senderId, humanAuthor || agentAuthor {
            messages.ensureThreadFollows([(serverId, parent.senderId, channelId, parentId)])
        }
    }

    func register(messageId: String, channelId: String, resolution: ResolvedMentions) {
        messages.recordMemberMentions(messageId: messageId, channelId: channelId,
                                      registrations: resolution.registrations)
    }
}
