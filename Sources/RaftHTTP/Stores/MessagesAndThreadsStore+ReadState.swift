import Foundation

extension MessagesAndThreadsStore {
    // MARK: - Agent delivery ack

    /// Message rows plus the legacy thread-follow rows the delivery ack reads,
    /// copied in one critical section.
    struct DeliveryAckMessageSnapshot: Sendable {
        let rows: [StoredHumanMessage]
        let threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
    }

    func deliveryAckMessageSnapshot() -> DeliveryAckMessageSnapshot {
        withState { state in
            return DeliveryAckMessageSnapshot(
                rows: state.humanMessageRows,
                threadFollows: state.threadFollows
            )
        }
    }

    /// Read-modify-write of every per-channel agent cursor the ack advanced.
    /// The previous cursor, the version bump and the write all happen in one
    /// critical section, so concurrent acks cannot both read version N and
    /// write N+1.
    func advanceAgentReadCursors(agentId: String, maxSeqByChannel: [String: Int]) {
        withState { state in
            for (channelId, maxSeq) in maxSeqByChannel {
                let key = "\(channelId)\n\(agentId)"
                let previous = state.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
                guard maxSeq > previous.seq else { continue }
                state.agentChannelReadCursors[key] = (maxSeq, previous.version + 1)
            }
        }
    }

    // MARK: - Channel read state and thread rows (managed-MCP assignments)

    /// Bumps one human's channel read-state version and returns the new value.
    func bumpChannelReadVersion(channelId: String, userId: String) -> Int {
        withState { state in
            let key = "\(channelId)\n\(userId)"
            let version = (state.channelReadVersions[key] ?? 0) + 1
            state.channelReadVersions[key] = version
            return version
        }
    }

    func channelReadVersion(channelId: String, userId: String) -> Int {
        withState { state in
            return state.channelReadVersions["\(channelId)\n\(userId)"] ?? 0
        }
    }

    enum ChannelReadAdvance: Sendable, Equatable {
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
        withState { state in
            let key = "\(channelId)\n\(userId)"
            let frontier = maxReadSeq()
            if seq <= frontier {
                return .unchanged(maxReadSeq: frontier, version: state.channelReadVersions[key] ?? 0)
            }
            let version = (state.channelReadVersions[key] ?? 0) + 1
            state.channelReadVersions[key] = version
            return .advanced(version: version)
        }
    }

    struct AgentReadAdvance: Sendable, Equatable {
        var seq: Int
        var version: Int
        var advanced: Bool
    }

    /// `POST /api/channels/:id/read-all` delegated to an agent receiver: the
    /// previous cursor, the version bump and the write are one critical section.
    func advanceAgentChannelRead(channelId: String, agentId: String, latestSeq: Int) -> AgentReadAdvance {
        withState { state in
            let key = "\(channelId)\n\(agentId)"
            let previous = state.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            let advanced = latestSeq > previous.seq
            let version = advanced ? previous.version + 1 : previous.version
            state.agentChannelReadCursors[key] = (seq: max(previous.seq, latestSeq), version: version)
            return AgentReadAdvance(seq: max(previous.seq, latestSeq), version: version, advanced: advanced)
        }
    }

    /// The Done-inbox stamp and the read-version bump of a receiver-owned
    /// residue read-all, in one critical section; returns the new version.
    func markInboxScopeDone(channelId: String, userId: String, at date: Date) -> Int {
        withState { state in
            state.inboxDoneScopes.insert("\(userId)\n\(channelId)")
            state.inboxDoneAt["\(userId)\n\(channelId)"] = date
            let key = "\(channelId)\n\(userId)"
            let version = (state.channelReadVersions[key] ?? 0) + 1
            state.channelReadVersions[key] = version
            return version
        }
    }

    func agentChannelReadSeq(channelId: String, agentId: String) -> Int {
        withState { state in
            return state.agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
        }
    }
}

extension MessagesAndThreadsStore {
    /// A system notice the acting agent caused is born read for that agent: the
    /// cursor passes `seq` and its version bumps, in one critical section.
    func markBornRead(channelId: String, agentId: String, seq: Int) {
        withState { state in
            let key = "\(channelId)\n\(agentId)"
            let previous = state.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            state.agentChannelReadCursors[key] = (max(previous.seq, seq), previous.version + 1)
        }
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
        withState { state in
            var scopeIds = [channelId]
            for (_, follow) in state.threadFollows where follow.userId == userId && follow.parentMessageId != "" {
                guard let parentRow = state.humanMessageRows.first(where: { $0.id == follow.parentMessageId }),
                      parentRow.channelId == channelId
                else { continue }
                if !scopeIds.contains(follow.threadChannelId) { scopeIds.append(follow.threadChannelId) }
            }
            return scopeIds.map { scope in
                let latest = state.humanMessageRows.filter { $0.channelId == scope }.map(\.seq).max() ?? 0
                let key = "\(userId)\n\(scope)"
                let previous = state.userChannelReadCursors[key] ?? 0
                let version = previous + 1
                state.userChannelReadCursors[key] = max(previous, latest)
                return ReadAllScopeResult(scopeId: scope, maxReadSeq: latest, readStateVersion: version)
            }
        }
    }

    /// Whether `userId` already owns a read cursor for `scopeId`.
    func hasUserReadCursor(userId: String, scopeId: String) -> Bool {
        withState { state in
            return state.userChannelReadCursors["\(userId)\n\(scopeId)"] != nil
        }
    }

    /// The replay a stored mutation answers, without writing.
    func readMutationReplay(
        key: String,
        fingerprint: String,
        userId: String
    ) -> ReadMutationReplay? {
        withState { state in
            return readMutationReplayLocked(key: key, fingerprint: fingerprint, userId: userId, state: &state)
        }
    }

    private func readMutationReplayLocked(
        key: String,
        fingerprint: String,
        userId: String,
        state: inout State
    ) -> ReadMutationReplay? {
        guard let existing = state.readMutationRecords[key] else { return nil }
        guard existing.fingerprint == fingerprint else { return .payloadMismatch }
        let cursor = state.userChannelReadCursors["\(userId)\n\(existing.scopeId ?? "")"] ?? 0
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
        withState { state in
            if let replay = readMutationReplayLocked(key: key, fingerprint: fingerprint, userId: userId, state: &state) {
                return .replay(replay)
            }
            let seq = (state.readMutationAuthoritySeq[sequenceKey] ?? 0) + 1
            state.readMutationAuthoritySeq[sequenceKey] = seq
            state.readMutationRecords[key] = record(seq)
            state.readMutationOrder.append(key)
            return .admitted(authoritySeq: seq)
        }
    }

    /// The principal's mutation frontier and requested scope cursors from one
    /// snapshot.
    func readMutationFrontier(userId: String, scopeIds: [String]?) -> ReadMutationFrontierSnapshot {
        withState { state in
            let sequences = state.readMutationAuthoritySeq.filter {
                $0.key.hasSuffix("\n\(userId)") || $0.key.contains("\n\(userId)")
            }
            let upper = sequences.values.max() ?? 0
            let keys = state.readMutationOrder.filter { state.readMutationRecords[$0]?.principalId == userId }
            let records = keys.compactMap { state.readMutationRecords[$0] }
            var lastTerminal = 0
            let items = records.map { record -> ReadMutationFrontierSnapshot.Item in
                if record.state != "admitted" { lastTerminal = max(lastTerminal, record.authoritySeq) }
                return ReadMutationFrontierSnapshot.Item(
                    mutationId: record.mutationId, authoritySeq: record.authoritySeq, state: record.state
                )
            }
            let cursors = scopeIds.map { ids in
                ids.map { scope in
                    (scopeId: scope, maxReadSeq: state.userChannelReadCursors["\(userId)\n\(scope)"] ?? 0)
                }
            }
            return ReadMutationFrontierSnapshot(
                snapshotUpperAuthoritySeq: upper,
                lastTerminalAuthoritySeq: lastTerminal,
                items: items,
                scopeCursors: cursors
            )
        }
    }

    /// Drops the follow rows of every thread in `threadChannelIds` whose
    /// follower is not in `keepUserIds`, in one critical section.
    func removeThreadFollows(
        inThreads threadChannelIds: Set<String>,
        exceptUsers keepUserIds: Set<String>
    ) {
        withState { state in
            for (key, follow) in state.threadFollows
            where threadChannelIds.contains(follow.threadChannelId) && !keepUserIds.contains(follow.userId) {
                state.threadFollows.removeValue(forKey: key)
            }
        }
    }

    /// The stored external-avatar asset and the storage-availability flag from
    /// one snapshot.
    func externalAvatarSnapshot(id: String) -> (asset: ExternalAvatarAsset?, storageAvailable: Bool) {
        withState { state in
            return (state.externalAvatarAssets[id], state.externalAvatarStorageAvailable)
        }
    }

    /// Thread-unread facts the summary builds from, from one snapshot.
    func threadUnreadFacts(channelId: String) -> [StoredHumanMessage] {
        withState { state in
            return state.humanMessageRows.filter { $0.channelId == channelId }
        }
    }

    /// Whether `userId` follows the thread and has not archived it to Done.
    func followsActiveThread(serverId: String, userId: String, threadChannelId: String) -> Bool {
        withState { state in
            return state.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] != nil
                && !state.inboxDoneScopes.contains("\(userId)\n\(threadChannelId)")
        }
    }

    /// The mention rows that target `userId` in `channelId`.
    func userMentionExists(channelId: String, userId: String) -> Bool {
        withState { state in
            return state.storedMentions.contains {
                $0.channelId == channelId && $0.targetType == "user" && $0.targetId == userId
            }
        }
    }
}
