import Foundation

/// The legacy machine-key surface: knowledge, message resolve, receive, the
/// task list and the server avatar upload.
///
/// Upstream `/internal/agent/:id/*` routes run `requireMachineAuth` and
/// `requireAgentScope(scope)` before their handler. `LegacyAgentMachineGate`
/// owns that one gate (the machine row or daemon-compat key row, the
/// agent/server match, the exact machine ownership and the keyed grant set);
/// this service only runs the operation for the actor the gate resolved. It
/// never authenticates, so a route cannot accidentally skip or duplicate the
/// published gate. `receive` is the one projection the port owns directly,
/// because the pinned server's queued inbox belongs to an agent orchestrator
/// the port does not have.
public struct LegacyAgentSurfaceService: Sendable {
    private let tasksAndLabs: TasksAndLabsService
    private let messageLookup: AgentMessageLookupService
    private let agentChannels: AgentChannelsService

    init(
        tasksAndLabs: TasksAndLabsService,
        messageLookup: AgentMessageLookupService,
        agentChannels: AgentChannelsService
    ) {
        self.tasksAndLabs = tasksAndLabs
        self.messageLookup = messageLookup
        self.agentChannels = agentChannels
    }

    // MARK: - GET /internal/agent/:id/messages/:messageId/resolve

    public func messageResolve(
        actor: LegacyAgentMachineActor,
        messageRef: String
    ) throws -> AgentMessageResolveResponse {
        try messageLookup.messageResolve(agent: actor.agent, messageRef: messageRef)
    }

    // MARK: - GET /internal/agent/:id/receive

    /// The legacy daemon long poll.
    ///
    /// The pinned route drains the machine inbox held by `agentOrchestrator`.
    /// This port has no in-process inbox, so a receive is an empty delivery:
    /// `{"messages":[]}`. `block` and `timeout` are validated by the route and
    /// then ignored; they cannot make a queued message appear. The middleware
    /// still authenticates and gates the call before answering, so it is not an
    /// unauthenticated empty probe.
    public func receive(actor: LegacyAgentMachineActor) throws -> AgentReceiveMessagesResponse {
        _ = actor
        return AgentReceiveMessagesResponse()
    }

    // MARK: - GET /internal/agent/:id/tasks

    public func tasks(
        actor: LegacyAgentMachineActor,
        channelRef: String,
        rawQuery: String?
    ) throws -> LegacyAgentTaskListResponse {
        guard !channelRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskApiError.channelQueryRequired
        }
        return try tasksAndLabs.legacyAgentTasks(
            agent: actor.agent, channelRef: channelRef, rawQuery: rawQuery
        )
    }

    // MARK: - POST /internal/agent/:id/server/avatar

    public func uploadServerAvatar(
        actor: LegacyAgentMachineActor,
        byteCount: Int
    ) throws -> ServerProfilePatchResponse {
        try agentChannels.uploadServerAvatar(agent: actor.agent, byteCount: byteCount)
    }
}
