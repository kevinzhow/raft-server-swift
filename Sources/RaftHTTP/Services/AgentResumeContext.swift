import Foundation
import RaftShared

/// Upstream `agent:start` resume context: the unread summary and the bounded
/// catch-up batch a woken agent reads for messages that arrived while it was
/// not running.
///
/// Upstream builds both from the unified inbox chain
/// (`channelService.selectAgentInboxChainRows` + `getAgentUnreadCounts` +
/// `messageService.getAgentResumeCatchupMessages`) and sends them only when the
/// agent has a session and no wake message/resume prompt. This port has no
/// RisingWave chain; the same rules run over the retained read cursors, message
/// rows and channel memberships. Selection never advances a cursor: the daemon
/// alone decides whether the rows were rendered.
struct AgentResumeContext: Sendable {
    /// Upstream `RESUME_CATCHUP_MAX_CHANNELS` / `RESUME_CATCHUP_MAX_CANDIDATES`
    /// / `RESUME_CATCHUP_MAX_ROWS_PER_CHANNEL` / `RESUME_CATCHUP_MAX_ROWS_TOTAL`.
    static let maxChannels = 8
    static let maxCandidates = maxChannels * 4
    static let maxRowsPerChannel = 5
    static let maxRowsTotal = 20
    /// Upstream `AGENT_UNREAD_SUMMARY_MAX_TARGETS`.
    static let maxSummaryTargets = 20

    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let oauth: OAuthLedger
    let tasks: TasksAndRemindersStore
    let profiles: AuthProfileStore

    struct Output: Sendable {
        var resumeMessages: [JSONValue]
        var unreadSummary: [String: Int]?
    }

    private struct Conversation {
        var id: String
        var storage: String
        var name: String
        var kind: String
    }

    private struct Candidate {
        var conversation: Conversation
        var pending: [AgentPendingMessage]
        var latestPiercingSeq: Int
        var latestUnreadSeq: Int
        var firstUnreadSeq: Int
    }

    /// Every unread row above the read cursor is catch-up input, exactly as
    /// upstream's chain offers it. A row that is also being delivered as a
    /// separate frame stays in the batch: the daemon, not the projection,
    /// decides what the model already saw.
    func build(serverId: String, agentId: String) -> Output {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            return Output(resumeMessages: [], unreadSummary: nil)
        }
        let postable = channels.postableChannels
        let joint = channels.jointProjections
        var conversations: [Conversation] = []
        for (id, channel) in postable.sorted(by: { $0.key < $1.key }) {
            guard channel.serverId == serverId, channel.deletedAt == nil else { continue }
            let visible: Bool
            if channel.kind == "dm" || channel.kind == "thread" || channel.kind == "private" {
                visible = channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
            } else {
                visible = true
            }
            guard visible else { continue }
            let storage = joint.first { $0.localChannelId == id }?.canonicalChannelId ?? id
            conversations.append(Conversation(id: id, storage: storage, name: channel.name, kind: channel.kind))
        }
        guard !conversations.isEmpty else { return Output(resumeMessages: [], unreadSummary: nil) }

        var prefs: [String: OAuthLedger.ChannelNotificationPrefs] = [:]
        for conversation in conversations where prefs[conversation.storage] == nil {
            prefs[conversation.storage] = oauth.notificationPrefs(channelId: conversation.storage, userId: agentId)
        }
        let pending = messages.pendingAgentMessages(
            conversations: conversations.map { AgentInboxConversation(id: $0.id, storage: $0.storage) },
            agentId: agentId, sinceSeq: nil, prefs: prefs)
        guard !pending.isEmpty else { return Output(resumeMessages: [], unreadSummary: nil) }

        var byConversation: [Int: [AgentPendingMessage]] = [:]
        for entry in pending { byConversation[entry.conversationIndex, default: []].append(entry) }

        // Unread summary labels are the agent-facing target DSL. This port has
        // no DM identity table; the peer face is the typed peer, named by the
        // canonical `users.name` / `agents.name` and carrying `~kind` when the
        // server directory holds a cross-kind twin (pinned `agentFacingDmRef`).
        // The directory rule is stable before the second DM exists.
        let directory = AgentDMRefDirectory(
            serverId: serverId, oauth: oauth,
            humanName: { [profiles] userId in profiles.account(userId: userId)?.name }
        )
        func dmChannel(for conversation: Conversation) -> String? {
            guard let channel = postable[conversation.id] else { return nil }
            return AgentFacingDMRef.canonical(
                serverId: serverId,
                agentId: agentId,
                channelId: conversation.id,
                channel: channel,
                humanIds: oauth.channelHumanIds(channelId: conversation.id),
                agentIds: oauth.channelAgentIds(channelId: conversation.id),
                reminderSurfaceId: nil,
                labels: directory,
                humanName: { [profiles] userId in profiles.account(userId: userId)?.name },
                agentName: { [oauth] peerId in
                    guard let peer = oauth.agentRuntimeInfo(id: peerId), !peer.deleted,
                          peer.serverId == serverId else { return nil }
                    return peer.name
                }
            )
        }
        func target(_ conversation: Conversation) -> String {
            switch conversation.kind {
            case "dm":
                if let ref = dmChannel(for: conversation) { return ref }
                let peer = postable[conversation.id]?.memberIds.first { $0 != agentId }
                    .flatMap { profiles.account(userId: $0)?.name }
                return "dm:@\(peer ?? conversation.name)"
            case "thread":
                if let channel = postable[conversation.id], let parentId = channel.parentChannelId,
                   let parentName = postable[parentId]?.name {
                    let short = channel.parentMessageId.map { String($0.prefix(8)) } ?? ""
                    return "#\(parentName):\(short)"
                }
                return "#\(conversation.name)"
            default:
                return "#\(conversation.name)"
            }
        }

        var counts: [String: Int] = [:]
        for (index, rows) in byConversation {
            guard index < conversations.count else { continue }
            counts[target(conversations[index]), default: 0] += rows.count
        }
        let summary = Self.capSummary(counts)

        // Upstream candidate order: the latest "piercing" sequence (DM activity
        // or the newest unread mention) desc, then latest unread, then earliest.
        let mentionSeqs = messages.agentMentionRows(agentId: agentId).reduce(into: [String: Int]()) { result, mention in
            guard let message = messages.humanMessageRows.first(where: { $0.id == mention.messageId }) else { return }
            result[message.channelId] = max(result[message.channelId] ?? 0, message.seq)
        }
        var candidates: [Candidate] = []
        for (index, rows) in byConversation {
            guard index < conversations.count else { continue }
            let conversation = conversations[index]
            let ordered = rows.sorted { $0.seq < $1.seq }
            let latest = ordered.last?.seq ?? 0
            let first = ordered.first?.seq ?? 0
            let piercing: Int
            if conversation.kind == "dm" {
                piercing = latest
            } else {
                piercing = mentionSeqs[conversation.storage] ?? 0
            }
            candidates.append(Candidate(conversation: conversation, pending: ordered,
                                        latestPiercingSeq: piercing, latestUnreadSeq: latest,
                                        firstUnreadSeq: first))
        }
        candidates.sort {
            if $0.latestPiercingSeq != $1.latestPiercingSeq { return $0.latestPiercingSeq > $1.latestPiercingSeq }
            if $0.latestUnreadSeq != $1.latestUnreadSeq { return $0.latestUnreadSeq > $1.latestUnreadSeq }
            return $0.firstUnreadSeq > $1.firstUnreadSeq
        }

        var resumeMessages: [JSONValue] = []
        var contributingChannels = 0
        for candidate in candidates.prefix(Self.maxCandidates) {
            if resumeMessages.count >= Self.maxRowsTotal { break }
            if contributingChannels >= Self.maxChannels { break }
            let rows = Array(candidate.pending.prefix(
                min(Self.maxRowsPerChannel, Self.maxRowsTotal - resumeMessages.count)))
            guard !rows.isEmpty else { continue }
            var contributed = false
            for row in rows {
                guard resumeMessages.count < Self.maxRowsTotal else { break }
                guard let payload = messagePayload(row.message, conversation: candidate.conversation,
                                                   agentId: agentId) else { continue }
                resumeMessages.append(payload)
                contributed = true
            }
            if contributed { contributingChannels += 1 }
        }
        return Output(resumeMessages: resumeMessages, unreadSummary: summary.isEmpty ? nil : summary)
    }

    /// `channelService.capAgentUnreadSummary`: DMs first, then the largest,
    /// then the label; the remainder folds into one line naming the count.
    static func capSummary(_ counts: [String: Int], max: Int = maxSummaryTargets) -> [String: Int] {
        guard counts.count > max else { return counts }
        let entries = counts.sorted { left, right in
            let leftDM = left.key.hasPrefix("dm:") ? 0 : 1
            let rightDM = right.key.hasPrefix("dm:") ? 0 : 1
            if leftDM != rightDM { return leftDM < rightDM }
            if left.value != right.value { return left.value > right.value }
            return left.key < right.key
        }
        let kept = entries.prefix(max)
        let rest = entries.dropFirst(max)
        let folded = rest.reduce(0) { $0 + $1.value }
        var result: [String: Int] = [:]
        for entry in kept { result[entry.key] = entry.value }
        result["(\(rest.count) more conversations — run `raft inbox check` to list them)"] = folded
        return result
    }

    private func messagePayload(_ message: StoredHumanMessage, conversation: Conversation,
                                agentId: String) -> JSONValue? {
        let postable = channels.postableChannels
        let sender: (name: String, description: String?)
        if message.messageType == "system" || message.senderId == "system" || message.senderType == "system" {
            sender = ("System", nil)
        } else if message.senderType == "agent" {
            let author = oauth.agentRuntimeInfo(id: message.senderId)
            sender = (author.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "Unknown", author?.description)
        } else {
            sender = (profiles.account(userId: message.senderId).map {
                ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.name
            } ?? "Unknown", nil)
        }
        let task = tasks.taskRecords.first { $0.messageId == message.id && $0.channelId == conversation.storage }
        let assigneeName = task?.assigneeId.map { id in
            task?.assigneeType == "agent"
                ? oauth.agentRuntimeInfo(id: id).map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "Unknown"
                : profiles.account(userId: id).map { ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.name } ?? "Unknown"
        }
        let attachments: [ChannelAttachment] = message.attachmentIds.compactMap { id in
            messages.attachmentDownloadRecord(attachmentId: id)?.attachment
        }
        var parent: (id: String, name: String, type: String)?
        if conversation.kind == "thread", let channel = postable[conversation.id],
           let parentId = channel.parentChannelId, let parentChannel = postable[parentId] {
            parent = (parentId, oauth.channelInfo(id: parentId)?.name ?? parentChannel.name, parentChannel.kind)
        }
        guard let data = try? MaterializedAgentDelivery.encodeBody(
            message: message, localChannelId: conversation.id, channelName: conversation.name,
            channelType: Self.agentVisibleChannelType(conversation.kind), senderName: sender.name,
            senderDescription: sender.description, recipientId: agentId, task: task,
            taskAssigneeName: assigneeName, attachments: attachments, parent: parent),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value
    }

    /// `toAgentVisibleChannelType`.
    static func agentVisibleChannelType(_ kind: String) -> String {
        switch kind {
        case "thread": "thread"
        case "dm": "dm"
        case "private": "private"
        default: "channel"
        }
    }
}
