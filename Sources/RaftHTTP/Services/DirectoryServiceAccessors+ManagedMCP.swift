import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Managed-MCP service accessors, moved out of `DirectoryServiceAccessors.swift`
/// (pure move) to keep that file under the Services line ceiling.
extension EmailLoginDirectory {
    /// Read mutations, joint-invite accept, the channel list, profile
    /// completion and the server create/details/analytics routes. The human
    /// session lookup belongs to the unmigrated auth domain and enters as a
    /// closure.
    public var managedMCPLifecycle: ManagedMCPLifecycleService {
        ManagedMCPLifecycleService(
            sessionUserId: { [self] in sessionUserId(authorization: $0) },
            oauth: oauth,
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            profiles: authProfileStore
        )
    }

    /// Provider connections (list, create, patch, rotate, retired probe,
    /// assigned agents).
    public var managedMCPProviderConnections: ManagedMCPProviderConnectionsService {
        ManagedMCPProviderConnectionsService(
            sessionUserId: { [self] in sessionUserId(authorization: $0) },
            oauth: oauth,
            providers: managedMCPAndCardsStore
        )
    }

    /// Push registration, browser subscription, delivery status, unbind and the
    /// family-revoke capability.
    public var managedMCPPush: ManagedMCPPushService {
        ManagedMCPPushService(
            oauth: oauth,
            profiles: authProfileStore,
            notifications: notificationsStore
        )
    }

    /// Announcements, external avatars, channel unread and notification
    /// settings, the agent user lookups and the app-installation reminder
    /// write. The session lookup, the agent credential resolution, the guest
    /// visibility rule and the human-message append belong to unmigrated
    /// domains and enter as closures.
    public var managedMCPOAuth: ManagedMCPOAuthService {
        ManagedMCPOAuthService(dependencies: ManagedMCPOAuthDependencies(
            sessionUserId: { [self] in sessionUserId(authorization: $0) },
            agentIdentity: { [self] authorization, capability in
                switch feedbackLocators.identityResolution(authorization: authorization, capability: capability) {
                case .success(let agentId, let serverId):
                    return (agentId: agentId, serverId: serverId)
                case .missingAuthorization, .invalidAccessToken, .capabilityNotAuthorized,
                     .invalidAgentCredential:
                    return nil
                }
            },
            agentScopes: { [self] in feedbackLocators.credentialScopes(authorization: $0) },
            guestDeniedHiddenChannel: { [self] channelId, serverId, userId in
                guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId)
            },
            appendMessage: { [messages = messagesAndThreadsStore, ledger = MessageLedgerPort(oauth: oauth)] message in
                messages.appendMessage(message, ledger: ledger, mirrorSystemMetadata: true)
            },
            oauth: oauth,
            notifications: notificationsStore,
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            feedback: feedbackStore,
            profiles: authProfileStore,
            now: { Date() }
        ))
    }

    /// `PATCH /api/channels/:id` and `POST /api/channels`. The channel
    /// visibility predicate belongs to the channel-agent routes and enters as a
    /// closure.
    public var managedMCPChannelRoutes: ManagedMCPChannelRoutesService {
        ManagedMCPChannelRoutesService(
            sessionUserId: { [self] in sessionUserId(authorization: $0) },
            channelActorCanSee: { [self] channelId, userId in
                channelActorCanSee(channelId: channelId, userId: userId)
            },
            oauth: oauth,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            profiles: authProfileStore
        )
    }

    /// App reminders (owner list, internal machine routes, agent-api routes)
    /// and the saved-message write. The reminder ledger, machine keys and
    /// agent credentials come from their stores; the session lookup and the
    /// agent capability decision belong to other domains and enter as closures.
    public var managedMCPAgentCatalog: ManagedMCPAgentCatalogService {
        ManagedMCPAgentCatalogService(
            reminders: tasksAndRemindersStore,
            machines: machinesAndComputersStore,
            agents: agentsRuntimeStore,
            oauth: oauth,
            dependencies: ManagedMCPAgentCatalogDependencies(
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                deniedCapability: { [feedbackLocators] authorization, capability in
                    switch feedbackLocators.capabilityDecision(authorization: authorization, capability: capability) {
                    case .allowed: nil
                    case .denied(let denied): denied
                    }
                }
            )
        )
    }

    /// The managed MCP control plane (`/api/mcp/*`). The server rows live in
    /// `ManagedMCPAndCardsStore`; the session lookup and the public origin come
    /// from the profile domain as closures.
    public var managedMCPControlPlane: ManagedMCPControlPlaneService {
        ManagedMCPControlPlaneService(
            servers: managedMCPAndCardsStore,
            oauth: oauth,
            dependencies: ManagedMCPControlPlaneDependencies(
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                serverURL: { [authProfileStore] in authProfileStore.serverURL }
            )
        )
    }

    /// Channel membership, thread creation and the human task routes. The
    /// channel, read-state and task rows come from their stores; the session
    /// lookup, the serialized system-notice append and the task-catalog
    /// projections belong to unmigrated domains and enter as closures
    /// (`ManagedMCPAssignmentsDependencies`). `publishTaskUpdated` takes the
    /// claimed task's published JSON so the channel-messaging domain can emit
    /// `task:updated`.
    public func channelAssignments(
        publishTaskUpdated: @escaping @Sendable (String) -> Void = { _ in }
    ) -> ManagedMCPAssignmentsService {
        ManagedMCPAssignmentsService(
            directory: self,
            appendSystemNotice: systemNoticeAppender,
            publishTaskUpdated: publishTaskUpdated
        )
    }

    /// Saved messages, direct channels, channel detail, read state and the
    /// agent channel archive/mute surface.
    public var managedMCPToolExecution: ManagedMCPToolExecutionService {
        ManagedMCPToolExecutionService(directory: self)
    }

    // MARK: Channel-visibility and mute forwarders for unmigrated callers
    //
    // The decisions live in `ManagedMCPChannelVisibility` and
    // `ManagedMCPToolExecutionService`; these keep the legacy signatures the
    // managed-MCP OAuth, reaction, action-card execute and thread wiring still
    // call.

    func channelActorCanSee(channelId: String, userId: String) -> Bool {
        ManagedMCPChannelVisibility(oauth: oauth, channels: serversAndChannelsStore)
            .actorCanSee(channelId: channelId, userId: userId)
    }

    func guestDeniedHiddenChannel(channelId: String, serverId: String, userId: String) -> Bool {
        ManagedMCPChannelVisibility(oauth: oauth, channels: serversAndChannelsStore)
            .guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId)
    }

}
