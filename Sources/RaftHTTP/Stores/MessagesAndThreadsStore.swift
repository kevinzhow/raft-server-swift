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
}
