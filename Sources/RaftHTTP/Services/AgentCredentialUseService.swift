import Foundation
import RaftShared

/// Records credential use through the agent owner, then publishes external
/// presence after the owner's throttle transaction has released its borrow.
struct AgentCredentialUseService: Sendable {
    private let agents: AgentsRuntimeStore
    private let oauth: OAuthLedger
    private let realtime: RealtimeRelayService

    init(agents: AgentsRuntimeStore, oauth: OAuthLedger, realtime: RealtimeRelayService) {
        self.agents = agents
        self.oauth = oauth
        self.realtime = realtime
    }

    func record(token: String) {
        guard let agentId = agents.recordCredentialUse(
            token: token,
            now: Date(),
            defaultThrottleMs: AuthTokenCodec.agentCredentialUseDefaultThrottleMs
        ) else { return }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.runtime == "external" else { return }
        realtime.emit(
            "server:\(agent.serverId)",
            "agent:seen",
            OrderedJSON.object([
                OrderedJSONField("agentId", agent.id),
                OrderedJSONField("lastSeenAt", DateText.isoString(Date())),
            ]).render()
        )
    }
}
