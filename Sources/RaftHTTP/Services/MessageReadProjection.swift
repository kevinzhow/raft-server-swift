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

/// Read-side composition returns the existing ordered DTOs. Stores provide
/// atomic row snapshots; channel/OAuth authority is a separate explicit input.
struct MessageReadProjection: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let profiles: AuthProfileStore
    let agents: AgentsRuntimeStore
    let oauth: OAuthLedger

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

    func threadSummaries(parentChannelId: String, parentIds: [String]) -> OrderedJSON {
        let parents = Set(parentIds)
        let threads = channels.postableChannels.compactMap { id, channel -> (id: String, parentId: String)? in
            guard channel.kind == "thread", channel.deletedAt == nil, channel.parentChannelId == parentChannelId,
                  let parentId = channel.parentMessageId, parents.contains(parentId) else { return nil }
            return (id, parentId)
        }
        let rows = messages.threadProjectionRows(channelIds: Set(threads.map(\.id)))
        return .object(threads.map { id, parentId in
            let replies = rows.filter { $0.channelId == id }
            return OrderedJSONField(parentId, OrderedJSON.object([
                .init("replyCount", replies.count),
                .init("latestReplies", .array(replies.filter { $0.messageType != "system" }.suffix(3).map {
                    .object([.init("preview", $0.content)])
                })),
            ]))
        })
    }

    func commentsEnabled(serverId: String, userId: String? = nil) -> Bool {
        agents.evaluateFeatureFlag(key: "attachment_comments_v0", userId: userId ?? "", serverId: serverId,
            platform: nil, client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)).enabled
    }

    func attachments(_ ids: [String], commentsVisible: Bool) -> [InboxAttachmentChipDTO] {
        messages.attachmentCommentSummaries(ids: ids, commentsVisible: commentsVisible).map {
            InboxAttachmentChipDTO(id: $0.attachmentId, commentCount: $0.commentCount)
        }
    }

    func comment(messageId: String) -> InboxCommentRefDTO? {
        messages.commentRef(messageId: messageId).map {
            InboxCommentRefDTO(attachmentId: $0.attachmentId, hostMessageId: $0.hostMessageId,
                hostSource: InboxCommentSourceDTO(channelId: $0.hostChannelId, rootThreadChannelId: $0.threadChannelId))
        }
    }
}
