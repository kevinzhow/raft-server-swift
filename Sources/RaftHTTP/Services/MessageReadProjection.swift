import Foundation

/// The channel facts shared by read projections and mention visibility. Each
/// value comes from one Channels snapshot; policy never borrows directory state.
struct MessageChannelFacts: Sendable {
    var channels: [String: PostableChannel]
    var joints: [JointChannelLink]

    init(_ state: ServersAndChannelsStore.State) {
        channels = state.postableChannels
        joints = state.jointProjections
    }

    func localChannel(canonical: String, serverId: String?, userId: String) -> String? {
        guard let serverId else { return nil }
        return joints.first {
            $0.canonicalChannelId == canonical && $0.serverId == serverId
                && channels[$0.localChannelId]?.memberIds.contains(userId) == true
        }?.localChannelId
    }

    func jointMembers(channelId: String) -> Set<String>? {
        let canonical = joints.first { $0.localChannelId == channelId }?.canonicalChannelId
            ?? (joints.contains { $0.canonicalChannelId == channelId } ? channelId : nil)
        guard let canonical else { return nil }
        return joints.filter { $0.canonicalChannelId == canonical }.reduce(channels[canonical]?.memberIds ?? []) {
            $0.union(channels[$1.localChannelId]?.memberIds ?? [])
        }
    }

    func canReadForward(_ item: ForwardItemRecord, userId: String, serverId: String?) -> Bool {
        guard let target = item.sourceTargetId, let serverId,
              let channel = channels[target], channel.serverId == serverId, channel.deletedAt == nil else { return false }
        if channel.kind == "channel" { return true }
        if channel.kind == "thread", let parentId = channel.parentChannelId,
           let parent = channels[parentId], parent.serverId == serverId, parent.deletedAt == nil {
            return parent.kind == "channel" || parent.memberIds.contains(userId) || channel.memberIds.contains(userId)
        }
        return channel.memberIds.contains(userId)
    }
}

/// The creation-time `conversationContext` of a retained row: the channel's
/// kind and, for a thread reply, the parent message's coordinates. Shared by
/// the channel-history read and the human-send `message:new` frame.
func messageConversationContext(
    channel: PostableChannel,
    channels: [String: PostableChannel]
) -> OrderedJSON {
    var fields: [OrderedJSONField] = [.init("channelType", channel.kind)]
    if channel.kind == "thread" {
        if let parent = channel.parentChannelId { fields.append(.init("parentChannelId", parent)) }
        if let parent = channel.parentMessageId { fields.append(.init("parentMessageId", parent)) }
        if let id = channel.parentChannelId, let parent = channels[id] {
            fields.append(.init("parentChannelType", parent.kind))
        }
    }
    return .object(fields)
}

/// Read-side composition returns the existing ordered DTOs. Stores provide
/// atomic row snapshots; channel/OAuth authority is a separate explicit input.
struct MessageReadProjection: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let profiles: AuthProfileStore
    let agents: AgentsRuntimeStore
    let oauth: OAuthLedger
    let tasks: TasksAndRemindersStore

    /// Message labels and stable handles are different published facts. Reply
    /// summaries use the handle, while message rows display the actual label.
    private func actor(id: String, type: String, externalName: String? = nil)
        -> (handle: String?, display: String?, avatar: String?, description: String?) {
        if type == "agent" {
            if let agent = oauth.agentRuntimeInfo(id: id) {
                return (agent.name, agent.displayName.isEmpty ? agent.name : agent.displayName, agent.avatarUrl, agent.description)
            }
            if let agent = agents.serverAgents[id] { return (agent.name, agent.name, agent.avatarUrl, nil) }
        } else if type == "external_projection" {
            return (externalName, externalName, nil, nil)
        } else if type == "user", let account = profiles.accounts.values.first(where: { $0.id == id }) {
            return (account.name, account.displayName?.isEmpty == false ? account.displayName : account.name,
                    account.avatarUrl, account.description)
        }
        return (nil, nil, nil, nil)
    }

    func readFacts(_ row: StoredHumanMessage, channelId: String, commentsVisible: Bool,
                   serverId: String?, userId: String?) -> MessageReadFactsDTO {
        let state = messages.state
        let channelState = channels.state
        let channel = channelState.postableChannels[channelId]
        let identity = actor(id: row.senderId, type: row.senderType, externalName: row.externalSenderName)
        let membership: String?
        if row.messageType == "system" || row.senderId == "system" { membership = nil }
        else if row.senderType == "agent", let agent = oauth.agentRuntimeInfo(id: row.senderId) {
            membership = agent.deleted ? "removed" : "active"
        } else if let server = channel?.serverId, oauth.memberRole(serverId: server, userId: row.senderId) != nil {
            membership = "active"
        } else { membership = channelState.serverMemberStatuses["\(channel?.serverId ?? "")\n\(row.senderId)"] ?? "removed" }
        let threadId = readableChildThreads(parentChannelId: channelId, parentIds: [row.id],
            serverId: serverId, userId: userId, channelState: channelState).first?.id
        let conversation: OrderedJSON? = channel.map {
            messageConversationContext(channel: $0, channels: channelState.postableChannels)
        }
        var retained: [OrderedJSONField] = []
        for (key, value) in [
            ("actionKind", row.actionKind), ("externalMessageId", row.externalMessageId),
            ("externalProvider", row.externalProvider), ("externalSenderName", row.externalSenderName),
            ("systemSubtype", row.systemSubtype), ("causalActorType", row.causalActorType), ("causalActorId", row.causalActorId),
        ] { if let value { retained.append(.init(key, value)) } }
        let task = tasks.taskRecords.first {
            $0.hasHostMessage && $0.messageId == row.id && $0.channelId == row.channelId
        }
        let overlay = task.map(TaskReadProjection.messageReadOverlay)
        // Upstream `projectForwardDestinationMessage` removes the six task
        // columns from a forwarded-bundle destination row on every read.
        let isForwardDestination = state.forwardRecords[row.id] != nil
        let assigneeId: String?
        let assigneeType: String?
        if isForwardDestination {
            assigneeId = nil
            assigneeType = nil
        } else if let overlay {
            retained += [.init("taskStatus", overlay.taskStatus), .init("taskNumber", overlay.taskNumber),
                .init("taskAssigneeType", optional: overlay.taskAssigneeType), .init("taskAssigneeId", optional: overlay.taskAssigneeId),
                .init("taskClaimedAt", optional: overlay.taskClaimedAt), .init("taskCompletedAt", optional: overlay.taskCompletedAt)]
            assigneeId = overlay.taskAssigneeId; assigneeType = overlay.taskAssigneeType
        } else {
            // Upstream spreads the stored message row, so the six task-domain
            // columns are always present; an ordinary row publishes them as
            // JSON null. This mirrors the create ack and `message:new`.
            retained += [
                .init("taskStatus", optional: row.taskStatus),
                .init("taskNumber", optional: row.taskNumber),
                .init("taskAssigneeType", optional: row.taskAssigneeType),
                .init("taskAssigneeId", optional: row.taskAssigneeId),
                .init("taskClaimedAt", optional: row.taskClaimedAt),
                .init("taskCompletedAt", optional: row.taskCompletedAt),
            ]
            assigneeId = row.taskAssigneeId; assigneeType = row.taskAssigneeType
        }
        if !isForwardDestination,
           overlay != nil || row.taskStatus != nil || row.taskNumber != nil || assigneeId != nil {
            let name = assigneeId.flatMap { id in assigneeType.flatMap { actor(id: id, type: $0).handle } }
            retained.append(.init("taskAssigneeName", optional: name))
        }
        let mentions = state.storedMentions.filter {
            $0.messageId == row.id && ($0.notifiableAtSend || $0.notifiedAt != nil)
        }.map { InboxMentionDTO(type: $0.targetType, id: $0.targetId, name: $0.handle) }
        return MessageReadFactsDTO(id: row.id, channelId: channelId, seq: row.seq,
            senderId: row.senderId, senderType: row.senderType, senderName: identity.display, senderHandle: identity.handle,
            senderDisplayName: identity.display, senderDescription: identity.description, senderAvatarUrl: identity.avatar,
            senderMembershipStatus: membership, messageType: row.messageType, content: row.content,
            createdAt: DateText.isoString(row.createdAt), randomId: row.randomId, threadId: threadId,
            conversationContext: conversation, attachments: attachmentChips(row, commentsVisible: commentsVisible, state: state),
            reactions: .array(reactions(messageId: row.id).map(\.jsonBody)), mentions: mentions,
            taskCurrentProjection: overlay?.taskCurrentProjection, retained: retained)
    }

    private struct ReadableChildThread {
        let id: String
        let parentId: String
        let storageId: String
    }

    /// Both anchors and summaries require child authority before resolving any
    /// canonical storage identity. A readable parent never grants an inactive,
    /// foreign or privately inaccessible child scope.
    private func readableChildThreads(parentChannelId: String, parentIds: Set<String>,
        serverId: String?, userId: String?, channelState: ServersAndChannelsStore.State) -> [ReadableChildThread] {
        let access = HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: agents)
        guard let userId, let scope = try? access.requireServerScope(serverId: serverId, userId: userId),
              access.authority(channelId: parentChannelId, serverId: scope.serverId, userId: userId) != nil else { return [] }
        return channelState.postableChannels.compactMap { id, channel -> ReadableChildThread? in
            guard channel.serverId == scope.serverId, channel.kind == "thread", channel.deletedAt == nil,
                  channel.parentChannelId == parentChannelId, let parent = channel.parentMessageId, parentIds.contains(parent),
                  access.authority(channelId: id, serverId: scope.serverId, userId: userId, origin: .localChannel) != nil
            else { return nil }
            let links = channelState.jointProjections.filter { $0.localChannelId == id }
            if !links.isEmpty {
                let active = links.filter { $0.serverId == scope.serverId && $0.status == "active" }
                guard active.count == 1, let link = active.first else { return nil }
                return ReadableChildThread(id: id, parentId: parent, storageId: link.canonicalChannelId)
            }
            return ReadableChildThread(id: id, parentId: parent, storageId: id)
        }.sorted { $0.id < $1.id }
    }

    func localChannel(canonical: String, serverId: String?, userId: String) -> String? {
        MessageChannelFacts(channels.state).localChannel(canonical: canonical, serverId: serverId, userId: userId)
    }

    func reactions(messageId: String) -> [ProfileReactionBucket] {
        let rows = messages.reactionRows(messageId: messageId)
        let accounts = profiles.accounts
        let legacyAgents = agents.serverAgents
        var order: [String] = []
        var buckets: [String: ProfileReactionBucket] = [:]
        for row in rows {
            let name: String
            if row.reactorType == "agent" {
                if let runtime = oauth.agentRuntimeInfo(id: row.reactorId) {
                    name = runtime.displayName.isEmpty ? runtime.name : runtime.displayName
                } else { name = legacyAgents[row.reactorId]?.name ?? "Unknown agent" }
            } else {
                name = accounts.values.first { $0.id == row.reactorId }.map { $0.displayName ?? $0.name } ?? "Unknown user"
            }
            if buckets[row.emoji] == nil {
                order.append(row.emoji)
                buckets[row.emoji] = ProfileReactionBucket(emoji: row.emoji, reactorIds: [], reactorNames: [])
            }
            buckets[row.emoji]?.reactorIds.append(row.reactorId)
            buckets[row.emoji]?.reactorNames.append(name)
        }
        return order.compactMap { buckets[$0] }
    }

    func forward(messageId: String, userId: String, serverId: String?) -> OrderedJSON? {
        guard let record = messages.forwardRecord(messageId: messageId) else { return nil }
        let facts = MessageChannelFacts(channels.state)
        return .object([
            .init("kind", "forwarded-bundle"),
            .init("forwardedItems", .array(record.items.map {
                .raw(facts.canReadForward($0, userId: userId, serverId: serverId)
                    ? MessageForwardProjection.forwardItemJSON($0)
                    : MessageForwardProjection.scrubbedForwardItemJSON($0))
            })),
        ])
    }

    func threadSummaries(parentChannelId: String, parentIds: [String], userId: String?, serverId: String?) -> OrderedJSON {
        let channelState = channels.state
        let messageState = messages.state
        let threads = readableChildThreads(parentChannelId: parentChannelId, parentIds: Set(parentIds),
            serverId: serverId, userId: userId, channelState: channelState)
        return .object(threads.map { thread in
            let replies = messageState.humanMessageRows.filter { $0.channelId == thread.id || $0.channelId == thread.storageId }
                .sorted { $0.seq < $1.seq }
            let conversation = replies.filter { $0.messageType != "system" }
            let latest = conversation.suffix(3).map { row -> OrderedJSON in
                let identity = actor(id: row.senderId, type: row.senderType, externalName: row.externalSenderName)
                var fields: [OrderedJSONField] = [
                    .init("messageId", row.id), .init("seq", row.seq), .init("preview", row.content),
                    .init("senderId", row.senderId), .init("senderType", row.senderType),
                    .init("senderAvatarUrl", optional: identity.avatar), .init("createdAt", DateText.isoString(row.createdAt)),
                ]
                if let name = identity.handle { fields.append(.init("senderName", name)) }
                if let display = identity.display { fields.append(.init("senderDisplayName", display)) }
                return .object(fields)
            }
            var participantIds: [String] = []
            for row in conversation where !participantIds.contains(row.senderId) { participantIds.append(row.senderId) }
            var fields: [OrderedJSONField] = [
                .init("replyCount", replies.count), .init("latestReplies", .array(latest)),
                .init("threadChannelId", thread.id), .init("lastReplyAt", optional: replies.last.map { DateText.isoString($0.createdAt) }),
                .init("participantIds", .array(participantIds.map(OrderedJSON.string))),
            ]
            if let userId, let serverId {
                let followed = messageState.threadFollows["\(serverId)\n\(userId)\n\(thread.id)"] != nil
                let active = followed && !messageState.inboxDoneScopes.contains("\(userId)\n\(thread.id)")
                let cursor = oauth.channelUnreadInfo(channelId: thread.id, userId: userId).maxReadSeq
                let unread = active ? replies.filter { $0.seq > cursor } : []
                fields += [.init("unreadCount", unread.count), .init("firstUnreadMessageId", optional: unread.first?.id),
                           .init("followed", followed)]
            }
            return OrderedJSONField(thread.parentId, OrderedJSON.object(fields))
        })
    }

    func commentsEnabled(serverId: String, userId: String? = nil) -> Bool {
        agents.evaluateFeatureFlag(key: "attachment_comments_v0", userId: userId ?? "", serverId: serverId,
            platform: nil, client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)).enabled
    }

    /// Compatibility bridge for the reaction ACK's existing ordered-ID input.
    /// The caller supplies its authorized retained message's IDs; only a unique
    /// real host binding can enrich them. Ambiguous references stay opaque.
    func attachments(_ ids: [String], commentsVisible: Bool) -> [InboxAttachmentChipDTO] {
        guard !ids.isEmpty else { return [] }
        let state = messages.state
        let hosts = state.humanMessageRows.filter { $0.attachmentIds == ids }
        guard hosts.count == 1, let host = hosts.first else {
            return ids.map { InboxAttachmentChipDTO(id: $0, commentCount: 0) }
        }
        return attachmentChips(host, commentsVisible: commentsVisible, state: state)
    }

    /// The retained message ID order remains stable. Real linked rows missing
    /// from legacy message ID arrays are appended in persisted link order; their
    /// upload channel is irrelevant once the actual host message owns the link.
    private func attachmentChips(_ message: StoredHumanMessage, commentsVisible: Bool,
                                 state: MessagesAndThreadsStore.State) -> [InboxAttachmentChipDTO] {
        messages.orderedAttachmentRows(for: message).map { entry in
            let row = entry.row?.messageId == message.id ? entry.row : nil
            return InboxAttachmentChipDTO(id: entry.id,
                commentCount: commentsVisible ? (state.attachmentCommentRecords[entry.id]?.filter { $0.hostMessageId == message.id }.count ?? 0) : 0,
                filename: row?.filename,
                mimeType: row.map { ChannelFileRules.resolveAttachmentMimeType(filename: $0.filename, stored: $0.mimeType) },
                sizeBytes: row?.sizeBytes,
                width: row?.width, height: row?.height)
        }
    }

    func comment(messageId: String) -> InboxCommentRefDTO? {
        messages.commentRef(messageId: messageId).map { record in
            let attachment = messages.channelAttachments[record.attachmentId]
            let filename = attachment?.messageId == record.hostMessageId ? attachment?.filename : nil
            return InboxCommentRefDTO(attachmentId: record.attachmentId, hostMessageId: record.hostMessageId,
                hostSource: InboxCommentSourceDTO(channelId: record.hostChannelId, rootThreadChannelId: record.threadChannelId),
                filename: filename)
        }
    }
}
