import Foundation

// Private persistence representations, not Codable conformances on shared records.
// Every stored record field has an explicit forward and reverse mapping.

struct MessagingPersistenceForwardItemRecordDTO: Codable, Sendable {
    let sourceMessageId: String
    let exposesPointers: Bool
    let sourceAuthorUniqueName: String
    let sourceIsThreadParent: Bool
    let contentSnapshot: String
    let sourceTargetId: String?
    let sourceThreadId: String?
    let parentChannelId: String?
    let snapshotId: String?
    let snapshotType: String
    let snapshotLabel: String
    let snapshotLabelVisibility: String
    let provenanceState: String
    let attachments: [MessagingPersistenceForwardAttachmentSnapshotDTO]
    let attachmentPolicy: String

    init(_ row: ForwardItemRecord) {
        sourceMessageId = row.sourceMessageId
        exposesPointers = row.exposesPointers
        sourceAuthorUniqueName = row.sourceAuthorUniqueName
        sourceIsThreadParent = row.sourceIsThreadParent
        contentSnapshot = row.contentSnapshot
        sourceTargetId = row.sourceTargetId
        sourceThreadId = row.sourceThreadId
        parentChannelId = row.parentChannelId
        snapshotId = row.snapshotId
        snapshotType = row.snapshotType
        snapshotLabel = row.snapshotLabel
        snapshotLabelVisibility = row.snapshotLabelVisibility
        provenanceState = row.provenanceState
        attachments = row.attachments.map(MessagingPersistenceForwardAttachmentSnapshotDTO.init)
        attachmentPolicy = row.attachmentPolicy
    }

    var value: ForwardItemRecord {
        ForwardItemRecord(
            sourceMessageId: sourceMessageId,
            exposesPointers: exposesPointers,
            sourceAuthorUniqueName: sourceAuthorUniqueName,
            sourceIsThreadParent: sourceIsThreadParent,
            contentSnapshot: contentSnapshot,
            sourceTargetId: sourceTargetId,
            sourceThreadId: sourceThreadId,
            parentChannelId: parentChannelId,
            snapshotId: snapshotId,
            snapshotType: snapshotType,
            snapshotLabel: snapshotLabel,
            snapshotLabelVisibility: snapshotLabelVisibility,
            provenanceState: provenanceState,
            attachments: attachments.map(\.value),
            attachmentPolicy: attachmentPolicy
        )
    }
}

struct MessagingPersistenceForwardAttachmentSnapshotDTO: Codable, Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let width: Int?
    let height: Int?

    init(_ row: ForwardAttachmentSnapshot) {
        id = row.id
        filename = row.filename
        mimeType = row.mimeType
        sizeBytes = row.sizeBytes
        width = row.width
        height = row.height
    }

    var value: ForwardAttachmentSnapshot {
        ForwardAttachmentSnapshot(
            id: id,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            width: width,
            height: height
        )
    }
}

struct MessagingPersistenceAgentThreadFollowRecordDTO: Codable, Sendable {
    let serverId: String
    let agentId: String
    let threadChannelId: String
    let parentMessageId: String
    let followedAt: MessagingPersistenceDateBits
    let reason: String
    let doneAt: MessagingPersistenceDateBits?
    let unfollowedAt: MessagingPersistenceDateBits?

    init(_ row: AgentThreadFollowRecord) {
        serverId = row.serverId
        agentId = row.agentId
        threadChannelId = row.threadChannelId
        parentMessageId = row.parentMessageId
        followedAt = MessagingPersistenceDateBits(row.followedAt)
        reason = row.reason
        doneAt = row.doneAt.map(MessagingPersistenceDateBits.init)
        unfollowedAt = row.unfollowedAt.map(MessagingPersistenceDateBits.init)
    }

    var value: AgentThreadFollowRecord {
        AgentThreadFollowRecord(
            serverId: serverId,
            agentId: agentId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            followedAt: followedAt.value,
            reason: reason,
            doneAt: doneAt?.value,
            unfollowedAt: unfollowedAt?.value
        )
    }
}

struct MessagingPersistenceAttachmentCommentRecordDTO: Codable, Sendable {
    let id: String
    let attachmentId: String
    let content: String
    let anchorJSON: String?
    let senderId: String
    let senderType: String
    let createdAt: MessagingPersistenceDateBits
    let threadChannelId: String?
    let hostMessageId: String?
    let hostChannelId: String?

    init(_ row: AttachmentCommentRecord) {
        id = row.id
        attachmentId = row.attachmentId
        content = row.content
        anchorJSON = row.anchorJSON
        senderId = row.senderId
        senderType = row.senderType
        createdAt = MessagingPersistenceDateBits(row.createdAt)
        threadChannelId = row.threadChannelId
        hostMessageId = row.hostMessageId
        hostChannelId = row.hostChannelId
    }

    var value: AttachmentCommentRecord {
        AttachmentCommentRecord(
            id: id,
            attachmentId: attachmentId,
            content: content,
            anchorJSON: anchorJSON,
            senderId: senderId,
            senderType: senderType,
            createdAt: createdAt.value,
            threadChannelId: threadChannelId,
            hostMessageId: hostMessageId,
            hostChannelId: hostChannelId
        )
    }
}

struct MessagingPersistenceForwardedSourceDTO: Codable, Sendable {
    let sourceServerId: String
    let sourceTargetId: String
    let sourceMessageId: String
    let snapshotId: String
    let snapshotType: String
    let snapshotLabel: String
    let snapshotLabelVisibility: String
    let provenanceState: String

    init(_ row: ForwardedSource) {
        sourceServerId = row.sourceServerId
        sourceTargetId = row.sourceTargetId
        sourceMessageId = row.sourceMessageId
        snapshotId = row.snapshotId
        snapshotType = row.snapshotType
        snapshotLabel = row.snapshotLabel
        snapshotLabelVisibility = row.snapshotLabelVisibility
        provenanceState = row.provenanceState
    }

    var value: ForwardedSource {
        ForwardedSource(
            sourceServerId: sourceServerId,
            sourceTargetId: sourceTargetId,
            sourceMessageId: sourceMessageId,
            snapshotId: snapshotId,
            snapshotType: snapshotType,
            snapshotLabel: snapshotLabel,
            snapshotLabelVisibility: snapshotLabelVisibility,
            provenanceState: provenanceState
        )
    }
}

struct MessagingPersistenceAttestedSendEventRecordDTO: Codable, Sendable {
    let eventType: String
    let agentId: String
    let messageId: String?
    let metadataJSON: String
    /// Added with the legacy attested-send columns; older snapshots omit it.
    let newMessageCount: Int?
    /// Added with the legacy attested-send columns; older snapshots omit it.
    let result: String?

    init(_ row: AttestedSendEventRecord) {
        eventType = row.eventType
        agentId = row.agentId
        messageId = row.messageId
        metadataJSON = row.metadataJSON
        newMessageCount = row.newMessageCount
        result = row.result
    }

    private enum CodingKeys: String, CodingKey {
        case eventType, agentId, messageId, metadataJSON, newMessageCount, result
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try values.decode(String.self, forKey: .eventType)
        agentId = try values.decode(String.self, forKey: .agentId)
        messageId = try values.decodeIfPresent(String.self, forKey: .messageId)
        metadataJSON = try values.decode(String.self, forKey: .metadataJSON)
        newMessageCount = try values.decodeIfPresent(Int.self, forKey: .newMessageCount)
        result = try values.decodeIfPresent(String.self, forKey: .result)
    }

    var value: AttestedSendEventRecord {
        AttestedSendEventRecord(
            eventType: eventType,
            agentId: agentId,
            messageId: messageId,
            metadataJSON: metadataJSON,
            newMessageCount: newMessageCount,
            result: result
        )
    }
}

struct MessagingPersistenceThreadUnfollowRecordDTO: Codable, Sendable {
    let serverId: String
    let userId: String
    let threadChannelId: String
    let parentMessageId: String
    let unfollowedAt: MessagingPersistenceDateBits
    let latestMessageId: String
    let replyCount: Int
    let frozenMessages: [MessagingPersistenceFrozenMessageDTO]

    init(_ row: ThreadUnfollowRecord) {
        serverId = row.serverId
        userId = row.userId
        threadChannelId = row.threadChannelId
        parentMessageId = row.parentMessageId
        unfollowedAt = MessagingPersistenceDateBits(row.unfollowedAt)
        latestMessageId = row.latestMessageId
        replyCount = row.replyCount
        frozenMessages = row.frozenMessages.map(MessagingPersistenceFrozenMessageDTO.init)
    }

    var value: ThreadUnfollowRecord {
        ThreadUnfollowRecord(
            serverId: serverId,
            userId: userId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            unfollowedAt: unfollowedAt.value,
            latestMessageId: latestMessageId,
            replyCount: replyCount,
            frozenMessages: frozenMessages.map(\.value)
        )
    }
}

struct MessagingPersistenceShareArtifactRecordDTO: Codable, Sendable {
    let bytes: Data
    let width: Int
    let height: Int
    let serverId: String
    let createdAt: MessagingPersistenceDateBits

    init(_ row: ShareArtifactRecord) {
        bytes = row.bytes
        width = row.width
        height = row.height
        serverId = row.serverId
        createdAt = MessagingPersistenceDateBits(row.createdAt)
    }

    var value: ShareArtifactRecord {
        ShareArtifactRecord(
            bytes: bytes,
            width: width,
            height: height,
            serverId: serverId,
            createdAt: createdAt.value
        )
    }
}

struct MessagingPersistenceReadMutationRecordDTO: Codable, Sendable {
    let mutationId: String
    let serverId: String
    let principalId: String
    let kind: String
    let scopeId: String?
    let fingerprint: String
    let authoritySeq: Int
    let state: String

    init(_ row: ReadMutationRecord) {
        mutationId = row.mutationId
        serverId = row.serverId
        principalId = row.principalId
        kind = row.kind
        scopeId = row.scopeId
        fingerprint = row.fingerprint
        authoritySeq = row.authoritySeq
        state = row.state
    }

    var value: ReadMutationRecord {
        ReadMutationRecord(
            mutationId: mutationId,
            serverId: serverId,
            principalId: principalId,
            kind: kind,
            scopeId: scopeId,
            fingerprint: fingerprint,
            authoritySeq: authoritySeq,
            state: state
        )
    }
}

struct MessagingPersistenceStoredInboxFactDTO: Codable, Sendable {
    let messageId: String
    let receiverType: String
    let receiverId: String
    let channelId: String?
    let serverId: String?
    let personalMention: Bool
    let unreadEligible: Bool

    init(_ row: StoredInboxFact) {
        messageId = row.messageId
        receiverType = row.receiverType
        receiverId = row.receiverId
        channelId = row.channelId
        serverId = row.serverId
        personalMention = row.personalMention
        unreadEligible = row.unreadEligible
    }

    var value: StoredInboxFact {
        StoredInboxFact(
            messageId: messageId,
            receiverType: receiverType,
            receiverId: receiverId,
            channelId: channelId,
            serverId: serverId,
            personalMention: personalMention,
            unreadEligible: unreadEligible
        )
    }
}
