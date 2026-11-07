/// Immutable public views of the concrete services in one owner graph.
/// Groups contain no stores, lookup closures or forwarding methods.
public struct IdentityServices: Sendable {
    public let core: AuthCoreService
    public let verification: AuthVerificationService
    public let profile: AuthProfileService
    public let identities: AuthIdentitiesService
    public let oauthFlows: OAuthFlowsService
    public let issuerMetadata: OAuthIssuerMetadataService
    public let authorization: OAuthAuthorizationService
    public let principal: OAuthPrincipalService
    public let runtimePolicy: DirectoryRuntimePolicy
}

public struct MessagingServices: Sendable {
    public let realtime: RealtimeRelayService
    public let inbox: InboxAndWakeService
    public let reactions: ReactionsRealtimeService
    public let create: HumanMessageCreateService
    public let send: MessageSendService
    public let socketMembership: SocketMembershipService
    public let files: ProfileAndChannelFilesService
    public let search: SearchMentionsService
    public let comments: AttachmentCommentsService
}

public struct ChannelServices: Sendable {
    public let members: ServerMembersAndSidebarService
    public let profile: ServerProfileAndOrderService
    public let membership: ChannelMembershipService
    public let invites: JoinLinksAndInvitesService
    /// General relay only; each HTTP host derives its fixed user delivery.
    public let messaging: ChannelMessagingService
    /// These graph values bind the general follower/task publishers.
    public let threads: ThreadsService
    public let assignments: ManagedMCPAssignmentsService
}

public struct AgentServices: Sendable {
    public let connections: AgentConnectionRelayService
    public let surface: AgentPrivateSurfaceService
    public let lifecycle: AgentsLifecycleService
    public let migrationStatus: AgentMigrationStatusService
    public let delivery: AgentSendDeliveryService
    public let channels: AgentChannelsService
    public let hostedMigration: AgentHostedMigrationService
    public let machineMigration: AgentMachineMigrationControlService
    public let history: AgentHistoryService
    public let attachments: AgentAttachmentsService
    public let integrationTokens: AgentIntegrationTokenService
}

public struct MachineServices: Sendable {
    public let fleet: ComputersFleetService
    public let hostedRuntime: MachinesAndHostedRuntimeService
    public let usage: RuntimeUsageAndAttestationsService
    public let forms: RuntimeFormsAndProbesService
}

public struct TaskServices: Sendable {
    public let catalog: TaskCatalogService
    public let labs: TasksAndLabsService
    public let marketplace: ActionCardMarketplaceService
}

public struct IntegrationServices: Sendable {
    public let prepare: ActionCardPrepareService
    public let execute: ActionCardExecuteService
    public let cards: ActionCardService
    public let registration: ActionCardIntegrationRegisterService
    public let apps: IntegrationsAndAppAccessService
    public let agentApps: AgentIntegrationAppsService
    public let messageLookup: AgentMessageLookupService
    public let lifecycle: ManagedMCPLifecycleService
    public let providers: ManagedMCPProviderConnectionsService
    public let oauth: ManagedMCPOAuthService
    public let channelRoutes: ManagedMCPChannelRoutesService
    public let reminders: ManagedMCPAgentCatalogService
    public let control: ManagedMCPControlPlaneService
    public let tools: ManagedMCPToolExecutionService
}

public struct NotificationServices: Sendable {
    public let native: NativeNotificationsService
    public let push: ManagedMCPPushService
    public let emailUnsubscribe: MobileAppEmailUnsubscribe
}

public struct FeedbackServices: Sendable {
    public let locators: FeedbackLocatorService
    public let submissions: ProductFeedbackSubmissionService
    public let tickets: FeedbackMultiAppService
}
