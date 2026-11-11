import Foundation

// Private persistence representations, not Codable conformances on shared records.
// Every stored record field has an explicit forward and reverse mapping.

struct MessagingPersistenceExternalAvatarAssetDTO: Codable, Sendable {
    let id: String
    let contentType: String
    let bytes: Data
    let sourceDigest: String
    let active: Bool

    init(_ row: ExternalAvatarAsset) {
        id = row.id
        contentType = row.contentType
        bytes = row.bytes
        sourceDigest = row.sourceDigest
        active = row.active
    }

    var value: ExternalAvatarAsset {
        ExternalAvatarAsset(
            id: id,
            contentType: contentType,
            bytes: bytes,
            sourceDigest: sourceDigest,
            active: active
        )
    }
}

struct MessagingPersistenceChannelAttachmentDTO: Codable, Sendable {
    let id: String
    let channelId: String
    let uploaderId: String
    let filename: String
    let messageId: String?
    let messagePosition: Int?
    let mimeType: String?
    let sizeBytes: Int?
    let width: Int?
    let height: Int?
    let uploaderType: String
    let createdAt: MessagingPersistenceDateBits
    let thumbnailKey: String?
    let storageKey: String?

    init(_ row: ChannelAttachment) {
        id = row.id
        channelId = row.channelId
        uploaderId = row.uploaderId
        filename = row.filename
        messageId = row.messageId
        messagePosition = row.messagePosition
        mimeType = row.mimeType
        sizeBytes = row.sizeBytes
        width = row.width
        height = row.height
        uploaderType = row.uploaderType
        createdAt = MessagingPersistenceDateBits(row.createdAt)
        thumbnailKey = row.thumbnailKey
        storageKey = row.storageKey
    }

    var value: ChannelAttachment {
        ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: messageId,
            messagePosition: messagePosition,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            width: width,
            height: height,
            uploaderType: uploaderType,
            createdAt: createdAt.value,
            thumbnailKey: thumbnailKey,
            storageKey: storageKey
        )
    }
}

struct MessagingPersistenceStoredHumanMessageDTO: Codable, Sendable {
    let id: String
    let channelId: String
    let senderId: String
    let content: String
    let seq: Int
    let randomId: String?
    let attachmentIds: [String]
    let messageType: String
    let senderType: String
    let createdAt: MessagingPersistenceDateBits
    let actionKind: String?
    let taskStatus: String?
    let taskNumber: Int?
    let taskAssigneeType: String?
    let taskAssigneeId: String?
    let taskClaimedAt: String?
    let taskCompletedAt: String?
    let senderTimezone: String?
    let externalMessageId: String?
    let externalProvider: String?
    let externalSenderName: String?
    let systemSubtype: String?
    let causalActorType: String?
    let causalActorId: String?
    let mentions: [MessagingPersistenceStoredMessageMentionDTO]
    /// Optional so every snapshot written before the owner opener decodes.
    let agentSendKey: String?

    init(_ row: StoredHumanMessage) {
        id = row.id
        channelId = row.channelId
        senderId = row.senderId
        content = row.content
        seq = row.seq
        randomId = row.randomId
        attachmentIds = row.attachmentIds
        messageType = row.messageType
        senderType = row.senderType
        createdAt = MessagingPersistenceDateBits(row.createdAt)
        actionKind = row.actionKind
        taskStatus = row.taskStatus
        taskNumber = row.taskNumber
        taskAssigneeType = row.taskAssigneeType
        taskAssigneeId = row.taskAssigneeId
        taskClaimedAt = row.taskClaimedAt
        taskCompletedAt = row.taskCompletedAt
        senderTimezone = row.senderTimezone
        externalMessageId = row.externalMessageId
        externalProvider = row.externalProvider
        externalSenderName = row.externalSenderName
        systemSubtype = row.systemSubtype
        causalActorType = row.causalActorType
        causalActorId = row.causalActorId
        mentions = row.mentions.map(MessagingPersistenceStoredMessageMentionDTO.init)
        agentSendKey = row.agentSendKey
    }

    var value: StoredHumanMessage {
        StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            seq: seq,
            randomId: randomId,
            attachmentIds: attachmentIds,
            messageType: messageType,
            senderType: senderType,
            createdAt: createdAt.value,
            actionKind: actionKind,
            taskStatus: taskStatus,
            taskNumber: taskNumber,
            taskAssigneeType: taskAssigneeType,
            taskAssigneeId: taskAssigneeId,
            taskClaimedAt: taskClaimedAt,
            taskCompletedAt: taskCompletedAt,
            senderTimezone: senderTimezone,
            externalMessageId: externalMessageId,
            externalProvider: externalProvider,
            externalSenderName: externalSenderName,
            systemSubtype: systemSubtype,
            causalActorType: causalActorType,
            causalActorId: causalActorId,
            mentions: mentions.map(\.value),
            agentSendKey: agentSendKey
        )
    }
}

struct MessagingPersistenceStoredMessageMentionDTO: Codable, Sendable {
    let type: String
    let id: String
    let name: String

    init(_ row: StoredMessageMention) {
        type = row.type
        id = row.id
        name = row.name
    }

    var value: StoredMessageMention {
        StoredMessageMention(
            type: type,
            id: id,
            name: name
        )
    }
}

struct MessagingPersistenceStoredReactionDTO: Codable, Sendable {
    let messageId: String
    let emoji: String
    let reactorId: String
    let reactorType: String

    init(_ row: StoredReaction) {
        messageId = row.messageId
        emoji = row.emoji
        reactorId = row.reactorId
        reactorType = row.reactorType
    }

    var value: StoredReaction {
        StoredReaction(
            messageId: messageId,
            emoji: emoji,
            reactorId: reactorId,
            reactorType: reactorType
        )
    }
}

struct MessagingPersistenceSystemAttentionReceiptDTO: Codable, Sendable {
    let seenAt: MessagingPersistenceDateBits?
    let dismissedAt: MessagingPersistenceDateBits?

    init(_ row: SystemAttentionReceipt) {
        seenAt = row.seenAt.map(MessagingPersistenceDateBits.init)
        dismissedAt = row.dismissedAt.map(MessagingPersistenceDateBits.init)
    }

    var value: SystemAttentionReceipt {
        SystemAttentionReceipt(
            seenAt: seenAt?.value,
            dismissedAt: dismissedAt?.value
        )
    }
}

struct MessagingPersistenceSystemAttentionIncidentDTO: Codable, Sendable {
    let id: String
    let serverId: String
    let machineId: String
    let provider: String
    let windowKey: String
    let activationGeneration: Int
    let affectedAgentIds: [String]
    let activatedAt: MessagingPersistenceDateBits
    let lastObservedAt: MessagingPersistenceDateBits
    let resetsAt: MessagingPersistenceDateBits?
    let state: String

    init(_ row: SystemAttentionIncident) {
        id = row.id
        serverId = row.serverId
        machineId = row.machineId
        provider = row.provider
        windowKey = row.windowKey
        activationGeneration = row.activationGeneration
        affectedAgentIds = row.affectedAgentIds
        activatedAt = MessagingPersistenceDateBits(row.activatedAt)
        lastObservedAt = MessagingPersistenceDateBits(row.lastObservedAt)
        resetsAt = row.resetsAt.map(MessagingPersistenceDateBits.init)
        state = row.state
    }

    var value: SystemAttentionIncident {
        SystemAttentionIncident(
            id: id,
            serverId: serverId,
            machineId: machineId,
            provider: provider,
            windowKey: windowKey,
            activationGeneration: activationGeneration,
            affectedAgentIds: affectedAgentIds,
            activatedAt: activatedAt.value,
            lastObservedAt: lastObservedAt.value,
            resetsAt: resetsAt?.value,
            state: state
        )
    }
}

struct MessagingPersistenceStoredMentionDTO: Codable, Sendable {
    let id: String
    let messageId: String
    let channelId: String
    let senderId: String
    let targetType: String
    let targetId: String
    let handle: String
    let notifiableAtSend: Bool
    let createdAt: MessagingPersistenceDateBits
    let notifiedAt: MessagingPersistenceDateBits?
    let notifiedByType: String?
    let notifiedById: String?
    let notifiedAction: String?
    let terminalCode: String?
    /// New optional group. Absent in every snapshot written before the mention
    /// delivery occurrence spine and never required by an older reader.
    let mentionDeliveryOccurrence: MessagingPersistenceMentionDeliveryOccurrenceDTO?

    init(_ row: StoredMention) {
        id = row.id
        messageId = row.messageId
        channelId = row.channelId
        senderId = row.senderId
        targetType = row.targetType
        targetId = row.targetId
        handle = row.handle
        notifiableAtSend = row.notifiableAtSend
        createdAt = MessagingPersistenceDateBits(row.createdAt)
        notifiedAt = row.notifiedAt.map(MessagingPersistenceDateBits.init)
        notifiedByType = row.notifiedByType
        notifiedById = row.notifiedById
        notifiedAction = row.notifiedAction
        terminalCode = row.terminalCode
        mentionDeliveryOccurrence = row.mentionDeliveryOccurrence.map(MessagingPersistenceMentionDeliveryOccurrenceDTO.init)
    }

    var value: StoredMention {
        StoredMention(
            id: id,
            messageId: messageId,
            channelId: channelId,
            senderId: senderId,
            targetType: targetType,
            targetId: targetId,
            handle: handle,
            notifiableAtSend: notifiableAtSend,
            createdAt: createdAt.value,
            notifiedAt: notifiedAt?.value,
            notifiedByType: notifiedByType,
            notifiedById: notifiedById,
            notifiedAction: notifiedAction,
            terminalCode: terminalCode,
            mentionDeliveryOccurrence: mentionDeliveryOccurrence?.value
        )
    }
}

/// Only the new optional key group. Every timestamp keeps reference-interval
/// bits so a restore cannot silently round a receipt time.
struct MessagingPersistenceMentionDeliveryOccurrenceDTO: Codable, Sendable {
    let state: String
    let deliveryPath: String
    let machineIdSnapshot: String?
    let launchIdSnapshot: String?
    let sessionIdSnapshot: String?
    let mentionRecordedAt: MessagingPersistenceDateBits
    let serverDecidedAt: MessagingPersistenceDateBits?
    let daemonReceivedAt: MessagingPersistenceDateBits?
    let daemonPendingAt: MessagingPersistenceDateBits?
    let daemonDrainedAt: MessagingPersistenceDateBits?
    let ackedAt: MessagingPersistenceDateBits?
    let terminalErrorAt: MessagingPersistenceDateBits?
    let terminalErrorCode: String?
    let terminalDecision: MessagingPersistenceMentionDeliveryTerminalDecisionDTO?
    let pendingCoalescedCount: Int
    let version: Int
    let deliveryPayloadJSON: String?
    let redriveCount: Int
    let lastRedriveAt: MessagingPersistenceDateBits?
    let recoveryCount: Int

    init(_ row: MentionDeliveryOccurrence) {
        state = row.state
        deliveryPath = row.deliveryPath
        machineIdSnapshot = row.machineIdSnapshot
        launchIdSnapshot = row.launchIdSnapshot
        sessionIdSnapshot = row.sessionIdSnapshot
        mentionRecordedAt = MessagingPersistenceDateBits(row.mentionRecordedAt)
        serverDecidedAt = row.serverDecidedAt.map(MessagingPersistenceDateBits.init)
        daemonReceivedAt = row.daemonReceivedAt.map(MessagingPersistenceDateBits.init)
        daemonPendingAt = row.daemonPendingAt.map(MessagingPersistenceDateBits.init)
        daemonDrainedAt = row.daemonDrainedAt.map(MessagingPersistenceDateBits.init)
        ackedAt = row.ackedAt.map(MessagingPersistenceDateBits.init)
        terminalErrorAt = row.terminalErrorAt.map(MessagingPersistenceDateBits.init)
        terminalErrorCode = row.terminalErrorCode
        terminalDecision = row.terminalDecision.map(MessagingPersistenceMentionDeliveryTerminalDecisionDTO.init)
        pendingCoalescedCount = row.pendingCoalescedCount
        version = row.version
        deliveryPayloadJSON = row.deliveryPayloadJSON
        redriveCount = row.redriveCount
        lastRedriveAt = row.lastRedriveAt.map(MessagingPersistenceDateBits.init)
        recoveryCount = row.recoveryCount
    }

    var value: MentionDeliveryOccurrence {
        MentionDeliveryOccurrence(
            state: state, deliveryPath: deliveryPath,
            machineIdSnapshot: machineIdSnapshot, launchIdSnapshot: launchIdSnapshot,
            sessionIdSnapshot: sessionIdSnapshot,
            mentionRecordedAt: mentionRecordedAt.value,
            serverDecidedAt: serverDecidedAt?.value, daemonReceivedAt: daemonReceivedAt?.value,
            daemonPendingAt: daemonPendingAt?.value, daemonDrainedAt: daemonDrainedAt?.value,
            ackedAt: ackedAt?.value, terminalErrorAt: terminalErrorAt?.value,
            terminalErrorCode: terminalErrorCode, terminalDecision: terminalDecision?.value,
            pendingCoalescedCount: pendingCoalescedCount, version: version,
            deliveryPayloadJSON: deliveryPayloadJSON, redriveCount: redriveCount,
            lastRedriveAt: lastRedriveAt?.value, recoveryCount: recoveryCount)
    }
}

struct MessagingPersistenceMentionDeliveryTerminalDecisionDTO: Codable, Sendable {
    let layer: String
    let stage: String
    let originalDaemonCode: String?

    init(_ row: MentionDeliveryTerminalDecision) {
        layer = row.layer; stage = row.stage; originalDaemonCode = row.originalDaemonCode
    }

    var value: MentionDeliveryTerminalDecision {
        MentionDeliveryTerminalDecision(layer: layer, stage: stage, originalDaemonCode: originalDaemonCode)
    }
}

struct MessagingPersistenceStoredForwardRecordDTO: Codable, Sendable {
    let sourceIds: [String]
    let items: [MessagingPersistenceForwardItemRecordDTO]
    let destinationTargetId: String

    init(_ row: StoredForwardRecord) {
        sourceIds = row.sourceIds
        items = row.items.map(MessagingPersistenceForwardItemRecordDTO.init)
        destinationTargetId = row.destinationTargetId
    }

    var value: StoredForwardRecord {
        StoredForwardRecord(
            sourceIds: sourceIds,
            items: items.map(\.value),
            destinationTargetId: destinationTargetId
        )
    }
}
