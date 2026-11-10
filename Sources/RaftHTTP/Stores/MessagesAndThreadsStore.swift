import Foundation
import RaftObjectStorage
import Synchronization
import RaftShared

/// Owns the human-message, reaction, mention, read-frontier, thread-follow and
/// attachment-comment rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class MessagesAndThreadsStore: Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State: Sendable {
        var humanMessageRows: [StoredHumanMessage] = []
        var channelAttachments: [String: ChannelAttachment] = [:]
        var attachmentObjectReferences: [String: AttachmentObjectReference] = [:]
        // Development bytes and live I/O configuration are transient. Production
        // requires the configured object store and persists only its references.
        var developmentAttachmentBytes: [String: Data] = [:]
        var attachmentObjectStorage: (any AttachmentObjectStoring)? = nil
        var requiresDurableAttachmentStorage = false
        var forwardedBundles: [String: [ForwardedSource]] = [:]
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
        /// The room-membership grant the human-send path applies before a new
        /// DM's first `message:new` frame.
        var realtimeRoomJoinerStorage: (@Sendable (String, String) -> Void)? = nil
    }

    private let stateStorage = TransactionalState(State())

    /// A whole-store value snapshot. Mutations of several rows use `withState`.
    var state: State {
        get { withState { $0 } }
        set { withState { $0 = newValue } }
    }

    /// One transaction over the owned state. Callbacks must not reenter this
    /// store; helpers called inside a transaction take its state explicitly.
    func withState<Result>(_ body: (inout State) -> Result) -> Result {
        stateStorage.withLock { state in body(&state) }
    }

    var humanMessageRows: [StoredHumanMessage] {
        get { withState { $0.humanMessageRows } }
        set { withState { $0.humanMessageRows = newValue } }
    }

    var channelAttachments: [String: ChannelAttachment] {
        get { withState { $0.channelAttachments } }
        set { withState { $0.channelAttachments = newValue } }
    }

    var forwardedBundles: [String: [ForwardedSource]] {
        get { withState { $0.forwardedBundles } }
        set { withState { $0.forwardedBundles = newValue } }
    }

    var forwardRecords: [String: StoredForwardRecord] {
        get { withState { $0.forwardRecords } }
        set { withState { $0.forwardRecords = newValue } }
    }

    var messageReactions: [StoredReaction] {
        get { withState { $0.messageReactions } }
        set { withState { $0.messageReactions = newValue } }
    }

    var reactionViewerVersions: [String: Int] {
        get { withState { $0.reactionViewerVersions } }
        set { withState { $0.reactionViewerVersions = newValue } }
    }

    var reactionDiscussionVersions: [String: Int] {
        get { withState { $0.reactionDiscussionVersions } }
        set { withState { $0.reactionDiscussionVersions = newValue } }
    }

    var storedMentions: [StoredMention] {
        get { withState { $0.storedMentions } }
        set { withState { $0.storedMentions = newValue } }
    }

    var attachmentCommentRecords: [String: [AttachmentCommentRecord]] {
        get { withState { $0.attachmentCommentRecords } }
        set { withState { $0.attachmentCommentRecords = newValue } }
    }

    var messageTranslationLedger: [String: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)] {
        get { withState { $0.messageTranslationLedger } }
        set { withState { $0.messageTranslationLedger = newValue } }
    }

    var readMutationRecords: [String: ReadMutationRecord] {
        get { withState { $0.readMutationRecords } }
        set { withState { $0.readMutationRecords = newValue } }
    }

    var readMutationAuthoritySeq: [String: Int] {
        get { withState { $0.readMutationAuthoritySeq } }
        set { withState { $0.readMutationAuthoritySeq = newValue } }
    }

    var readMutationOrder: [String] {
        get { withState { $0.readMutationOrder } }
        set { withState { $0.readMutationOrder = newValue } }
    }

    var readMutationAcks: [String: (scopeId: String, throughSeq: Int)] {
        get { withState { $0.readMutationAcks } }
        set { withState { $0.readMutationAcks = newValue } }
    }

    var userChannelReadCursors: [String: Int] {
        get { withState { $0.userChannelReadCursors } }
        set { withState { $0.userChannelReadCursors = newValue } }
    }

    var shareArtifacts: [String: ShareArtifactRecord] {
        get { withState { $0.shareArtifacts } }
        set { withState { $0.shareArtifacts = newValue } }
    }

    var systemAttentionIncidents: [SystemAttentionIncident] {
        get { withState { $0.systemAttentionIncidents } }
        set { withState { $0.systemAttentionIncidents = newValue } }
    }

    var systemAttentionReceipts: [String: SystemAttentionReceipt] {
        get { withState { $0.systemAttentionReceipts } }
        set { withState { $0.systemAttentionReceipts = newValue } }
    }

    var threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)] {
        get { withState { $0.threadFollows } }
        set { withState { $0.threadFollows = newValue } }
    }

    var threadUnfollows: [String: ThreadUnfollowRecord] {
        get { withState { $0.threadUnfollows } }
        set { withState { $0.threadUnfollows = newValue } }
    }

    var threadFollowStarts: [String: Date] {
        get { withState { $0.threadFollowStarts } }
        set { withState { $0.threadFollowStarts = newValue } }
    }

    var threadFollowerRemovals: [String: (serverId: String, threadChannelId: String, agentId: String)] {
        get { withState { $0.threadFollowerRemovals } }
        set { withState { $0.threadFollowerRemovals = newValue } }
    }

    var staleThreadFollowerUndoTokens: Set<String> {
        get { withState { $0.staleThreadFollowerUndoTokens } }
        set { withState { $0.staleThreadFollowerUndoTokens = newValue } }
    }

    var channelReadVersions: [String: Int] {
        get { withState { $0.channelReadVersions } }
        set { withState { $0.channelReadVersions = newValue } }
    }

    var agentChannelReadCursors: [String: (seq: Int, version: Int)] {
        get { withState { $0.agentChannelReadCursors } }
        set { withState { $0.agentChannelReadCursors = newValue } }
    }

    var attestedSendEventRecords: [AttestedSendEventRecord] {
        get { withState { $0.attestedSendEventRecords } }
        set { withState { $0.attestedSendEventRecords = newValue } }
    }

    var agentSendActivityRecords: [String: [(title: String, text: String, producerFactId: String?)]] {
        get { withState { $0.agentSendActivityRecords } }
        set { withState { $0.agentSendActivityRecords = newValue } }
    }

    var inboxDoneScopes: Set<String> {
        get { withState { $0.inboxDoneScopes } }
        set { withState { $0.inboxDoneScopes = newValue } }
    }

    var inboxDoneAt: [String: Date] {
        get { withState { $0.inboxDoneAt } }
        set { withState { $0.inboxDoneAt = newValue } }
    }

    var inboxDoneFrontiers: [String: Int] {
        get { withState { $0.inboxDoneFrontiers } }
        set { withState { $0.inboxDoneFrontiers = newValue } }
    }

    var inboxResidues: Set<String> {
        get { withState { $0.inboxResidues } }
        set { withState { $0.inboxResidues = newValue } }
    }

    var deferredUnreadAdvance: [String: Int] {
        get { withState { $0.deferredUnreadAdvance } }
        set { withState { $0.deferredUnreadAdvance = newValue } }
    }

    var externalAvatarAssets: [String: ExternalAvatarAsset] {
        get { withState { $0.externalAvatarAssets } }
        set { withState { $0.externalAvatarAssets = newValue } }
    }

    var externalAvatarStorageAvailable: Bool {
        get { withState { $0.externalAvatarStorageAvailable } }
        set { withState { $0.externalAvatarStorageAvailable = newValue } }
    }

    // MARK: - Injected messaging configuration

    var translationProviderOverride: String? {
        get { withState { $0.translationProviderOverride } }
        set { withState { $0.translationProviderOverride = newValue } }
    }

    var attachmentPreviewBody: (@Sendable (_ attachmentId: String) -> String?)? {
        get { withState { $0.attachmentPreviewBody } }
        set { withState { $0.attachmentPreviewBody = newValue } }
    }

    var attachmentPresign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)? {
        get { withState { $0.attachmentPresign } }
        set { withState { $0.attachmentPresign = newValue } }
    }

    var readPositionSettleMs: Int {
        get { withState { $0.readPositionSettleMs } }
        set { withState { $0.readPositionSettleMs = newValue } }
    }

    var sendFreshnessModeOverride: String? {
        get { withState { $0.sendFreshnessModeOverride } }
        set { withState { $0.sendFreshnessModeOverride = newValue } }
    }

    var realtimeEmitterStorage: (@Sendable (String, String, String?) -> Void)? {
        get { withState { $0.realtimeEmitterStorage } }
        set { withState { $0.realtimeEmitterStorage = newValue } }
    }

    var realtimeRoomJoinerStorage: (@Sendable (String, String) -> Void)? {
        get { withState { $0.realtimeRoomJoinerStorage } }
        set { withState { $0.realtimeRoomJoinerStorage = newValue } }
    }
}
