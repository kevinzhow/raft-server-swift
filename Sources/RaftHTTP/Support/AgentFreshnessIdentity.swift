import Foundation

public enum AgentFreshnessIdentity {
    static func freshnessDecisionProducerFactId(
        agentId: String, target: String, reason: String, pendingMaxSeq: Int,
        modelSeenSeq: Int, heldMessageCount: Int, omittedMessageCount: Int
    ) -> String {
        let payload = OrderedJSON.object([
            OrderedJSONField("action", "send"), OrderedJSONField("agentId", agentId),
            OrderedJSONField("decision", "syncing_hold"), OrderedJSONField("heldMessageCount", heldMessageCount),
            OrderedJSONField("modelSeenSeq", modelSeenSeq), OrderedJSONField("omittedMessageCount", omittedMessageCount),
            OrderedJSONField("pendingMaxSeq", pendingMaxSeq), OrderedJSONField("reason", reason),
            OrderedJSONField("target", target),
        ]).render()
        return "freshness_decision_fact:" + AuthTokenCodec.sha256Hex(payload)
    }

    static let selfCausedFreshnessExemptSubtypes: Set<String> = ["task.created_summary"]
}
