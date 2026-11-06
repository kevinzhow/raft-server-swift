import Foundation

struct MessageMentionFacts: Sendable {
    struct Human: Sendable {
        var id: String
        var name: String
        var displayName: String?
    }
    struct Agent: Sendable { var id: String; var name: String }
    var humans: [Human]
    var agents: [Agent]
    var typedAgentIds: Set<String>
    var memberRoles: [String: String]
    var senderId: String
    var senderIsAgent: Bool
    var hideHumans: Bool
    var sharedHumanIds: Set<String>

    func visibleHuman(_ id: String) -> Bool {
        if id == senderId || !hideHumans { return true }
        guard let role = memberRoles[id] else { return false }
        if memberRoles[senderId] != "member" && !senderIsAgent { return true }
        return role == "owner" || role == "admin" || sharedHumanIds.contains(id)
    }
}

/// Resolution is pure policy over explicit profile, roster and channel facts.
/// In particular, rejected typed mentions still suppress matching text handles.
enum MessageMentionPolicy {
    static func resolve(content: String, typed: [MentionInput], warnUnresolved: Bool, facts: MessageMentionFacts) -> ResolvedMentions {
        var result: [MentionInput] = []
        var seen = Set<String>()
        var typedNames = Set<String>()
        let humanIds = Set(facts.humans.map(\.id))
        let agentIds = facts.typedAgentIds
        func append(_ type: String, _ id: String, _ name: String) {
            if seen.insert("\(type):\(id)").inserted { result.append(MentionInput(type: type, id: id, name: name)) }
        }
        for mention in typed where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id), !mention.name.isEmpty else { continue }
            typedNames.insert(mention.name.lowercased())
            let allowed = mention.type == "user"
                ? (facts.hideHumans ? facts.visibleHuman(mention.id) : humanIds.contains(mention.id))
                : agentIds.contains(mention.id)
            if allowed { append(mention.type, mention.id, mention.name) }
        }
        var unresolved: [String] = []
        var handles = Set<String>()
        for handle in MessageMentionRules.mentionHandlesOutsideCode(content)
        where !typedNames.contains(handle.lowercased()) && handles.insert(handle).inserted {
            let humans = facts.humans.filter {
                $0.id != facts.senderId && facts.memberRoles[$0.id] != nil && facts.visibleHuman($0.id)
                    && ($0.name.caseInsensitiveCompare(handle) == .orderedSame
                        || ($0.displayName ?? "").caseInsensitiveCompare(handle) == .orderedSame)
            }
            let agents = facts.agents.filter { $0.name.caseInsensitiveCompare(handle) == .orderedSame }
            if warnUnresolved && humans.count + agents.count != 1 {
                unresolved.append("@" + handle)
            } else {
                for human in humans { append("user", human.id, handle) }
                for agent in agents { append("agent", agent.id, handle) }
            }
        }
        return ResolvedMentions(mentions: result, unresolved: unresolved)
    }
}

/// Acquires independent domain snapshots, evaluates pure mention policy, and
/// hands eligible targets to one Messages transaction for unique registration.
struct MessageMentionsService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let profiles: AuthProfileStore
    let agents: AgentsRuntimeStore
    let oauth: OAuthLedger

    func resolve(serverId: String, senderId: String, content: String, typed: [MentionInput], warnUnresolved: Bool) -> ResolvedMentions {
        let state = channels.state
        let channelFacts = MessageChannelFacts(state)
        var shared = Set<String>()
        for (id, channel) in state.postableChannels
        where channel.serverId == serverId && channel.deletedAt == nil && channel.memberIds.contains(senderId) {
            if channel.name != "all" { shared.formUnion(channel.memberIds) }
            shared.formUnion(channelFacts.jointMembers(channelId: id) ?? [])
        }
        let legacyAgents = agents.serverAgents
        var roster = oauth.serverAgents(serverId: serverId).map { MessageMentionFacts.Agent(id: $0.id, name: $0.name) }
        for (id, agent) in legacyAgents where agent.serverId == serverId && !roster.contains(where: { $0.id == id }) {
            roster.append(.init(id: id, name: agent.name))
        }
        let facts = MessageMentionFacts(
            humans: profiles.accounts.values.map { .init(id: $0.id, name: $0.name, displayName: $0.displayName) },
            agents: roster,
            typedAgentIds: Set(typed.filter {
                $0.type == "agent" && (oauth.agentRuntimeInfo(id: $0.id)?.serverId == serverId
                    || legacyAgents[$0.id]?.serverId == serverId)
            }.map(\.id)),
            memberRoles: Dictionary(uniqueKeysWithValues: oauth.memberRoles(serverId: serverId).map { ($0.userId, $0.role) }),
            senderId: senderId, senderIsAgent: oauth.agentRuntimeInfo(id: senderId)?.serverId == serverId,
            hideHumans: state.hideHumansFromMembers[serverId] == true, sharedHumanIds: shared
        )
        return MessageMentionPolicy.resolve(content: content, typed: typed, warnUnresolved: warnUnresolved, facts: facts)
    }

    func register(messageId: String, channelId: String, mentions: [MentionInput]) {
        guard let channel = channels.postableChannel(id: channelId) else { return }
        let eligible = mentions.filter {
            guard ServerScope.isUUID($0.id) else { return false }
            switch $0.type {
            case "user": return oauth.memberRole(serverId: channel.serverId, userId: $0.id) != nil
            case "agent": return oauth.agentRuntimeInfo(id: $0.id)?.serverId == channel.serverId
            default: return false
            }
        }
        messages.recordMemberMentions(messageId: messageId, channelId: channelId, mentions: eligible)
    }
}
