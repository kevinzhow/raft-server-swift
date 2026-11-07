/// Explicit publisher input distinguishes published, silent and custom thread
/// scenes. No default silently replaces the old factory's no-op behavior.
func composeThreads(
    messages: MessagesAndThreadsStore,
    auth: AuthCoreService,
    channels: ServersAndChannelsStore,
    profiles: AuthProfileStore,
    tasks: TasksAndRemindersStore,
    oauth: OAuthLedger,
    probe: ChannelProbeAccessQuery,
    lifecycle: AgentsLifecycleService,
    visibility: ManagedMCPChannelVisibility,
    publishFollowersUpdated: @escaping @Sendable (ThreadFollowersUpdatedPayload) -> Void
) -> ThreadsService {
    ThreadsService(
        store: messages,
        dependencies: ThreadsDependencies(
            auth: auth,
            channels: channels,
            profiles: profiles,
            tasks: tasks,
            oauth: oauth,
            channelProbeAccess: probe.access,
            guestCanSeeScope: lifecycle.guestCanSeeScope,
            visibility: visibility
        ),
        publishFollowersUpdated: publishFollowersUpdated
    )
}

/// The published graph passes its general task publisher. A silent/custom
/// scene must supply that choice explicitly against these same owner references.
func composeChannelAssignments(
    channels: ServersAndChannelsStore,
    messages: MessagesAndThreadsStore,
    tasks: TasksAndRemindersStore,
    agents: AgentsRuntimeStore,
    profiles: AuthProfileStore,
    oauth: OAuthLedger,
    auth: AuthCoreService,
    ownership: AssistantOwnershipQuery,
    probe: ChannelProbeAccessQuery,
    notices: SystemNoticeAppender,
    membership: ChannelMembershipService,
    catalog: TaskCatalogService,
    publishTaskUpdated: @escaping @Sendable (String) -> Void
) -> ManagedMCPAssignmentsService {
    ManagedMCPAssignmentsService(
        channels: channels,
        messages: messages,
        tasks: tasks,
        agents: agents,
        profiles: profiles,
        oauth: oauth,
        auth: auth,
        ownership: ownership,
        probe: probe,
        notices: notices,
        membership: membership,
        catalog: catalog,
        publishTaskUpdated: publishTaskUpdated
    )
}
