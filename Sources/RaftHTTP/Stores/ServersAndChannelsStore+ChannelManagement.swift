import Foundation

// MARK: - Channel archive, membership and agent channel management

extension ServersAndChannelsStore {
    /// The two facts the archive route reads before it decides: whether the
    /// caller is a channel admin and whether the channel is a joint projection.
    func archivePolicy(channelId: String, userId: String) -> (channelAdmin: Bool, jointArchive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            storage.channelHumanRoles["\(channelId)\n\(userId)"] == "admin",
            storage.jointProjections.contains { $0.localChannelId == channelId }
        )
    }

    /// Marks one channel and every thread under it archived (or not) in one
    /// critical section.
    func setArchived(channelId: String, archived: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.archived = archived
        for (id, var postable) in storage.postableChannels where postable.parentChannelId == channelId {
            postable.archived = archived
            storage.postableChannels[id] = postable
        }
    }

    /// The archive flag of exactly one projection (no thread cascade).
    func setArchivedFlag(channelId: String, archived: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.archived = archived
    }

    func setPostableName(channelId: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.name = name
    }

    /// The final name/kind write of a channel update.
    func updatePostable(channelId: String, name: String, kind: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.name = name
        storage.postableChannels[channelId]?.kind = kind
    }

    func isGuestJoinable(channelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.guestJoinableChannels[channelId] ?? false
    }

    /// The local channel ids that share the joint canonical channel of
    /// `channelId` (empty for a non-joint channel), from one snapshot.
    func jointLinkIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let canonical = storage.jointProjections
            .first(where: { $0.localChannelId == channelId })?.canonicalChannelId
        else { return [] }
        return storage.jointProjections.filter { $0.canonicalChannelId == canonical }.map(\.localChannelId)
    }

    /// Removes one agent from the posting set and answers the channel kind, in
    /// one critical section.
    func removeAgentMember(channelId: String, agentId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.memberIds.remove(agentId)
        return storage.postableChannels[channelId]?.kind ?? "channel"
    }

    func markChannelDeleted(channelId: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.deletedAt = now
    }

    func removeMember(channelId: String, memberId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.memberIds.remove(memberId)
    }

    /// Adds one human to the posting set, creating the row when the channel has
    /// none.
    func insertMember(channelId: String, serverId: String, userId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId, default: PostableChannel(serverId: serverId, memberIds: [])]
            .memberIds.insert(userId)
    }

    /// Replaces the posting row of a freshly created channel.
    func insertCreatedChannel(channelId: String, serverId: String, kind: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId] = PostableChannel(
            serverId: serverId, memberIds: [], kind: kind, name: name
        )
    }
}

// MARK: - Managed MCP lifecycle: channel and joint-invite sections

/// One joint invite row, copied out of the ledger.
struct JointInviteSnapshot: Sendable, Equatable {
    let id: String
    let hostServerId: String
    let hostChannelId: String
    let targetServerId: String
    let targetChannelId: String
    let targetOwnerId: String
    let status: String
}

/// What changing a channel's visibility left behind for the follow cleanup.
struct ChannelVisibilityChange: Sendable, Equatable {
    /// The posting members at the moment the kind changed.
    let memberIds: Set<String>
    /// The thread channels whose parent is the changed channel.
    let threadChannelIds: Set<String>
}

/// Per-channel facts the channel list projects, from one snapshot.
struct ChannelListFacts: Sendable {
    let guestVisible: [String: Bool]
    let humanRoles: [String: String]
    let jointLocalChannelIds: Set<String>
}

extension ServersAndChannelsStore {
    /// One channel's human-access facts for a user: whether the posting set or
    /// the kind admits them, from one snapshot.
    func postableMembership(channelId: String, userId: String) -> (isMember: Bool, kind: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = storage.postableChannels[channelId] else { return nil }
        return (channel.memberIds.contains(userId), channel.kind)
    }

    /// Whether the posting row lists `userId` as a member.
    func isPostableMember(channelId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels[channelId]?.memberIds.contains(userId) == true
    }

    /// The facts `GET /api/channels` projects for every row, read once.
    func channelListFacts() -> ChannelListFacts {
        lock.lock()
        defer { lock.unlock() }
        return ChannelListFacts(
            guestVisible: storage.guestVisibleChannels,
            humanRoles: storage.channelHumanRoles,
            jointLocalChannelIds: Set(storage.jointProjections.map(\.localChannelId))
        )
    }

    /// One invite by id.
    func jointInvite(id: String) -> JointInviteSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storage.jointInvites.first { $0.id == id }.map {
            JointInviteSnapshot(
                id: $0.id, hostServerId: $0.hostServerId, hostChannelId: $0.hostChannelId,
                targetServerId: $0.targetServerId, targetChannelId: $0.targetChannelId,
                targetOwnerId: $0.targetOwnerId, status: $0.status
            )
        }
    }

    /// Accepts the invite and admits `userId` to the target channel's posting
    /// set in one critical section; answers the channel name (empty when the
    /// posting row is missing).
    func acceptJointInvite(id: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.jointInvites.firstIndex(where: { $0.id == id }) else { return nil }
        let targetChannelId = storage.jointInvites[index].targetChannelId
        storage.jointInvites[index].status = "accepted"
        storage.postableChannels[targetChannelId]?.memberIds.insert(userId)
        return storage.postableChannels[targetChannelId]?.name ?? ""
    }

    /// Creates the two posting rows, the two joint projections and the pending
    /// invite of a joint channel in one critical section.
    func createJointChannelPair(
        hostServerId: String,
        hostChannelId: String,
        hostUserId: String,
        targetServerId: String,
        targetChannelId: String,
        targetOwnerId: String,
        name: String,
        inviteId: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        storage.jointProjections.append(JointChannelLink(
            localChannelId: hostChannelId, canonicalChannelId: hostChannelId, serverId: hostServerId
        ))
        storage.jointProjections.append(JointChannelLink(
            localChannelId: targetChannelId, canonicalChannelId: hostChannelId, serverId: targetServerId
        ))
        storage.postableChannels[hostChannelId] = PostableChannel(
            serverId: hostServerId, memberIds: [hostUserId], kind: "joint", name: name
        )
        storage.postableChannels[targetChannelId] = PostableChannel(
            serverId: targetServerId, memberIds: [], kind: "joint", name: name
        )
        storage.jointInvites.append((
            inviteId, hostServerId, hostChannelId, targetServerId, targetChannelId, targetOwnerId, "pending"
        ))
    }

    /// An existing live public/private channel of the same name, and whether
    /// `userId` could unarchive it (it is archived and they administer it).
    func channelNameCollision(serverId: String, name: String, userId: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let collision = storage.postableChannels.first { _, channel in
            channel.serverId == serverId && channel.name == name && channel.deletedAt == nil
                && (channel.kind == "channel" || channel.kind == "private")
        }
        guard let collision else { return nil }
        return (collision.value.archived
            && storage.channelHumanRoles["\(collision.key)\n\(userId)"] == "admin")
    }

    /// Records a freshly created public channel with its creator as member.
    func insertOwnedChannel(channelId: String, serverId: String, userId: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId] = PostableChannel(
            serverId: serverId, memberIds: [userId], name: name
        )
    }

    /// Sets the guest visibility/joinability flags that were supplied and
    /// answers both current values, in one critical section.
    func applyGuestFlags(
        channelId: String,
        visible: Bool?,
        joinable: Bool?
    ) -> (visible: Bool, joinable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let visible { storage.guestVisibleChannels[channelId] = visible }
        if let joinable { storage.guestJoinableChannels[channelId] = joinable }
        return (storage.guestVisibleChannels[channelId] ?? false, storage.guestJoinableChannels[channelId] ?? false)
    }

    /// Sets the posting kind and answers the members and child threads the
    /// follow cleanup needs, in one critical section.
    func applyChannelVisibility(channelId: String, kind: String) -> ChannelVisibilityChange {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.kind = kind
        let members = storage.postableChannels[channelId]?.memberIds ?? []
        let threads = Set(storage.postableChannels.filter {
            $0.value.kind == "thread" && $0.value.parentChannelId == channelId
        }.keys)
        return ChannelVisibilityChange(memberIds: members, threadChannelIds: threads)
    }

    /// The posting row's kind, when present.
    func postableKind(channelId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels[channelId]?.kind
    }

    /// Thread parent facts for the unread summary, from one snapshot.
    func threadParentSnapshot(channelId: String) -> (kind: String, parentChannelId: String?, parentMessageId: String?, parentDeleted: Bool?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = storage.postableChannels[channelId] else { return nil }
        let parentDeleted: Bool? = channel.parentChannelId.flatMap { parentId in
            storage.postableChannels[parentId].map { $0.deletedAt != nil }
        }
        return (channel.kind, channel.parentChannelId, channel.parentMessageId, parentDeleted)
    }

    /// The posting rows, joint projections and hidden-human flags the agent
    /// channel-membership read consults, from one snapshot.
    func postableAndJointSnapshot() -> (postable: [String: PostableChannel], joint: [JointChannelLink], hideHumans: [String: Bool]) {
        lock.lock()
        defer { lock.unlock() }
        return (storage.postableChannels, storage.jointProjections, storage.hideHumansFromMembers)
    }
}

// MARK: - Human message create: channel membership grant

extension ServersAndChannelsStore {
    /// A claimed `add` mention action makes a human target a channel member.
    func addChannelMember(channelId: String, userId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.memberIds.insert(userId)
    }
}
