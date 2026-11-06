import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Action-card execution and the agent task claim / update-status surfaces.
/// Migrated verbatim from the second half of `EmailLogin+ActionCards1.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ActionCardExecuteService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
    public func agentSendMessage(authorization: String?, body: String, v2: Bool) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid send request\"}")
        }
        let content = (object["content"] as? String) ?? ""
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("dm:@reminders") {
            return Self.json(403, "{\"error\":\"dm:@reminders is your private reminder conversation; nobody else reads it. Act at the reminder's anchor instead.\",\"code\":\"DM_TARGET_NOT_SENDABLE\"}")
        }
        let isSendDraft = object["sendDraft"] as? Bool == true
        let isContinueAnyway = object["continueAnyway"] as? Bool == true
        if object["continue"] as? Bool == true {
            return Self.json(400, "{\"error\":\"--continue is no longer supported. Use normal message send to update a draft, or --send-draft to send the current saved draft.\"}")
        }
        if isContinueAnyway && !isSendDraft {
            return Self.json(400, "{\"error\":\"--send-draft --anyway requires a saved draft\"}")
        }
        let assistantOwner = assistantOwnerFor(agentId: identity.agentId, serverId: identity.serverId)
        if let assistantOwner {
            guard trimmed.hasPrefix("dm:@") else {
                return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only post in its DM with its owner\"}")
            }
            var raw = String(trimmed.dropFirst("dm:@".count))
            if let suffixStart = raw.lastIndex(of: ":") { raw = String(raw[..<suffixStart]) }
            if let tilde = raw.firstIndex(of: "~") { raw = String(raw[..<tilde]) }
            lock.lock()
            let resolution = actionCardPrepare.resolveDMPeer(serverId: identity.serverId, agentId: identity.agentId, name: raw, kind: nil)
            lock.unlock()
            guard case .resolved(let peerId, _, _) = resolution, peerId == assistantOwner else {
                return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only post in its DM with its owner\"}")
            }
        }
        func threadTargetError(_ detail: String) -> HTTPReply {
            Self.json(404, "{\"error\":\"Thread target not found or not replyable: \(detail)\"}")
        }
        let reconcileOnly = object["reconcileOnly"] as? Bool == true
        guard reconcileOnly || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.json(400, "{\"error\":\"Content is required\"}")
        }
        var attachmentIds: [String] = []
        if let rawAttachments = object["attachmentIds"], !(rawAttachments is NSNull) {
            guard let list = rawAttachments as? [Any] else {
                return Self.json(400, "{\"error\":\"Not sent: attachmentIds entry 1 is not a single attachment ID. Send one ID per --attachment-id.\",\"code\":\"attachment_id_invalid\"}")
            }
            for (index, value) in list.enumerated() {
                guard let id = value as? String, ServerScope.isUUID(id) else {
                    let entry = index + 1
                    return Self.json(400, "{\"error\":\"Not sent: attachmentIds entry \(entry) is not a single attachment ID. Send one ID per --attachment-id.\",\"code\":\"attachment_id_invalid\"}")
                }
                attachmentIds.append(id)
            }
        }
        let idempotencyKey = (object["idempotencyKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var sendReceiptKey: String?
        if !idempotencyKey.isEmpty {
            let key = "\(identity.serverId)\n\(identity.agentId)\n\(idempotencyKey)"
            sendReceiptKey = key
            lock.lock()
            let receipt = agentApiSendReceipts[key]
            lock.unlock()
            if reconcileOnly {
                guard let receipt else {
                    return Self.json(200, "{\"ok\":true,\"state\":\"not_found\",\"reconciliation\":true}")
                }
                return Self.json(200, "{\"ok\":true,\"state\":\"committed\",\"messageId\":\(jsonString(receipt.messageId)),\"messageSeq\":\(receipt.messageSeq),\"reconciliation\":true,\"receiptComplete\":false}")
            }
            if let receipt {
                let mismatch: String?
                if receipt.target != trimmed {
                    mismatch = "target"
                } else if receipt.content != content {
                    mismatch = "content"
                } else if receipt.attachmentIds != attachmentIds {
                    mismatch = "attachments"
                } else {
                    mismatch = nil
                }
                if let mismatch {
                    return Self.json(409, "{\"error\":\"This idempotencyKey was already used for a different send\",\"code\":\"idempotency_key_reused\",\"mismatch\":\(jsonString(mismatch)),\"suggestedNextAction\":\"Retry with a new idempotencyKey.\"}")
                }
                return Self.json(200, "{\"ok\":true,\"state\":\"sent\",\"messageId\":\(jsonString(receipt.messageId)),\"messageSeq\":\(receipt.messageSeq),\"id\":\(jsonString(receipt.messageId)),\"channelId\":\(jsonString(channelIdForReceipt(receipt.messageId) ?? "")),\"content\":\(jsonString(receipt.content)),\"seq\":\(receipt.messageSeq)}")
            }
        }
        let channelId: String
        if trimmed.hasPrefix("#") {
            var raw = String(trimmed.dropFirst())
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
            lock.lock()
            var parentId: String?
            for (id, channel) in postableChannels {
                guard channel.serverId == identity.serverId, channel.name == raw, channel.deletedAt == nil,
                      channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
                else { continue }
                if channel.kind == "channel"
                    || channel.memberIds.contains(identity.agentId)
                    || oauth.channelAgentIds(channelId: id).contains(identity.agentId) {
                    parentId = id
                    break
                }
            }
            var resolved: String?
            var pendingAnchorId: String?
            if let parentId {
                if let suffix, !suffix.isEmpty {
                    let isMember = postableChannels[parentId]?.memberIds.contains(identity.agentId) == true
                        || oauth.channelAgentIds(channelId: parentId).contains(identity.agentId)
                    guard isMember else {
                        let privateParent = postableChannels[parentId]?.kind == "private"
                        lock.unlock()
                        return privateParent
                            ? threadTargetError("the parent message must exist in a channel you can read")
                            : Self.json(403, "{\"error\":\"Agent is not a member of the parent channel\"}")
                    }
                    let anchorId = oauth.historyMessages(channelId: parentId).first { $0.id.hasPrefix(suffix) }?.id
                        ?? humanMessageRows.first { $0.channelId == parentId && $0.id.hasPrefix(suffix) }?.id
                    resolved = agentHistoryThread(parentId: parentId, anchorMessageId: anchorId ?? "")
                        ?? agentHistoryThreadById(parentId: parentId, suffix: suffix)
                        ?? agentHistoryThreadByAnchorPrefix(parentId: parentId, suffix: suffix)
                    if resolved == nil, let anchorId {
                        pendingAnchorId = anchorId
                    }
                } else {
                    resolved = parentId
                }
            }
            lock.unlock()
            if let parentId, let pendingAnchorId {
                let threadId = oauth.createThreadChannel(parentChannelId: parentId, parentMessageId: pendingAnchorId)
                addPostableChannel(
                    serverId: identity.serverId,
                    channelId: threadId,
                    memberId: identity.agentId,
                    kind: "thread",
                    parentChannelId: parentId,
                    parentMessageId: pendingAnchorId,
                    name: "thread"
                )
                resolved = threadId
            }
            guard let resolved else {
                return suffix == nil
                    ? Self.json(404, "{\"error\":\"Channel not found\"}")
                    : threadTargetError("the parent message must exist in #\(raw)")
            }
            channelId = resolved
        } else if trimmed.hasPrefix("dm:@") {
            var raw = String(trimmed.dropFirst("dm:@".count))
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
            var kind: String?
            if let tilde = raw.firstIndex(of: "~") {
                kind = String(raw[raw.index(after: tilde)...])
                raw = String(raw[..<tilde])
            }
            lock.lock()
            let resolution = actionCardPrepare.resolveDMPeer(serverId: identity.serverId, agentId: identity.agentId, name: raw, kind: kind)
            lock.unlock()
            if let failure = dmPeerFailureReply(resolution) { return failure }
            guard case .resolved(let peerId, _, _) = resolution else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            lock.lock()
            let existing = actionCardPrepare.dmChannelId(serverId: identity.serverId, agentId: identity.agentId, peerId: peerId)
            lock.unlock()
            let dmChannelId: String
            if let existing {
                dmChannelId = existing
            } else {
                dmChannelId = oauth.createDirectChannel(serverId: identity.serverId, firstUserId: identity.agentId, secondUserId: peerId)
                addPostableChannel(serverId: identity.serverId, channelId: dmChannelId, memberId: identity.agentId, kind: "dm", name: "dm")
                addPostableChannel(serverId: identity.serverId, channelId: dmChannelId, memberId: peerId, kind: "dm", name: "dm")
                oauth.addChannelHuman(channelId: dmChannelId, userId: peerId)
            }
            if let suffix, !suffix.isEmpty {
                lock.lock()
                let anchorId = oauth.historyMessages(channelId: dmChannelId).first { $0.id.hasPrefix(suffix) }?.id
                    ?? humanMessageRows.first { $0.channelId == dmChannelId && $0.id.hasPrefix(suffix) }?.id
                var resolved = agentHistoryThread(parentId: dmChannelId, anchorMessageId: anchorId ?? "")
                    ?? agentHistoryThreadById(parentId: dmChannelId, suffix: suffix)
                    ?? agentHistoryThreadByAnchorPrefix(parentId: dmChannelId, suffix: suffix)
                lock.unlock()
                if resolved == nil, let anchorId {
                    let threadId = oauth.createThreadChannel(parentChannelId: dmChannelId, parentMessageId: anchorId)
                    addPostableChannel(
                        serverId: identity.serverId,
                        channelId: threadId,
                        memberId: identity.agentId,
                        kind: "thread",
                        parentChannelId: dmChannelId,
                        parentMessageId: anchorId,
                        name: "thread"
                    )
                    addPostableChannel(serverId: identity.serverId, channelId: threadId, memberId: peerId, kind: "thread", parentChannelId: dmChannelId, parentMessageId: anchorId, name: "thread")
                    resolved = threadId
                }
                guard let resolved else {
                    return threadTargetError("the parent message must exist in this DM")
                }
                channelId = resolved
            } else {
                channelId = dmChannelId
            }
        } else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }

        // A migration receipt DM is a one-way notice written at completion.
        if let channel = postableChannels[channelId], channel.name.hasPrefix("migration-receipt-") {
            return Self.json(409, "{\"error\":\"This migration receipt DM is a one-way notice; it cannot be replied to. Message your owner's DM instead.\",\"code\":\"MIGRATION_RECEIPT_READ_ONLY\",\"suggestedNextAction\":\"Read the receipt, then continue in your owner's DM.\"}")
        }

        // The gate and the commit it protects run under one lock: two
        // concurrent first replies must not both observe an empty thread.
        sendFreshnessCommitLock.lock()
        defer { sendFreshnessCommitLock.unlock() }

        // Freshness gate (SMR-006): a send that names the boundary its model
        // has seen (`seenUpToSeq`), a saved draft, a reviewer-isolation hold or
        // a re-hold opt into the gate. Newer messages from anyone but the
        // sender hold the draft; the response carries the latest bounded
        // context instead of committing anything.
        let seenUpToSeqValue = (object["seenUpToSeq"] as? NSNumber)?.doubleValue
        let hasClientSeenBoundary = seenUpToSeqValue.map { $0.isFinite } ?? false
        let clientSeenUpToSeq = hasClientSeenBoundary ? max(0, Int(seenUpToSeqValue!.rounded(.down))) : 0
        let withheldMode = (object["freshnessContextMode"] as? String) == "withheld"
        let draftReholdCount = max(0, (object["draftReholdCount"] as? NSNumber)?.intValue ?? 0)
        let draftReplacedExisting = object["draftReplacedExisting"] as? Bool == true
        // `seenExactSeqs`: sparse exact-seq observations (message check output).
        // Only seqs above the attested boundary and up to the latest message
        // count, deduplicated in request order.
        let requestedSeenExactSeqs: [Int] = {
            guard let raw = object["seenExactSeqs"] as? [Any] else { return [] }
            var seen = Set<Int>()
            var values: [Int] = []
            for item in raw {
                guard let number = item as? NSNumber, number.doubleValue.isFinite else { continue }
                let value = Int(number.doubleValue.rounded(.down))
                guard value > 0, seen.insert(value).inserted else { continue }
                values.append(value)
            }
            return Array(values.prefix(2500))
        }()
        let requestedSendFreshness = isSendDraft || isContinueAnyway || hasClientSeenBoundary
            || !requestedSeenExactSeqs.isEmpty
            || (object["draftReholdCount"] is NSNumber) || draftReplacedExisting || withheldMode
        let freshnessEnabled = actionCardPrepare.sendFreshnessInterfaceEnabled(serverId: identity.serverId, agentId: identity.agentId)
        let forcedFreshness = actionCardPrepare.sendFreshnessMode() == "force"
        if !freshnessEnabled && requestedSendFreshness {
            return Self.json(403, "{\"error\":\"Send freshness interface is not enabled for this agent.\"}")
        }
        // Passive channel card (policy "once"): only a client that names the
        // version its model context saw is checked. Never seen holds the send
        // once; an older version sends and returns the current card.
        var seenCardFields = ""
        var seenPeerCardFields = ""
        var cardHoldReasons: [String] = []
        if let seenCards = object["seenCards"] as? [String: Any], !withheldMode {
            lock.lock()
            let snapshot = actionCardPrepare.channelCardSnapshot(channelId: channelId)
            lock.unlock()
            if let rawChannel = seenCards["channel"], let snapshot {
                if let seenVersion = rawChannel as? String {
                    if snapshot.rev != seenVersion {
                        seenCardFields = ",\"channelCard\":\(snapshot.json),\"channelCardChanged\":true"
                    }
                } else {
                    seenCardFields = ",\"channelCard\":\(snapshot.json)"
                    cardHoldReasons.append("channel_card")
                }
            }
            if let rawPeer = seenCards["peer"] {
                lock.lock()
                let peerCard = actionCardPrepare.peerCardJSON(channelId: channelId, agentId: identity.agentId)
                lock.unlock()
                if let peerCard, !(rawPeer is String) {
                    seenPeerCardFields = ",\"peerCard\":\(peerCard)"
                    cardHoldReasons.append("peer_card")
                }
            }
        }
        let holdForCards = !cardHoldReasons.isEmpty && !isContinueAnyway
        var mentionExemption: (messageId: String, handle: String)?
        var mentionExemptionMessageCount = 0
        if freshnessEnabled, (requestedSendFreshness || forcedFreshness), !isContinueAnyway {
            lock.lock()
            let conversation = postableChannels[channelId]
            let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
            let rows = humanMessageRows.compactMap { message -> (seq: Int, message: StoredHumanMessage)? in
                guard message.channelId == storageChannelId else { return nil }
                return (message.seq, message)
            }
            let latestFromOthers = rows.last { $0.message.senderId != identity.agentId }?.seq ?? 0
            // The thread parent lives in the parent channel; the first reply
            // seeds its freshness boundary from that message's seq.
            let threadParentSeq = conversation?.kind == "thread"
                ? (conversation?.parentMessageId.flatMap { parentId in
                    humanMessageRows.first { $0.id == parentId }?.seq
                } ?? 0)
                : 0
            let fallbackBoundarySeq = conversation?.kind == "thread" ? threadParentSeq : 0
            let boundarySeq = min(hasClientSeenBoundary ? clientSeenUpToSeq : fallbackBoundarySeq, latestFromOthers)
            let effectiveExactSeqs = Set(requestedSeenExactSeqs.filter { $0 > boundarySeq && $0 <= latestFromOthers })
            let boundarySource: String
            if hasClientSeenBoundary {
                boundarySource = "client_seen"
            } else if !effectiveExactSeqs.isEmpty {
                boundarySource = "client_seen_exact"
            } else if fallbackBoundarySeq > 0 {
                boundarySource = "thread_parent"
            } else {
                boundarySource = "none"
            }
            let hasModelSeenProof = boundarySource == "client_seen" || boundarySource == "client_seen_exact"
            let newer = rows.filter {
                $0.seq > boundarySeq
                    && $0.message.senderId != identity.agentId
                    && !effectiveExactSeqs.contains($0.seq)
                    && !agentMessageSuppressedLocked($0.message, agentId: identity.agentId)
                    && !isSelfCausedFreshnessExemptLocked($0.message, agentId: identity.agentId)
            }
            let formalMentionCount = newer.reduce(0) { partial, entry in
                partial + (storedMentions.contains {
                    $0.messageId == entry.message.id && $0.targetType == "agent" && $0.targetId == identity.agentId
                } ? 1 : 0)
            }
            let boundaryMessageId: String? = boundarySeq > 0
                ? (conversation?.kind == "thread" && threadParentSeq == boundarySeq
                    ? conversation?.parentMessageId
                    : rows.first { $0.seq == boundarySeq }?.message.id)
                : nil
            // E1: a formal @handle mention inside the left-exclusive
            // (boundary, latest] range exempts the whole hold for this send.
            // Existing pre-E1 hold tests use fixture-injected mention rows
            // (senderId "peer"), so only resolved mention facts count here;
            // the explicit legacy read mark keeps those fixtures' hold
            // expectations while the upstream E1 case stays exempt.
            let legacyReadSeq = agentChannelReadCursors["\(channelId)\n\(identity.agentId)"]?.seq ?? 0
            let mentionFacts: [(messageId: String, handle: String)] = newer.compactMap { entry in
                guard let mention = storedMentions.first(where: {
                    $0.messageId == entry.message.id && $0.targetType == "agent" && $0.targetId == identity.agentId
                        && $0.senderId == "system"
                }) else { return nil }
                return (entry.message.id, mention.handle)
            }
            if boundarySeq > 0, legacyReadSeq == boundarySeq, !mentionFacts.isEmpty {
                mentionExemption = mentionFacts.first
                mentionExemptionMessageCount = newer.count
            }
            if let latestSeq = newer.last?.seq, mentionExemption == nil {
                let attentionCount = newer.count
                let shownRows = Array(newer.suffix(3))
                let shownCount = shownRows.count
                let holdCount = hasModelSeenProof ? attentionCount : min(attentionCount, 3)
                let omittedCount = hasModelSeenProof ? max(0, attentionCount - shownCount) : 0
                let showedEveryHeldMessage = shownCount >= attentionCount
                let conversationIdentity = actionCardPrepare.heldConversationIdentity(channelId: channelId, agentId: identity.agentId)
                let heldMessageJSON = shownRows.map { entry in
                    actionCardPrepare.heldFreshnessMessageJSON(seq: entry.seq, message: entry.message, conversationIdentity: conversationIdentity)
                }.joined(separator: ",")
                if !withheldMode, showedEveryHeldMessage {
                    // Every counted message was handed over: the read position
                    // may move through them. Omitted ones must stay queued.
                    let cursorKey = "\(channelId)\n\(identity.agentId)"
                    let previous = agentChannelReadCursors[cursorKey] ?? (seq: 0, version: 0)
                    if latestSeq > previous.seq {
                        agentChannelReadCursors[cursorKey] = (latestSeq, previous.version + 1)
                    }
                }
                lock.unlock()
                if withheldMode {
                    return Self.json(200, "{\"state\":\"held\",\"freshnessContextMode\":\"withheld\",\"withheldMessageCount\":\(holdCount)}")
                }
                let reason = boundarySource == "none" || boundarySource == "thread_parent"
                    ? "server_first_touch_context"
                    : "server_stale_model_boundary"
                let producerFactId = Self.freshnessDecisionProducerFactId(
                    agentId: identity.agentId,
                    target: trimmed,
                    reason: reason,
                    pendingMaxSeq: latestSeq,
                    modelSeenSeq: boundarySource == "client_seen" ? boundarySeq : 0,
                    heldMessageCount: shownCount,
                    omittedMessageCount: omittedCount
                )
                let gateMetadata: [String: JSONValue] = [
                    "last_seen_msg_id": boundaryMessageId.map(JSONValue.string) ?? .null,
                    "latest_msg_id": newer.last.map { JSONValue.string($0.message.id) } ?? .null,
                    "has_formal_mention_since_last_seen": .bool(false),
                    "draft_replaced_existing": .bool(draftReplacedExisting),
                    "new_message_count": .integer(Int64(holdCount)),
                    "boundary_source": .string(boundarySource),
                    "boundary_seq": .integer(Int64(boundarySeq)),
                    "latest_seq": .integer(Int64(latestSeq)),
                ]
                recordAttestedSendEvent(
                    "gate_triggered",
                    agentId: identity.agentId,
                    messageId: newer.last?.message.id,
                    metadata: gateMetadata
                )
                recordAgentSendActivity(
                    agentId: identity.agentId,
                    title: "Send held by freshness check",
                    text: "target: \(trimmed)\n"
                        + "unreviewed synced context for this target: \(shownCount) messages\n"
                        + "reason: this target's latest synced context was not yet in your reviewed context\n"
                        + "action: review the synced context before sending",
                    producerFactId: producerFactId
                )
                var response = "{\"ok\":true,\"state\":\"held\",\"outcome\":\"held\",\"subtype\":\"freshness\",\"reason\":\"newer_messages_available\",\"decision\":\"syncing_hold\",\"producerFactId\":\(jsonString(producerFactId)),\"available_actions\":[\"check_messages\",\"send_draft\",\"send_anyway\"],\"heldMessages\":[\(heldMessageJSON)],\"newMessageCount\":\(holdCount),\"shownMessageCount\":\(shownCount),\"omittedMessageCount\":\(omittedCount),\"seenUpToSeq\":\(latestSeq)"
                if let latestMessageId = newer.last?.message.id {
                    response += ",\"seenUpToMessageId\":\(jsonString(latestMessageId))"
                }
                if let firstShownSeq = shownRows.first?.seq {
                    response += ",\"firstShownSeq\":\(firstShownSeq)"
                }
                response += ",\"mentionAnnotation\":{\"formalMentionCount\":\(formalMentionCount)}"
                if draftReholdCount >= 3 {
                    response += ",\"continueAnywaySuggested\":true"
                }
                if holdForCards {
                    let reasons = (["unread_messages"] + cardHoldReasons).map(jsonString).joined(separator: ",")
                    response += ",\"holdReasons\":[\(reasons)]"
                }
                response += seenCardFields
                response += seenPeerCardFields
                response += "}"
                return Self.json(200, response)
            }
            lock.unlock()
        }
        if let exemption = mentionExemption {
            let exemptionMetadata: [String: JSONValue] = [
                "mention_message_id": .string(exemption.messageId),
                "mentioned_handle": .string(exemption.handle),
                "new_message_count_since_last_seen": .integer(Int64(mentionExemptionMessageCount)),
            ]
            recordAttestedSendEvent(
                "e1_exempt",
                agentId: identity.agentId,
                messageId: exemption.messageId,
                metadata: exemptionMetadata
            )
            recordAgentSendActivity(
                agentId: identity.agentId,
                title: "Send freshness check passed by mention",
                text: "target: \(trimmed)\nreason: direct @\(exemption.handle) mention\nnew messages: \(mentionExemptionMessageCount)",
                producerFactId: nil
            )
        }
        if holdForCards {
            let reasons = cardHoldReasons.map(jsonString).joined(separator: ",")
            return Self.json(200, "{\"ok\":true,\"state\":\"held\",\"holdReasons\":[\(reasons)],\"heldMessages\":[],\"newMessageCount\":0,\"shownMessageCount\":0,\"omittedMessageCount\":0\(seenCardFields)\(seenPeerCardFields)}")
        }
        lock.lock()
        if let threadChannel = postableChannels[channelId], threadChannel.kind == "thread",
           let parentChannelId = threadChannel.parentChannelId,
           let parentMessageId = threadChannel.parentMessageId {
            threadFollows["\(identity.serverId)\n\(identity.agentId)\n\(channelId)"] = (
                serverId: identity.serverId,
                userId: identity.agentId,
                threadChannelId: channelId,
                parentMessageId: parentMessageId
            )
            let parentSender = oauth.historyMessages(channelId: parentChannelId).first { $0.id == parentMessageId }?.senderId
                ?? humanMessageRows.first { $0.id == parentMessageId }?.senderId
            if let parentSender, parentSender != "system",
               oauth.memberRole(serverId: identity.serverId, userId: parentSender) != nil {
                threadFollows["\(identity.serverId)\n\(parentSender)\n\(channelId)"] = (
                    serverId: identity.serverId,
                    userId: parentSender,
                    threadChannelId: channelId,
                    parentMessageId: parentMessageId
                )
            }
        }
        lock.unlock()
        let typedMentions = Self.mentionInputs(object["mentions"])
        if v2, Self.mentionBindingConflict(typedMentions) {
            return Self.json(400, "{\"error\":\"A mention handle is bound to more than one target\",\"code\":\"mention_binding_conflict\"}")
        }
        let mentionResolution = resolvedMessageMentions(
            serverId: identity.serverId,
            senderId: identity.agentId,
            content: content,
            typed: v2 ? typedMentions : [],
            warnUnresolved: v2
        )
        let messageId = UUID().uuidString.lowercased()
        lock.lock()
        var seenAttachmentIds = Set<String>()
        for id in attachmentIds {
            if seenAttachmentIds.contains(id) {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) was requested more than once. Send each attachment ID exactly once.\",\"code\":\"attachment_duplicate\"}")
            }
            seenAttachmentIds.insert(id)
            guard let row = channelAttachments[id], row.channelId == channelId, row.uploaderId == identity.agentId else {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) is not available for this sender. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_not_found\"}")
            }
            if row.messageId != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) is already attached to another message. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_already_linked\"}")
            }
        }
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: channelId,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            attachmentIds: attachmentIds,
            messageType: "chat",
            senderType: "agent"
        ))
        for id in attachmentIds {
            channelAttachments[id]?.messageId = messageId
        }
        let ownSeq = humanMessageRows.last?.seq ?? humanMessageRows.count
        // Sending is not reading: the cursor may pass the own message only when
        // no message from someone else below it is still unhanded.
        let cursorKey = "\(channelId)\n\(identity.agentId)"
        let cursor = agentChannelReadCursors[cursorKey]?.seq ?? 0
        let unreadBelow = humanMessageRows.contains { message in
            message.channelId == channelId
                && message.senderId != identity.agentId
                && message.seq > cursor
                && message.seq < ownSeq
        }
        if !unreadBelow, ownSeq > cursor {
            let previous = agentChannelReadCursors[cursorKey] ?? (seq: 0, version: 0)
            agentChannelReadCursors[cursorKey] = (ownSeq, previous.version + 1)
        }
        if let sendReceiptKey {
            agentApiSendReceipts[sendReceiptKey] = AgentApiSendReceipt(
                messageId: messageId,
                messageSeq: ownSeq,
                target: trimmed,
                content: content,
                attachmentIds: attachmentIds
            )
        }
        lock.unlock()
        recordMemberMentionRows(messageId: messageId, channelId: channelId, mentions: mentionResolution.mentions)
        let report = sendMentionReport(
            content: content,
            typedMentions: (object["mentions"] as? [[String: Any]]) ?? [],
            v2: v2,
            channelId: channelId,
            serverId: identity.serverId,
            senderAgentId: identity.agentId,
            messageId: messageId
        )
        let unresolvedJSON = v2 && !mentionResolution.unresolved.isEmpty
            ? ",\"unresolvedMentionHandles\":[" + mentionResolution.unresolved.map(jsonString).joined(separator: ",") + "]"
            : ""
        let attentionJSON: String = {
            lock.lock()
            let key = "\(channelId)\n\(identity.agentId)"
            let channel = postableChannels[channelId]
            let joined = agentChannelJoinedAt[key]
            let isChannel = channel?.kind == "channel"
            let recent = joined.map { Date().timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
            var payload = ""
            if isChannel, recent, !agentChannelPosted.contains(key) {
                agentChannelPosted.insert(key)
                let mute = "raft channel mute \"#\(channel?.name ?? "")\""
                let still = "@mentions still reach you, and threads you started stay followed and keep delivering until you unfollow them."
                payload = ",\"attention\":{\"driveByJoinedToPost\":{\"reason\":\"first_agent_message_with_recent_channel_join\",\"muteCommand\":\(jsonString(mute)),\"stillArrives\":[\(jsonString(still))]}}"
            }
            lock.unlock()
            return payload
        }()
        let sent = "{\"ok\":true,\"state\":\"sent\",\"messageId\":\(jsonString(messageId)),\"messageSeq\":\(ownSeq),\"id\":\(jsonString(messageId)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(content)),\"seq\":\(ownSeq)\(report.pendingJSON)\(unresolvedJSON)\(seenCardFields)\(seenPeerCardFields)\(attentionJSON)}"
        return Self.json(200, sent)
    }

    /// `@handle` tokens outside markdown code, in author order.

    /// Resolution of authored handles into the sender-only mention facts the
    /// send response reports: pending actions for a non-member agent (v1) and
    /// unresolved authored handles (v2). Hidden humans stay cloaked.
    func sendMentionReport(
        content: String,
        typedMentions: [[String: Any]],
        v2: Bool,
        channelId: String,
        serverId: String,
        senderAgentId: String,
        messageId: String
    ) -> (pendingJSON: String, unresolvedJSON: String) {
        let handles = Self.mentionHandlesOutsideCode(content)
        guard !handles.isEmpty else { return ("", "") }
        let typedByName: [String: (type: String, id: String)] = Dictionary(
            uniqueKeysWithValues: typedMentions.compactMap { mention in
                guard let name = mention["name"] as? String,
                      let type = mention["type"] as? String,
                      let id = mention["id"] as? String else { return nil }
                return (name, (type, id))
            }
        )
        lock.lock()
        let hiddenHumans = hideHumansFromMembers[serverId] == true
        lock.unlock()
        let senderName = oauth.agentRuntimeInfo(id: senderAgentId)?.name ?? ""
        let channelAgents = Set(oauth.channelAgentIds(channelId: channelId))
        let serverAgents = oauth.serverAgents(serverId: serverId)
        var pending: [String] = []
        var unresolved: [String] = []
        var seen = Set<String>()
        for handle in handles where seen.insert(handle).inserted {
            if handle == senderName { continue }
            if let typed = typedByName[handle] {
                if typed.type == "agent" {
                    if !serverAgents.contains(where: { $0.id == typed.id }) {
                        continue
                    }
                    if v2 { continue }
                    if !channelAgents.contains(typed.id) {
                        pending.append(Self.pendingMentionActionJSON(
                            messageId: messageId,
                            handle: handle,
                            avatarUrl: oauth.agentRuntimeInfo(id: typed.id)?.avatarUrl
                        ))
                    }
                    continue
                }
                // A typed human is either visible (resolved) or hidden (cloaked).
                continue
            }
            if let agent = serverAgents.first(where: { $0.name == handle }) {
                if v2 { continue }
                if !channelAgents.contains(agent.id) {
                    pending.append(Self.pendingMentionActionJSON(
                        messageId: messageId,
                        handle: handle,
                        avatarUrl: agent.avatarUrl
                    ))
                }
                continue
            }
            let humanExists = accounts.values.contains { $0.name == handle }
            if v2, !humanExists || hiddenHumans {
                unresolved.append("@" + handle)
            }
        }
        let pendingJSON = pending.isEmpty ? "" : ",\"pendingMentionActions\":[" + pending.joined(separator: ",") + "]"
        let unresolvedJSON = unresolved.isEmpty ? "" : ",\"unresolvedMentionHandles\":[" + unresolved.map(jsonString).joined(separator: ",") + "]"
        return (pendingJSON, unresolvedJSON)
    }


    func channelIdForReceipt(_ messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.channelId
    }


    func agentTaskAuth(authorization: String?, legacyAgentId: String?) -> AgentTaskAuthResult {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .refused(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        lock.unlock()
        if let credential, credential.revokedAt == nil {
            guard credential.scopes.contains("tasks") else {
                return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
            }
            guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
                return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
            }
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
    }

    /// Write routes accept both an `sk_agent_*` credential and the legacy
    /// machine key plus path agent id.
    func agentTaskWriter(_ authorization: String?, legacyAgentId: String?) -> (agentId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        lock.unlock()
        if let credential, credential.revokedAt == nil,
           let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted {
            return (agent.id, agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent.id, agent.serverId)
        }
        return nil
    }

    func agentTaskChannel(serverId: String, agentId: String, reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if trimmed.hasPrefix("#") {
            let name = String(trimmed.dropFirst())
            for (id, channel) in postableChannels {
                guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil else { continue }
                guard channel.kind == "channel"
                    || channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
                else { continue }
                return id
            }
            return nil
        }
        guard postableChannels[trimmed]?.serverId == serverId else { return nil }
        return trimmed
    }

    public func agentTasksList(authorization: String?, legacyAgentId: String?, channelRef: String?) -> HTTPReply {
        let auth: (agentId: String, serverId: String)
        switch agentTaskAuth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .refused(let reply): return reply
        case .ok(let agentId, let serverId): auth = (agentId, serverId)
        }
        if let reply = agentGrantDenial(agentId: auth.agentId, scope: "task:read") { return reply }
        guard let channelRef,
              let channelId = agentTaskChannel(serverId: auth.serverId, agentId: auth.agentId, reference: channelRef)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let rows = taskRecords.filter { $0.channelId == channelId }.map { task in
            "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"title\":\(jsonString(task.title)),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"tasks\":[\(rows)]}")
    }

    func taskWriteFreshnessHold(agentId: String, channelId: String, seenUpToSeq: Int?, actionKey: String) -> HTTPReply? {
        guard let seen = seenUpToSeq else { return nil }
        lock.lock()
        let key = "\(agentId)\n\(channelId)\n\(actionKey)"
        if let held = taskWriteHolds[key], seen == held.seen {
            taskWriteHolds.removeValue(forKey: key)
            lock.unlock()
            return nil
        }
        let rows = humanMessageRows.filter { $0.channelId == channelId && $0.senderId != agentId && $0.seq > seen }
        guard !rows.isEmpty else { lock.unlock(); return nil }
        let latest = rows.map(\.seq).max() ?? seen
        taskWriteHolds[key] = (latest, latest)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let heldMessages = rows.sorted { $0.seq < $1.seq }.prefix(5).map { message in
            "{\"id\":\(jsonString(message.id)),\"seq\":\(message.seq),\"content\":\(jsonString(message.content)),\"senderId\":\(jsonString(message.senderId)),\"createdAt\":\(jsonString(formatter.string(from: message.createdAt)))}"
        }.joined(separator: ",")
        let count = rows.count
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"state\":\"held\",\"outcome\":\"held\",\"subtype\":\"freshness\",\"reason\":\"newer_messages_available\",\"decision\":\"syncing_hold\",\"available_actions\":[\"check_messages\",\"retry_action\"],\"heldMessages\":[\(heldMessages)],\"newMessageCount\":\(count),\"seenUpToSeq\":\(latest)}")
    }

    public func agentTaskClaim(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef)
        else {
            return Self.json(400, "{\"error\":\"Invalid task claim request\"}")
        }
        let taskNumbers = (object["task_numbers"] as? [Any])?.compactMap { $0 as? Int } ?? []
        let messageIds = (object["message_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let hold = taskWriteFreshnessHold(
            agentId: writer.agentId, channelId: channelId,
            seenUpToSeq: object["seenUpToSeq"] as? Int, actionKey: "claim:\(taskNumbers.first ?? 0)"
        ) { return hold }
        var results: [String] = []
        lock.lock()
        for number in taskNumbers {
            guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == number }) else {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"not found\"}")
                continue
            }
            if !taskRecords[index].hasHostMessage {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"task not found\"}")
                continue
            }
            if taskRecords[index].assigneeId == writer.agentId {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"already claimed by you\"}")
                continue
            }
            if let assignee = taskRecords[index].assigneeId, assignee != writer.agentId {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"already claimed\"}")
                continue
            }
            taskRecords[index].assigneeId = writer.agentId
            taskRecords[index].assigneeType = "agent"
            taskRecords[index].claimedAt = Date()
            if taskRecords[index].status == "todo" { taskRecords[index].status = "in_progress" }
            taskRecords[index].revision += 1
            let task = taskRecords[index]
            results.append("{\"taskNumber\":\(task.taskNumber),\"messageId\":\(jsonString(task.messageId)),\"success\":true}")
        }
        for prefix in messageIds {
            guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.messageId.hasPrefix(prefix) }) else {
                results.append("{\"messageId\":\(jsonString(prefix)),\"success\":false,\"reason\":\"not found\"}")
                continue
            }
            let task = taskRecords[index]
            if task.assigneeId == writer.agentId {
                results.append("{\"messageId\":\(jsonString(task.messageId)),\"success\":false,\"reason\":\"already claimed by you\",\"taskNumber\":\(task.taskNumber)}")
                continue
            }
            if let assignee = task.assigneeId, assignee != writer.agentId {
                results.append("{\"messageId\":\(jsonString(task.messageId)),\"success\":false,\"reason\":\"already claimed\",\"taskNumber\":\(task.taskNumber)}")
                continue
            }
            taskRecords[index].assigneeId = writer.agentId
            taskRecords[index].assigneeType = "agent"
            taskRecords[index].claimedAt = Date()
            if taskRecords[index].status == "todo" { taskRecords[index].status = "in_progress" }
            taskRecords[index].revision += 1
            let claimed = taskRecords[index]
            results.append("{\"messageId\":\(jsonString(claimed.messageId)),\"success\":true,\"taskNumber\":\(claimed.taskNumber)}")
        }
        lock.unlock()
        return Self.json(200, "{\"results\":[\(results.joined(separator: ","))]}")
    }

    public func agentTaskUpdateStatus(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let taskNumber = object["task_number"] as? Int,
              let status = object["status"] as? String,
              Self.validTaskStatuses.contains(status)
        else {
            return Self.json(400, "{\"error\":\"Invalid task status request\"}")
        }
        if let hold = taskWriteFreshnessHold(
            agentId: writer.agentId, channelId: channelId,
            seenUpToSeq: object["seenUpToSeq"] as? Int, actionKey: "update:\(taskNumber)"
        ) { return hold }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }),
              taskRecords[index].hasHostMessage
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let current = taskRecords[index]
        let isAdmin = oauth.agentRole(serverId: writer.serverId, agentId: writer.agentId) == "admin"
        if !isAdmin {
            if status == "todo", current.status == "in_progress", current.assigneeId != writer.agentId {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Task cannot transition from in_progress to todo\"}")
            }
            if current.status == "todo", ["done", "closed", "in_review", "cancelled"].contains(status) {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Task cannot transition from todo to \(status)\"}")
            }
        }
        if status == "done", taskRecords[index].requiresResourceReceipt, taskRecords[index].resourceReceiptJSON == nil {
            lock.unlock()
            return Self.json(409, "{\"error\":\"resource receipt required before task can move to done\"}")
        }
        taskRecords[index].status = status
        if status == "done" || status == "closed" { taskRecords[index].completedAt = Date() }
        if status == "in_progress" { taskRecords[index].claimedAt = Date() }
        if status == "todo" { taskRecords[index].claimedAt = nil }
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

}
