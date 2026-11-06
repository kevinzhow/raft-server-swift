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
}
