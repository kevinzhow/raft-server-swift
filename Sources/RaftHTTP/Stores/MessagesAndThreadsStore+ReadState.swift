import Foundation

extension MessagesAndThreadsStore {
    // MARK: - Agent delivery ack

    /// Message rows plus the legacy thread-follow rows the delivery ack reads,
    /// copied in one critical section.
    struct DeliveryAckMessageSnapshot {
        let rows: [StoredHumanMessage]
        let threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
    }

    func deliveryAckMessageSnapshot() -> DeliveryAckMessageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DeliveryAckMessageSnapshot(
            rows: storage.humanMessageRows,
            threadFollows: storage.threadFollows
        )
    }

    /// Read-modify-write of every per-channel agent cursor the ack advanced.
    /// The previous cursor, the version bump and the write all happen in one
    /// critical section, so concurrent acks cannot both read version N and
    /// write N+1.
    func advanceAgentReadCursors(agentId: String, maxSeqByChannel: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        for (channelId, maxSeq) in maxSeqByChannel {
            let key = "\(channelId)\n\(agentId)"
            let previous = storage.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            guard maxSeq > previous.seq else { continue }
            storage.agentChannelReadCursors[key] = (maxSeq, previous.version + 1)
        }
    }

    // MARK: - Channel read state and thread rows (managed-MCP assignments)

    /// Bumps one human's channel read-state version and returns the new value.
    func bumpChannelReadVersion(channelId: String, userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(userId)"
        let version = (storage.channelReadVersions[key] ?? 0) + 1
        storage.channelReadVersions[key] = version
        return version
    }

    func channelReadVersion(channelId: String, userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.channelReadVersions["\(channelId)\n\(userId)"] ?? 0
    }

    enum ChannelReadAdvance: Equatable {
        /// The frontier already covers `seq`; nothing was written.
        case unchanged(maxReadSeq: Int, version: Int)
        case advanced(version: Int)
    }

    /// `POST /api/channels/:id/read`: the frontier comparison and the version
    /// bump are one critical section. `maxReadSeq` reads the ledger frontier
    /// inside the section and must not call back into this store.
    func advanceChannelRead(
        channelId: String,
        userId: String,
        seq: Int,
        maxReadSeq: () -> Int
    ) -> ChannelReadAdvance {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(userId)"
        let frontier = maxReadSeq()
        if seq <= frontier {
            return .unchanged(maxReadSeq: frontier, version: storage.channelReadVersions[key] ?? 0)
        }
        let version = (storage.channelReadVersions[key] ?? 0) + 1
        storage.channelReadVersions[key] = version
        return .advanced(version: version)
    }

    struct AgentReadAdvance: Equatable {
        var seq: Int
        var version: Int
        var advanced: Bool
    }

    /// `POST /api/channels/:id/read-all` delegated to an agent receiver: the
    /// previous cursor, the version bump and the write are one critical section.
    func advanceAgentChannelRead(channelId: String, agentId: String, latestSeq: Int) -> AgentReadAdvance {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let previous = storage.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
        let advanced = latestSeq > previous.seq
        let version = advanced ? previous.version + 1 : previous.version
        storage.agentChannelReadCursors[key] = (seq: max(previous.seq, latestSeq), version: version)
        return AgentReadAdvance(seq: max(previous.seq, latestSeq), version: version, advanced: advanced)
    }

    /// The Done-inbox stamp and the read-version bump of a receiver-owned
    /// residue read-all, in one critical section; returns the new version.
    func markInboxScopeDone(channelId: String, userId: String, at date: Date) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.inboxDoneScopes.insert("\(userId)\n\(channelId)")
        storage.inboxDoneAt["\(userId)\n\(channelId)"] = date
        let key = "\(channelId)\n\(userId)"
        let version = (storage.channelReadVersions[key] ?? 0) + 1
        storage.channelReadVersions[key] = version
        return version
    }

    func agentChannelReadSeq(channelId: String, agentId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
    }
}

extension MessagesAndThreadsStore {
    /// A system notice the acting agent caused is born read for that agent: the
    /// cursor passes `seq` and its version bumps, in one critical section.
    func markBornRead(channelId: String, agentId: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let previous = storage.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
        storage.agentChannelReadCursors[key] = (max(previous.seq, seq), previous.version + 1)
    }
}

// MARK: - Managed MCP lifecycle: read-state sections

/// One advanced read-all scope: the new cursor position and the version the
/// published body reports.
struct ReadAllScopeResult: Sendable, Equatable {
    let scopeId: String
    let maxReadSeq: Int
    let readStateVersion: Int
}

/// What a stored read-mutation answers for the same mutation id.
enum ReadMutationReplay: Sendable, Equatable {
    /// Same id, different payload.
    case payloadMismatch
    /// A channel read-all whose cursor already moved.
    case alreadyTerminal(scopeId: String, cursor: Int)
    case alreadyAdmitted
}

/// Result of the locked check-then-insert of one read mutation.
enum ReadMutationAdmission: Sendable, Equatable {
    case admitted(authoritySeq: Int)
    case replay(ReadMutationReplay)
}

/// The authority frontier the principal can observe, from one snapshot.
struct ReadMutationFrontierSnapshot: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let mutationId: String
        let authoritySeq: Int
        let state: String
    }

    let snapshotUpperAuthoritySeq: Int
    let lastTerminalAuthoritySeq: Int
    let items: [Item]
    let scopeCursors: [(scopeId: String, maxReadSeq: Int)]?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshotUpperAuthoritySeq == rhs.snapshotUpperAuthoritySeq
            && lhs.lastTerminalAuthoritySeq == rhs.lastTerminalAuthoritySeq
            && lhs.items == rhs.items
            && (lhs.scopeCursors?.map { "\($0.scopeId)\n\($0.maxReadSeq)" })
                == (rhs.scopeCursors?.map { "\($0.scopeId)\n\($0.maxReadSeq)" })
    }
}

extension MessagesAndThreadsStore {
    /// Marks the channel and every followed thread under it read for `userId`.
    ///
    /// The scope derivation (the user's follows whose parent message sits in the
    /// channel), each scope's latest sequence and the cursor writes are one
    /// critical section, so two concurrent read-alls cannot interleave a cursor
    /// read with another request's write.
    func advanceConversationReadAll(userId: String, channelId: String) -> [ReadAllScopeResult] {
        lock.lock()
        defer { lock.unlock() }
        var scopeIds = [channelId]
        for (_, follow) in storage.threadFollows where follow.userId == userId && follow.parentMessageId != "" {
            guard let parentRow = storage.humanMessageRows.first(where: { $0.id == follow.parentMessageId }),
                  parentRow.channelId == channelId
            else { continue }
            if !scopeIds.contains(follow.threadChannelId) { scopeIds.append(follow.threadChannelId) }
        }
        return scopeIds.map { scope in
            let latest = storage.humanMessageRows.filter { $0.channelId == scope }.map(\.seq).max() ?? 0
            let key = "\(userId)\n\(scope)"
            let previous = storage.userChannelReadCursors[key] ?? 0
            let version = previous + 1
            storage.userChannelReadCursors[key] = max(previous, latest)
            return ReadAllScopeResult(scopeId: scope, maxReadSeq: latest, readStateVersion: version)
        }
    }

    /// Whether `userId` already owns a read cursor for `scopeId`.
    func hasUserReadCursor(userId: String, scopeId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.userChannelReadCursors["\(userId)\n\(scopeId)"] != nil
    }

    /// The replay a stored mutation answers, without writing.
    func readMutationReplay(
        key: String,
        fingerprint: String,
        userId: String
    ) -> ReadMutationReplay? {
        lock.lock()
        defer { lock.unlock() }
        return readMutationReplayLocked(key: key, fingerprint: fingerprint, userId: userId)
    }

    private func readMutationReplayLocked(
        key: String,
        fingerprint: String,
        userId: String
    ) -> ReadMutationReplay? {
        guard let existing = storage.readMutationRecords[key] else { return nil }
        guard existing.fingerprint == fingerprint else { return .payloadMismatch }
        let cursor = storage.userChannelReadCursors["\(userId)\n\(existing.scopeId ?? "")"] ?? 0
        if existing.kind == "channel_read_all", cursor > 0 {
            return .alreadyTerminal(scopeId: existing.scopeId ?? "", cursor: cursor)
        }
        return .alreadyAdmitted
    }

    /// Admits one read mutation: the existing-id check, the per-principal
    /// authority sequence bump and the record insert are one critical section,
    /// so two requests with the same mutation id cannot both be admitted.
    func admitReadMutation(
        key: String,
        sequenceKey: String,
        userId: String,
        fingerprint: String,
        record: (_ authoritySeq: Int) -> ReadMutationRecord
    ) -> ReadMutationAdmission {
        lock.lock()
        defer { lock.unlock() }
        if let replay = readMutationReplayLocked(key: key, fingerprint: fingerprint, userId: userId) {
            return .replay(replay)
        }
        let seq = (storage.readMutationAuthoritySeq[sequenceKey] ?? 0) + 1
        storage.readMutationAuthoritySeq[sequenceKey] = seq
        storage.readMutationRecords[key] = record(seq)
        storage.readMutationOrder.append(key)
        return .admitted(authoritySeq: seq)
    }

    /// The principal's mutation frontier and requested scope cursors from one
    /// snapshot.
    func readMutationFrontier(userId: String, scopeIds: [String]?) -> ReadMutationFrontierSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let sequences = storage.readMutationAuthoritySeq.filter {
            $0.key.hasSuffix("\n\(userId)") || $0.key.contains("\n\(userId)")
        }
        let upper = sequences.values.max() ?? 0
        let keys = storage.readMutationOrder.filter { storage.readMutationRecords[$0]?.principalId == userId }
        let records = keys.compactMap { storage.readMutationRecords[$0] }
        var lastTerminal = 0
        let items = records.map { record -> ReadMutationFrontierSnapshot.Item in
            if record.state != "admitted" { lastTerminal = max(lastTerminal, record.authoritySeq) }
            return ReadMutationFrontierSnapshot.Item(
                mutationId: record.mutationId, authoritySeq: record.authoritySeq, state: record.state
            )
        }
        let cursors = scopeIds.map { ids in
            ids.map { scope in
                (scopeId: scope, maxReadSeq: storage.userChannelReadCursors["\(userId)\n\(scope)"] ?? 0)
            }
        }
        return ReadMutationFrontierSnapshot(
            snapshotUpperAuthoritySeq: upper,
            lastTerminalAuthoritySeq: lastTerminal,
            items: items,
            scopeCursors: cursors
        )
    }

    /// Drops the follow rows of every thread in `threadChannelIds` whose
    /// follower is not in `keepUserIds`, in one critical section.
    func removeThreadFollows(
        inThreads threadChannelIds: Set<String>,
        exceptUsers keepUserIds: Set<String>
    ) {
        lock.lock()
        defer { lock.unlock() }
        for (key, follow) in storage.threadFollows
        where threadChannelIds.contains(follow.threadChannelId) && !keepUserIds.contains(follow.userId) {
            storage.threadFollows.removeValue(forKey: key)
        }
    }

    /// The stored external-avatar asset and the storage-availability flag from
    /// one snapshot.
    func externalAvatarSnapshot(id: String) -> (asset: ExternalAvatarAsset?, storageAvailable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage.externalAvatarAssets[id], storage.externalAvatarStorageAvailable)
    }

    /// Thread-unread facts the summary builds from, from one snapshot.
    func threadUnreadFacts(channelId: String) -> [StoredHumanMessage] {
        lock.lock()
        defer { lock.unlock() }
        return storage.humanMessageRows.filter { $0.channelId == channelId }
    }

    /// Whether `userId` follows the thread and has not archived it to Done.
    func followsActiveThread(serverId: String, userId: String, threadChannelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] != nil
            && !storage.inboxDoneScopes.contains("\(userId)\n\(threadChannelId)")
    }

    /// The mention rows that target `userId` in `channelId`.
    func userMentionExists(channelId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.storedMentions.contains {
            $0.channelId == channelId && $0.targetType == "user" && $0.targetId == userId
        }
    }
}
