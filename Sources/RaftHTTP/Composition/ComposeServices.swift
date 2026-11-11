/// Fresh production owners are allocated exactly once and never escape here.
func composeServices() -> ServiceContainer {
    let profiles = AuthProfileStore()
    let notifications = NotificationsStore()
    let productEvents = ProductEventStore()
    let inboxFacts = InboxFactStore()
    let threadFollows = ThreadFollowStore()
    let messages = MessagesAndThreadsStore()
    let agents = AgentsRuntimeStore()
    let tasks = TasksAndRemindersStore()
    let machines = MachinesAndComputersStore()
    let channels = ServersAndChannelsStore()
    let cards = ManagedMCPAndCardsStore()
    let feedback = FeedbackStore()
    let oauth = OAuthLedger()
    return composeServices(
        profiles: profiles,
        notifications: notifications,
        productEvents: productEvents,
        inboxFacts: inboxFacts,
        threadFollows: threadFollows,
        messages: messages,
        agents: agents,
        tasks: tasks,
        machines: machines,
        channels: channels,
        cards: cards,
        feedback: feedback,
        oauth: oauth
    )
}

/// All owners are required. A scene supplies the same references to its private
/// domain fixtures; composition never creates a second, partially default graph.
func composeServices(
    profiles: AuthProfileStore,
    notifications: NotificationsStore,
    productEvents: ProductEventStore,
    inboxFacts: InboxFactStore,
    threadFollows: ThreadFollowStore,
    messages: MessagesAndThreadsStore,
    agents: AgentsRuntimeStore,
    tasks: TasksAndRemindersStore,
    machines: MachinesAndComputersStore,
    channels: ServersAndChannelsStore,
    cards: ManagedMCPAndCardsStore,
    feedback: FeedbackStore,
    oauth: OAuthLedger
) -> ServiceContainer {
    let ledger = MessageLedgerPort(oauth: oauth)
    let ownership = AssistantOwnershipQuery(agents: agents, oauth: oauth)
    let suppression = MessageSuppressionService(messages: messages, oauth: oauth)
    let taskCredentials = AgentTaskCredentials(agents: agents, machines: machines, channels: channels, cards: cards, oauth: oauth)
    let visibility = ManagedMCPChannelVisibility(oauth: oauth, channels: channels)
    let probe = ChannelProbeAccessQuery(channels: channels, messages: messages, inboxFacts: inboxFacts, oauth: oauth)
    let projection = MessageReadProjection(messages: messages, channels: channels, profiles: profiles, agents: agents, oauth: oauth, tasks: tasks)
    let mentions = MessageMentionsService(messages: messages, channels: channels, profiles: profiles, agents: agents, oauth: oauth)
    let metadata = ActionCardMetadataProjection(cards: cards, oauth: oauth)
    let locators = FeedbackLocatorService(feedback: feedback, agents: agents, channels: channels, cards: cards, oauth: oauth)

    let core = AuthCoreService(store: profiles)
    let verification = AuthVerificationService(store: profiles)
    let profile = AuthProfileService(store: profiles)
    let identities = AuthIdentitiesService(store: profiles, oauth: oauth)
    let oauthFlows = OAuthFlowsService(store: OAuthFlowsStore(profiles: profiles), flags: agents, oauth: oauth)
    let issuerMetadata = OAuthIssuerMetadataService(profiles: profiles, oauth: oauth)
    let authorization = OAuthAuthorizationService(profiles: profiles, oauth: oauth)
    let principal = OAuthPrincipalService(profiles: profiles, oauth: oauth)
    let runtimePolicy = DirectoryRuntimePolicy(profiles: profiles)
    let realtime = RealtimeRelayService(messages: messages)
    let notices = SystemNoticeAppender(
        messages: messages, channels: channels, profiles: profiles, oauth: oauth,
        ledger: ledger, emit: { room, event, payload in
            realtime.emit(room, event, payload)
        }
    )
    let connections = AgentConnectionRelayService(agents: agents)
    let credentialUse = AgentCredentialUseService(agents: agents, oauth: oauth, realtime: realtime)
    let native = NativeNotificationsService(rows: notifications.native, settings: notifications, profiles: profiles)
    let emailUnsubscribe = MobileAppEmailUnsubscribe(profiles: profiles, notifications: notifications)
    let catalog = TaskCatalogService(tasks: tasks, profiles: profiles, oauth: oauth, messages: messages, channels: channels, flags: agents)
    let feedbackTransport = FeedbackService(
        store: feedback,
        dependencies: FeedbackService.Dependencies(profiles: profiles, flags: agents)
    )
    let roleNotices = AgentRoleNoticeService(profiles: profiles, channels: channels, oauth: oauth, notices: notices)

    let lifecycle = AgentsLifecycleService(
        profiles: profiles,
        agents: agents,
        machines: machines,
        channels: channels,
        messages: messages,
        inboxFacts: inboxFacts,
        productEvents: productEvents,
        oauth: oauth,
        dependencies: AgentsLifecycleDependencies(
            recordAgentCredentialUse: credentialUse.record,
            jointLocalChannelId: projection.localChannel
        )
    )
    let hostedRuntime = MachinesAndHostedRuntimeService(
        auth: core,
        oauth: oauth,
        agents: agents,
        machines: machines,
        channels: channels,
        profiles: profiles,
        realtime: realtime,
        provider: connections
    )
    let membership = ChannelMembershipService(
        auth: core,
        oauth: oauth,
        channels: channels,
        agents: agents,
        feedbackLocators: locators,
        visibility: visibility,
        notices: notices
    )
    let agentChannels = AgentChannelsService(
        oauth: oauth,
        channels: channels,
        agents: agents,
        machines: machines,
        profiles: profiles,
        feedbackLocators: locators,
        appendSystemNotice: notices.append
    )
    let forms = RuntimeFormsAndProbesService(
        auth: core,
        oauth: oauth,
        machines: machines,
        servers: channels,
        notifications: notifications,
        agents: agents,
        realtime: realtime
    )
    let socketMembership = SocketMembershipService(
        channels: channels,
        messages: messages,
        tasks: tasks,
        oauth: oauth,
        flags: agents,
        attachmentCommentsEnabled: projection.commentsEnabled
    )
    let prepare = ActionCardPrepareService(
        oauth: oauth,
        cards: cards,
        feedback: feedback,
        agents: agents,
        channels: channels,
        accounts: profiles,
        messages: messages,
        sessionUserId: lifecycle.sessionUserId,
        assistantOwner: ownership.liveOwner
    )
    let migrationStatus = AgentMigrationStatusService(auth: core, oauth: oauth, agents: agents, realtime: realtime)
    let members = ServerMembersAndSidebarService(dependencies: ServerMembersAndSidebarDependencies(
        auth: core,
        realtime: realtime,
        profiles: profiles,
        oauth: oauth,
        channels: channels,
        tasks: tasks
    ))
    let serverProfile = ServerProfileAndOrderService(dependencies: ServerProfileAndOrderDependencies(
        auth: core,
        machineIdForCredential: hostedRuntime.machineIdForCredential,
        oauth: oauth,
        channels: channels,
        messages: messages,
        profiles: profiles,
        machines: machines,
        agents: agents
    ))
    let mcpLifecycle = ManagedMCPLifecycleService(
        sessionUserId: lifecycle.sessionUserId,
        oauth: oauth,
        messages: messages,
        channels: channels,
        profiles: profiles
    )
    let providers = ManagedMCPProviderConnectionsService(
        sessionUserId: lifecycle.sessionUserId,
        oauth: oauth,
        providers: cards
    )
    let push = ManagedMCPPushService(oauth: oauth, profiles: profiles, notifications: notifications)
    let mcpOAuth = ManagedMCPOAuthService(dependencies: ManagedMCPOAuthDependencies(
        auth: core,
        locator: locators,
        visibility: visibility,
        oauth: oauth,
        notifications: notifications,
        messages: messages,
        channels: channels,
        feedback: feedback,
        profiles: profiles
    ))
    let reminders = ManagedMCPAgentCatalogService(
        reminders: tasks,
        machines: machines,
        agents: agents,
        oauth: oauth,
        dependencies: ManagedMCPAgentCatalogDependencies(auth: core, locator: locators)
    )
    let control = ManagedMCPControlPlaneService(
        servers: cards,
        oauth: oauth,
        dependencies: ManagedMCPControlPlaneDependencies(
            sessionUserId: lifecycle.sessionUserId,
            serverURL: { profiles.serverURL }
        )
    )
    let channelRoutes = ManagedMCPChannelRoutesService(
        sessionUserId: lifecycle.sessionUserId,
        channelActorCanSee: { channelId, userId in
            guard let serverId = channels.postableChannels[channelId]?.serverId
                ?? oauth.channelInfo(id: channelId)?.serverId else { return false }
            if HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: agents)
                .authority(channelId: channelId, serverId: serverId, userId: userId) != nil { return true }
            guard channels.postableChannel(id: channelId) == nil else { return false }
            return LedgerChannelReadFallback.canReadHuman(
                channelId: channelId, serverId: serverId, userId: userId, oauth: oauth)
        },
        oauth: oauth,
        channels: channels,
        messages: messages,
        profiles: profiles
    )
    // The base has no user transport. A host derives its own fixed Hub binding.
    let channelMessaging = ChannelMessagingService(
        dependencies: ChannelMessagingDependencies(auth: core, oauth: oauth, catalog: catalog),
        sink: ChannelRealtimeSink(emit: realtime.emit)
    )
    let lookup = AgentCredentialLookup(agents: agents, channels: agentChannels, credentialUse: credentialUse)
    let search = SearchMentionsService(
        channels: channels,
        messages: messages,
        profiles: profiles,
        machines: machines,
        agents: agents,
        tasks: tasks,
        feedback: feedback,
        oauth: oauth,
        dependencies: SearchMentionsDependencies(
            auth: core,
            credentials: lookup,
            machineIdForCredential: hostedRuntime.machineIdForCredential,
            canMachineServeAgent: hostedRuntime.canMachineServeAgent,
            projection: projection,
            cards: metadata
        )
    )
    let reactions = ReactionsRealtimeService(
        messages: messages,
        channels: channels,
        inboxFacts: inboxFacts,
        cards: cards,
        oauth: oauth,
        dependencies: ReactionsRealtimeDependencies(
            auth: core,
            credentials: lookup,
            agents: agents,
            profiles: profiles,
            guestCanSeeScope: lifecycle.guestCanSeeScope
        )
    )
    let registration = ActionCardIntegrationRegisterService(
        cards: cards,
        channels: channels,
        messages: messages,
        inboxFacts: inboxFacts,
        accounts: profiles,
        agents: agents,
        oauth: oauth,
        dependencies: ActionCardIntegrationRegisterDependencies(
            sessionUserId: lifecycle.sessionUserId,
            agentCredential: lookup.agentCredentialAgent,
            identityResolution: locators.identityResolution,
            appendHumanMessage: { messages.appendMessage($0, ledger: ledger) },
            addPostableChannel: { serverId, channelId, memberId, kind, parentId, anchorId, name in
                channels.addPostableChannel(
                    serverId: serverId, channelId: channelId, memberId: memberId, kind: kind,
                    parentChannelId: parentId, parentMessageId: anchorId, name: name
                )
            },
            emitRealtime: realtime.emit,
            publishMessageUpdated: { messageId, metadataJSON in
                MessageUpdatePublisher(
                    messages: messages, channels: channels, profiles: profiles, oauth: oauth,
                    emit: { room, event, payload in realtime.emit(room, event, payload) }
                ).actionCard(messageId: messageId, metadataJSON: metadataJSON)
            },
            marketplaceInstallableClient: oauth.marketplaceInstallableClientIdentity,
            publicIntegrationClient: oauth.publicIntegrationClientIdentity
        )
    )
    let tools = ManagedMCPToolExecutionService(
        channels: channels,
        messages: messages,
        agents: agents,
        profiles: profiles,
        notifications: notifications,
        inboxFacts: inboxFacts,
        oauth: oauth,
        feedbackLocators: locators,
        auth: core,
        realtime: realtime,
        taskCredentials: taskCredentials,
        credentialLookup: lookup,
        suppression: suppression
    )
    let surface = AgentPrivateSurfaceService(
        auth: core,
        oauth: oauth,
        agents: agents,
        credentialUse: credentialUse,
        machines: machines,
        channels: channels,
        messages: messages,
        cards: cards,
        realtime: realtime,
        prepare: prepare,
        reactions: reactions,
        notices: roleNotices
    )
    let execute = ActionCardExecuteService(
        tasks: tasks,
        messages: messages,
        channels: channels,
        agents: agents,
        machines: machines,
        oauth: oauth,
        feedbackLocators: locators,
        cards: cards,
        prepare: prepare,
        ownership: ownership,
        suppression: suppression,
        mentions: mentions,
        ledger: ledger
    )
    let humanCreate = HumanMessageCreateService(
        channels: channels,
        messages: messages,
        agents: agents,
        profiles: profiles,
        oauth: oauth,
        dependencies: HumanMessageCreateDependencies(
            credentials: lookup,
            writer: HumanMessageCommitService(
                messages: messages, channels: channels, profiles: profiles, catalog: catalog,
                oauth: oauth, ledger: ledger, emit: realtime.emit
            ),
            mentions: mentions,
            channels: channels,
            search: search
        ),
        machines: machines
    )
    let inbox = InboxAndWakeService(
        messages: messages,
        channels: channels,
        oauth: oauth,
        flags: agents,
        dependencies: InboxAndWakeDependencies(
            auth: core,
            profiles: profiles,
            channelProbeAccess: probe.access,
            guestCanSeeScope: lifecycle.guestCanSeeScope,
            search: search,
            projection: projection,
            cards: metadata
        )
    )
    let delivery = AgentSendDeliveryService(
        machines: machines,
        channels: channels,
        messages: messages,
        agents: agents,
        threadFollows: threadFollows,
        managedMCP: cards,
        oauth: oauth,
        prepare: prepare,
        search: search,
        ledger: ledger,
        publishCommittedMessage: { message in
            let realtimeFrames = MessageRealtimeService(
                messages: messages, channels: channels, profiles: profiles, oauth: oauth
            )
            for frame in realtimeFrames.frames(for: message) {
                realtime.emit(frame.room, frame.event, frame.payload)
            }
        }
    )
    let files = ProfileAndChannelFilesService(
        messages: messages,
        channels: channels,
        accounts: profiles,
        agents: agents,
        machines: machines,
        oauth: oauth,
        dependencies: ProfileAndChannelFilesDependencies(
            auth: core, lookup: lookup, locator: locators, realtime: realtime, projection: projection
        )
    )
    let attachments = AgentAttachmentsService(messages: messages, channels: channels, agents: agents, oauth: oauth, locators: locators)
    let comments = AttachmentCommentsService(
        messages: messages,
        channels: channels,
        profiles: profiles,
        oauth: oauth,
        dependencies: AttachmentCommentsDependencies(
            sessionUserId: lifecycle.sessionUserId,
            commentsEnabled: projection.commentsEnabled,
            visibleAttachment: lifecycle.canSeeAttachment,
            visibleAttachmentUnlocked: lifecycle.canSeeAttachmentIgnoringJoint,
            agentCredential: lookup.agentCredentialAgent,
            agentVisibleAttachment: attachments.visibleAttachment,
            agentHistoryThread: { channels.historyThread(parentId: $0, anchorMessageId: $1) },
            resolveMentions: { serverId, channelId, senderId, content, typed, warn, surface in
                try mentions.resolve(serverId: serverId, channelId: channelId, senderId: senderId,
                    content: content, typed: typed, warnUnresolved: warn, surface: surface)
            },
            recordMemberMentionRows: mentions.register,
            emitRealtime: { room, event, payload in realtime.emit(room, event, payload) }
        )
    )
    let messageLookup = AgentMessageLookupService(
        messages: messages,
        channels: channels,
        profiles: profiles,
        oauth: oauth,
        dependencies: AgentMessageLookupDependencies(lookup: lookup, search: search)
    )
    let agentApps = AgentIntegrationAppsService(
        oauth: oauth,
        logins: cards,
        dependencies: AgentIntegrationAppsDependencies(lookup: lookup, register: registration)
    )
    let send = MessageSendService(
        messages: messages,
        channels: channels,
        profiles: profiles,
        oauth: oauth,
        visibleAttachment: lifecycle.canSeeAttachment,
        emitRealtime: realtime.emit,
        registerPostableChannel: { serverId, channelId, memberId, kind, name in
            channels.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, kind: kind, name: name)
        },
        appendHumanMessage: { messages.appendMessage($0, ledger: ledger) }
    )
    let fleet = ComputersFleetService(
        machines: machines,
        agents: agents,
        profiles: profiles,
        oauth: oauth,
        dependencies: ComputersFleetDependencies(auth: core, realtime: realtime, lifecycle: lifecycle, agents: agents, machines: machines)
    )
    let usage = RuntimeUsageAndAttestationsService(
        machines: machines,
        messages: messages,
        channels: channels,
        agents: agents,
        oauth: oauth,
        sessionUserId: lifecycle.sessionUserId,
        channelAccess: catalog.canReadChannel
    )
    let marketplace = ActionCardMarketplaceService(
        tasks: tasks,
        messages: messages,
        inboxFacts: inboxFacts,
        channels: channels,
        accounts: profiles,
        agents: agents,
        machines: machines,
        cards: cards,
        oauth: oauth,
        locator: locators,
        idempotency: ActionCardTaskIdempotencyLedger.port(cards: cards),
        appendHumanMessage: { messages.appendMessage($0, ledger: ledger) },
        serializeReceipt: MarketplaceReceiptProjection.renderObjectReceipt
    )
    let apps = IntegrationsAndAppAccessService(oauth: oauth, sessionUserId: lifecycle.sessionUserId)
    let appManagement = IntegrationAppManagementService(
        oauth: oauth,
        sessionUserId: lifecycle.sessionUserId,
        userDisplayName: { userId in
            guard let account = profiles.account(userId: userId) else { return nil }
            return account.displayName ?? account.name
        }
    )
    let integrationTokens = AgentIntegrationTokenService(agents: agents, grants: cards, profiles: profiles, oauth: oauth)
    let invites = JoinLinksAndInvitesService(
        store: channels,
        accounts: profiles,
        agents: agents,
        computers: machines,
        oauth: oauth,
        dependencies: JoinLinksAndInvitesDependencies(
            sessionUserId: lifecycle.sessionUserId,
            emitRealtime: realtime.emit,
            setupAccountFacts: AuthProfileSetupAccountFacts(accounts: profiles)
        )
    )
    let threads = composeThreads(
        messages: messages, auth: core, channels: channels, profiles: profiles,
        tasks: tasks, oauth: oauth, probe: probe, lifecycle: lifecycle, visibility: visibility,
        publishFollowersUpdated: channelMessaging.publishThreadFollowers
    )
    let assignments = composeChannelAssignments(
        channels: channels, messages: messages, tasks: tasks, agents: agents, profiles: profiles,
        oauth: oauth, auth: core, ownership: ownership, probe: probe, notices: notices,
        membership: membership, catalog: catalog,
        createThreadFirstReply: { serverId, channelId, userId, content in
            try humanCreate.createThreadFirstReply(
                serverId: serverId, channelId: channelId, userId: userId, content: content
            )
        },
        publishTaskUpdated: channelMessaging.publishCommittedTaskUpdated
    )
    let labs = TasksAndLabsService(
        sessionUserId: lifecycle.sessionUserId,
        oauth: oauth,
        tasks: tasks,
        agentTasks: execute,
        feedbackLocators: locators,
        messages: messages,
        channels: channels,
        profiles: profiles,
        flags: agents
    )
    let actionCards = ActionCardService(
        store: cards,
        productEvents: productEvents,
        oauth: oauth,
        sessionUserId: lifecycle.sessionUserId,
        cardWriteDecision: registration.actionCardWriteDecision,
        mcpIdentity: { locators.identityResolution(authorization: $0, capability: "mcp") },
        publishMessageUpdated: { messageId, metadataJSON in
            MessageUpdatePublisher(
                messages: messages, channels: channels, profiles: profiles, oauth: oauth,
                emit: { room, event, payload in realtime.emit(room, event, payload) }
            ).actionCard(messageId: messageId, metadataJSON: metadataJSON)
        }
    )
    let history = AgentHistoryService(
        messages: messages,
        channels: channels,
        machines: machines,
        agents: agents,
        accounts: profiles,
        feedback: feedback,
        oauth: oauth,
        actionCardPrepare: prepare,
        channelMembership: membership,
        dependencies: AgentHistoryDependencies(
            threadByAnchor: { channels.historyThread(parentId: $0, anchorMessageId: $1) },
            threadById: { channels.historyThread(parentId: $0, idPrefix: $1) },
            threadByAnchorPrefix: { channels.historyThread(parentId: $0, anchorPrefix: $1) },
            agentReadUpdated: notifications.dispatchAgentReadUpdated
        )
    )
    let hostedMigration = AgentHostedMigrationService(
        agents: agents,
        machines: machines,
        oauth: oauth,
        dependencies: AgentHostedMigrationDependencies(auth: core, agents: agents, realtime: realtime, messageSend: send)
    )
    let machineMigration = AgentMachineMigrationControlService(
        agents: agents,
        machines: machines,
        channels: channels,
        messages: messages,
        tasks: tasks,
        oauth: oauth,
        dependencies: AgentMachineMigrationControlDependencies(sessionUserId: lifecycle.sessionUserId, emitRealtime: realtime.emit)
    )
    let submissions = ProductFeedbackSubmissionService(dependencies: ProductFeedbackSubmissionDependencies(
        auth: core, profiles: profiles, flags: agents, oauth: oauth, transport: feedbackTransport, events: productEvents
    ))
    let tickets = FeedbackMultiAppService(dependencies: FeedbackMultiAppDependencies(
        userId: lifecycle.sessionUserId,
        emailVerified: profiles.isEmailVerified,
        routeEnvironment: feedbackTransport.routeEnvironment,
        ensureRouteBinding: feedbackTransport.ensureRouteBindingAsync,
        bearer: feedbackTransport.bearerAsync,
        handsRequest: feedbackTransport.handsRequestAsync,
        warn: feedbackTransport.warn
    ))

    return ServiceContainer(
        identity: IdentityServices(
            core: core, verification: verification, profile: profile, identities: identities,
            oauthFlows: oauthFlows, issuerMetadata: issuerMetadata, authorization: authorization, principal: principal, runtimePolicy: runtimePolicy
        ),
        messaging: MessagingServices(
            realtime: realtime, inbox: inbox, reactions: reactions, create: humanCreate, send: send,
            socketMembership: socketMembership, files: files, search: search, comments: comments
        ),
        channels: ChannelServices(
            members: members, profile: serverProfile, membership: membership, invites: invites,
            messaging: channelMessaging, threads: threads, assignments: assignments
        ),
        agents: AgentServices(
            connections: connections, surface: surface, lifecycle: lifecycle, migrationStatus: migrationStatus,
            delivery: delivery, channels: agentChannels, hostedMigration: hostedMigration,
            machineMigration: machineMigration, history: history, attachments: attachments, integrationTokens: integrationTokens
        ),
        machines: MachineServices(fleet: fleet, hostedRuntime: hostedRuntime, usage: usage, forms: forms),
        tasks: TaskServices(catalog: catalog, labs: labs, marketplace: marketplace),
        integrations: IntegrationServices(
            prepare: prepare, execute: execute, cards: actionCards, registration: registration,
            apps: apps, appManagement: appManagement, agentApps: agentApps, messageLookup: messageLookup, lifecycle: mcpLifecycle,
            providers: providers, oauth: mcpOAuth, channelRoutes: channelRoutes, reminders: reminders,
            control: control, tools: tools
        ),
        notifications: NotificationServices(native: native, push: push, emailUnsubscribe: emailUnsubscribe),
        feedback: FeedbackServices(locators: locators, submissions: submissions, tickets: tickets)
    )
}
