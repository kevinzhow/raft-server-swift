@testable import RaftHTTP
import Foundation

/// Durable mention-delivery occurrence seams for published-path tests. Every
/// helper drives the real `MessagesAndThreadsStore` occurrence transitions; it
/// never writes a projection or an outcome directly.
extension EmailLoginDirectory {
    public func mentionDeliveryOccurrenceStateForTesting(messageId: String, agentId: String) -> String? {
        messagesAndThreadsStore.mentionDeliveryOccurrence(messageId: messageId, agentId: agentId)?
            .occurrence.state
    }

    public func mentionDeliveryOutcomeForTesting(messageId: String, agentId: String) -> String {
        let occurrence = messagesAndThreadsStore.mentionDeliveryOccurrence(messageId: messageId, agentId: agentId)?
            .occurrence
        switch MentionDeliverySenderProjection.outcome(occurrence: occurrence) {
        case .delivered: return "delivered"
        case .pending: return "pending"
        case .lost(let category): return "lost:\(category)"
        case .unknown: return "unknown"
        }
    }

    private static let mentionDeliveryTestIdentity = MentionDeliveryOccurrenceEvaluation.Identity(
        machineId: "mention-test-machine", launchId: "mention-test-launch", sessionId: "mention-test-session")

    /// Freeze the server decision and (optionally) walk the daemon receipts.
    /// `nil` outcome leaves the occurrence decided but undelivered (`pending`).
    @discardableResult
    public func advanceMentionDeliveryForTesting(
        messageId: String, agentId: String,
        outcome: String?,
        pendingCoalesced: Bool = false
    ) -> Bool {
        let identity = Self.mentionDeliveryTestIdentity
        guard let row = messagesAndThreadsStore.mentionDeliveryOccurrence(messageId: messageId, agentId: agentId) else { return false }
        let payload = row.occurrence.deliveryPayloadJSON ?? "{\"message_id\":\"\(messageId)\"}"
        guard messagesAndThreadsStore.attachMentionDeliveryPayload(occurrenceId: row.occurrenceId, payloadJSON: payload),
              messagesAndThreadsStore.recordMentionDeliveryServerDecision(
                occurrenceId: row.occurrenceId, payloadJSON: payload, messageId: messageId,
                identity: identity) != nil else { return false }
        guard let outcome else { return true }
        switch outcome {
        case "delivered":
            _ = messagesAndThreadsStore.recordMentionDeliveryDaemonTransition(
                occurrenceId: row.occurrenceId, messageId: messageId, agentId: agentId, identity: identity,
                stage: "daemon_received", outcome: "accepted")
            _ = messagesAndThreadsStore.recordMentionDeliveryDaemonTransition(
                occurrenceId: row.occurrenceId, messageId: messageId, agentId: agentId, identity: identity,
                stage: "daemon_drained", outcome: "accepted")
            return messagesAndThreadsStore.recordMentionDeliveryAck(
                occurrenceId: row.occurrenceId, messageId: messageId, agentId: agentId, identity: identity) != nil
        case "daemon_pending":
            _ = messagesAndThreadsStore.recordMentionDeliveryDaemonTransition(
                occurrenceId: row.occurrenceId, messageId: messageId, agentId: agentId, identity: identity,
                stage: "daemon_received", outcome: "accepted")
            return messagesAndThreadsStore.recordMentionDeliveryDaemonTransition(
                occurrenceId: row.occurrenceId, messageId: messageId, agentId: agentId, identity: identity,
                stage: "daemon_pending", outcome: pendingCoalesced ? "coalesced" : "accepted") != nil
        case "instrument_failed":
            return messagesAndThreadsStore.abandonMentionDeliveryWithoutInstrumentation(
                occurrenceId: row.occurrenceId) != nil
        default:
            let decision = MentionDeliveryTerminalDecision(layer: "daemon", stage: "terminal_receipt",
                                                           originalDaemonCode: outcome)
            return messagesAndThreadsStore.recordMentionDeliveryTerminalError(
                occurrenceId: row.occurrenceId, messageId: messageId, agentId: agentId, identity: identity,
                code: outcome, decision: decision, requireIdentity: true) != nil
        }
    }

    /// The notify/add resolution path ensures the occurrence for a mention that
    /// was not notifiable at send time.
    @discardableResult
    public func ensureMentionDeliveryOccurrenceForTesting(messageId: String, agentId: String) -> String? {
        messagesAndThreadsStore.ensureMentionDeliveryOccurrence(messageId: messageId, agentId: agentId)
    }

    /// The occurrence id of a message's mention row, if the send path recorded one.
    public func mentionDeliveryOccurrenceIdForTesting(messageId: String, agentId: String) -> String? {
        messagesAndThreadsStore.mentionDeliveryOccurrence(messageId: messageId, agentId: agentId)?.occurrenceId
    }
}
