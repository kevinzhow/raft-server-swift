import Foundation

extension ServersAndChannelsStore {
    // MARK: - Socket room membership

    /// Read-only view the `sync:resume` visibility rules need: channels and the
    /// guest-visibility flags observed in the same critical section.
    struct ChannelReadSnapshot: Sendable {
        let channels: [String: PostableChannel]
        let guestVisibleChannels: [String: Bool]
    }

    /// Channel ids the guest gate currently marks visible.
    func guestVisibleChannelIds(_ channelIds: [String]) -> Set<String> {
        mutex.withLock { storage in
            return Set(channelIds.filter { storage.guestVisibleChannels[$0] == true })
        }
    }

    /// One locked snapshot for the viewer-filtered `sync:resume` replay.
    func channelReadSnapshot() -> ChannelReadSnapshot {
        mutex.withLock { storage in
            return ChannelReadSnapshot(
                channels: storage.postableChannels,
                guestVisibleChannels: storage.guestVisibleChannels
            )
        }
    }

    /// `channel:<id>` plus every child thread room, in one critical section.
    func channelRoomIds(channelId: String) -> [String] {
        mutex.withLock { storage in
            var rooms = ["channel:\(channelId)"]
            for (id, channel) in storage.postableChannels
            where channel.kind == "thread" && channel.parentChannelId == channelId {
                rooms.append("channel:\(id)")
            }
            return rooms
        }
    }

    /// Cascade of a departed server member over the channel rows this store
    /// owns: every channel loses the member, and thread keys hanging off a
    /// private/DM parent are returned in the same critical section for the
    /// thread-follow store to delete.
    struct MembershipRevocation: Sendable {
        let channelIds: [String]
        let threadKeys: [String]
    }

    func revokeMembership(serverId: String, userId: String) -> MembershipRevocation {
        mutex.withLock { storage in
            let channels = storage.postableChannels
            var channelIds: [String] = []
            var threadKeys: [String] = []
            for (id, channel) in channels where channel.serverId == serverId {
                channelIds.append(id)
                storage.postableChannels[id]?.memberIds.remove(userId)
                // Mirrors `removeMember`: only follows hanging off a private/DM
                // parent die with the server membership; public-parent follows
                // survive so the thread stays in Activity after a rejoin.
                guard channel.kind == "thread",
                      let parentId = channel.parentChannelId,
                      let parent = channels[parentId],
                      parent.kind == "private" || parent.kind == "dm"
                else { continue }
                threadKeys.append("\(serverId)\n\(userId)\n\(id)")
            }
            return MembershipRevocation(channelIds: channelIds, threadKeys: threadKeys)
        }
    }

    // MARK: - Action-card thread carriers

    /// The `dm` channel between one agent and one human, in one critical
    /// section. Dictionary order is the legacy first-match order.
    func actionCardDMChannel(agentId: String, peerId: String) -> String? {
        mutex.withLock { storage in
            return storage.postableChannels.first { _, channel in
                channel.kind == "dm"
                    && channel.memberIds.contains(agentId)
                    && channel.memberIds.contains(peerId)
            }?.key
        }
    }

    /// The thread under `parentChannelId` whose parent message is exactly
    /// `parentMessageId`, in one critical section.
    func actionCardThreadChannel(parentChannelId: String, parentMessageId: String) -> String? {
        mutex.withLock { storage in
            return storage.postableChannels.first { _, channel in
                channel.kind == "thread"
                    && channel.parentChannelId == parentChannelId
                    && channel.parentMessageId == parentMessageId
            }?.key
        }
    }

    /// Whether a live channel or private channel already uses `name` on the
    /// server, in one critical section.
    func isDuplicateActionCardChannelName(serverId: String, name: String) -> Bool {
        mutex.withLock { storage in
            return storage.postableChannels.values.contains {
                $0.serverId == serverId && $0.name == name && $0.deletedAt == nil
                    && ($0.kind == "channel" || $0.kind == "private")
            }
        }
    }

    /// Finds or creates the reply thread under `storageChannelId` for the
    /// action-card message, plus one projection thread per Joint link, all in
    /// one critical section.
    ///
    /// The fixed OAuth command creates the ledger channel while this store's
    /// lock is held, so concurrent executes cannot create two canonical threads
    /// for the same card. A missing carrier keeps the fallback server id.
    func findOrCreateActionCardReplyThread(
        storageChannelId: String,
        messageId: String,
        requesterAgentId: String,
        confirmerUserId: String,
        fallbackServerId: String,
        threadChannels: ThreadChannelCommand
    ) -> String? {
        mutex.withLock { storage in
            let storageServerId = storage.postableChannels[storageChannelId]?.serverId ?? fallbackServerId
            var canonicalThread = storage.postableChannels.first { _, channel in
                channel.kind == "thread"
                    && channel.parentChannelId == storageChannelId
                    && channel.parentMessageId == messageId
            }?.key
            if canonicalThread == nil {
                let threadId = threadChannels.createThreadChannel(
                    parentChannelId: storageChannelId, parentMessageId: messageId
                )
                var thread = storage.postableChannels[threadId]
                    ?? PostableChannel(serverId: storageServerId, memberIds: [])
                thread.serverId = storageServerId
                thread.kind = "thread"
                thread.parentChannelId = storageChannelId
                thread.parentMessageId = messageId
                thread.name = "thread"
                thread.memberIds.insert(requesterAgentId)
                thread.memberIds.insert(confirmerUserId)
                if let parentMembers = storage.postableChannels[storageChannelId]?.memberIds {
                    thread.memberIds.formUnion(parentMembers)
                }
                storage.postableChannels[threadId] = thread
                canonicalThread = threadId
            }
            guard let threadId = canonicalThread else { return nil }
            // Give each Joint projection its own thread row pointing at the
            // canonical thread, so either human surface can read the reply. The
            // legacy loop appended to `jointProjections` while iterating the same
            // array value; `for` captures the original slice, so the new links are
            // not revisited.
            for link in storage.jointProjections where link.canonicalChannelId == storageChannelId {
                let existing = storage.postableChannels.first { _, channel in
                    channel.kind == "thread"
                        && channel.parentChannelId == link.localChannelId
                        && channel.parentMessageId == messageId
                }?.key
                let localThreadId: String
                if let existing {
                    localThreadId = existing
                } else {
                    let created = threadChannels.createThreadChannel(
                        parentChannelId: link.localChannelId, parentMessageId: messageId
                    )
                    var thread = storage.postableChannels[created]
                        ?? PostableChannel(serverId: link.serverId, memberIds: [])
                    thread.serverId = link.serverId
                    thread.kind = "thread"
                    thread.parentChannelId = link.localChannelId
                    thread.parentMessageId = messageId
                    thread.name = "thread"
                    thread.memberIds.insert(requesterAgentId)
                    thread.memberIds.insert(confirmerUserId)
                    if let parentMembers = storage.postableChannels[link.localChannelId]?.memberIds {
                        thread.memberIds.formUnion(parentMembers)
                    }
                    storage.postableChannels[created] = thread
                    storage.jointProjections.append(JointChannelLink(
                        localChannelId: created,
                        canonicalChannelId: threadId,
                        serverId: link.serverId
                    ))
                    localThreadId = created
                }
                if localThreadId != threadId {
                    storage.postableChannels[localThreadId]?.memberIds.insert(requesterAgentId)
                    storage.postableChannels[localThreadId]?.memberIds.insert(confirmerUserId)
                }
            }
            return threadId
        }
    }

    // MARK: - Agent send delivery channel resolution

    /// The live channel a `#name` send target resolves to, in one critical
    /// section. Dictionary order is the legacy first-match order.
    func postableChannel(serverId: String, name: String) -> (id: String, channel: PostableChannel)? {
        mutex.withLock { storage in
            for (id, channel) in storage.postableChannels
            where channel.serverId == serverId && channel.name == name && channel.deletedAt == nil {
                return (id, channel)
            }
            return nil
        }
    }

    /// The live thread under `parentChannelId` whose parent message text starts
    /// with `shortId`, in one critical section.
    func threadChannel(
        serverId: String,
        parentChannelId: String,
        shortId: String
    ) -> (id: String, channel: PostableChannel)? {
        mutex.withLock { storage in
            for (id, channel) in storage.postableChannels
            where channel.serverId == serverId
                && channel.kind == "thread"
                && channel.parentChannelId == parentChannelId
                && (channel.parentMessageId?.hasPrefix(shortId) ?? false)
                && channel.deletedAt == nil {
                return (id, channel)
            }
            return nil
        }
    }

    /// A thread reference that does not filter server or deletion, matching the
    /// legacy `threads/unfollow` `#name:short` lookup.
    func threadChannel(parentChannelId: String, shortId: String) -> (id: String, channel: PostableChannel)? {
        mutex.withLock { storage in
            for (id, channel) in storage.postableChannels
            where channel.kind == "thread"
                && channel.parentChannelId == parentChannelId
                && (channel.parentMessageId?.hasPrefix(shortId) ?? false) {
                return (id, channel)
            }
            return nil
        }
    }

    /// One channel row by id, in one critical section.
    func postableChannel(id: String) -> PostableChannel? {
        mutex.withLock { storage in
            return storage.postableChannels[id]
        }
    }

    /// Channels, joint links and thread slices for the delivery-ack read in
    /// one locked snapshot instead of one lock per lookup.
    struct DeliveryAckChannelSnapshot: Sendable {
        let channels: [String: PostableChannel]
        let jointProjections: [JointChannelLink]
    }

    func deliveryAckChannelSnapshot() -> DeliveryAckChannelSnapshot {
        mutex.withLock { storage in
            return DeliveryAckChannelSnapshot(
                channels: storage.postableChannels,
                jointProjections: storage.jointProjections
            )
        }
    }

    /// The legacy `threads/unfollow` parent lookup ignores `deletedAt`; this is
    /// the same first-match order without the live filter.
    func postableChannelIncludingDeleted(serverId: String, name: String) -> (id: String, channel: PostableChannel)? {
        mutex.withLock { storage in
            for (id, channel) in storage.postableChannels
            where channel.serverId == serverId && channel.name == name {
                return (id, channel)
            }
            return nil
        }
    }

    /// The channel ids that still have a live row, in the caller's order. A
    /// missing row survives, exactly as the legacy
    /// `postableChannels[id]?.deletedAt == nil` filter did.
    func liveChannelIds(_ channelIds: [String]) -> [String] {
        mutex.withLock { storage in
            return channelIds.filter { storage.postableChannels[$0]?.deletedAt == nil }
        }
    }

    /// Whether a channel row exists and is not soft-deleted.
    func liveChannelExists(_ channelId: String) -> Bool {
        mutex.withLock { storage in
            return storage.postableChannels[channelId] != nil && storage.postableChannels[channelId]?.deletedAt == nil
        }
    }
}
