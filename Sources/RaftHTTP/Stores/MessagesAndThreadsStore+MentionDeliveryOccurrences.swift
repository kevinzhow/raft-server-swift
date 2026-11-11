import Foundation

/// `mention_delivery_occurrences` over the retained formal mention rows.
///
/// Upstream stores one occurrence row per notifiable agent mention, keyed by
/// the mention row id. This owner keeps the same value group on the mention row
/// it belongs to, so the occurrence and its mention facts are written, restored
/// and rolled back together. Every mutation is one `Messages` critical section.
extension MessagesAndThreadsStore {
    // MARK: - Reads

    /// One occurrence with the mention facts the sender projection publishes
    /// (`targetId`, authored handle, target type, message id).
    struct MentionDeliveryOccurrenceRow: Sendable, Equatable {
        var occurrenceId: String
        var messageId: String
        var channelId: String
        var targetId: String
        var targetType: String
        var handle: String
        var notifiableAtSend: Bool
        var notifiedAt: Date?
        var terminalCode: String?
        var occurrence: MentionDeliveryOccurrence
    }

    private func occurrenceRow(_ row: StoredMention) -> MentionDeliveryOccurrenceRow? {
        guard let occurrence = row.mentionDeliveryOccurrence else { return nil }
        return MentionDeliveryOccurrenceRow(
            occurrenceId: row.id, messageId: row.messageId, channelId: row.channelId,
            targetId: row.targetId, targetType: row.targetType, handle: row.handle,
            notifiableAtSend: row.notifiableAtSend, notifiedAt: row.notifiedAt,
            terminalCode: row.terminalCode, occurrence: occurrence)
    }

    /// `listMentionDeliveryOccurrencesForMessage(messageId)`.
    func mentionDeliveryOccurrences(messageId: String) -> [MentionDeliveryOccurrenceRow] {
        withState { state in
            state.storedMentions
                .filter { $0.messageId == messageId }
                .compactMap(occurrenceRow)
                .sorted { $0.occurrenceId < $1.occurrenceId }
        }
    }

    /// `getMentionDeliveryOccurrence(messageId, agentId)`.
    func mentionDeliveryOccurrence(messageId: String, agentId: String) -> MentionDeliveryOccurrenceRow? {
        withState { state in
            state.storedMentions.first {
                $0.messageId == messageId && $0.targetType == "agent" && $0.targetId == agentId
            }.flatMap(occurrenceRow)
        }
    }

    func mentionDeliveryOccurrence(occurrenceId: String) -> MentionDeliveryOccurrenceRow? {
        withState { state in
            state.storedMentions.first { $0.id == occurrenceId }.flatMap(occurrenceRow)
        }
    }

    /// `lookupMentionDeliveryOccurrence(messageId, agentId)`.
    func evaluateMentionDeliveryOccurrence(messageId: String, agentId: String) -> MentionDeliveryLookupResult {
        withState { state in
            guard let mention = state.storedMentions.first(where: {
                $0.messageId == messageId && $0.targetType == "agent" && $0.targetId == agentId
            }), let occurrence = mention.mentionDeliveryOccurrence else { return .notJoinable }
            return MentionDeliveryOccurrenceEvaluation.evaluate(occurrence)
        }
    }

    // MARK: - Creation and payload

    /// The occurrence `insertMentionRowsWithOccurrenceRecords` writes atomically
    /// with the mention facts. Callers run inside `recordMemberMentions`'s single
    /// critical section.
    static func initialMentionDeliveryOccurrence(for mention: StoredMention, host: StoredHumanMessage, at now: Date)
        -> MentionDeliveryOccurrence? {
        guard mention.targetType == "agent", mention.notifiableAtSend,
              // An agent that mentions itself is never delivered its own message,
              // so its occurrence could never gain a payload.
              !(host.senderType == "agent" && host.senderId == mention.targetId) else { return nil }
        return MentionDeliveryOccurrenceEvaluation.recorded(at: now)
    }

    /// `ensureAgentMentionDeliveryOccurrencesForAgents`: a mention resolved later
    /// (`notifiedAt` set by the sender's notify/add action) gains its occurrence
    /// when the delivery is prepared. Returns the occurrence id exactly once.
    @discardableResult
    func ensureMentionDeliveryOccurrence(mentionId: String) -> String? {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == mentionId }),
                  state.storedMentions[index].targetType == "agent",
                  state.storedMentions[index].notifiableAtSend || state.storedMentions[index].notifiedAt != nil else {
                return nil
            }
            if state.storedMentions[index].mentionDeliveryOccurrence == nil {
                state.storedMentions[index].mentionDeliveryOccurrence = MentionDeliveryOccurrenceEvaluation.recorded(at: Date())
            }
            return state.storedMentions[index].id
        }
    }

    /// The occurrence id for a mention that became deliverable after it was
    /// written (the sender's notify/add resolution sets `notifiedAt`). No
    /// occurrence is invented for a row that is neither notifiable at send nor
    /// later notified.
    @discardableResult
    func ensureMentionDeliveryOccurrence(messageId: String, agentId: String) -> String? {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: {
                $0.messageId == messageId && $0.targetType == "agent" && $0.targetId == agentId
            }), state.storedMentions[index].notifiableAtSend || state.storedMentions[index].notifiedAt != nil else {
                return nil
            }
            if state.storedMentions[index].mentionDeliveryOccurrence == nil {
                state.storedMentions[index].mentionDeliveryOccurrence = MentionDeliveryOccurrenceEvaluation.recorded(at: Date())
            }
            return state.storedMentions[index].id
        }
    }

    /// Persist the exact `AgentMessage` the server is about to deliver.
    /// Coalescing (`coalesce`) never replaces an earlier payload, matching the
    /// upstream `coalesce(delivery_payload, excluded.delivery_payload)` upsert.
    @discardableResult
    func attachMentionDeliveryPayload(occurrenceId: String, payloadJSON: String) -> Bool {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == occurrenceId }),
                  var occurrence = state.storedMentions[index].mentionDeliveryOccurrence else { return false }
            guard occurrence.deliveryPayloadJSON == nil else { return true }
            occurrence.deliveryPayloadJSON = payloadJSON
            state.storedMentions[index].mentionDeliveryOccurrence = occurrence
            return true
        }
    }

    // MARK: - Server decision and daemon receipts

    /// `recordMentionDeliveryServerDecision`. A terminal row and an already
    /// decided row with a different identity or payload are NOT re-delivered;
    /// returning nil is the idempotency guard against a second copy.
    func recordMentionDeliveryServerDecision(occurrenceId: String, payloadJSON: String,
                                             messageId: String, identity: MentionDeliveryOccurrenceEvaluation.Identity)
        -> MentionDeliveryOccurrenceRow? {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == occurrenceId }),
                  var occurrence = state.storedMentions[index].mentionDeliveryOccurrence else { return nil }
            if occurrence.state == MentionDeliveryState.acked.rawValue
                || occurrence.state == MentionDeliveryState.terminalError.rawValue { return nil }
            if occurrence.serverDecidedAt != nil {
                let same = occurrence.machineIdSnapshot == identity.machineId
                    && occurrence.launchIdSnapshot == identity.launchId
                    && occurrence.sessionIdSnapshot == identity.sessionId
                    && occurrence.deliveryPayloadJSON == payloadJSON
                return same ? occurrenceRow(state.storedMentions[index]) : nil
            }
            guard occurrence.state == MentionDeliveryState.recorded.rawValue else { return nil }
            occurrence.deliveryPayloadJSON = occurrence.deliveryPayloadJSON ?? payloadJSON
            occurrence.state = MentionDeliveryState.serverDecided.rawValue
            occurrence.machineIdSnapshot = identity.machineId
            occurrence.launchIdSnapshot = identity.launchId
            occurrence.sessionIdSnapshot = identity.sessionId
            occurrence.serverDecidedAt = Date()
            occurrence.version += 1
            state.storedMentions[index].mentionDeliveryOccurrence = occurrence
            return occurrenceRow(state.storedMentions[index])
        }
    }

    /// `recordMentionDeliveryDaemonTransition`. Every stage keeps the earliest
    /// receipt of that stage and only ever advances a non-terminal state.
    @discardableResult
    func recordMentionDeliveryDaemonTransition(occurrenceId: String, messageId: String, agentId: String,
                                               identity: MentionDeliveryOccurrenceEvaluation.Identity,
                                               stage: String, outcome: String?) -> MentionDeliveryOccurrenceRow? {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == occurrenceId }),
                  var occurrence = state.storedMentions[index].mentionDeliveryOccurrence,
                  state.storedMentions[index].messageId == messageId,
                  state.storedMentions[index].targetId == agentId,
                  MentionDeliveryOccurrenceEvaluation.identityMatches(occurrence, identity),
                  occurrence.ackedAt == nil, occurrence.terminalErrorAt == nil else { return nil }
            let now = Date()
            switch stage {
            case "daemon_received":
                occurrence.daemonReceivedAt = occurrence.daemonReceivedAt ?? now
                if occurrence.state == MentionDeliveryState.serverDecided.rawValue {
                    occurrence.state = MentionDeliveryState.daemonReceived.rawValue
                }
            case "daemon_pending":
                occurrence.daemonPendingAt = occurrence.daemonPendingAt ?? now
                occurrence.deliveryPath = "busy"
                if [MentionDeliveryState.serverDecided.rawValue,
                    MentionDeliveryState.daemonReceived.rawValue].contains(occurrence.state) {
                    occurrence.state = MentionDeliveryState.daemonPending.rawValue
                }
                if outcome == "coalesced" {
                    occurrence.pendingCoalescedCount += 1
                }
            case "daemon_drained":
                occurrence.daemonDrainedAt = occurrence.daemonDrainedAt ?? now
                if occurrence.deliveryPath != "busy" { occurrence.deliveryPath = "immediate" }
                occurrence.state = MentionDeliveryState.daemonDrained.rawValue
            default:
                return nil
            }
            occurrence.version += 1
            state.storedMentions[index].mentionDeliveryOccurrence = occurrence
            return occurrenceRow(state.storedMentions[index])
        }
    }

    /// `recordMentionDeliveryAck`: the terminal daemon receipt. It requires the
    /// drained transition, so an ack alone can never claim delivery.
    @discardableResult
    func recordMentionDeliveryAck(occurrenceId: String, messageId: String, agentId: String,
                                  identity: MentionDeliveryOccurrenceEvaluation.Identity)
        -> MentionDeliveryOccurrenceRow? {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == occurrenceId }),
                  var occurrence = state.storedMentions[index].mentionDeliveryOccurrence,
                  state.storedMentions[index].messageId == messageId,
                  state.storedMentions[index].targetId == agentId,
                  MentionDeliveryOccurrenceEvaluation.identityMatches(occurrence, identity),
                  occurrence.daemonDrainedAt != nil,
                  occurrence.ackedAt == nil, occurrence.terminalErrorAt == nil else { return nil }
            occurrence.state = MentionDeliveryState.acked.rawValue
            occurrence.ackedAt = Date()
            occurrence.version += 1
            state.storedMentions[index].mentionDeliveryOccurrence = occurrence
            return occurrenceRow(state.storedMentions[index])
        }
    }

    /// `recordMentionDeliveryTerminalError` and its identity-drift variant.
    @discardableResult
    func recordMentionDeliveryTerminalError(occurrenceId: String, messageId: String, agentId: String,
                                            identity: MentionDeliveryOccurrenceEvaluation.Identity,
                                            code: String, decision: MentionDeliveryTerminalDecision,
                                            requireIdentity: Bool) -> MentionDeliveryOccurrenceRow? {
        guard MentionDeliveryTerminalCodes.all.contains(code) else { return nil }
        return withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == occurrenceId }),
                  var occurrence = state.storedMentions[index].mentionDeliveryOccurrence,
                  state.storedMentions[index].messageId == messageId,
                  state.storedMentions[index].targetId == agentId,
                  !requireIdentity || MentionDeliveryOccurrenceEvaluation.identityMatches(occurrence, identity),
                  occurrence.ackedAt == nil, occurrence.terminalErrorAt == nil else { return nil }
            occurrence.state = MentionDeliveryState.terminalError.rawValue
            occurrence.terminalErrorAt = Date()
            occurrence.terminalErrorCode = code
            occurrence.terminalDecision = decision
            occurrence.version += 1
            state.storedMentions[index].mentionDeliveryOccurrence = occurrence
            return occurrenceRow(state.storedMentions[index])
        }
    }

    /// `abandonMentionDeliveryWithoutInstrumentation`: one-shot CAS out of the
    /// pre-decision fanout state. Only the winner owns the untracked delivery.
    @discardableResult
    func abandonMentionDeliveryWithoutInstrumentation(occurrenceId: String) -> MentionDeliveryOccurrenceRow? {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == occurrenceId }),
                  var occurrence = state.storedMentions[index].mentionDeliveryOccurrence,
                  occurrence.state == MentionDeliveryState.recorded.rawValue,
                  occurrence.serverDecidedAt == nil, occurrence.ackedAt == nil,
                  occurrence.terminalErrorAt == nil else { return nil }
            occurrence.state = MentionDeliveryState.terminalError.rawValue
            occurrence.terminalErrorAt = Date()
            occurrence.terminalErrorCode = "INSTRUMENT_FAILED"
            occurrence.terminalDecision = MentionDeliveryTerminalDecision(
                layer: "server", stage: "instrumentation_fallback", originalDaemonCode: nil)
            occurrence.version += 1
            state.storedMentions[index].mentionDeliveryOccurrence = occurrence
            return occurrenceRow(state.storedMentions[index])
        }
    }

    // MARK: - Recovery listings and claim

    enum MentionDeliveryRecoveryClaim: Sendable, Equatable {
        case claimed(occurrence: MentionDeliveryOccurrence)
        case exhausted(occurrence: MentionDeliveryOccurrence)
        case stale
    }

    /// `claimMentionDeliveryRecovery`. Rows the daemon never received keep
    /// recovering without limit; rows the daemon already holds spend one round
    /// and past `maxRounds` become terminal `REDELIVERY_EXHAUSTED`.
    func claimMentionDeliveryRecovery(occurrenceId: String, expectedVersion: Int,
                                      maxRounds: Int = MentionDeliveryOccurrenceEvaluation.maxRecoveryRounds)
        -> MentionDeliveryRecoveryClaim {
        withState { state in
            guard let index = state.storedMentions.firstIndex(where: { $0.id == occurrenceId }),
                  var occurrence = state.storedMentions[index].mentionDeliveryOccurrence,
                  occurrence.version == expectedVersion,
                  occurrence.ackedAt == nil, occurrence.terminalErrorAt == nil else { return .stale }
            let daemonHeld = [MentionDeliveryState.daemonReceived.rawValue,
                              MentionDeliveryState.daemonPending.rawValue].contains(occurrence.state)
            guard daemonHeld else {
                // Never reached the daemon: this trigger does not spend budget.
                return .claimed(occurrence: occurrence)
            }
            if occurrence.recoveryCount < maxRounds {
                occurrence.recoveryCount += 1
                occurrence.version += 1
                state.storedMentions[index].mentionDeliveryOccurrence = occurrence
                return .claimed(occurrence: occurrence)
            }
            occurrence.state = MentionDeliveryState.terminalError.rawValue
            occurrence.terminalErrorAt = Date()
            occurrence.terminalErrorCode = "REDELIVERY_EXHAUSTED"
            occurrence.terminalDecision = MentionDeliveryTerminalDecision(
                layer: "server", stage: "recovery_exhausted", originalDaemonCode: nil)
            occurrence.version += 1
            state.storedMentions[index].mentionDeliveryOccurrence = occurrence
            return .exhausted(occurrence: occurrence)
        }
    }

    /// `listRecoverableMentionDeliveries(machineId)`: already server-decided rows
    /// for this machine that are not terminal.
    ///
    /// Unlike upstream this does not require a stored payload: this port builds
    /// and persists the exact `AgentMessage` in the materializer immediately
    /// before the wire write, so a decided row without one is a row whose
    /// dispatch never prepared a frame. Recovery stages the command; the
    /// materializer attaches the payload and freezes the decision.
    func recoverableMentionDeliveries(machineId: String) -> [MentionDeliveryOccurrenceRow] {
        withState { state in
            state.storedMentions.compactMap(occurrenceRow).filter {
                $0.occurrence.machineIdSnapshot == machineId
                    && $0.occurrence.serverDecidedAt != nil
                    && $0.occurrence.ackedAt == nil
                    && $0.occurrence.terminalErrorAt == nil
                    && [MentionDeliveryState.serverDecided.rawValue,
                        MentionDeliveryState.daemonReceived.rawValue,
                        MentionDeliveryState.daemonPending.rawValue].contains($0.occurrence.state)
            }.sorted { $0.occurrenceId < $1.occurrenceId }
        }
    }

    /// `listRecoverableMentionDeliveriesForAgent(machineId, agentId)`: includes
    /// rows with no server decision yet (the `agent:session` path decides them
    /// with the session identity that just became known).
    func recoverableMentionDeliveries(machineId: String, agentId: String) -> [MentionDeliveryOccurrenceRow] {
        withState { state in
            state.storedMentions.compactMap(occurrenceRow).filter {
                $0.targetType == "agent" && $0.targetId == agentId
                    && $0.occurrence.ackedAt == nil
                    && $0.occurrence.terminalErrorAt == nil
                    && [MentionDeliveryState.recorded.rawValue,
                        MentionDeliveryState.serverDecided.rawValue,
                        MentionDeliveryState.daemonReceived.rawValue,
                        MentionDeliveryState.daemonPending.rawValue].contains($0.occurrence.state)
                    && ($0.occurrence.machineIdSnapshot == nil || $0.occurrence.machineIdSnapshot == machineId)
            }.sorted { $0.occurrenceId < $1.occurrenceId }
        }
    }
}
