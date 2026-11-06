import Foundation

/// Owns the human-message, reaction, mention, read-frontier, thread-follow and
/// attachment-comment rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class MessagesAndThreadsStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var humanMessageRows: [StoredHumanMessage] = []
        var channelAttachments: [String: ChannelAttachment] = [:]
        var recordedChannelMessageEvents: [EmailLoginDirectory.ChannelMessageEvent] = []
        var forwardedBundles: [String: [EmailLoginDirectory.ForwardedSource]] = [:]
        var forwardRecords: [String: StoredForwardRecord] = [:]
        var messageReactions: [StoredReaction] = []
        var reactionViewerVersions: [String: Int] = [:]
        var reactionDiscussionVersions: [String: Int] = [:]
        var storedMentions: [StoredMention] = []
        var attachmentCommentRecords: [String: [AttachmentCommentRecord]] = [:]
        var messageTranslationLedger: [String: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)] = [:]
        var readMutationRecords: [String: ReadMutationRecord] = [:]
        var readMutationAuthoritySeq: [String: Int] = [:]
        var readMutationOrder: [String] = []
        var readMutationAcks: [String: (scopeId: String, throughSeq: Int)] = [:]
        var userChannelReadCursors: [String: Int] = [:]
        var shareArtifacts: [String: ShareArtifactRecord] = [:]
        var systemAttentionIncidents: [SystemAttentionIncident] = []
        var systemAttentionReceipts: [String: SystemAttentionReceipt] = [:]
        var threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)] = [:]
        var threadUnfollows: [String: ThreadUnfollowRecord] = [:]
        var threadFollowStarts: [String: Date] = [:]
        var threadFollowerRemovals: [String: (serverId: String, threadChannelId: String, agentId: String)] = [:]
        var staleThreadFollowerUndoTokens: Set<String> = []
        var channelReadVersions: [String: Int] = [:]
        var agentChannelReadCursors: [String: (seq: Int, version: Int)] = [:]
        var attestedSendEventRecords: [AttestedSendEventRecord] = []
        var agentSendActivityRecords: [String: [(title: String, text: String, producerFactId: String?)]] = [:]
        var inboxDoneScopes: Set<String> = []
        var inboxDoneAt: [String: Date] = [:]
        var inboxDoneFrontiers: [String: Int] = [:]
        var inboxResidues: Set<String> = []
        var deferredUnreadAdvance: [String: Int] = [:]
        var externalAvatarAssets: [String: ExternalAvatarAsset] = [:]
        var externalAvatarStorageAvailable = true
        // Injectable messaging/attachment configuration that used to live inline
        // on `EmailLoginDirectory`.
        var translationProviderOverride: String? = nil
        var attachmentPreviewBody: (@Sendable (_ attachmentId: String) -> String?)? = nil
        var attachmentPresign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)? = nil
        var readPositionSettleMs: Int = 2000
        var sendFreshnessModeOverride: String? = nil
        var realtimeEmitterStorage: (@Sendable (String, String, String?) -> Void)? = nil
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    /// Runs `body` on the owned state in ONE critical section, for a decision
    /// that reads and writes several rows and must not interleave with another
    /// request. `body` must not call back into this store.
    func withState<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var humanMessageRows: [StoredHumanMessage] {
        get { state.humanMessageRows }
        set { state.humanMessageRows = newValue }
    }

    var channelAttachments: [String: ChannelAttachment] {
        get { state.channelAttachments }
        set { state.channelAttachments = newValue }
    }

    var recordedChannelMessageEvents: [EmailLoginDirectory.ChannelMessageEvent] {
        get { state.recordedChannelMessageEvents }
        set { state.recordedChannelMessageEvents = newValue }
    }

    var forwardedBundles: [String: [EmailLoginDirectory.ForwardedSource]] {
        get { state.forwardedBundles }
        set { state.forwardedBundles = newValue }
    }

    var forwardRecords: [String: StoredForwardRecord] {
        get { state.forwardRecords }
        set { state.forwardRecords = newValue }
    }

    var messageReactions: [StoredReaction] {
        get { state.messageReactions }
        set { state.messageReactions = newValue }
    }

    var reactionViewerVersions: [String: Int] {
        get { state.reactionViewerVersions }
        set { state.reactionViewerVersions = newValue }
    }

    var reactionDiscussionVersions: [String: Int] {
        get { state.reactionDiscussionVersions }
        set { state.reactionDiscussionVersions = newValue }
    }

    var storedMentions: [StoredMention] {
        get { state.storedMentions }
        set { state.storedMentions = newValue }
    }

    var attachmentCommentRecords: [String: [AttachmentCommentRecord]] {
        get { state.attachmentCommentRecords }
        set { state.attachmentCommentRecords = newValue }
    }

    var messageTranslationLedger: [String: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)] {
        get { state.messageTranslationLedger }
        set { state.messageTranslationLedger = newValue }
    }

    var readMutationRecords: [String: ReadMutationRecord] {
        get { state.readMutationRecords }
        set { state.readMutationRecords = newValue }
    }

    var readMutationAuthoritySeq: [String: Int] {
        get { state.readMutationAuthoritySeq }
        set { state.readMutationAuthoritySeq = newValue }
    }

    var readMutationOrder: [String] {
        get { state.readMutationOrder }
        set { state.readMutationOrder = newValue }
    }

    var readMutationAcks: [String: (scopeId: String, throughSeq: Int)] {
        get { state.readMutationAcks }
        set { state.readMutationAcks = newValue }
    }

    var userChannelReadCursors: [String: Int] {
        get { state.userChannelReadCursors }
        set { state.userChannelReadCursors = newValue }
    }

    var shareArtifacts: [String: ShareArtifactRecord] {
        get { state.shareArtifacts }
        set { state.shareArtifacts = newValue }
    }

    var systemAttentionIncidents: [SystemAttentionIncident] {
        get { state.systemAttentionIncidents }
        set { state.systemAttentionIncidents = newValue }
    }

    var systemAttentionReceipts: [String: SystemAttentionReceipt] {
        get { state.systemAttentionReceipts }
        set { state.systemAttentionReceipts = newValue }
    }

    var threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)] {
        get { state.threadFollows }
        set { state.threadFollows = newValue }
    }

    var threadUnfollows: [String: ThreadUnfollowRecord] {
        get { state.threadUnfollows }
        set { state.threadUnfollows = newValue }
    }

    var threadFollowStarts: [String: Date] {
        get { state.threadFollowStarts }
        set { state.threadFollowStarts = newValue }
    }

    var threadFollowerRemovals: [String: (serverId: String, threadChannelId: String, agentId: String)] {
        get { state.threadFollowerRemovals }
        set { state.threadFollowerRemovals = newValue }
    }

    var staleThreadFollowerUndoTokens: Set<String> {
        get { state.staleThreadFollowerUndoTokens }
        set { state.staleThreadFollowerUndoTokens = newValue }
    }

    var channelReadVersions: [String: Int] {
        get { state.channelReadVersions }
        set { state.channelReadVersions = newValue }
    }

    var agentChannelReadCursors: [String: (seq: Int, version: Int)] {
        get { state.agentChannelReadCursors }
        set { state.agentChannelReadCursors = newValue }
    }

    var attestedSendEventRecords: [AttestedSendEventRecord] {
        get { state.attestedSendEventRecords }
        set { state.attestedSendEventRecords = newValue }
    }

    var agentSendActivityRecords: [String: [(title: String, text: String, producerFactId: String?)]] {
        get { state.agentSendActivityRecords }
        set { state.agentSendActivityRecords = newValue }
    }

    var inboxDoneScopes: Set<String> {
        get { state.inboxDoneScopes }
        set { state.inboxDoneScopes = newValue }
    }

    var inboxDoneAt: [String: Date] {
        get { state.inboxDoneAt }
        set { state.inboxDoneAt = newValue }
    }

    var inboxDoneFrontiers: [String: Int] {
        get { state.inboxDoneFrontiers }
        set { state.inboxDoneFrontiers = newValue }
    }

    var inboxResidues: Set<String> {
        get { state.inboxResidues }
        set { state.inboxResidues = newValue }
    }

    var deferredUnreadAdvance: [String: Int] {
        get { state.deferredUnreadAdvance }
        set { state.deferredUnreadAdvance = newValue }
    }

    var externalAvatarAssets: [String: ExternalAvatarAsset] {
        get { state.externalAvatarAssets }
        set { state.externalAvatarAssets = newValue }
    }

    var externalAvatarStorageAvailable: Bool {
        get { state.externalAvatarStorageAvailable }
        set { state.externalAvatarStorageAvailable = newValue }
    }

    // MARK: - Injected messaging configuration

    var translationProviderOverride: String? {
        get { state.translationProviderOverride }
        set { state.translationProviderOverride = newValue }
    }

    var attachmentPreviewBody: (@Sendable (_ attachmentId: String) -> String?)? {
        get { state.attachmentPreviewBody }
        set { state.attachmentPreviewBody = newValue }
    }

    var attachmentPresign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)? {
        get { state.attachmentPresign }
        set { state.attachmentPresign = newValue }
    }

    var readPositionSettleMs: Int {
        get { state.readPositionSettleMs }
        set { state.readPositionSettleMs = newValue }
    }

    var sendFreshnessModeOverride: String? {
        get { state.sendFreshnessModeOverride }
        set { state.sendFreshnessModeOverride = newValue }
    }

    var realtimeEmitterStorage: (@Sendable (String, String, String?) -> Void)? {
        get { state.realtimeEmitterStorage }
        set { state.realtimeEmitterStorage = newValue }
    }

    // MARK: - Socket room membership

    /// Human message rows after `lastSeq`, copied under one lock. The caller
    /// sorts the page; the store only owns the read.
    func messagesForResume(afterSeq: Int) -> [StoredHumanMessage] {
        lock.lock()
        defer { lock.unlock() }
        return storage.humanMessageRows.filter { $0.seq > afterSeq }
    }

    /// Follow/unfollow keys as one snapshot so the recursive parent-visibility
    /// check does not take the store lock once per thread.
    struct ThreadFollowSnapshot {
        let follows: Set<String>
        let unfollows: Set<String>
    }

    func threadFollowSnapshot() -> ThreadFollowSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ThreadFollowSnapshot(
            follows: Set(storage.threadFollows.keys),
            unfollows: Set(storage.threadUnfollows.keys)
        )
    }

    /// Removes every follow row for `keys` in one critical section.
    func removeThreadFollows(keys: [String]) {
        guard !keys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for key in keys {
            storage.threadFollows.removeValue(forKey: key)
            storage.threadUnfollows.removeValue(forKey: key)
            storage.threadFollowStarts.removeValue(forKey: key)
        }
    }

    // MARK: - Thread follow ledger

    /// One `(thread, parent message)` follow row, copied out of the ledger.
    struct ThreadFollowRow: Sendable, Equatable {
        let threadChannelId: String
        let parentMessageId: String
    }

    /// The thread a parent message already follows, searched across the whole
    /// ledger exactly as the legacy resolver did.
    func threadId(serverId: String, parentMessageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.threadFollows.values.first {
            $0.serverId == serverId && $0.parentMessageId == parentMessageId
        }?.threadChannelId
    }

    /// A user's active follows on one server, with inbox-done scopes filtered
    /// out under the same lock that reads the rows.
    func activeThreadFollows(serverId: String, userId: String) -> [ThreadFollowRow] {
        lock.lock()
        defer { lock.unlock() }
        return storage.threadFollows.values
            .filter {
                $0.serverId == serverId
                    && $0.userId == userId
                    && !storage.inboxDoneScopes.contains("\(userId)\n\($0.threadChannelId)")
            }
            .map { ThreadFollowRow(threadChannelId: $0.threadChannelId, parentMessageId: $0.parentMessageId) }
    }

    func isThreadFollowed(serverId: String, userId: String, threadChannelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] != nil
    }

    /// Unread-eligible personal mention ids for one user. The followed-thread
    /// projection intersects these with the thread's unread replies.
    func unreadMentionMessageIds(userId: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(storage.storedMentions.lazy.filter {
            $0.targetType == "user" && $0.targetId == userId && $0.notifiableAtSend
        }.map(\.messageId))
    }

    /// One user's unfollow suppression rows on a server, newest first is left
    /// to the caller.
    func threadUnfollowRecords(serverId: String, userId: String) -> [ThreadUnfollowRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.threadUnfollows.values.filter {
            $0.serverId == serverId && $0.userId == userId
        }
    }

    /// The follow/unfollow write: follow row, follow start and the unfollow
    /// suppression row change in one critical section. The legacy handler read
    /// the follow start, filtered the frozen replies and wrote the suppression
    /// row under the directory lock; splitting those reads here would let two
    /// concurrent writes interleave a follow and a suppression row.
    func applyThreadFollow(
        serverId: String,
        userId: String,
        threadChannelId: String,
        parentMessageId: String,
        follow: Bool,
        now: Date
    ) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
        if follow {
            storage.threadFollows[key] = (
                serverId: serverId,
                userId: userId,
                threadChannelId: threadChannelId,
                parentMessageId: parentMessageId
            )
            if storage.threadFollowStarts[key] == nil {
                storage.threadFollowStarts[key] = now
            }
            storage.threadUnfollows.removeValue(forKey: key)
            return
        }
        storage.threadFollows.removeValue(forKey: key)
        let startedAt = storage.threadFollowStarts.removeValue(forKey: key) ?? .distantPast
        let frozen = storage.humanMessageRows
            .filter { $0.channelId == threadChannelId && $0.createdAt >= startedAt }
            .map { (id: $0.id, content: $0.content) }
        storage.threadUnfollows[key] = ThreadUnfollowRecord(
            serverId: serverId,
            userId: userId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            unfollowedAt: now,
            latestMessageId: frozen.last?.id ?? parentMessageId,
            replyCount: frozen.count,
            frozenMessages: frozen
        )
    }

    // MARK: - Reaction writes

    /// One reaction write: the row change and the viewer/discussion versions
    /// that describe it, copied under the same lock.
    struct ReactionWriteSnapshot {
        let rows: [StoredReaction]
        let viewerVersion: Int
        let discussionVersion: Int
    }

    /// A human add/remove. The idempotency check, the row change, the
    /// viewer-version bump and the discussion-version bump are one critical
    /// section, so two concurrent identical posts cannot both count as a
    /// change and a remove cannot race an add.
    func applyUserReaction(
        messageId: String,
        userId: String,
        emoji: String,
        remove: Bool
    ) -> ReactionWriteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let before = storage.messageReactions.count
        if remove {
            storage.messageReactions.removeAll {
                $0.messageId == messageId && $0.emoji == emoji
                    && $0.reactorId == userId && $0.reactorType == "user"
            }
        } else if !storage.messageReactions.contains(where: {
            $0.messageId == messageId && $0.emoji == emoji
                && $0.reactorId == userId && $0.reactorType == "user"
        }) {
            storage.messageReactions.append(StoredReaction(
                messageId: messageId,
                emoji: emoji,
                reactorId: userId,
                reactorType: "user"
            ))
        }
        let viewerKey = "\(messageId)\n\(userId)"
        if storage.messageReactions.count != before {
            storage.reactionViewerVersions[viewerKey] =
                (storage.reactionViewerVersions[viewerKey] ?? 0) + 1
            let discussionKey = "\(messageId)\n\(emoji)"
            storage.reactionDiscussionVersions[discussionKey] =
                (storage.reactionDiscussionVersions[discussionKey] ?? 0) + 1
        }
        return ReactionWriteSnapshot(
            rows: storage.messageReactions.filter { $0.messageId == messageId },
            viewerVersion: storage.reactionViewerVersions[viewerKey] ?? 0,
            discussionVersion: storage.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0
        )
    }

    /// The agent variant: same atomic row change, no viewer version (engine
    /// agents have no `reactionViewer` snapshot).
    func applyAgentReaction(
        messageId: String,
        agentId: String,
        emoji: String,
        remove: Bool
    ) -> ReactionWriteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let before = storage.messageReactions.count
        if remove {
            storage.messageReactions.removeAll {
                $0.messageId == messageId && $0.emoji == emoji
                    && $0.reactorId == agentId && $0.reactorType == "agent"
            }
        } else if !storage.messageReactions.contains(where: {
            $0.messageId == messageId && $0.emoji == emoji
                && $0.reactorId == agentId && $0.reactorType == "agent"
        }) {
            storage.messageReactions.append(StoredReaction(
                messageId: messageId,
                emoji: emoji,
                reactorId: agentId,
                reactorType: "agent"
            ))
        }
        if storage.messageReactions.count != before {
            let discussionKey = "\(messageId)\n\(emoji)"
            storage.reactionDiscussionVersions[discussionKey] =
                (storage.reactionDiscussionVersions[discussionKey] ?? 0) + 1
        }
        return ReactionWriteSnapshot(
            rows: storage.messageReactions.filter { $0.messageId == messageId },
            viewerVersion: 0,
            discussionVersion: storage.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0
        )
    }

    /// One viewer read: the version and the caller's own emojis from the same
    /// locked snapshot.
    struct ReactionViewerSnapshot {
        let viewerVersion: Int
        let reactedEmojis: [String]
    }

    func reactionViewerSnapshot(messageId: String, userId: String) -> ReactionViewerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let emojis = storage.messageReactions
            .filter {
                $0.messageId == messageId && $0.reactorType == "user"
                    && $0.reactorId == userId
            }
            .map(\.emoji)
            .sorted(by: EmailLoginDirectory.utf16Ascending)
        return ReactionViewerSnapshot(
            viewerVersion: storage.reactionViewerVersions["\(messageId)\n\(userId)"] ?? 0,
            reactedEmojis: emojis
        )
    }

    /// One actor-page read: the discussion version and the matching rows from
    /// the same locked snapshot.
    struct ReactionDiscussionSnapshot {
        let discussionVersion: Int
        let rows: [StoredReaction]
    }

    func reactionDiscussionSnapshot(messageId: String, emoji: String) -> ReactionDiscussionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ReactionDiscussionSnapshot(
            discussionVersion: storage.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0,
            rows: storage.messageReactions.filter {
                $0.messageId == messageId && $0.emoji == emoji
            }
        )
    }

    /// Attachment chip counts for one replayed message, in request order.
    struct AttachmentCommentSummary {
        let attachmentId: String
        let commentCount: Int
    }

    func attachmentCommentSummaries(ids: [String], commentsVisible: Bool) -> [AttachmentCommentSummary] {
        lock.lock()
        defer { lock.unlock() }
        return ids.map { id in
            AttachmentCommentSummary(
                attachmentId: id,
                commentCount: commentsVisible ? (storage.attachmentCommentRecords[id]?.count ?? 0) : 0
            )
        }
    }

    /// Scoped comment chip anchored on `messageId`, as one locked snapshot.
    struct AttachmentCommentRef {
        let attachmentId: String
        let hostMessageId: String
        let hostChannelId: String
        let threadChannelId: String?
    }

    func commentRef(messageId: String) -> AttachmentCommentRef? {
        lock.lock()
        defer { lock.unlock() }
        for (attachmentId, records) in storage.attachmentCommentRecords {
            guard let record = records.first(where: { $0.id == messageId }),
                  let hostMessageId = record.hostMessageId,
                  let hostChannelId = record.hostChannelId
            else { continue }
            return AttachmentCommentRef(
                attachmentId: attachmentId,
                hostMessageId: hostMessageId,
                hostChannelId: hostChannelId,
                threadChannelId: record.threadChannelId
            )
        }
        return nil
    }

    /// One critical section for an attachment comment: the comment row and the
    /// host-thread message row it posts as. The sequence is the server-wide
    /// `rows.count + 1` the shared append stamps, so a concurrent comment can
    /// never take the same sequence or land between the two writes. Returns the
    /// stamped sequence.
    func appendAttachmentComment(_ record: AttachmentCommentRecord, message: StoredHumanMessage) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.attachmentCommentRecords[record.attachmentId, default: []].append(record)
        var stored = message
        stored.seq = storage.humanMessageRows.count + 1
        storage.humanMessageRows.append(stored)
        return stored.seq
    }

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

    /// Follows the creator (and, when a different live member wrote the
    /// parent, the parent author) of a freshly created thread in one critical
    /// section.
    func followCreatedThread(
        serverId: String,
        userId: String,
        threadChannelId: String,
        parentMessageId: String,
        parentAuthorId: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        storage.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] =
            (serverId, userId, threadChannelId, parentMessageId)
        if let parentAuthorId {
            storage.threadFollows["\(serverId)\n\(parentAuthorId)\n\(threadChannelId)"] =
                (serverId, parentAuthorId, threadChannelId, parentMessageId)
        }
    }

    /// `DELETE /api/tasks/:taskId`: clears the task shadow a host message
    /// carried, in one critical section.
    func clearTaskShadow(messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let shadow = storage.humanMessageRows.firstIndex(where: { $0.id == messageId }) else { return }
        storage.humanMessageRows[shadow].taskStatus = nil
        storage.humanMessageRows[shadow].taskNumber = nil
        storage.humanMessageRows[shadow].taskAssigneeType = nil
        storage.humanMessageRows[shadow].taskAssigneeId = nil
        storage.humanMessageRows[shadow].taskClaimedAt = nil
        storage.humanMessageRows[shadow].taskCompletedAt = nil
    }

    // MARK: - Agent task and inbox reads

    /// The first message row whose id is exactly `prefix` or starts with it,
    /// but only when it belongs to `channelId`.
    ///
    /// The retired converter called `humanMessageRows.first(where:)` with the
    /// id predicate and then compared the channel, so a prefix that first
    /// matches a row in another channel is a miss rather than a second lookup.
    func messageForConvert(prefix: String, channelId: String) -> StoredHumanMessage? {
        lock.lock()
        defer { lock.unlock() }
        guard let message = storage.humanMessageRows.first(where: {
            $0.id == prefix || $0.id.hasPrefix(prefix)
        }), message.channelId == channelId else {
            return nil
        }
        return message
    }

    /// One locked snapshot of every ledger the agent inbox projection reads:
    /// message rows, mentions, read cursors and the followed-thread rows.
    struct InboxSnapshot {
        let messages: [StoredHumanMessage]
        let mentions: [StoredMention]
        let readCursors: [String: (seq: Int, version: Int)]
        let threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
        let threadFollowStarts: [String: Date]
    }

    func inboxSnapshot() -> InboxSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return InboxSnapshot(
            messages: storage.humanMessageRows,
            mentions: storage.storedMentions,
            readCursors: storage.agentChannelReadCursors,
            threadFollows: storage.threadFollows,
            threadFollowStarts: storage.threadFollowStarts
        )
    }

    // MARK: - System attention and share artifacts

    /// One recipient's active, not-dismissed attention incidents in the archive
    /// order (newest activation first), with the receipt timestamps from the
    /// same locked snapshot.
    struct SystemAttentionNotificationRow {
        let incident: SystemAttentionIncident
        let seenAt: Date?
    }

    func systemAttentionNotifications(
        serverId: String,
        userId: String
    ) -> [SystemAttentionNotificationRow] {
        lock.lock()
        defer { lock.unlock() }
        return storage.systemAttentionIncidents
            .filter { $0.serverId == serverId && $0.state == "active" }
            .compactMap { incident -> SystemAttentionNotificationRow? in
                let receipt = storage.systemAttentionReceipts["\(incident.id)\n\(userId)"]
                guard receipt?.dismissedAt == nil else { return nil }
                return SystemAttentionNotificationRow(incident: incident, seenAt: receipt?.seenAt)
            }
            .sorted { $0.incident.activatedAt > $1.incident.activatedAt }
    }

    /// Decides and writes one recipient receipt in a single critical section.
    ///
    /// The enabled flag, the active-incident lookup and the receipt update all
    /// happen here, so two concurrent marks cannot both observe "not seen" and
    /// let a dismissal race a fresh seen-at. Returns `false` when the feed is
    /// disabled or the incident is not an active row of `serverId`.
    func recordSystemAttentionReceipt(
        serverId: String,
        incidentId: String,
        userId: String,
        attentionEnabled: Bool,
        dismiss: Bool,
        now: Date
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard attentionEnabled,
              storage.systemAttentionIncidents.contains(where: {
                  $0.id == incidentId && $0.serverId == serverId && $0.state == "active"
              })
        else { return false }
        let key = "\(incidentId)\n\(userId)"
        var receipt = storage.systemAttentionReceipts[key]
            ?? SystemAttentionReceipt(seenAt: nil, dismissedAt: nil)
        if receipt.seenAt == nil { receipt.seenAt = now }
        if dismiss { receipt.dismissedAt = now }
        storage.systemAttentionReceipts[key] = receipt
        return true
    }

    /// Stores one uploaded share artifact under the store lock. The id was
    /// already unique, so this is a single insert with no read first.
    func insertShareArtifact(
        id: String,
        bytes: Data,
        width: Int,
        height: Int,
        serverId: String,
        createdAt: Date
    ) {
        lock.lock()
        storage.shareArtifacts[id] = ShareArtifactRecord(
            bytes: bytes,
            width: width,
            height: height,
            serverId: serverId,
            createdAt: createdAt
        )
        lock.unlock()
    }

    // MARK: - Share artifacts and message translations

    /// One uploaded share artifact, or nil when no row carries the id.
    func shareArtifact(id: String) -> ShareArtifactRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.shareArtifacts[id]
    }

    /// Records the translation outcome for one message in a single critical
    /// section, so a concurrent batch cannot interleave a half-written row.
    func recordMessageTranslation(
        messageId: String,
        status: String,
        providerBilledChars: Int,
        targetLanguage: String,
        translatedContent: String
    ) {
        lock.lock()
        storage.messageTranslationLedger[messageId] = (
            status: status,
            providerBilledChars: providerBilledChars,
            targetLanguage: targetLanguage,
            translatedContent: translatedContent
        )
        lock.unlock()
    }

    // MARK: - Agent send commit

    /// The message's channel id for the idempotency replay response.
    func channelId(forMessageId messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.humanMessageRows.first { $0.id == messageId }?.channelId
    }

    /// The pre-append attachment policy, as one locked read.
    enum SendAttachmentCheck: Sendable, Equatable {
        case ok
        case duplicate(String)
        case unavailable(String)
        case alreadyLinked(String)
    }

    func validateSendAttachments(
        ids: [String],
        channelId: String,
        uploaderId: String
    ) -> SendAttachmentCheck {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        for id in ids {
            guard seen.insert(id).inserted else { return .duplicate(id) }
            guard let row = storage.channelAttachments[id],
                  row.channelId == channelId,
                  row.uploaderId == uploaderId
            else { return .unavailable(id) }
            if row.messageId != nil { return .alreadyLinked(id) }
        }
        return .ok
    }

    func linkSendAttachments(ids: [String], messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            storage.channelAttachments[id]?.messageId = messageId
        }
    }

    /// The legacy "sending is not reading" cursor rule: the cursor may pass the
    /// own message only when no message from someone else below it is still
    /// unhanded. The decision and the version bump are one critical section.
    func advanceAgentReadCursorAfterSend(channelId: String, agentId: String, ownSeq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let cursor = storage.agentChannelReadCursors[key]?.seq ?? 0
        let unreadBelow = storage.humanMessageRows.contains { message in
            message.channelId == channelId
                && message.senderId != agentId
                && message.seq > cursor
                && message.seq < ownSeq
        }
        if !unreadBelow, ownSeq > cursor {
            let previous = storage.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            storage.agentChannelReadCursors[key] = (ownSeq, previous.version + 1)
        }
    }

    /// The thread follow rows an agent send writes, in one critical section.
    func ensureThreadFollows(
        _ rows: [(serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
    ) {
        lock.lock()
        defer { lock.unlock() }
        for row in rows {
            storage.threadFollows["\(row.serverId)\n\(row.userId)\n\(row.threadChannelId)"] = row
        }
    }

    /// The freshness gate's read set from one critical section: every message
    /// row, every mention row and the agent's read frontier.
    struct SendFreshnessSnapshot {
        let rows: [StoredHumanMessage]
        let mentions: [StoredMention]
        let readCursor: (seq: Int, version: Int)
    }

    func sendFreshnessSnapshot(channelId: String, agentId: String) -> SendFreshnessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SendFreshnessSnapshot(
            rows: storage.humanMessageRows,
            mentions: storage.storedMentions,
            readCursor: storage.agentChannelReadCursors["\(channelId)\n\(agentId)"] ?? (seq: 0, version: 0)
        )
    }

    // MARK: - Action-card reply rows

    /// The first human-message id in `channelId` that starts with `idPrefix`,
    /// in one critical section. The action-card DM-thread resolver uses it as
    /// the legacy `humanMessageRows.first` anchor lookup.
    func humanMessageId(channelId: String, idPrefix: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.humanMessageRows.first {
            $0.channelId == channelId && $0.id.hasPrefix(idPrefix)
        }?.id
    }

    /// Appends one mention row under the store lock.
    func appendMention(_ mention: StoredMention) {
        lock.lock()
        storage.storedMentions.append(mention)
        lock.unlock()
    }

    // MARK: - Message send: attachment URL and thread-follower undo ledger

    /// The row and the presigner `GET /api/attachments/:id/url` needs, read as
    /// one snapshot so the mime type and the injected presigner cannot come
    /// from two different configurations.
    struct AttachmentDownloadRecord {
        let attachment: ChannelAttachment
        let presign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)?
    }

    func attachmentDownloadRecord(attachmentId: String) -> AttachmentDownloadRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let attachment = storage.channelAttachments[attachmentId] else { return nil }
        return AttachmentDownloadRecord(attachment: attachment, presign: storage.attachmentPresign)
    }

    /// One message row by id, in one critical section.
    func humanMessageRow(id: String) -> StoredHumanMessage? {
        lock.lock()
        defer { lock.unlock() }
        return storage.humanMessageRows.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// The decision and the write of `DELETE …/threads/:threadId/followers/agents/:agentId`.
    enum ThreadFollowerRemovalWrite: Sendable, Equatable {
        /// A row for this thread/agent pair already exists; its token is returned.
        case replay(undoToken: String)
        /// This request inserted the row.
        case created(undoToken: String)
    }

    /// One locked critical section over the undo ledger: an existing removal for
    /// the thread/agent pair replays its token, otherwise `undoToken` is
    /// inserted. Two concurrent removals therefore issue exactly one token.
    func beginThreadFollowerRemoval(
        serverId: String,
        threadId: String,
        agentId: String,
        undoToken: String
    ) -> ThreadFollowerRemovalWrite {
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage.threadFollowerRemovals.first(where: {
            $0.value.threadChannelId == threadId && $0.value.agentId == agentId
        }) {
            return .replay(undoToken: existing.key)
        }
        storage.threadFollowerRemovals[undoToken] = (
            serverId: serverId,
            threadChannelId: threadId,
            agentId: agentId
        )
        return .created(undoToken: undoToken)
    }

    /// The decision and the write of the restore route.
    enum ThreadFollowerRestoreWrite: Sendable, Equatable {
        /// The token was live for this thread/agent pair and is now consumed.
        case restored
        /// Unknown, already consumed, or issued for another thread/agent pair.
        case notRemoved
    }

    /// One locked critical section: the token is consumed and marked stale
    /// together, so a token can restore at most once.
    func restoreThreadFollower(
        threadId: String,
        agentId: String,
        undoToken: String
    ) -> ThreadFollowerRestoreWrite {
        lock.lock()
        defer { lock.unlock() }
        guard let record = storage.threadFollowerRemovals[undoToken],
              record.threadChannelId == threadId,
              record.agentId == agentId
        else { return .notRemoved }
        storage.threadFollowerRemovals.removeValue(forKey: undoToken)
        storage.staleThreadFollowerUndoTokens.insert(undoToken)
        return .restored
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

// MARK: - Agent history reads (AgentHistoryService)

/// One locked read of an agent's unread position in a channel.
struct AgentUnreadPosition: Sendable, Equatable {
    var priorSeq: Int
    var settleMs: Int
    var pendingDeferred: Int?
}

/// The per-page facts a history row projects from the human message rows.
struct AgentHistoryAnnotations: Sendable {
    var external: [String: (messageId: String?, provider: String?, actor: String?)]
    var mentionedIds: Set<String>
}

extension MessagesAndThreadsStore {
    /// The agent's read cursor for one channel (0 before the first read).
    func agentReadSeq(channelId: String, agentId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
    }

    /// Cursor, settle window and any deferred advance, read together.
    func agentUnreadPosition(channelId: String, agentId: String) -> AgentUnreadPosition {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        return AgentUnreadPosition(
            priorSeq: storage.agentChannelReadCursors[key]?.seq ?? 0,
            settleMs: storage.readPositionSettleMs,
            pendingDeferred: storage.deferredUnreadAdvance[key]
        )
    }

    /// Moves the cursor to `seq` and bumps its version in one critical section.
    /// The history read writes the page maximum as given (no `max` against the
    /// previous value); callers decide whether the move is admissible.
    func setAgentReadCursor(channelId: String, agentId: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let version = storage.agentChannelReadCursors[key]?.version ?? 0
        storage.agentChannelReadCursors[key] = (seq, version + 1)
    }

    /// Settles a deferred advance: the cursor moves and the deferred mark is
    /// cleared in one critical section.
    func commitDeferredUnreadAdvance(channelId: String, agentId: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let version = storage.agentChannelReadCursors[key]?.version ?? 0
        storage.agentChannelReadCursors[key] = (seq, version + 1)
        storage.deferredUnreadAdvance.removeValue(forKey: key)
    }

    func clearDeferredUnreadAdvance(channelId: String, agentId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.deferredUnreadAdvance.removeValue(forKey: "\(channelId)\n\(agentId)")
    }

    func deferUnreadAdvance(channelId: String, agentId: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage.deferredUnreadAdvance["\(channelId)\n\(agentId)"] = seq
    }

    /// External-projection facts and agent mentions for one history page, from
    /// one snapshot of the rows.
    func historyAnnotations(messageIds: Set<String>, agentId: String) -> AgentHistoryAnnotations {
        lock.lock()
        defer { lock.unlock() }
        let external: [String: (messageId: String?, provider: String?, actor: String?)] = Dictionary(
            uniqueKeysWithValues: storage.humanMessageRows.filter { messageIds.contains($0.id) }.map {
                ($0.id, ($0.externalMessageId, $0.externalProvider, $0.externalSenderName))
            }
        )
        let mentioned = Set(
            storage.storedMentions
                .filter { $0.targetType == "agent" && $0.targetId == agentId }
                .map(\.messageId)
        )
        return AgentHistoryAnnotations(external: external, mentionedIds: mentioned)
    }
}

// MARK: - Human message create: mention rows, thread follows, forward commit

/// What a human mention-action resolution has to do to another store once the
/// mention row itself has been claimed.
enum MentionActionEffect: Sendable, Equatable {
    /// The agent target receives the message in its delivery ledger.
    case deliver(agentId: String, messageId: String)
    /// The agent target is added to the channel's agent roster and receives the message.
    case addAgent(channelId: String, agentId: String, messageId: String)
    /// The human target becomes a channel member.
    case addMember(channelId: String, userId: String)
}

/// One resolved id of a mention-action batch: the published result row and the
/// cross-store effects its claim implies.
struct MentionActionStep: Sendable, Equatable {
    var result: MentionActionResult
    var effects: [MentionActionEffect]
}

/// One outsider mention that needs a stored resolution row beside the message.
struct PendingMentionCandidate: Sendable, Equatable {
    var type: String
    var id: String
    var name: String
}

/// A mentioned member of a thread whose follow row the reply writes.
struct ThreadMentionFollowTarget: Sendable, Equatable {
    var userId: String
    /// Whether the parent channel lists the user as a member. A suppressed
    /// follow is reactivated only for a parent member.
    var isParentMember: Bool
}

extension MessagesAndThreadsStore {
    /// Resolution rows for the outsider mentions a send leaves pending, in one
    /// critical section: a mention that already has a row for this
    /// `(message, target)` reuses it, otherwise one row is appended. Two
    /// concurrent identical sends therefore cannot append two rows for one
    /// target.
    func resolvePendingMentionRows(
        messageId: String,
        channelId: String,
        candidates: [PendingMentionCandidate]
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var ids: [String] = []
        for candidate in candidates {
            if let existing = storage.storedMentions.first(where: {
                $0.messageId == messageId && $0.targetType == candidate.type && $0.targetId == candidate.id
            }) {
                ids.append(existing.id)
                continue
            }
            let id = UUID().uuidString.lowercased()
            let senderId = storage.humanMessageRows.first { $0.id == messageId }?.senderId ?? ""
            storage.storedMentions.append(StoredMention(
                id: id,
                messageId: messageId,
                channelId: channelId,
                senderId: senderId,
                targetType: candidate.type,
                targetId: candidate.id,
                handle: candidate.name,
                notifiableAtSend: false,
                notifiedAt: nil,
                notifiedByType: nil,
                notifiedById: nil,
                notifiedAction: nil
            ))
            ids.append(id)
        }
        return ids
    }

    /// The follow rows a thread reply writes, in one critical section: the
    /// sender's follow, then each mentioned member's follow. A mentioned member
    /// with an unfollow suppression row is reactivated only when `isParentMember`
    /// holds; otherwise the suppression stays and no follow is written.
    func applyThreadReplyFollows(
        serverId: String,
        threadChannelId: String,
        parentMessageId: String,
        senderId: String,
        mentioned: [ThreadMentionFollowTarget]
    ) {
        lock.lock()
        defer { lock.unlock() }
        func key(_ userId: String) -> String { "\(serverId)\n\(userId)\n\(threadChannelId)" }
        storage.threadFollows[key(senderId)] = (
            serverId: serverId,
            userId: senderId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId
        )
        for target in mentioned {
            if storage.threadUnfollows[key(target.userId)] != nil {
                guard target.isParentMember else { continue }
                storage.threadUnfollows.removeValue(forKey: key(target.userId))
            }
            storage.threadFollows[key(target.userId)] = (
                serverId: serverId,
                userId: target.userId,
                threadChannelId: threadChannelId,
                parentMessageId: parentMessageId
            )
        }
    }

    /// `POST /api/messages/mention-actions/execute`: every id of the batch is
    /// decided and claimed in one critical section. The decision closures are
    /// pure over snapshots the caller took beforehand, so no other store's lock
    /// is taken while this one is held.
    func applyUserMentionActions(
        ids: [String],
        action: String,
        userId: String,
        now: Date,
        inScope: (StoredMention) -> Bool,
        targetCanRead: (StoredMention) -> Bool,
        senderStillInChannel: (StoredMention) -> Bool
    ) -> [MentionActionStep] {
        lock.lock()
        defer { lock.unlock() }
        var steps: [MentionActionStep] = []
        for id in ids {
            guard let index = storage.storedMentions.firstIndex(where: { $0.id == id }),
                  inScope(storage.storedMentions[index]),
                  storage.storedMentions[index].senderId == userId
            else {
                steps.append(MentionActionStep(
                    result: MentionActionResult(resolutionId: id, action: action, status: "not_found"),
                    effects: []
                ))
                continue
            }
            let mention = storage.storedMentions[index]
            if action == "notify" {
                if !targetCanRead(mention) {
                    steps.append(MentionActionStep(
                        result: MentionActionResult(
                            resolutionId: id,
                            action: "notify",
                            status: "no_permission",
                            reason: "target_lacks_read_access"
                        ),
                        effects: []
                    ))
                    continue
                }
                var effects: [MentionActionEffect] = []
                if mention.notifiedAt == nil {
                    storage.storedMentions[index].notifiedAt = now
                    storage.storedMentions[index].notifiedByType = "user"
                    storage.storedMentions[index].notifiedById = userId
                    storage.storedMentions[index].notifiedAction = "notify_only"
                    if mention.targetType == "agent" {
                        effects.append(.deliver(agentId: mention.targetId, messageId: mention.messageId))
                    }
                }
                steps.append(MentionActionStep(
                    result: MentionActionResult(
                        resolutionId: id,
                        action: "notify",
                        status: "queued",
                        deduped: [id]
                    ),
                    effects: effects
                ))
            } else if mention.notifiedAction == "add" {
                steps.append(MentionActionStep(
                    result: MentionActionResult(
                        resolutionId: id,
                        action: "add",
                        status: "delivered",
                        reason: "already_delivered",
                        deduped: [id]
                    ),
                    effects: []
                ))
            } else if !senderStillInChannel(mention) {
                steps.append(MentionActionStep(
                    result: MentionActionResult(
                        resolutionId: id,
                        action: "add",
                        status: "no_permission",
                        reason: "sender_lacks_channel_access"
                    ),
                    effects: []
                ))
            } else {
                storage.storedMentions[index].notifiedAt = now
                storage.storedMentions[index].notifiedByType = "user"
                storage.storedMentions[index].notifiedById = userId
                storage.storedMentions[index].notifiedAction = "add"
                let effect: MentionActionEffect = mention.targetType == "agent"
                    ? .addAgent(channelId: mention.channelId, agentId: mention.targetId, messageId: mention.messageId)
                    : .addMember(channelId: mention.channelId, userId: mention.targetId)
                steps.append(MentionActionStep(
                    result: MentionActionResult(
                        resolutionId: id,
                        action: "add",
                        status: "delivered",
                        deduped: [id]
                    ),
                    effects: [effect]
                ))
            }
        }
        return steps
    }

    /// `POST /internal/agent-api/mention-actions/execute`: the batch for one
    /// agent in one critical section. A `notify` marks every still-unnotified
    /// row of the same `(message, target)` and reports the deduplicated ids.
    func applyAgentMentionActions(
        ids: [String],
        action: String,
        agentId: String,
        now: Date,
        inScope: (StoredMention) -> Bool,
        targetCanRead: (StoredMention) -> Bool,
        senderStillInChannel: (StoredMention) -> Bool
    ) -> [MentionActionResult] {
        lock.lock()
        defer { lock.unlock() }
        var results: [MentionActionResult] = []
        for id in ids {
            guard let index = storage.storedMentions.firstIndex(where: { $0.id == id }),
                  storage.storedMentions[index].senderId == agentId,
                  inScope(storage.storedMentions[index]),
                  storage.humanMessageRows.contains(where: { $0.id == storage.storedMentions[index].messageId })
            else {
                results.append(MentionActionResult(resolutionId: id, action: action, status: "not_found"))
                continue
            }
            let mention = storage.storedMentions[index]
            if action == "notify" {
                guard targetCanRead(mention) else {
                    results.append(MentionActionResult(
                        resolutionId: id,
                        action: "notify",
                        status: "no_permission",
                        reason: "target_lacks_read_access"
                    ))
                    continue
                }
                var deduped = [id]
                for other in storage.storedMentions.indices
                where storage.storedMentions[other].messageId == mention.messageId
                    && storage.storedMentions[other].targetType == mention.targetType
                    && storage.storedMentions[other].targetId == mention.targetId
                    && storage.storedMentions[other].notifiedAt == nil {
                    storage.storedMentions[other].notifiedAt = now
                    storage.storedMentions[other].notifiedByType = "agent"
                    storage.storedMentions[other].notifiedById = agentId
                    storage.storedMentions[other].notifiedAction = "notify_only"
                    if storage.storedMentions[other].id != id { deduped.append(storage.storedMentions[other].id) }
                }
                results.append(MentionActionResult(
                    resolutionId: id,
                    action: "notify",
                    status: "queued",
                    deduped: deduped
                ))
            } else if senderStillInChannel(mention) {
                results.append(MentionActionResult(
                    resolutionId: id,
                    action: "add",
                    status: "no_permission",
                    reason: "add_requires_human_member_authority"
                ))
            } else {
                results.append(MentionActionResult(
                    resolutionId: id,
                    action: "add",
                    status: "no_permission",
                    reason: "sender_lacks_channel_access"
                ))
            }
        }
        return results
    }

    /// The forward commit: the bundle metadata, the forward record, the
    /// projected attachment ids on the message row and the attachment copies
    /// land together. Returns the message row as the destination publishes it,
    /// or nil when the row is gone.
    func commitForward(
        messageId: String,
        bundle: [EmailLoginDirectory.ForwardedSource],
        record: StoredForwardRecord,
        projections: [(attachment: ChannelAttachment, id: String, position: Int)],
        destinationChannelId: String
    ) -> StoredHumanMessage? {
        lock.lock()
        defer { lock.unlock() }
        storage.forwardedBundles[messageId] = bundle
        storage.forwardRecords[messageId] = record
        if let index = storage.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            storage.humanMessageRows[index].attachmentIds = projections.map(\.id)
        }
        for projection in projections {
            var copy = projection.attachment
            copy.id = projection.id
            copy.channelId = destinationChannelId
            copy.messageId = messageId
            copy.messagePosition = projection.position
            storage.channelAttachments[copy.id] = copy
        }
        guard var message = storage.humanMessageRows.first(where: { $0.id == messageId }) else { return nil }
        message.channelId = destinationChannelId
        return message
    }
}

extension MessagesAndThreadsStore {
    /// Stores one uploaded file row. The row carries its final uploader type, so
    /// no reader can observe an agent upload as a user upload.
    func insertAttachment(_ attachment: ChannelAttachment) {
        lock.lock()
        storage.channelAttachments[attachment.id] = attachment
        lock.unlock()
    }
}
