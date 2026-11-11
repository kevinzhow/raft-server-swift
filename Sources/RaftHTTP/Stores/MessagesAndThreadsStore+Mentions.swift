import Foundation

/// A claim is returned only by the existing Messages owner. Cross-owner effects
/// are staged by the service in the same enclosing business transaction.
struct MentionActionClaim: Sendable {
    var result: MentionActionResult
    var mention: StoredMention
    var newlyClaimed: Bool
}

struct PendingMentionCandidate: Sendable, Equatable {
    var type: String
    var id: String
    var name: String
}

struct ThreadMentionFollowTarget: Sendable, Equatable {
    var userId: String
    var isParentMember: Bool
}

extension MessagesAndThreadsStore {
    /// Prepared membership/lexical facts are immutable. The retained host,
    /// unique-key check and insertion share this one Messages critical section.
    func recordMemberMentions(messageId: String, channelId: String,
                              registrations: [ResolvedMentionRegistration]) {
        withState { state in
            let hosts = state.humanMessageRows.filter { $0.id == messageId && $0.channelId == channelId }
            guard hosts.count == 1, let host = hosts.first else { return }
            var existing = Set(state.storedMentions.filter { $0.messageId == messageId }
                .map { "\($0.targetType):\($0.targetId)" })
            let now = Date()
            for row in registrations where existing.insert("\(row.mention.type):\(row.mention.id)").inserted {
                let mention = StoredMention(
                    id: UUID().uuidString.lowercased(), messageId: messageId, channelId: channelId,
                    senderId: host.senderId, targetType: row.mention.type, targetId: row.mention.id,
                    handle: row.mention.name, notifiableAtSend: row.notifiableAtSend,
                    notifiedAt: nil, notifiedByType: nil,
                    notifiedById: nil, notifiedAction: nil)
                // Upstream inserts the occurrence atomically with the mention
                // facts, so "recorded but never delivered" is recoverable while
                // "delivered but never recorded" is not.
                var stored = mention
                stored.mentionDeliveryOccurrence = Self.initialMentionDeliveryOccurrence(
                    for: mention, host: host, at: now)
                state.storedMentions.append(stored)
            }
        }
    }

    /// The existing store-level concurrency operation also requires a real host;
    /// it cannot invent an author or revise an existing send-time snapshot.
    func resolvePendingMentionRows(messageId: String, channelId: String,
                                   candidates: [PendingMentionCandidate]) -> [String] {
        recordMemberMentions(messageId: messageId, channelId: channelId,
            registrations: candidates.map {
                .init(mention: MentionInput(type: $0.type, id: $0.id, name: $0.name), notifiableAtSend: false)
            })
        return withState { state in
            candidates.compactMap { candidate in
                state.storedMentions.first {
                    $0.messageId == messageId && $0.channelId == channelId
                        && $0.targetType == candidate.type && $0.targetId == candidate.id
                }?.id
            }
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
            state.threadUnfollows.removeValue(forKey: key(senderId))
            Self.retireManagedThreadFollowerRemovals(in: &state, serverId: serverId,
                threadId: threadChannelId, agentId: senderId)
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
                Self.retireManagedThreadFollowerRemovals(in: &state, serverId: serverId,
                    threadId: threadChannelId, agentId: target.userId)
                state.threadFollows[key(target.userId)] = (
                    serverId: serverId,
                    userId: target.userId,
                    threadChannelId: threadChannelId,
                    parentMessageId: parentMessageId
                )
            }
        }
    }

    /// Atomic cross-message claim. The service checks authority over the retained
    /// BPR view; actual host author, identity and current claim state are checked
    /// again here. No callback or another owner's lock runs while State is held.
    func claimMentionGroup(resolutionId: String, action: String, actorType: String,
                           actorId: String, now: Date) -> MentionActionClaim? {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == resolutionId }) else { return nil }
            let selected = state.storedMentions[index]
            let hosts = state.humanMessageRows.filter { $0.id == selected.messageId }
            guard hosts.count == 1, let host = hosts.first, host.channelId == selected.channelId,
                  host.senderType == actorType, host.senderId == actorId else { return nil }
            func result(_ status: String, _ reason: String? = nil, _ ids: [String]? = nil) -> MentionActionResult {
                MentionActionResult(resolutionId: selected.id, action: action, status: status,
                    reason: reason, deduped: ids, messageId: selected.messageId, channelId: selected.channelId,
                    targetType: selected.targetType, targetId: selected.targetId)
            }
            if selected.notifiedAction == "add" || selected.notifiedAction == "invite"
                || (selected.notifiedAt != nil && (action == "notify" || selected.notifiedAction != "notify_only")) {
                return MentionActionClaim(result: result(action == "notify" ? "queued" : "delivered",
                    action == "notify" ? "already_queued" : "already_delivered", [selected.id]),
                    mention: selected, newlyClaimed: false)
            }
            guard !selected.notifiableAtSend else {
                return MentionActionClaim(result: result("stale", "no_longer_pending"), mention: selected, newlyClaimed: false)
            }
            guard now.timeIntervalSince(selected.createdAt) <= MessageMentionRules.pendingLifetime else {
                return MentionActionClaim(result: result("expired"), mention: selected, newlyClaimed: false)
            }
            let authors = Dictionary(state.humanMessageRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var ids: [String] = []
            for other in state.storedMentions.indices {
                let row = state.storedMentions[other]
                guard row.channelId == selected.channelId, row.targetType == selected.targetType,
                      row.targetId == selected.targetId, !row.notifiableAtSend,
                      now.timeIntervalSince(row.createdAt) < MessageMentionRules.pendingLifetime,
                      let author = authors[row.messageId], author.channelId == row.channelId,
                      author.senderType == actorType, author.senderId == actorId,
                      row.notifiedAt == nil || (action == "add" && row.notifiedAction == "notify_only") else { continue }
                state.storedMentions[other].notifiedAt = now
                state.storedMentions[other].notifiedByType = actorType
                state.storedMentions[other].notifiedById = actorId
                state.storedMentions[other].notifiedAction = action == "notify" ? "notify_only" : "add"
                ids.append(row.id)
            }
            guard !ids.isEmpty else { return nil }
            return MentionActionClaim(result: result(action == "notify" ? "queued" : "delivered", nil, ids),
                                      mention: selected, newlyClaimed: true)
        }
    }

    /// A real mention ADD reactivates the existing follow and Done/unfollow
    /// projection together. Its start is the actual action time, never backdated.
    func completeMentionThreadJoin(serverId: String, targetId: String, threadChannelId: String,
                                   parentMessageId: String, at date: Date) {
        withState { state in
            let key = "\(serverId)\n\(targetId)\n\(threadChannelId)"
            Self.retireManagedThreadFollowerRemovals(in: &state, serverId: serverId,
                threadId: threadChannelId, agentId: targetId)
            state.threadFollows[key] = (serverId, targetId, threadChannelId, parentMessageId)
            state.threadFollowStarts[key] = date
            state.threadUnfollows.removeValue(forKey: key)
            state.inboxDoneScopes.remove("\(targetId)\n\(threadChannelId)")
            state.inboxDoneAt.removeValue(forKey: "\(targetId)\n\(threadChannelId)")
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
                // Forward projections retain the immutable physical object. Its
                // AEAD authenticates objectKey, not this new projection id; the
                // copied row preserves that storageKey and plaintext size.
                if let reference = state.attachmentObjectReferences[projection.attachment.id] {
                    state.attachmentObjectReferences[copy.id] = reference
                }
            }
            guard var message = state.humanMessageRows.first(where: { $0.id == messageId }) else { return nil }
            message.channelId = destinationChannelId
            return message
        }
    }
}
