import Foundation

// MARK: - Channel archive, membership and agent channel management

extension ServersAndChannelsStore {
    /// The two facts the archive route reads before it decides: whether the
    /// caller is a channel admin and whether the channel is a joint projection.
    func archivePolicy(channelId: String, userId: String) -> (channelAdmin: Bool, jointArchive: Bool) {
        mutex.withLock { storage in
            return (
                storage.channelHumanRoles["\(channelId)\n\(userId)"] == "admin",
                storage.jointProjections.contains { $0.localChannelId == channelId }
            )
        }
    }

    /// Marks one channel and every thread under it archived (or not) in one
    /// critical section.
    func setArchived(channelId: String, archived: Bool) {
        mutex.withLock { storage in
            storage.postableChannels[channelId]?.archived = archived
            for (id, var postable) in storage.postableChannels where postable.parentChannelId == channelId {
                postable.archived = archived
                storage.postableChannels[id] = postable
            }
        }
    }

    /// The archive flag of exactly one projection (no thread cascade).
    func setArchivedFlag(channelId: String, archived: Bool) {
        mutex.withLock { storage in
            storage.postableChannels[channelId]?.archived = archived
        }
    }

    func setPostableName(channelId: String, name: String) {
        mutex.withLock { storage in
            storage.postableChannels[channelId]?.name = name
        }
    }

    /// The final name/kind write of a channel update.
    func updatePostable(channelId: String, name: String, kind: String) {
        mutex.withLock { storage in
            storage.postableChannels[channelId]?.name = name
            storage.postableChannels[channelId]?.kind = kind
        }
    }

    func isGuestJoinable(channelId: String) -> Bool {
        mutex.withLock { storage in
            return storage.guestJoinableChannels[channelId] ?? false
        }
    }

    /// The local channel ids that share the joint canonical channel of
    /// `channelId` (empty for a non-joint channel), from one snapshot.
    func jointLinkIds(channelId: String) -> [String] {
        mutex.withLock { storage in
            guard let canonical = storage.jointProjections
                .first(where: { $0.localChannelId == channelId })?.canonicalChannelId
            else { return [] }
            return storage.jointProjections.filter { $0.canonicalChannelId == canonical }.map(\.localChannelId)
        }
    }

    /// Removes one agent from the posting set and answers the channel kind, in
    /// one critical section.
    func removeAgentMember(channelId: String, agentId: String) -> String {
        mutex.withLock { storage in
            storage.postableChannels[channelId]?.memberIds.remove(agentId)
            return storage.postableChannels[channelId]?.kind ?? "channel"
        }
    }

    func markChannelDeleted(channelId: String, now: Date) {
        mutex.withLock { storage in
            storage.postableChannels[channelId]?.deletedAt = now
        }
    }

    func removeMember(channelId: String, memberId: String) {
        _ = mutex.withLock { storage in
            storage.postableChannels[channelId]?.memberIds.remove(memberId)
        }
    }

    /// Adds one human to the posting set, creating the row when the channel has
    /// none.
    func insertMember(channelId: String, serverId: String, userId: String) {
        _ = mutex.withLock { storage in
            storage.postableChannels[channelId, default: PostableChannel(serverId: serverId, memberIds: [])]
                .memberIds.insert(userId)
        }
    }

    /// Replaces the posting row of a freshly created channel.
    func insertCreatedChannel(channelId: String, serverId: String, kind: String, name: String) {
        mutex.withLock { storage in
            storage.postableChannels[channelId] = PostableChannel(
                serverId: serverId, memberIds: [], kind: kind, name: name
            )
        }
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
    let invitedByUserId: String
    let createdAt: Date
    let expiresAt: Date
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
        mutex.withLock { storage in
            guard let channel = storage.postableChannels[channelId] else { return nil }
            return (channel.memberIds.contains(userId), channel.kind)
        }
    }

    /// Whether the posting row lists `userId` as a member.
    func isPostableMember(channelId: String, userId: String) -> Bool {
        mutex.withLock { storage in
            return storage.postableChannels[channelId]?.memberIds.contains(userId) == true
        }
    }

    /// The facts `GET /api/channels` projects for every row, read once.
    func channelListFacts() -> ChannelListFacts {
        mutex.withLock { storage in
            return ChannelListFacts(
                guestVisible: storage.guestVisibleChannels,
                humanRoles: storage.channelHumanRoles,
                jointLocalChannelIds: Set(storage.jointProjections.map(\.localChannelId))
            )
        }
    }

    /// One invite by id.
    func jointInvite(id: String) -> JointInviteSnapshot? {
        mutex.withLock { storage in
            return storage.jointInvites.first { $0.id == id }.map {
                JointInviteSnapshot(
                    id: $0.id, hostServerId: $0.hostServerId, hostChannelId: $0.hostChannelId,
                    targetServerId: $0.targetServerId, targetChannelId: $0.targetChannelId,
                    targetOwnerId: $0.targetOwnerId, invitedByUserId: $0.invitedByUserId,
                    createdAt: $0.createdAt, expiresAt: $0.expiresAt, status: $0.status
                )
            }
        }
    }

    /// Pending, unexpired invites addressed to one person on one server.
    func pendingJointInvites(serverId: String, userId: String, now: Date) -> [JointInviteSnapshot] {
        mutex.withLock { storage in
            return storage.jointInvites
                .filter {
                    $0.targetServerId == serverId && $0.targetOwnerId == userId
                        && $0.status == "pending" && $0.expiresAt > now
                }
                .sorted { $0.createdAt > $1.createdAt }
                .map {
                    JointInviteSnapshot(
                        id: $0.id, hostServerId: $0.hostServerId, hostChannelId: $0.hostChannelId,
                        targetServerId: $0.targetServerId, targetChannelId: $0.targetChannelId,
                        targetOwnerId: $0.targetOwnerId, invitedByUserId: $0.invitedByUserId,
                        createdAt: $0.createdAt, expiresAt: $0.expiresAt, status: $0.status
                    )
                }
        }
    }

    /// Refreshes every pending invite hosted by one projection and answers how
    /// many rows moved. A joint with no pending invite is distinguished from a
    /// missing projection by the caller's earlier read.
    func resendJointInvites(
        hostChannelId: String,
        hostServerId: String,
        requestedByUserId: String,
        now: Date,
        ttl: TimeInterval
    ) -> Int {
        mutex.withLock { storage in
            var count = 0
            for index in storage.jointInvites.indices {
                guard storage.jointInvites[index].hostChannelId == hostChannelId,
                      storage.jointInvites[index].hostServerId == hostServerId,
                      storage.jointInvites[index].status == "pending"
                else { continue }
                storage.jointInvites[index].invitedByUserId = requestedByUserId
                storage.jointInvites[index].createdAt = now
                storage.jointInvites[index].expiresAt = now.addingTimeInterval(ttl)
                count += 1
            }
            return count
        }
    }

    /// Adds one target-server projection and its pending invites to an existing
    /// joint channel in one critical section.
    func addJointServerProjection(
        hostChannelId: String,
        hostServerId: String,
        targetServerId: String,
        targetChannelId: String,
        invitedByUserId: String,
        name: String,
        invites: [(inviteId: String, userId: String)],
        now: Date,
        ttl: TimeInterval
    ) {
        mutex.withLock { storage in
            let canonical = storage.jointProjections
                .first { $0.localChannelId == hostChannelId }?.canonicalChannelId ?? hostChannelId
            storage.jointProjections.append(JointChannelLink(
                localChannelId: targetChannelId,
                canonicalChannelId: canonical,
                serverId: targetServerId
            ))
            storage.postableChannels[targetChannelId] = PostableChannel(
                serverId: targetServerId, memberIds: [], kind: "joint", name: name
            )
            for invite in invites {
                storage.jointInvites.append((
                    invite.inviteId, hostServerId, hostChannelId, targetServerId, targetChannelId,
                    invite.userId, invitedByUserId, now, now.addingTimeInterval(ttl), "pending"
                ))
            }
        }
    }

    /// Adds pending invite rows for an already-projected target server.
    func addJointInvites(
        hostChannelId: String,
        hostServerId: String,
        targetServerId: String,
        targetChannelId: String,
        invitedByUserId: String,
        invites: [(inviteId: String, userId: String)],
        now: Date,
        ttl: TimeInterval
    ) {
        mutex.withLock { storage in
            for invite in invites {
                storage.jointInvites.append((
                    invite.inviteId, hostServerId, hostChannelId, targetServerId, targetChannelId,
                    invite.userId, invitedByUserId, now, now.addingTimeInterval(ttl), "pending"
                ))
            }
        }
    }

    /// Drops one server's projection and marks its local channel deleted.
    /// Answers false when the channel is not a joint projection.
    func disconnectJointProjection(channelId: String, now: Date) -> Bool {
        mutex.withLock { storage in
            guard let index = storage.jointProjections.firstIndex(where: { $0.localChannelId == channelId })
            else { return false }
            storage.jointProjections.remove(at: index)
            storage.postableChannels[channelId]?.deletedAt = now
            return true
        }
    }

    /// The local channel a server already projects for `channelId`'s joint.
    func jointLocalChannel(channelId: String, serverId: String) -> String? {
        mutex.withLock { storage in
            guard let canonical = storage.jointProjections
                .first(where: { $0.localChannelId == channelId })?.canonicalChannelId
            else { return nil }
            return storage.jointProjections.first {
                $0.canonicalChannelId == canonical && $0.serverId == serverId
            }?.localChannelId
        }
    }

    /// The canonical row of `channelId`'s joint projection, if any.
    func jointCanonicalChannelId(channelId: String) -> String? {
        mutex.withLock { storage in
            storage.jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
        }
    }

    /// Accepts the invite and admits `userId` to the target channel's posting
    /// set in one critical section; answers the channel name (empty when the
    /// posting row is missing).
    func acceptJointInvite(id: String, userId: String) -> String? {
        mutex.withLock { storage in
            guard let index = storage.jointInvites.firstIndex(where: { $0.id == id }) else { return nil }
            let targetChannelId = storage.jointInvites[index].targetChannelId
            storage.jointInvites[index].status = "accepted"
            storage.postableChannels[targetChannelId]?.memberIds.insert(userId)
            return storage.postableChannels[targetChannelId]?.name ?? ""
        }
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
        inviteId: String,
        now: Date = Date(),
        ttl: TimeInterval = 14 * 24 * 60 * 60
    ) {
        mutex.withLock { storage in
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
                inviteId, hostServerId, hostChannelId, targetServerId, targetChannelId,
                targetOwnerId, hostUserId, now, now.addingTimeInterval(ttl), "pending"
            ))
        }
    }

    /// An existing live public/private channel of the same name, and whether
    /// `userId` could unarchive it (it is archived and they administer it).
    func channelNameCollision(serverId: String, name: String, userId: String) -> Bool? {
        mutex.withLock { storage in
            let collision = storage.postableChannels.first { _, channel in
                channel.serverId == serverId && channel.name == name && channel.deletedAt == nil
                    && (channel.kind == "channel" || channel.kind == "private")
            }
            guard let collision else { return nil }
            return (collision.value.archived
                && storage.channelHumanRoles["\(collision.key)\n\(userId)"] == "admin")
        }
    }

    /// Records the requested visibility and complete initial membership together.
    func insertOwnedChannel(
        channelId: String, serverId: String, userId: String, name: String,
        kind: String = "channel", userIds: Set<String> = [], agentIds: Set<String> = []
    ) {
        mutex.withLock { storage in
            storage.postableChannels[channelId] = PostableChannel(
                serverId: serverId, memberIds: userIds.union(agentIds).union([userId]), kind: kind, name: name
            )
            storage.channelHumanRoles["\(channelId)\n\(userId)"] = "admin"
            storage.guestVisibleChannels[channelId] = false
            storage.guestJoinableChannels[channelId] = false
        }
    }

    /// Sets the guest visibility/joinability flags that were supplied and
    /// answers both current values, in one critical section.
    func applyGuestFlags(
        channelId: String,
        visible: Bool?,
        joinable: Bool?
    ) -> (visible: Bool, joinable: Bool) {
        mutex.withLock { storage in
            if let visible { storage.guestVisibleChannels[channelId] = visible }
            if let joinable { storage.guestJoinableChannels[channelId] = joinable }
            return (storage.guestVisibleChannels[channelId] ?? false, storage.guestJoinableChannels[channelId] ?? false)
        }
    }

    /// Sets the posting kind and answers the members and child threads the
    /// follow cleanup needs, in one critical section.
    func applyChannelVisibility(channelId: String, kind: String) -> ChannelVisibilityChange {
        mutex.withLock { storage in
            storage.postableChannels[channelId]?.kind = kind
            let members = storage.postableChannels[channelId]?.memberIds ?? []
            let threads = Set(storage.postableChannels.filter {
                $0.value.kind == "thread" && $0.value.parentChannelId == channelId
            }.keys)
            return ChannelVisibilityChange(memberIds: members, threadChannelIds: threads)
        }
    }

    /// The posting row's kind, when present.
    func postableKind(channelId: String) -> String? {
        mutex.withLock { storage in
            return storage.postableChannels[channelId]?.kind
        }
    }

    /// Thread parent facts for the unread summary, from one snapshot.
    func threadParentSnapshot(channelId: String) -> (kind: String, parentChannelId: String?, parentMessageId: String?, parentDeleted: Bool?)? {
        mutex.withLock { storage in
            guard let channel = storage.postableChannels[channelId] else { return nil }
            let parentDeleted: Bool? = channel.parentChannelId.flatMap { parentId in
                storage.postableChannels[parentId].map { $0.deletedAt != nil }
            }
            return (channel.kind, channel.parentChannelId, channel.parentMessageId, parentDeleted)
        }
    }

    /// The posting rows, joint projections and hidden-human flags the agent
    /// channel-membership read consults, from one snapshot.
    func postableAndJointSnapshot() -> (postable: [String: PostableChannel], joint: [JointChannelLink], hideHumans: [String: Bool]) {
        mutex.withLock { storage in
            return (storage.postableChannels, storage.jointProjections, storage.hideHumansFromMembers)
        }
    }
}

// MARK: - Human message create: channel membership grant

extension ServersAndChannelsStore {
    /// A claimed `add` mention action makes a human target a channel member.
    func addChannelMember(channelId: String, userId: String) {
        _ = mutex.withLock { storage in
            storage.postableChannels[channelId]?.memberIds.insert(userId)
        }
    }
}
