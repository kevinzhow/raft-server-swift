import Foundation
import RaftObjectStorage

extension MessagesAndThreadsStore {
    /// Captures this owner once. Cross-owner consistency belongs to the caller.
    /// Encoding and record conversion run after the original lock is released.
    func exportPersistenceData() throws -> Data {
        let captured = withState { $0 }
        return try MessagingPersistenceFormat.encode(
            MessagingPersistenceMessagesSnapshot(captured), owner: MessagingPersistenceMessagesSnapshot.owner
        )
    }

    /// Decode, version validation and all record conversion finish before lock
    /// acquisition. Assign only business fields on this same store instance.
    func restorePersistenceData(from data: Data) throws {
        let payload = try MessagingPersistenceFormat.decode(
            MessagingPersistenceMessagesSnapshot.self, from: data, owner: MessagingPersistenceMessagesSnapshot.owner
        )
        let replacement = payload.makeState()
        withState { state in
            state.humanMessageRows = replacement.humanMessageRows
            state.channelAttachments = replacement.channelAttachments
            state.attachmentObjectReferences = replacement.attachmentObjectReferences
            state.forwardedBundles = replacement.forwardedBundles
            state.forwardRecords = replacement.forwardRecords
            state.messageReactions = replacement.messageReactions
            state.reactionViewerVersions = replacement.reactionViewerVersions
            state.reactionDiscussionVersions = replacement.reactionDiscussionVersions
            state.storedMentions = replacement.storedMentions
            state.attachmentCommentRecords = replacement.attachmentCommentRecords
            state.messageTranslationLedger = replacement.messageTranslationLedger
            state.readMutationRecords = replacement.readMutationRecords
            state.readMutationAuthoritySeq = replacement.readMutationAuthoritySeq
            state.readMutationOrder = replacement.readMutationOrder
            state.readMutationAcks = replacement.readMutationAcks
            state.userChannelReadCursors = replacement.userChannelReadCursors
            state.shareArtifacts = replacement.shareArtifacts
            state.systemAttentionIncidents = replacement.systemAttentionIncidents
            state.systemAttentionReceipts = replacement.systemAttentionReceipts
            state.threadFollows = replacement.threadFollows
            state.threadUnfollows = replacement.threadUnfollows
            state.threadFollowStarts = replacement.threadFollowStarts
            state.threadFollowerRemovals = replacement.threadFollowerRemovals
            state.staleThreadFollowerUndoTokens = replacement.staleThreadFollowerUndoTokens
            state.channelReadVersions = replacement.channelReadVersions
            state.agentChannelReadCursors = replacement.agentChannelReadCursors
            state.attestedSendEventRecords = replacement.attestedSendEventRecords
            state.agentSendActivityRecords = replacement.agentSendActivityRecords
            state.inboxDoneScopes = replacement.inboxDoneScopes
            state.inboxDoneAt = replacement.inboxDoneAt
            state.inboxDoneFrontiers = replacement.inboxDoneFrontiers
            state.inboxResidues = replacement.inboxResidues
            state.deferredUnreadAdvance = replacement.deferredUnreadAdvance
            state.externalAvatarAssets = replacement.externalAvatarAssets
        }
    }
}

/// Complete business partition of MessagesAndThreadsStore.State (33 fields).
/// Excluded and preserved during restore: externalAvatarStorageAvailable
/// (live storage availability), translationProviderOverride, attachmentPreviewBody,
/// attachmentPresign, readPositionSettleMs, sendFreshnessModeOverride and
/// realtimeEmitterStorage. No observers, relay or policy closures are persisted.
private struct MessagingPersistenceMessagesSnapshot: Codable, Sendable {
    static let owner = "messages-and-threads"

    let humanMessageRows: [MessagingPersistenceStoredHumanMessageDTO]
    let channelAttachments: [String: MessagingPersistenceChannelAttachmentDTO]
    let attachmentObjectReferences: [String: AttachmentObjectReference]?
    let forwardedBundles: [String: [MessagingPersistenceForwardedSourceDTO]]
    let forwardRecords: [String: MessagingPersistenceStoredForwardRecordDTO]
    let messageReactions: [MessagingPersistenceStoredReactionDTO]
    let reactionViewerVersions: [String: Int]
    let reactionDiscussionVersions: [String: Int]
    let storedMentions: [MessagingPersistenceStoredMentionDTO]
    let attachmentCommentRecords: [String: [MessagingPersistenceAttachmentCommentRecordDTO]]
    let messageTranslationLedger: [String: MessagingPersistenceTranslationDTO]
    let readMutationRecords: [String: MessagingPersistenceReadMutationRecordDTO]
    let readMutationAuthoritySeq: [String: Int]
    let readMutationOrder: [String]
    let readMutationAcks: [String: MessagingPersistenceReadAckDTO]
    let userChannelReadCursors: [String: Int]
    let shareArtifacts: [String: MessagingPersistenceShareArtifactRecordDTO]
    let systemAttentionIncidents: [MessagingPersistenceSystemAttentionIncidentDTO]
    let systemAttentionReceipts: [String: MessagingPersistenceSystemAttentionReceiptDTO]
    let threadFollows: [String: MessagingPersistenceUserThreadFollowDTO]
    let threadUnfollows: [String: MessagingPersistenceThreadUnfollowRecordDTO]
    let threadFollowStarts: [String: MessagingPersistenceDateBits]
    let threadFollowerRemovals: [String: MessagingPersistenceFollowerRemovalDTO]
    let staleThreadFollowerUndoTokens: Set<String>
    let channelReadVersions: [String: Int]
    let agentChannelReadCursors: [String: MessagingPersistenceAgentReadCursorDTO]
    let attestedSendEventRecords: [MessagingPersistenceAttestedSendEventRecordDTO]
    let agentSendActivityRecords: [String: [MessagingPersistenceAgentActivityDTO]]
    let inboxDoneScopes: Set<String>
    let inboxDoneAt: [String: MessagingPersistenceDateBits]
    let inboxDoneFrontiers: [String: Int]
    let inboxResidues: Set<String>
    let deferredUnreadAdvance: [String: Int]
    let externalAvatarAssets: [String: MessagingPersistenceExternalAvatarAssetDTO]

    init(_ state: MessagesAndThreadsStore.State) {
        humanMessageRows = state.humanMessageRows.map(MessagingPersistenceStoredHumanMessageDTO.init)
        channelAttachments = state.channelAttachments.mapValues(MessagingPersistenceChannelAttachmentDTO.init)
        attachmentObjectReferences = state.attachmentObjectReferences
        forwardedBundles = state.forwardedBundles.mapValues { $0.map(MessagingPersistenceForwardedSourceDTO.init) }
        forwardRecords = state.forwardRecords.mapValues(MessagingPersistenceStoredForwardRecordDTO.init)
        messageReactions = state.messageReactions.map(MessagingPersistenceStoredReactionDTO.init)
        reactionViewerVersions = state.reactionViewerVersions
        reactionDiscussionVersions = state.reactionDiscussionVersions
        storedMentions = state.storedMentions.map(MessagingPersistenceStoredMentionDTO.init)
        attachmentCommentRecords = state.attachmentCommentRecords.mapValues { $0.map(MessagingPersistenceAttachmentCommentRecordDTO.init) }
        messageTranslationLedger = state.messageTranslationLedger.mapValues(MessagingPersistenceTranslationDTO.init)
        readMutationRecords = state.readMutationRecords.mapValues(MessagingPersistenceReadMutationRecordDTO.init)
        readMutationAuthoritySeq = state.readMutationAuthoritySeq
        readMutationOrder = state.readMutationOrder
        readMutationAcks = state.readMutationAcks.mapValues(MessagingPersistenceReadAckDTO.init)
        userChannelReadCursors = state.userChannelReadCursors
        shareArtifacts = state.shareArtifacts.mapValues(MessagingPersistenceShareArtifactRecordDTO.init)
        systemAttentionIncidents = state.systemAttentionIncidents.map(MessagingPersistenceSystemAttentionIncidentDTO.init)
        systemAttentionReceipts = state.systemAttentionReceipts.mapValues(MessagingPersistenceSystemAttentionReceiptDTO.init)
        threadFollows = state.threadFollows.mapValues(MessagingPersistenceUserThreadFollowDTO.init)
        threadUnfollows = state.threadUnfollows.mapValues(MessagingPersistenceThreadUnfollowRecordDTO.init)
        threadFollowStarts = state.threadFollowStarts.mapValues(MessagingPersistenceDateBits.init)
        threadFollowerRemovals = state.threadFollowerRemovals.mapValues(MessagingPersistenceFollowerRemovalDTO.init)
        staleThreadFollowerUndoTokens = state.staleThreadFollowerUndoTokens
        channelReadVersions = state.channelReadVersions
        agentChannelReadCursors = state.agentChannelReadCursors.mapValues(MessagingPersistenceAgentReadCursorDTO.init)
        attestedSendEventRecords = state.attestedSendEventRecords.map(MessagingPersistenceAttestedSendEventRecordDTO.init)
        agentSendActivityRecords = state.agentSendActivityRecords.mapValues { $0.map(MessagingPersistenceAgentActivityDTO.init) }
        inboxDoneScopes = state.inboxDoneScopes
        inboxDoneAt = state.inboxDoneAt.mapValues(MessagingPersistenceDateBits.init)
        inboxDoneFrontiers = state.inboxDoneFrontiers
        inboxResidues = state.inboxResidues
        deferredUnreadAdvance = state.deferredUnreadAdvance
        externalAvatarAssets = state.externalAvatarAssets.mapValues(MessagingPersistenceExternalAvatarAssetDTO.init)
    }

    func makeState() -> MessagesAndThreadsStore.State {
        var restored = MessagesAndThreadsStore.State()
        restored.humanMessageRows = humanMessageRows.map(\.value)
        restored.channelAttachments = channelAttachments.mapValues(\.value)
        restored.attachmentObjectReferences = attachmentObjectReferences ?? [:]
        restored.forwardedBundles = forwardedBundles.mapValues { $0.map(\.value) }
        restored.forwardRecords = forwardRecords.mapValues(\.value)
        restored.messageReactions = messageReactions.map(\.value)
        restored.reactionViewerVersions = reactionViewerVersions
        restored.reactionDiscussionVersions = reactionDiscussionVersions
        restored.storedMentions = storedMentions.map(\.value)
        restored.attachmentCommentRecords = attachmentCommentRecords.mapValues { $0.map(\.value) }
        restored.messageTranslationLedger = messageTranslationLedger.mapValues(\.value)
        restored.readMutationRecords = readMutationRecords.mapValues(\.value)
        restored.readMutationAuthoritySeq = readMutationAuthoritySeq
        restored.readMutationOrder = readMutationOrder
        restored.readMutationAcks = readMutationAcks.mapValues(\.value)
        restored.userChannelReadCursors = userChannelReadCursors
        restored.shareArtifacts = shareArtifacts.mapValues(\.value)
        restored.systemAttentionIncidents = systemAttentionIncidents.map(\.value)
        restored.systemAttentionReceipts = systemAttentionReceipts.mapValues(\.value)
        restored.threadFollows = threadFollows.mapValues(\.value)
        restored.threadUnfollows = threadUnfollows.mapValues(\.value)
        restored.threadFollowStarts = threadFollowStarts.mapValues(\.value)
        restored.threadFollowerRemovals = threadFollowerRemovals.mapValues(\.value)
        restored.staleThreadFollowerUndoTokens = staleThreadFollowerUndoTokens
        restored.channelReadVersions = channelReadVersions
        restored.agentChannelReadCursors = agentChannelReadCursors.mapValues(\.value)
        restored.attestedSendEventRecords = attestedSendEventRecords.map(\.value)
        restored.agentSendActivityRecords = agentSendActivityRecords.mapValues { $0.map(\.value) }
        restored.inboxDoneScopes = inboxDoneScopes
        restored.inboxDoneAt = inboxDoneAt.mapValues(\.value)
        restored.inboxDoneFrontiers = inboxDoneFrontiers
        restored.inboxResidues = inboxResidues
        restored.deferredUnreadAdvance = deferredUnreadAdvance
        restored.externalAvatarAssets = externalAvatarAssets.mapValues(\.value)
        return restored
    }
}
