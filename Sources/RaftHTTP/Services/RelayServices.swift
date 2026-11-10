import Foundation

/// Installs the socket room sink and delivers events through its current snapshot.
/// The sink may change its installation while handling an event.
public struct RealtimeRelayService: Sendable {
    public typealias Emitter = @Sendable (String, String, String?) -> Void
    /// Grants one room to every live socket of one user. The hub that owns the
    /// sessions installs it; the message path calls it before publishing a new
    /// DM's first frame.
    public typealias RoomJoiner = @Sendable (_ userId: String, _ room: String) -> Void
    /// The upstream `socketUserServerRoom(userId, serverId).socketsJoin(room)`
    /// grant: only sessions attached to that server join, unlike `RoomJoiner`.
    public typealias ServerRoomJoiner = @Sendable (
        _ userId: String, _ serverId: String, _ room: String
    ) -> Void

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

    public func installRoomJoiner(_ joiner: RoomJoiner?) {
        messages.realtimeRoomJoinerStorage = joiner
    }

    public func installServerRoomJoiner(_ joiner: ServerRoomJoiner?) {
        messages.realtimeServerRoomJoinerStorage = joiner
    }

    public func joinUserSessions(_ userId: String, _ room: String) {
        let joiner = messages.realtimeRoomJoinerStorage
        joiner?(userId, room)
    }

    /// Prefer the server-scoped grant when installed. The unscoped fallback
    /// keeps unit fixtures that install only `RoomJoiner` working.
    public func joinUserServerSessions(_ userId: String, _ serverId: String, _ room: String) {
        let serverJoiner = messages.realtimeServerRoomJoinerStorage
        if let serverJoiner {
            serverJoiner(userId, serverId, room)
            return
        }
        let joiner = messages.realtimeRoomJoinerStorage
        joiner?(userId, room)
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
