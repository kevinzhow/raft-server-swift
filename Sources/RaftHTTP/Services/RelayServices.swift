import Foundation

/// Installs the socket room sink and delivers events through its current snapshot.
/// The sink may change its installation while handling an event.
public struct RealtimeRelayService: Sendable {
    public typealias Emitter = @Sendable (String, String, String?) -> Void

    private let messages: MessagesAndThreadsStore

    init(messages: MessagesAndThreadsStore) {
        self.messages = messages
    }

    public func install(_ emitter: Emitter?) {
        messages.realtimeEmitterStorage = emitter
    }

    public func emit(_ room: String, _ event: String, _ payload: String?) {
        let emitter = messages.realtimeEmitterStorage
        emitter?(room, event, payload)
    }
}

/// Dispatches provider requests using the currently installed connection relay.
/// Provider execution happens after the owned slot snapshot has been released.
public struct AgentConnectionRelayService: Sendable {
    public typealias Provider = @Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult

    private let agents: AgentsRuntimeStore

    init(agents: AgentsRuntimeStore) {
        self.agents = agents
    }

    public func install(_ provider: Provider?) {
        agents.agentConnectionProviderStorage = provider
    }

    public func call(_ request: AgentConnectionProviderRequest) -> AgentConnectionProviderResult {
        guard let provider = agents.agentConnectionProviderStorage else { return .unavailable }
        return provider(request)
    }
}
