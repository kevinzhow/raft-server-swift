import Foundation

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
        withState { state in
            var ids: [String] = []
            for candidate in candidates {
                if let existing = state.storedMentions.first(where: {
                    $0.messageId == messageId && $0.targetType == candidate.type && $0.targetId == candidate.id
                }) {
                    ids.append(existing.id)
                    continue
                }
                let id = UUID().uuidString.lowercased()
                let senderId = state.humanMessageRows.first { $0.id == messageId }?.senderId ?? ""
                state.storedMentions.append(StoredMention(
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
        withState { state in
            func key(_ userId: String) -> String { "\(serverId)\n\(userId)\n\(threadChannelId)" }
            state.threadFollows[key(senderId)] = (
                serverId: serverId,
                userId: senderId,
                threadChannelId: threadChannelId,
                parentMessageId: parentMessageId
            )
            for target in mentioned {
                if state.threadUnfollows[key(target.userId)] != nil {
                    guard target.isParentMember else { continue }
                    state.threadUnfollows.removeValue(forKey: key(target.userId))
                }
                state.threadFollows[key(target.userId)] = (
                    serverId: serverId,
                    userId: target.userId,
                    threadChannelId: threadChannelId,
                    parentMessageId: parentMessageId
                )
            }
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
        withState { state in
            var steps: [MentionActionStep] = []
            for id in ids {
                guard let index = state.storedMentions.firstIndex(where: { $0.id == id }),
                      inScope(state.storedMentions[index]),
                      state.storedMentions[index].senderId == userId
                else {
                    steps.append(MentionActionStep(
                        result: MentionActionResult(resolutionId: id, action: action, status: "not_found"),
                        effects: []
                    ))
                    continue
                }
                let mention = state.storedMentions[index]
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
                        state.storedMentions[index].notifiedAt = now
                        state.storedMentions[index].notifiedByType = "user"
                        state.storedMentions[index].notifiedById = userId
                        state.storedMentions[index].notifiedAction = "notify_only"
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
                    state.storedMentions[index].notifiedAt = now
                    state.storedMentions[index].notifiedByType = "user"
                    state.storedMentions[index].notifiedById = userId
                    state.storedMentions[index].notifiedAction = "add"
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
        withState { state in
            var results: [MentionActionResult] = []
            for id in ids {
                guard let index = state.storedMentions.firstIndex(where: { $0.id == id }),
                      state.storedMentions[index].senderId == agentId,
                      inScope(state.storedMentions[index]),
                      state.humanMessageRows.contains(where: { $0.id == state.storedMentions[index].messageId })
                else {
                    results.append(MentionActionResult(resolutionId: id, action: action, status: "not_found"))
                    continue
                }
                let mention = state.storedMentions[index]
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
                    for other in state.storedMentions.indices
                    where state.storedMentions[other].messageId == mention.messageId
                        && state.storedMentions[other].targetType == mention.targetType
                        && state.storedMentions[other].targetId == mention.targetId
                        && state.storedMentions[other].notifiedAt == nil {
                        state.storedMentions[other].notifiedAt = now
                        state.storedMentions[other].notifiedByType = "agent"
                        state.storedMentions[other].notifiedById = agentId
                        state.storedMentions[other].notifiedAction = "notify_only"
                        if state.storedMentions[other].id != id { deduped.append(state.storedMentions[other].id) }
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
    }

    /// The forward commit: the bundle metadata, the forward record, the
    /// projected attachment ids on the message row and the attachment copies
    /// land together. Returns the message row as the destination publishes it,
    /// or nil when the row is gone.
    func commitForward(
        messageId: String,
        bundle: [ForwardedSource],
        record: StoredForwardRecord,
        projections: [(attachment: ChannelAttachment, id: String, position: Int)],
        destinationChannelId: String
    ) -> StoredHumanMessage? {
        withState { state in
            state.forwardedBundles[messageId] = bundle
            state.forwardRecords[messageId] = record
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
                state.humanMessageRows[index].attachmentIds = projections.map(\.id)
            }
            for projection in projections {
                var copy = projection.attachment
                copy.id = projection.id
                copy.channelId = destinationChannelId
                copy.messageId = messageId
                copy.messagePosition = projection.position
                state.channelAttachments[copy.id] = copy
            }
            guard var message = state.humanMessageRows.first(where: { $0.id == messageId }) else { return nil }
            message.channelId = destinationChannelId
            return message
        }
    }
}
