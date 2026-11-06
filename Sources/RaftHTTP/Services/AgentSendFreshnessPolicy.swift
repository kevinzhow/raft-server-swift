import Foundation

/// Pure message policy for notices that do not trip the send freshness gate.
enum AgentSendFreshnessPolicy {
    static func isSelfCausedExempt(_ message: StoredHumanMessage, agentId: String) -> Bool {
        message.messageType == "system"
            && message.causalActorType == "agent"
            && message.causalActorId == agentId
            && message.systemSubtype.map { AgentFreshnessIdentity.selfCausedFreshnessExemptSubtypes.contains($0) } == true
    }
}
