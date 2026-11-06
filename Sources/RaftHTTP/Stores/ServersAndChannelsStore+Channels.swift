import Foundation

extension ServersAndChannelsStore {
    /// The soft-delete decision and write are one critical section.
    ///
    /// `DELETE /api/channels/:channelId` used to read the row, check the role
    /// and write `deletedAt` under the directory lock. `memberRole` is fetched
    /// by the service before this call because it lives in the OAuth ledger,
    /// not in this store; everything that depends on the channel row stays in
    /// this one locked value.
    func softDeleteChannel(
        channelId: String,
        serverId: String?,
        userId: String,
        memberRole: String?,
        now: Date
    ) -> SoftDeleteChannelOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var channel = storage.postableChannels[channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return .notFound }
        if let memberRole {
            guard memberRole == "owner" || memberRole == "admin" else { return .forbidden }
        } else if !channel.memberIds.contains(userId) {
            return .forbidden
        }
        channel.deletedAt = now
        storage.postableChannels[channelId] = channel
        return .deleted
    }

    /// Records a channel the owner can post in. Resource-reference checks run
    /// only after this membership is visible.
    func addPostableChannel(
        serverId: String,
        channelId: String,
        memberId: String,
        kind: String = "channel",
        parentChannelId: String? = nil,
        parentMessageId: String? = nil,
        name: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        var channel = storage.postableChannels[channelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        if channel.kind == "channel" || kind != "channel" {
            channel.kind = kind
        }
        if let parentChannelId {
            channel.parentChannelId = parentChannelId
        }
        if let parentMessageId {
            channel.parentMessageId = parentMessageId
        }
        if let name {
            channel.name = name
        }
        storage.postableChannels[channelId] = channel
    }

    /// Links a server's local joint channel to the canonical channel that
    /// stores the messages.
    func addJointChannelProjection(localChannelId: String, canonicalChannelId: String, serverId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.jointProjections.append(JointChannelLink(
            localChannelId: localChannelId,
            canonicalChannelId: canonicalChannelId,
            serverId: serverId
        ))
    }

    /// A thread whose messages hang off one parent message. Context short links
    /// on the parent channel can land here.
    func addThreadChannel(
        serverId: String,
        threadChannelId: String,
        parentChannelId: String,
        parentMessageId: String,
        memberId: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        var channel = storage.postableChannels[threadChannelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        channel.kind = "thread"
        channel.parentChannelId = parentChannelId
        channel.parentMessageId = parentMessageId
        storage.postableChannels[threadChannelId] = channel
    }

    /// A user-to-user DM. Only the two participants may be notified by a
    /// mention.
    func addDirectMessage(serverId: String, channelId: String, participantIds: [String], agentId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId] = PostableChannel(
            serverId: serverId,
            memberIds: Set(participantIds),
            kind: "dm",
            agentId: agentId
        )
    }


    // MARK: - Channel member set, channel roles and thread rows (managed-MCP assignments)
    //
    // Each method below is one critical section over the rows it reads and
    // rewrites. The retired handlers held the directory lock for the same span.

    /// Drops one member id from a channel's postable member set.
    func removePostableMember(channelId: String, memberId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.memberIds.remove(memberId)
    }

    /// Adds one member id to a channel's postable member set, creating the row
    /// (kind `channel`) when the channel has none yet.
    func insertPostableMember(serverId: String, channelId: String, memberId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId, default: PostableChannel(serverId: serverId, memberIds: [])]
            .memberIds.insert(memberId)
    }

    /// The channel-local role (`admin`) one human holds, when any.
    func channelHumanRole(channelId: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.channelHumanRoles["\(channelId)\n\(userId)"]
    }

    /// The channel authority revision; a channel that never changed authority
    /// reports `1`.
    func channelAuthorityRevision(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.channelAuthorityRevisions[channelId] ?? 1
    }

    /// Writes one channel-local role and bumps the channel authority revision
    /// in the same critical section; returns the new revision.
    func setChannelHumanRole(channelId: String, memberId: String, role: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.channelHumanRoles["\(channelId)\n\(memberId)"] = role
        let revision = (storage.channelAuthorityRevisions[channelId] ?? 1) + 1
        storage.channelAuthorityRevisions[channelId] = revision
        return revision
    }

    enum ThreadForParentMessage {
        /// A live thread already hangs off the parent message.
        case existing(id: String)
        /// A new thread row was created and ordered.
        case created(id: String)
    }

    /// `POST /api/channels/:id/threads`: the existing-thread lookup, the new
    /// thread's channel row and its creation order are one critical section, so
    /// two concurrent requests for the same parent message cannot both create
    /// a thread. `createChannel` mints the ledger channel; it runs inside the
    /// section and must not call back into this store.
    func findOrCreateThread(
        serverId: String,
        parentChannelId: String,
        parentMessageId: String,
        creatorId: String,
        createChannel: () -> String
    ) -> ThreadForParentMessage {
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage.postableChannels.first(where: { _, candidate in
            candidate.serverId == serverId && candidate.kind == "thread"
                && candidate.parentChannelId == parentChannelId && candidate.parentMessageId == parentMessageId
                && candidate.deletedAt == nil
        }) {
            return .existing(id: existing.key)
        }
        let threadId = createChannel()
        storage.postableChannels[threadId] = PostableChannel(
            serverId: serverId,
            memberIds: [creatorId],
            kind: "thread",
            parentChannelId: parentChannelId,
            parentMessageId: parentMessageId,
            name: "thread"
        )
        storage.threadOrder.append(threadId)
        return .created(id: threadId)
    }

    /// The DM row `POST /api/channels/dm` records: kind `dm`, name `dm`.
    func upsertDirectChannel(serverId: String, channelId: String, memberIds: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId] = PostableChannel(
            serverId: serverId,
            memberIds: memberIds,
            kind: "dm",
            name: "dm"
        )
    }

    /// The migration receipt DM: one agent-only direct channel named
    /// `name` whose member set is exactly `memberId`, in one critical section.
    func directChannelId(name: String, memberId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels.first {
            $0.value.kind == "dm" && $0.value.name == name && $0.value.memberIds == [memberId]
        }?.key
    }

    /// The local channel an active joint projection of `canonicalChannelId`
    /// publishes inside `serverId`.
    func activeJointLocalChannelId(canonicalChannelId: String, serverId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.jointProjections.first {
            $0.canonicalChannelId == canonicalChannelId
                && $0.serverId == serverId
                && $0.status == "active"
        }?.localChannelId
    }
}

/// The decision `DELETE /api/channels/:channelId` makes while holding the
/// channel store lock. The channel row is written in the same critical
/// section as the decision.
enum SoftDeleteChannelOutcome: Sendable, Equatable {
    case deleted
    case notFound
    case forbidden
}
