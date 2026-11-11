import Foundation
import Testing
@testable import RaftHTTP

/// The durable mention-delivery occurrence spine: creation, the upstream state
/// machine, receipts, identity drift, bounded recovery and snapshot
/// compatibility. These are owner-level cases; the published HTTP projections
/// are covered separately.
@Suite(.serialized) struct MentionDeliveryOccurrenceTests {
    private struct Fixture: Sendable {
        let messages: MessagesAndThreadsStore
        let server = "occurrence-server"
        let channel = "occurrence-channel"
        let message = "occurrence-message"
        let agent = "occurrence-agent"
    }

    private func fixture(senderType: String = "user", senderId: String = "occurrence-author",
                         notifiable: Bool = true, mentionType: String = "agent") -> Fixture {
        let fixture = Fixture(messages: MessagesAndThreadsStore())
        fixture.messages.withState { state in
            state.humanMessageRows.append(StoredHumanMessage(
                id: fixture.message, channelId: fixture.channel, senderId: senderId,
                content: "ping @Cindy", seq: 7, messageType: "user", senderType: senderType))
            state.storedMentions.append(contentsOf: [])
        }
        fixture.messages.recordMemberMentions(
            messageId: fixture.message, channelId: fixture.channel,
            registrations: [.init(
                mention: MentionInput(type: mentionType, id: fixture.agent, name: "Cindy"),
                notifiableAtSend: notifiable)])
        return fixture
    }

    private let identity = MentionDeliveryOccurrenceEvaluation.Identity(
        machineId: "machine-1", launchId: "launch-1", sessionId: "session-1")

    private func decide(_ f: Fixture, outcome: String? = nil) -> MessagesAndThreadsStore.MentionDeliveryOccurrenceRow? {
        guard let row = f.messages.mentionDeliveryOccurrence(messageId: f.message, agentId: f.agent) else { return nil }
        let payload = "{\"message_id\":\"\(f.message)\",\"seq\":7}"
        guard f.messages.attachMentionDeliveryPayload(occurrenceId: row.occurrenceId, payloadJSON: payload),
              f.messages.recordMentionDeliveryServerDecision(
                occurrenceId: row.occurrenceId, payloadJSON: payload, messageId: f.message,
                identity: identity) != nil else { return nil }
        return f.messages.mentionDeliveryOccurrence(messageId: f.message, agentId: f.agent)
    }

    @Test func formalNotifiableAgentMentionRecordsAnOccurrenceAtomically() {
        let f = fixture()
        let row = f.messages.mentionDeliveryOccurrence(messageId: f.message, agentId: f.agent)
        #expect(row?.occurrence.state == "recorded")
        #expect(row?.occurrence.mentionRecordedAt != nil)
        #expect(row?.occurrence.deliveryPayloadJSON == nil)
        #expect(row?.occurrence.version == 0)
    }

    @Test func noOccurrenceForUserSelfNonNotifiableOrNonAgentMentions() {
        #expect(fixture(mentionType: "user").messages
            .mentionDeliveryOccurrence(messageId: "occurrence-message", agentId: "occurrence-agent") == nil)
        // An agent that mentions itself is never delivered its own message.
        #expect(fixture(senderType: "agent", senderId: "occurrence-agent").messages
            .mentionDeliveryOccurrence(messageId: "occurrence-message", agentId: "occurrence-agent") == nil)
        // An outsider mention is not formal at send; the notify action ensures one.
        let outsider = fixture(notifiable: false)
        #expect(outsider.messages
            .mentionDeliveryOccurrence(messageId: outsider.message, agentId: outsider.agent) == nil)
        #expect(outsider.messages.ensureMentionDeliveryOccurrence(
            messageId: outsider.message, agentId: outsider.agent) == nil)
        outsider.messages.withState { state in
            if let index = state.storedMentions.firstIndex(where: { $0.messageId == outsider.message }) {
                state.storedMentions[index].notifiedAt = Date()
                state.storedMentions[index].notifiedAction = "notify_only"
            }
        }
        #expect(outsider.messages.ensureMentionDeliveryOccurrence(
            messageId: outsider.message, agentId: outsider.agent) != nil)
    }

    @Test func upstreamEvaluateProjectionAndReceipts() throws {
        // No server decision yet: a broken hop is still in flight, not lost.
        let undecided = fixture()
        #expect(undecided.messages.evaluateMentionDeliveryOccurrence(
            messageId: undecided.message, agentId: undecided.agent) == .brokenHop(hop: "SERVER_DECISION", version: 0))
        #expect(mentionOutcome(undecided) == "pending")

        // A server decision without a daemon receipt: DAEMON_RECEIVE is the hop.
        let decided = fixture()
        _ = decide(decided)
        #expect(decided.messages.evaluateMentionDeliveryOccurrence(
            messageId: decided.message, agentId: decided.agent) == .brokenHop(hop: "DAEMON_RECEIVE", version: 1))

        // Busy path with the pending receipt, then the drain, then the ACK.
        let busy = fixture()
        let busyRow = try #require(decide(busy))
        _ = busy.messages.recordMentionDeliveryDaemonTransition(
            occurrenceId: busyRow.occurrenceId, messageId: busy.message, agentId: busy.agent,
            identity: identity, stage: "daemon_received", outcome: "accepted")
        _ = busy.messages.recordMentionDeliveryDaemonTransition(
            occurrenceId: busyRow.occurrenceId, messageId: busy.message, agentId: busy.agent,
            identity: identity, stage: "daemon_pending", outcome: "coalesced")
        let busyState = try #require(busy.messages.mentionDeliveryOccurrence(
            messageId: busy.message, agentId: busy.agent)).occurrence
        #expect(busyState.state == "daemon_pending")
        #expect(busyState.deliveryPath == "busy")
        #expect(busyState.pendingCoalescedCount == 1)
        #expect(busy.messages.evaluateMentionDeliveryOccurrence(
            messageId: busy.message, agentId: busy.agent) == .brokenHop(hop: "DAEMON_DRAIN", version: busyState.version))

        _ = busy.messages.recordMentionDeliveryDaemonTransition(
            occurrenceId: busyRow.occurrenceId, messageId: busy.message, agentId: busy.agent,
            identity: identity, stage: "daemon_drained", outcome: "accepted")
        #expect(busy.messages.evaluateMentionDeliveryOccurrence(
            messageId: busy.message, agentId: busy.agent) == .brokenHop(hop: "ACK", version: 4))
        _ = busy.messages.recordMentionDeliveryAck(
            occurrenceId: busyRow.occurrenceId, messageId: busy.message, agentId: busy.agent, identity: identity)
        guard case .acked = busy.messages.evaluateMentionDeliveryOccurrence(
            messageId: busy.message, agentId: busy.agent) else {
            Issue.record("an ACK after daemon_drained is the delivered terminal")
            return
        }
        #expect(mentionOutcome(busy) == "delivered")

        // A daemon terminal refusal outranks earlier receipts.
        let lost = fixture()
        let lostRow = try #require(decide(lost))
        _ = lost.messages.recordMentionDeliveryTerminalError(
            occurrenceId: lostRow.occurrenceId, messageId: lost.message, agentId: lost.agent,
            identity: identity, code: "QUOTA_LIMITED",
            decision: .init(layer: "daemon", stage: "terminal_receipt", originalDaemonCode: "QUOTA_LIMITED"),
            requireIdentity: true)
        #expect(lost.messages.evaluateMentionDeliveryOccurrence(
            messageId: lost.message, agentId: lost.agent) == .terminalError(code: "QUOTA_LIMITED", version: 2))
        #expect(mentionOutcome(lost) == "lost:quota")

        // An ack alone can never claim delivery: the drained receipt is required.
        let premature = fixture()
        let prematureRow = try #require(decide(premature))
        #expect(premature.messages.recordMentionDeliveryAck(
            occurrenceId: prematureRow.occurrenceId, messageId: premature.message,
            agentId: premature.agent, identity: identity) == nil)

        // An abandoned occurrence reports the instrumentation failure, never a
        // verdict about the target.
        let abandoned = fixture()
        let abandonedRow = try #require(abandoned.messages.mentionDeliveryOccurrence(
            messageId: abandoned.message, agentId: abandoned.agent))
        #expect(abandoned.messages.abandonMentionDeliveryWithoutInstrumentation(
            occurrenceId: abandonedRow.occurrenceId) != nil)
        #expect(abandoned.messages.recordMentionDeliveryAck(
            occurrenceId: abandonedRow.occurrenceId, messageId: abandoned.message,
            agentId: abandoned.agent, identity: identity) == nil)
        #expect(mentionOutcome(abandoned) == "unknown")
    }

    @Test func aReceiptFromAnotherIdentityIsRefusedAndDriftsTerminal() throws {
        let f = fixture()
        let row = try #require(decide(f))
        let other = MentionDeliveryOccurrenceEvaluation.Identity(
            machineId: identity.machineId, launchId: "launch-2", sessionId: "session-2")
        #expect(f.messages.recordMentionDeliveryDaemonTransition(
            occurrenceId: row.occurrenceId, messageId: f.message, agentId: f.agent, identity: other,
            stage: "daemon_received", outcome: "accepted") == nil)
        #expect(f.messages.recordMentionDeliveryAck(
            occurrenceId: row.occurrenceId, messageId: f.message, agentId: f.agent, identity: other) == nil)
        #expect(f.messages.recordMentionDeliveryTerminalError(
            occurrenceId: row.occurrenceId, messageId: f.message, agentId: f.agent, identity: other,
            code: "IDENTITY_DRIFT",
            decision: .init(layer: "server", stage: "stage_receipt", originalDaemonCode: nil),
            requireIdentity: true) == nil)
    }

    @Test func recoveryRoundsAreBoundedOnlyForDaemonHeldRows() throws {
        let f = fixture()
        let row = try #require(decide(f))
        _ = f.messages.recordMentionDeliveryDaemonTransition(
            occurrenceId: row.occurrenceId, messageId: f.message, agentId: f.agent,
            identity: identity, stage: "daemon_received", outcome: "accepted")
        var version = try #require(f.messages.mentionDeliveryOccurrence(
            messageId: f.message, agentId: f.agent)).occurrence.version
        for round in 1...MentionDeliveryOccurrenceEvaluation.maxRecoveryRounds {
            guard case .claimed(let claimed) = f.messages.claimMentionDeliveryRecovery(
                occurrenceId: row.occurrenceId, expectedVersion: version) else {
                Issue.record("round \(round) is within the budget")
                return
            }
            #expect(claimed.recoveryCount == round)
            version = claimed.version
        }
        guard case .exhausted(let exhausted) = f.messages.claimMentionDeliveryRecovery(
            occurrenceId: row.occurrenceId, expectedVersion: version) else {
            Issue.record("the fourth round past the budget is terminal")
            return
        }
        #expect(exhausted.state == "terminal_error")
        #expect(exhausted.terminalErrorCode == "REDELIVERY_EXHAUSTED")
        #expect(f.messages.recoverableMentionDeliveries(machineId: identity.machineId).isEmpty)

        // A row the daemon never received keeps recovering without spending.
        let undecided = fixture()
        _ = decide(undecided)
        let undecidedRow = try #require(undecided.messages.mentionDeliveryOccurrence(
            messageId: undecided.message, agentId: undecided.agent))
        for _ in 0..<5 {
            guard case .claimed(let claimed) = undecided.messages.claimMentionDeliveryRecovery(
                occurrenceId: undecidedRow.occurrenceId, expectedVersion: undecidedRow.occurrence.version) else {
                Issue.record("a row the daemon never received is unbounded")
                return
            }
            #expect(claimed.recoveryCount == 0)
        }
    }

    @Test func recoverableListingsGateOnPayloadMachineAndTerminalState() throws {
        // A recorded row still waiting for its session identity is listed for
        // the agent pass (the materializer attaches the payload and freezes the
        // decision), but never for the machine pass, which replays decided rows.
        let undecided = fixture()
        #expect(undecided.messages.recoverableMentionDeliveries(machineId: identity.machineId).isEmpty)
        #expect(undecided.messages.recoverableMentionDeliveries(
            machineId: identity.machineId, agentId: undecided.agent).count == 1)

        let f = fixture()
        _ = decide(f)
        let machineRows = f.messages.recoverableMentionDeliveries(machineId: identity.machineId)
        #expect(machineRows.map(\.occurrenceId).count == 1)
        #expect(machineRows.first?.occurrence.state == "server_decided")
        #expect(f.messages.recoverableMentionDeliveries(
            machineId: identity.machineId, agentId: f.agent).count == 1)
        // A row decided for another machine is not this machine's recovery.
        #expect(f.messages.recoverableMentionDeliveries(machineId: "other-machine").isEmpty)
        // An acked row leaves the listing.
        #expect(advanceToAck(f))
        #expect(f.messages.recoverableMentionDeliveries(machineId: identity.machineId).isEmpty)
        #expect(f.messages.recoverableMentionDeliveries(
            machineId: identity.machineId, agentId: f.agent).isEmpty)
    }

    private func advanceToAck(_ f: Fixture) -> Bool {
        guard let row = f.messages.mentionDeliveryOccurrence(messageId: f.message, agentId: f.agent) else { return false }
        _ = f.messages.recordMentionDeliveryDaemonTransition(
            occurrenceId: row.occurrenceId, messageId: f.message, agentId: f.agent, identity: identity,
            stage: "daemon_received", outcome: "accepted")
        _ = f.messages.recordMentionDeliveryDaemonTransition(
            occurrenceId: row.occurrenceId, messageId: f.message, agentId: f.agent, identity: identity,
            stage: "daemon_drained", outcome: "accepted")
        return f.messages.recordMentionDeliveryAck(
            occurrenceId: row.occurrenceId, messageId: f.message, agentId: f.agent, identity: identity) != nil
    }

    @Test func occurrenceGroupIsACompatibleOptionalSnapshotKey() throws {
        let mention = StoredMention(
            id: "occurrence-id", messageId: "occurrence-message", channelId: "occurrence-channel",
            senderId: "occurrence-author", targetType: "agent", targetId: "occurrence-agent",
            handle: "Cindy", notifiableAtSend: true,
            mentionDeliveryOccurrence: MentionDeliveryOccurrenceEvaluation.recorded(at: Date()))
        let encoded = try JSONEncoder().encode(MessagingPersistenceStoredMentionDTO(mention))
        let restored = try JSONDecoder().decode(MessagingPersistenceStoredMentionDTO.self, from: encoded).value
        #expect(restored.mentionDeliveryOccurrence?.state == "recorded")
        #expect(restored.mentionDeliveryOccurrence?.recoveryCount == 0)

        // A snapshot written before the spine has no key at all and restores.
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "mentionDeliveryOccurrence")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let legacyRestored = try JSONDecoder().decode(MessagingPersistenceStoredMentionDTO.self, from: legacy).value
        #expect(legacyRestored.mentionDeliveryOccurrence == nil)
        #expect(legacyRestored.terminalCode == nil)

        // Without an occurrence the key is omitted, so an older reader is unaffected.
        let plain = StoredMention(
            id: "plain-id", messageId: "occurrence-message", channelId: "occurrence-channel",
            senderId: "occurrence-author", targetType: "user", targetId: "peer", handle: "peer",
            notifiableAtSend: false)
        let plainObject = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MessagingPersistenceStoredMentionDTO(plain))) as? [String: Any])
        #expect(plainObject["mentionDeliveryOccurrence"] == nil)
    }

    private func mentionOutcome(_ f: Fixture) -> String {
        let occurrence = f.messages.mentionDeliveryOccurrence(messageId: f.message, agentId: f.agent)?.occurrence
        switch MentionDeliverySenderProjection.outcome(occurrence: occurrence) {
        case .delivered: return "delivered"
        case .pending: return "pending"
        case .lost(let category): return "lost:\(category)"
        case .unknown: return "unknown"
        }
    }
}
