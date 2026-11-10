import Foundation
import RaftShared

/// `POST /api/messages/forward`: the single and the batch forward write.
///
/// The prepare phase only reads (message rows, channels, accounts) and builds
/// the bundle metadata from snapshots. The message insert is the injected,
/// serialized message write, and the commit — bundle, forward record,
/// projected attachment ids and attachment copies — is one
/// `MessagesAndThreadsStore` critical section.
extension HumanMessageCreateService {
    /// An empty note becomes `Forwarded N message(s)` in the destination.
    public func forwardHumanMessage(
        _ request: HumanMessageForwardRequest?,
        authorization: String?,
        serverId: String?
    ) throws -> HumanMessageForwardResponse {
        let userId = try requireUser(authorization)
        guard profiles.isEmailVerified(userId: userId) else {
            throw HumanMessageCreateError.emailVerificationRequired
        }
        guard let serverId, !serverId.isEmpty else { throw HumanMessageCreateError.missingServerIdHeader }
        guard let request else { throw HumanMessageCreateError.forwardInvalidRequest }
        let destinationChannelId: String
        if case .string(let raw)? = request.destinationChannelId {
            destinationChannelId = MessageMentionRules.trimmingJavaScriptWhitespace(raw)
        } else if case .string(let raw)? = request.channelId {
            destinationChannelId = MessageMentionRules.trimmingJavaScriptWhitespace(raw)
        } else {
            destinationChannelId = ""
        }
        let note: String
        switch request.note {
        case nil, .null?: note = ""
        case .string(let raw)?: note = MessageMentionRules.trimmingJavaScriptWhitespace(raw)
        case .some: throw HumanMessageCreateError.forwardInvalidRequest
        }
        guard let sourceIds = Self.forwardSourceIds(request.sourceMessageIds) else {
            throw HumanMessageCreateError.forwardInvalidRequest
        }
        let requestId: String?
        switch request.requestId {
        case nil, .null?: requestId = nil
        case .string(let raw)?:
            let value = MessageMentionRules.trimmingJavaScriptWhitespace(raw)
            guard ServerScope.isUUID(value) else { throw HumanMessageCreateError.forwardInvalidRequest }
            requestId = value
        case .some: throw HumanMessageCreateError.forwardInvalidRequest
        }
        let suppliedRandomId: String?
        switch request.randomId {
        case nil: suppliedRandomId = nil
        case .string(let raw)? where !raw.isEmpty && raw.utf16.count <= 128: suppliedRandomId = raw
        case .some: throw HumanMessageCreateError.forwardInvalidRequest
        }
        // Node validates both scalars even when a batch requestId wins over randomId.
        if request.destinationChannelIds != nil {
            guard Self.forwardDestinationIds(request.destinationChannelIds) != nil, requestId != nil else {
                throw HumanMessageCreateError.forwardInvalidRequest
            }
        } else if destinationChannelId.isEmpty {
            throw HumanMessageCreateError.forwardInvalidRequest
        }
        if note.utf16.count > 32_000 { throw HumanMessageCreateError.messageTooLong }
        if request.destinationChannelIds != nil {
            return try forwardToMany(request: request, sourceIds: sourceIds, note: note,
                                     authorization: authorization, serverId: serverId)
        }
        let randomId = requestId.map { "forward:\($0):\(destinationChannelId)" }
            ?? suppliedRandomId ?? "forward-\(UUID().uuidString.lowercased())"
        return try forwardOne(userId: userId, serverId: serverId,
                              destinationChannelId: destinationChannelId, sourceIds: sourceIds,
                              note: note, randomId: randomId)
    }

    /// A batch keeps one result per distinct destination. A denial or conflict
    /// stays inside that result.
    private func forwardToMany(
        request: HumanMessageForwardRequest,
        sourceIds: [String],
        note: String,
        authorization: String?,
        serverId: String
    ) throws -> HumanMessageForwardResponse {
        guard let destinations = Self.forwardDestinationIds(request.destinationChannelIds),
              case .string(let rawRequestId)? = request.requestId
        else {
            throw HumanMessageCreateError.forwardInvalidRequest
        }
        let requestId = MessageMentionRules.trimmingJavaScriptWhitespace(rawRequestId)
        guard ServerScope.isUUID(requestId) else { throw HumanMessageCreateError.forwardInvalidRequest }
        // Source refusal belongs to the whole request, before destination rows.
        let userId = try requireUser(authorization)
        _ = try prepareForwardSources(userId: userId, serverId: serverId, sourceIds: sourceIds)
        var results: [ForwardBatchResult] = []
        var successes = 0
        var replays = 0
        for destination in destinations {
            do {
                // Each destination re-enters the single forward with the same
                // credential, so the session and verification are rechecked.
                let userId = try requireUser(authorization)
                guard profiles.isEmailVerified(userId: userId) else {
                    throw HumanMessageCreateError.emailVerificationRequired
                }
                let reply = try forwardOne(
                    userId: userId,
                    serverId: serverId,
                    destinationChannelId: destination,
                    sourceIds: sourceIds,
                    note: note,
                    randomId: "forward:\(requestId):\(destination)"
                )
                successes += 1
                if reply.outcome == "idempotent_replay" { replays += 1 }
                results.append(.success(destinationChannelId: destination, message: reply))
            } catch let error as HumanMessageCreateError {
                switch error.status {
                case 409:
                    results.append(.failed(
                        destinationChannelId: destination,
                        code: "request_conflict",
                        error: "Forward request conflicts with an earlier request"
                    ))
                case 403, 404:
                    results.append(.failed(
                        destinationChannelId: destination,
                        code: "destination_unavailable",
                        error: "Could not forward to this target"
                    ))
                default:
                    results.append(.failed(
                        destinationChannelId: destination,
                        code: "forward_failed",
                        error: "Could not forward to this target"
                    ))
                }
            }
        }
        let failed = destinations.count - successes
        let outcome: String
        if failed > 0 {
            outcome = successes > 0 ? "partial_failure" : "all_failed"
        } else if replays == destinations.count {
            outcome = "idempotent_replay"
        } else {
            outcome = "success"
        }
        return .batch(results, outcome: outcome)
    }

    /// Resolve the complete source snapshot before destination checks and replay.
    /// The shared strict read port remains authoritative, including joint sources.
    private func prepareForwardSources(
        userId: String, serverId: String, sourceIds: [String]
    ) throws -> [(PendingForwardSource, ForwardSourceContext)] {
        let messageState = messages.state
        let channelState = channels.state
        let postable = channelState.postableChannels
        var pending: [PendingForwardSource] = []
        for id in sourceIds {
            guard let message = messageState.humanMessageRows.first(where: { $0.id == id }),
                  let storage = postable[message.channelId] else {
                throw HumanMessageCreateError.forwardMessageNotFound
            }
            let inJointServer = channelState.jointProjections.contains {
                ($0.canonicalChannelId == message.channelId || $0.localChannelId == message.channelId)
                    && $0.serverId == serverId && $0.status == "active"
            }
            guard storage.serverId == serverId || inJointServer else {
                throw HumanMessageCreateError.forwardMessageNotFound
            }
            guard storage.deletedAt == nil else { throw HumanMessageCreateError.forwardCrossServerSource }
            let jointLocalId = dependencies.jointLocalChannelId(message.channelId, serverId, userId)
            guard dependencies.messageVisibleToUser(message.channelId, serverId, userId) else {
                throw HumanMessageCreateError.forwardSourceNotFound
            }
            guard let channel = jointLocalId.flatMap({ postable[$0] }) ?? postable[message.channelId],
                  channel.deletedAt == nil else { throw HumanMessageCreateError.forwardCrossServerSource }
            if message.actionKind == "forwarded-bundle" || messageState.forwardedBundles[message.id] != nil {
                throw HumanMessageCreateError.forwardedSourceNotSupported
            }
            if message.messageType != "chat" || message.actionKind != nil {
                throw HumanMessageCreateError.unsupportedSourceMessage
            }
            let attachments = messageState.channelAttachments.values
                .filter { $0.messageId == message.id }
                .sorted { ($0.messagePosition ?? 0) < ($1.messagePosition ?? 0) }
            pending.append(PendingForwardSource(
                messageId: message.id, content: message.content, createdAt: message.createdAt,
                channelId: jointLocalId ?? message.channelId, channelKind: channel.kind,
                channelName: channel.name, parentChannelId: channel.parentChannelId,
                senderId: message.senderId, attachments: attachments
            ))
        }
        let selectedThreads = Set(pending.filter { $0.channelKind == "thread" }.map(\.channelId))
        let prepared = try pending.map { original in
            var source = original
            if source.channelKind == "thread" {
                let storage = messageState.humanMessageRows.first { $0.id == source.messageId }
                    .flatMap { postable[$0.channelId] }
                let parentId = storage?.parentMessageId ?? postable[source.channelId]?.parentMessageId
                guard let parentId,
                      let parent = messageState.humanMessageRows.first(where: { $0.id == parentId }),
                      let parentStorage = postable[parent.channelId], parentStorage.deletedAt == nil,
                      parentStorage.kind != "thread" else { throw HumanMessageCreateError.forwardUnsupportedSource }
                let localParentId = dependencies.jointLocalChannelId(parent.channelId, serverId, userId)
                    ?? parent.channelId
                guard let visibleParent = postable[localParentId], visibleParent.serverId == serverId,
                      visibleParent.deletedAt == nil, visibleParent.kind != "thread" else {
                    throw HumanMessageCreateError.forwardUnsupportedSource
                }
                source.parentChannelId = localParentId
            }
            return (source, Self.forwardContext(source: source, selectedThreads: selectedThreads, channels: postable))
        }
        if Set(prepared.map { $0.1.bundleSourceId }).count != 1 {
            throw HumanMessageCreateError.crossSourceBundle
        }
        return prepared
    }

    /// Revalidate source and destination before any idempotent acknowledgement.
    /// A successful replay retains its original immutable snapshots and IDs.
    private func forwardOne(
        userId: String, serverId: String, destinationChannelId: String,
        sourceIds: [String], note: String, randomId: String
    ) throws -> HumanMessageForwardResponse {
        let prepared = try prepareForwardSources(userId: userId, serverId: serverId, sourceIds: sourceIds)
        let channelState = channels.state
        let postable = channelState.postableChannels
        guard let destination = postable[destinationChannelId], destination.serverId == serverId,
              destination.deletedAt == nil else { throw HumanMessageCreateError.forwardDestinationNotFound }
        guard destination.memberIds.contains(userId) else {
            throw HumanMessageCreateError.forwardDestinationMembershipRequired
        }
        // Retained messages use canonical storage; the request and reply use
        // the selected local projection. Reuse the same mapping for replay.
        let storageChannelId = channelState.jointProjections
            .first { $0.localChannelId == destinationChannelId }?.canonicalChannelId ?? destinationChannelId
        let content = note.isEmpty
            ? "Forwarded \(sourceIds.count) message\(sourceIds.count == 1 ? "" : "s")" : note
        let messageState = messages.state
        if let existing = messageState.humanMessageRows.first(where: {
            $0.senderId == userId && $0.randomId == randomId
        }) {
            if existing.channelId == storageChannelId,
               existing.content.utf16.elementsEqual(content.utf16),
               let record = messageState.forwardRecords[existing.id], record.sourceIds == sourceIds,
               record.destinationTargetId == destinationChannelId {
                var response = existing
                response.channelId = destinationChannelId
                return .message(forwardedMessage(response, record), outcome: "idempotent_replay")
            }
            throw HumanMessageCreateError.forwardIdempotencyConflict
        }
        let ordered = prepared.sorted { lhs, rhs in
            if lhs.1.sourceIsThreadParent != rhs.1.sourceIsThreadParent {
                return lhs.1.sourceIsThreadParent
            }
            if lhs.0.createdAt != rhs.0.createdAt { return lhs.0.createdAt < rhs.0.createdAt }
            return lhs.0.messageId < rhs.0.messageId
        }
        var legacy: [ForwardedSource] = []
        var itemRecords: [ForwardItemRecord] = []
        var projections: [(attachment: ChannelAttachment, id: String, position: Int)] = []
        var position = 0
        for (source, context) in ordered {
            let exposed = context.sourceTargetId != nil
            legacy.append(ForwardedSource(
                sourceServerId: exposed ? serverId : "",
                sourceTargetId: context.sourceTargetId ?? "",
                sourceMessageId: exposed ? source.messageId : "",
                snapshotId: context.snapshotId ?? "",
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available"
            ))
            var snapshots: [ForwardAttachmentSnapshot] = []
            for attachment in source.attachments {
                let projectedId = UUID().uuidString.lowercased()
                snapshots.append(ForwardAttachmentSnapshot(
                    id: projectedId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType ?? "",
                    sizeBytes: attachment.sizeBytes ?? 0,
                    width: attachment.width,
                    height: attachment.height
                ))
                projections.append((attachment, projectedId, position))
                position += 1
            }
            let exposesPointers = context.snapshotLabelVisibility == "public" && context.sourceTargetId != nil
            let uniqueName = profiles.account(userId: source.senderId)?.name ?? "unknown"
            itemRecords.append(ForwardItemRecord(
                sourceMessageId: source.messageId,
                exposesPointers: exposesPointers,
                sourceAuthorUniqueName: uniqueName,
                sourceIsThreadParent: context.sourceIsThreadParent,
                contentSnapshot: source.content,
                sourceTargetId: context.sourceTargetId,
                sourceThreadId: context.sourceThreadId,
                parentChannelId: context.parentChannelId,
                snapshotId: context.snapshotId,
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available",
                attachments: snapshots,
                attachmentPolicy: snapshots.isEmpty ? "excluded" : "projected"
            ))
        }
        let record = StoredForwardRecord(
            sourceIds: sourceIds,
            items: itemRecords,
            destinationTargetId: destinationChannelId
        )
        // Upstream `persistForwardBundle` commits the bundle before
        // `broadcastAndDeliver`, so the frame carries the forwarded metadata.
        // This store therefore defers publication until `commitForward`.
        let written = dependencies.storeHumanMessageDeferred(storageChannelId, userId, content, randomId, [], nil, [])
        guard written.status == 200 else {
            throw HumanMessageCreateError.messageWriteRejected(status: UInt(written.status), body: written.body)
        }
        guard let messageId = Self.messageId(in: written.body) else {
            return .stored(messageJSON: written.body)
        }
        guard let message = messages.commitForward(
            messageId: messageId,
            bundle: legacy,
            record: record,
            projections: projections,
            destinationChannelId: destinationChannelId
        ) else {
            return .stored(messageJSON: written.body)
        }
        dependencies.publishForwardedMessage(message)
        return .message(forwardedMessage(message, record), outcome: "success")
    }

    private func forwardedMessage(_ message: StoredHumanMessage, _ record: StoredForwardRecord) -> ForwardedMessage {
        ForwardedMessage(
            id: message.id,
            channelId: message.channelId,
            content: message.content,
            attachmentIds: message.attachmentIds,
            randomId: message.randomId,
            destinationTargetId: record.destinationTargetId,
            renderedItems: record.items.map { dependencies.renderForwardItem($0) }
        )
    }

    // MARK: - Pure helpers

    /// Up to 10 distinct UUID destinations; any malformed entry refuses the batch.
    static func forwardDestinationIds(_ value: JSONValue?) -> [String]? {
        guard case .array(let rows)? = value, !rows.isEmpty else { return nil }
        var ids: [String] = []
        var seen = Set<String>()
        for row in rows {
            guard case .string(let raw) = row else { return nil }
            let id = MessageMentionRules.trimmingJavaScriptWhitespace(raw)
            guard ServerScope.isUUID(id) else { return nil }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        if ids.isEmpty || ids.count > 10 { return nil }
        return ids
    }

    /// Up to 20 distinct UUID source messages; a duplicate or malformed entry
    /// refuses the request.
    static func forwardSourceIds(_ value: JSONValue?) -> [String]? {
        guard case .array(let rows)? = value, !rows.isEmpty, rows.count <= 20 else { return nil }
        var ids: [String] = []
        for row in rows {
            guard case .string(let raw) = row else { return nil }
            let id = MessageMentionRules.trimmingJavaScriptWhitespace(raw)
            guard ServerScope.isUUID(id), !ids.contains(id) else { return nil }
            ids.append(id)
        }
        return ids
    }

    /// Which source a forwarded message points back to, and how much of it the
    /// bundle may expose.
    static func forwardContext(
        source: PendingForwardSource,
        selectedThreads: Set<String>,
        channels: [String: PostableChannel]
    ) -> ForwardSourceContext {
        if source.channelKind == "thread" {
            let parent = source.parentChannelId.flatMap { channels[$0] }
            let publicParent = parent?.kind == "channel"
            return ForwardSourceContext(
                bundleSourceId: source.channelId,
                sourceTargetId: publicParent ? source.channelId : nil,
                sourceThreadId: publicParent ? source.channelId : nil,
                parentChannelId: publicParent ? source.parentChannelId : nil,
                sourceIsThreadParent: false,
                snapshotId: publicParent ? source.parentChannelId : nil,
                snapshotType: "thread",
                snapshotLabel: publicParent ? "#\(parent?.name ?? "")" : "",
                snapshotLabelVisibility: publicParent ? "public" : "restricted"
            )
        }
        if source.channelKind == "channel",
           let threadId = channels.first(where: {
               $0.value.kind == "thread" && $0.value.parentMessageId == source.messageId
           })?.key,
           selectedThreads.contains(threadId) {
            return ForwardSourceContext(
                bundleSourceId: threadId,
                sourceTargetId: threadId,
                sourceThreadId: threadId,
                parentChannelId: source.channelId,
                sourceIsThreadParent: true,
                snapshotId: source.channelId,
                snapshotType: "thread",
                snapshotLabel: "#\(source.channelName)",
                snapshotLabelVisibility: "public"
            )
        }
        let publicSource = source.channelKind == "channel"
        return ForwardSourceContext(
            bundleSourceId: source.channelId,
            sourceTargetId: publicSource ? source.channelId : nil,
            sourceThreadId: nil,
            parentChannelId: nil,
            sourceIsThreadParent: false,
            snapshotId: publicSource ? source.channelId : nil,
            snapshotType: publicSource ? "channel" : source.channelKind,
            snapshotLabel: publicSource ? "#\(source.channelName)" : "",
            snapshotLabelVisibility: publicSource ? "public" : "restricted"
        )
    }
}
