import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Domain service accessors, continued from `AuthCoreService.swift` (pure move:
/// that file is near the Services line ceiling). Each accessor wires one
/// migrated service from the directory's stores and the OAuth ledger.
extension EmailLoginDirectory {
    /// The Computer fleet: machine roster, Computer attach/adoption, runner
    /// control plane and the lifecycle controls. The directory supplies the
    /// machine, agent and profile stores and the OAuth ledger; the session
    /// lookup, the realtime emitter, the device-login gate, the agent credential
    /// mint and the Computer credential lookup belong to unmigrated domains and
    /// enter as closures.
    public var computersFleet: ComputersFleetService {
        ComputersFleetService(
            machines: machinesAndComputersStore,
            agents: agentsRuntimeStore,
            profiles: authProfileStore,
            oauth: oauth,
            dependencies: ComputersFleetDependencies(
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                emitRealtime: { [self] room, event, payload in
                    emitRealtime(room, event, payload)
                },
                computerAttachEnabled: { [self] in
                    computerAttachEnabled()
                },
                mintAgentCredential: { [self] agentId, scopes, name in
                    let minted = mintAgentCredential(agentId: agentId, scopes: scopes, name: name)
                    lock.lock()
                    let credentialId = agentCredentials[minted]?.id ?? UUID().uuidString.lowercased()
                    lock.unlock()
                    return ComputersFleetDependencies.MintedCredential(apiKey: minted, credentialId: credentialId)
                },
                computerCredential: { [self] apiKey in
                    computerCredential(apiKey: apiKey)
                }
            )
        )
    }

    /// Product feedback locators for `POST/GET /internal/agent-api/feedback-locators`
    /// plus the agent credential/grant decisions the rest of the agent API
    /// shares. The directory only supplies its stores and the OAuth ledger.
    public var feedbackLocators: FeedbackLocatorService {
        FeedbackLocatorService(directory: self)
    }

    /// The served-inbox surface: the channel message page and its sync cursor,
    /// the mention-delivery diagnostics and the Done inbox page. The directory
    /// supplies the message and channel stores, the OAuth ledger, and the
    /// cross-domain closures the service takes at `init`.
    public var inboxAndWake: InboxAndWakeService {
        InboxAndWakeService(directory: self)
    }

    /// Machine credential lookups, the onboarding identity adoption, the hosted
    /// runtime and the provider account connections. The directory supplies its
    /// stores; the session lookup, the realtime emitter and the provider relay
    /// enter as closures.
    public var machinesAndHostedRuntime: MachinesAndHostedRuntimeService {
        MachinesAndHostedRuntimeService(directory: self)
    }

    public func machineIdForCredential(authorization: String?) -> String? {
        machinesAndHostedRuntime.machineIdForCredential(authorization: authorization)
    }

    func canMachineServeAgent(machineId: String, agent: OAuthLedger.AgentRuntimeInfo) -> Bool {
        machinesAndHostedRuntime.canMachineServeAgent(machineId: machineId, agent: agent)
    }

    public func machineAPIKey(machineId: String) -> String? {
        machinesAndHostedRuntime.machineAPIKey(machineId: machineId)
    }

    public func bumpMachineStatusVersion(machineId: String) -> Int {
        machinesAndHostedRuntime.bumpMachineStatusVersion(machineId: machineId)
    }

    public func setMachineOnline(machineId: String, online: Bool) {
        machinesAndHostedRuntime.setMachineOnline(machineId: machineId, online: online)
    }

    public func enableHostedModelPicker(serverId: String) {
        machinesAndHostedRuntime.enableHostedModelPicker(serverId: serverId)
    }

    /// Agent records and their private surfaces: creation, listing, the profile
    /// patch, credentials, the wake-hint stream and the assistant-owner reads.
    /// The directory supplies its stores; the session lookup, the realtime
    /// emitter, the hosted provider flag, the wake-hint projection and the role
    /// notice enter as closures.
    public var agentSurface: AgentPrivateSurfaceService {
        AgentPrivateSurfaceService(directory: self)
    }

    func recordAgentCredentialUse(token: String) {
        agentSurface.recordAgentCredentialUse(token: token)
    }

    func assistantOwnerFor(agentId: String, serverId: String) -> String? {
        agentSurface.assistantOwner(agentId: agentId, serverId: serverId)
    }

    func assistantOwnerRaw(_ agentId: String) -> String? {
        agentSurface.assistantOwnerRaw(agentId: agentId)
    }

    /// The Done/Undone, read-all, Activity page and agent mention, wake-hint and
    /// event surface. The directory supplies its stores and the OAuth ledger;
    /// the session lookup, the agent read credential, guest scope visibility and
    /// account names enter as closures.
    public var reactionsRealtime: ReactionsRealtimeService {
        ReactionsRealtimeService(directory: self)
    }

    /// The content-free wake hints of one agent, for the wake-hint stream.
    func pendingWakeHints(
        agentId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        sinceSeq: Int?,
        limit: Int
    ) -> [AgentWakeHintRow] {
        reactionsRealtime.pendingWakeHints(agentId: agentId, agent: agent, sinceSeq: sinceSeq, limit: limit)
            .hints.compactMap { hint in
                hint.seq.map { AgentWakeHintRow(seq: $0, json: hint.jsonBody.render()) }
            }
    }

    /// A system notice an agent caused itself, of a subtype that never trips
    /// the send freshness gate.
    func isSelfCausedFreshnessExemptLocked(_ message: StoredHumanMessage, agentId: String) -> Bool {
        message.messageType == "system"
            && message.causalActorType == "agent"
            && message.causalActorId == agentId
            && message.systemSubtype.map { Self.selfCausedFreshnessExemptSubtypes.contains($0) } == true
    }

    /// A real server-role change on an agent posts a system notice into the
    /// actor's DM with the agent (creating the DM when needed). The account,
    /// channel and message ledgers change together, so this stays one directory
    /// critical section.
    func postAgentRoleNotice(
        serverId: String,
        actorUserId: String,
        agentId: String,
        agentName: String,
        from: String,
        to: String
    ) {
        lock.lock()
        let actorName = accounts.values.first { $0.id == actorUserId }?.name ?? "Someone"
        var dmId = postableChannels.first { _, channel in
            channel.serverId == serverId && channel.kind == "dm"
                && channel.memberIds.contains(actorUserId) && channel.memberIds.contains(agentId)
        }?.key
        if dmId == nil {
            dmId = oauth.createDirectChannel(serverId: serverId, firstUserId: actorUserId, secondUserId: agentId)
            if let created = dmId {
                postableChannels[created] = PostableChannel(serverId: serverId, memberIds: [actorUserId, agentId], kind: "dm", name: "dm")
                oauth.addChannelAgent(channelId: created, agentId: agentId)
                oauth.addChannelHuman(channelId: created, userId: actorUserId)
            }
        }
        if let dmId {
            appendHumanMessageLocked(StoredHumanMessage(
                id: UUID().uuidString.lowercased(),
                channelId: dmId,
                senderId: actorUserId,
                content: "@\(actorName) changed @\(agentName)'s server role from \(from) to \(to).",
                messageType: "system",
                senderType: "user",
                actionKind: "agent.server_role_changed"
            ))
        }
        lock.unlock()
    }

    /// Human message create, the sender-side mention actions and the forward
    /// write. The directory supplies the message, channel, agent and profile
    /// stores and the OAuth ledger; the message append, mention resolution and
    /// the forwarded-item projection still belong to unmigrated domains and
    /// enter as closures.
    public var humanMessageCreate: HumanMessageCreateService {
        HumanMessageCreateService(directory: self)
    }

    public var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    public var userCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accounts.count
    }

    public var legalAcceptanceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authProfileStore.legalAcceptanceCount
    }

    public var emailVerificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emailVerifications
    }

    public var providerExchangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return providerExchanges
    }

    public var retirementReceiptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retirementReceipts.count
    }

    public var mobileOAuthRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests.count
    }

    /// Rows the directory holds for `GET /api/messages` style readbacks.
    public var humanMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.count
    }

    /// Product-feedback submission and onboarding-wizard event recording. The
    /// Hands transport and route binding are still owned by the not-yet-migrated
    /// `FeedbackService`, so they enter as closures; the account row, the
    /// feature-flag decision and product-event rows come from their stores.
    public var productFeedbackSubmissions: ProductFeedbackSubmissionService {
        let feedback = FeedbackService(directory: self)
        return ProductFeedbackSubmissionService(
            dependencies: ProductFeedbackSubmissionDependencies(
                account: { [authProfileStore] userId in
                    authProfileStore.account(userId: userId)
                },
                userId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                resolveAttribution: { [self] serverId, userId in
                    guard ServerScope.isUUID(serverId),
                          let profile = oauth.serverProfile(id: serverId),
                          oauth.memberRole(serverId: serverId, userId: userId) != nil,
                          !profile.slug.isEmpty
                    else { return nil }
                    return ProductFeedbackReporterAttribution(
                        serverSlug: profile.slug,
                        handle: authProfileStore.account(userId: userId)?.name ?? ""
                    )
                },
                multiAppEnabled: { [self] userId in
                    evaluateFeatureFlagKey(
                        key: EmailLoginDirectory.productFeedbackMultiAppFlag,
                        userId: userId,
                        serverId: nil,
                        platform: nil,
                        client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
                    ).enabled
                },
                configuration: { [self, feedbackStore] in
                    let snapshot = feedbackStore.handsFeedbackSubmissionConfiguration(
                        base: ProcessInfo.processInfo.environment,
                        conversationSessionEnabled: authProfileStore.handsConversationSessionEnabled
                    )
                    return ProductFeedbackRelayConfiguration(
                        environment: snapshot.environment,
                        appsJSON: snapshot.appsJSON,
                        configured: snapshot.configured
                            || snapshot.environment["HANDS_FEEDBACK_BASE_URL"] != nil
                    )
                },
                multiRouteEnvironment: { source, appsJSON, environment in
                    try EmailLoginDirectory.feedbackMultiRouteEnvironment(
                        source: source,
                        appsJSON: appsJSON,
                        environment: environment
                    )
                },
                legacyRouteEnvironment: { environment in
                    EmailLoginDirectory.feedbackLegacyRouteEnvironment(environment)
                },
                ensureRouteBinding: { userId, environment in
                    try await feedback.ensureRouteBindingAsync(userId: userId, environment: environment)
                },
                send: { request in
                    await feedback.sendAsync(request)
                },
                warn: { message in
                    feedback.warn(message)
                },
                appendProductEvent: { [productEventStore] event in
                    productEventStore.append(event)
                },
                serverAnalyticsAllowed: { [self] serverId in
                    oauth.serverAnalyticsAllowed(id: serverId)
                }
            )
        )
    }

    /// Server member roles/removal, server deletion, the sidebar order ledger,
    /// server labs and the task snapshot/period aggregates. The directory
    /// supplies the two domain stores and the OAuth ledger; the session lookup,
    /// the human-name check and the realtime emitter enter as closures because
    /// they belong to domains that have not migrated yet.
    public var serverMembersAndSidebar: ServerMembersAndSidebarService {
        ServerMembersAndSidebarService(directory: self)
    }

    /// Server tasks: channel task reads, the assignee write and the agent amend.
    public var tasksAndLabs: TasksAndLabsService {
        TasksAndLabsService(
            sessionUserId: { [self] in sessionUserId(authorization: $0) },
            oauth: oauth,
            tasks: tasksAndRemindersStore,
            agentTasks: actionCardExecute,
            feedbackLocators: feedbackLocators
        )
    }

    /// The system notice (and the acting agent's born-read cursor) the channel
    /// membership writes post; the append still serializes under the directory lock.
    private var systemNoticeAppender: @Sendable (StoredHumanMessage, String?) -> Int {
        { [self] message, bornReadAgentId in
            lock.lock()
            defer { lock.unlock() }
            let seq = appendHumanMessageLocked(message)
            if let bornReadAgentId {
                messagesAndThreadsStore.markBornRead(
                    channelId: message.channelId, agentId: bornReadAgentId, seq: seq
                )
            }
            return seq
        }
    }

    /// Channel archive, human join and the agent join/leave of a plain channel.
    public var channelMembership: ChannelMembershipService {
        ChannelMembershipService(
            sessionUserId: { [self] in sessionUserId(authorization: $0) },
            oauth: oauth,
            channels: serversAndChannelsStore,
            agents: agentsRuntimeStore,
            feedbackLocators: feedbackLocators,
            channelActorCanSee: { [self] channelId, userId in
                channelActorCanSee(channelId: channelId, userId: userId)
            },
            appendSystemNotice: systemNoticeAppender
        )
    }

    /// The agent-principal channel and server management surface.
    public var agentChannels: AgentChannelsService {
        AgentChannelsService(
            oauth: oauth,
            channels: serversAndChannelsStore,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            profiles: authProfileStore,
            feedbackLocators: feedbackLocators,
            appendSystemNotice: systemNoticeAppender
        )
    }

    /// Machine-migration transport (the Computer callbacks), agent machine
    /// assignment and agent credentials. The agent, machine and OAuth rows come
    /// from their stores; the session lookup, the realtime emitter, the agent
    /// credential mint and the migration-receipt DM (message-send domain) enter
    /// as closures.
    public var agentHostedMigration: AgentHostedMigrationService {
        AgentHostedMigrationService(
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            oauth: oauth,
            dependencies: AgentHostedMigrationDependencies(
                sessionUserId: { [self] in sessionUserId(authorization: $0) },
                emitRealtime: { [self] room, event, payload in emitRealtime(room, event, payload) },
                mintAgentCredential: { [self] agentId, scopes, name in
                    mintAgentCredential(agentId: agentId, scopes: scopes, name: name)
                },
                createMigrationReceiptDm: { [self] agentId, serverId, supportRef in
                    messageSend.createMigrationReceiptDm(agentId: agentId, serverId: serverId, supportRef: supportRef)
                }
            )
        )
    }

    /// Migrating an agent (hosted and Computer), the hosted confirmation, the
    /// private agent surfaces, scopes, workspace tree/read, archived workspace,
    /// delete and the runtime verbs. The session lookup and the realtime emitter
    /// enter as closures.
    public var agentMachineMigrationControl: AgentMachineMigrationControlService {
        AgentMachineMigrationControlService(
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            tasks: tasksAndRemindersStore,
            oauth: oauth,
            dependencies: AgentMachineMigrationControlDependencies(
                sessionUserId: { [self] in sessionUserId(authorization: $0) },
                emitRealtime: { [self] room, event, payload in emitRealtime(room, event, payload) }
            )
        )
    }

    /// The Computer-key lookup `/daemon/connect` and the Computer fleet share.
    public func computerCredential(apiKey: String) -> ComputerCredentialLookup {
        machinesAndComputersStore.computerCredential(apiKey: apiKey)
    }

    /// Whether the bearer is a live (non-revoked) Computer credential; the
    /// migration control surfaces gate on it.
    func computerCredentialValid(_ authorization: String?) -> Bool {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
        let key = String(authorization.dropFirst("Bearer ".count))
        return machinesAndComputersStore.computerCredentialIsLive(token: key)
    }

    /// Runtime forms, option sources and probes, runtime account usage, the
    /// server onboarding/notification settings and machine registration. The
    /// machine, notification, onboarding and agent rows live in their stores;
    /// the session lookup, the realtime emitter and `registerMachine` /
    /// `machineAPIKey` enter as closures (`RuntimeFormsAndProbesDependencies`).
    public var runtimeFormsAndProbes: RuntimeFormsAndProbesService {
        RuntimeFormsAndProbesService(directory: self)
    }

    /// Server profile, switcher order, pre-join agreement, translation, the
    /// member directory, scope attestations and the share-artifact pages. The
    /// directory supplies the stores and the OAuth ledger; the session and
    /// machine-credential lookups enter as closures.
    public var serverProfileAndOrder: ServerProfileAndOrderService {
        ServerProfileAndOrderService(directory: self)
    }

    /// The user id behind a live access token, for the community-join route.
    public func authenticatedUserId(authorization: String?) -> String? {
        sessionUserId(authorization: authorization)
    }

    /// Product-feedback ticket routes (`/api/product-feedback/tickets…`). The
    /// Hands transport, route binding and reporter session are still owned by
    /// the not-yet-migrated `FeedbackService`, so they enter as closures; the
    /// session lookup and the account row come from their domains.
    public var feedbackMultiApp: FeedbackMultiAppService {
        let feedback = FeedbackService(directory: self)
        return FeedbackMultiAppService(
            dependencies: FeedbackMultiAppDependencies(
                userId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                emailVerified: { [authProfileStore] userId in
                    authProfileStore.account(userId: userId)?.emailVerified == true
                },
                routeEnvironment: { source, userId in
                    try feedback.routeEnvironment(source: source, userId: userId)
                },
                ensureRouteBinding: { userId, environment in
                    try await feedback.ensureRouteBindingAsync(userId: userId, environment: environment)
                },
                bearer: { userId, reporterId, environment in
                    try await feedback.bearerAsync(userId: userId, reporterId: reporterId, environment: environment)
                },
                handsRequest: { environment, method, path, bearer, reporterId, headers, body in
                    await feedback.handsRequestAsync(
                        environment: environment,
                        method: method,
                        path: path,
                        bearer: bearer,
                        reporterId: reporterId,
                        headers: headers,
                        body: body
                    )
                },
                warn: { message in
                    feedback.warn(message)
                }
            )
        )
    }

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
            appendMessage: { [self] message in
                lock.lock()
                defer { lock.unlock() }
                appendHumanMessageLocked(message)
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

    /// The agent history read and the machine channel join/leave. The read
    /// cursors live in the message store; the thread lookups belong to the
    /// action-card helpers and the read-update hook is the notifications
    /// store's, so they enter as closures.
    public var agentHistory: AgentHistoryService {
        AgentHistoryService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            machines: machinesAndComputersStore,
            agents: agentsRuntimeStore,
            accounts: authProfileStore,
            feedback: feedbackStore,
            oauth: oauth,
            actionCardPrepare: actionCardPrepare,
            channelMembership: channelMembership,
            dependencies: AgentHistoryDependencies(
                threadByAnchor: { [self] parentId, anchorMessageId in
                    agentHistoryThread(parentId: parentId, anchorMessageId: anchorMessageId)
                },
                threadById: { [self] parentId, suffix in
                    agentHistoryThreadById(parentId: parentId, suffix: suffix)
                },
                threadByAnchorPrefix: { [self] parentId, suffix in
                    agentHistoryThreadByAnchorPrefix(parentId: parentId, suffix: suffix)
                },
                agentReadUpdated: { [notificationsStore] serverId, channelId, agentId, seq in
                    notificationsStore.onAgentReadUpdated?(serverId, channelId, agentId, seq)
                }
            )
        )
    }

    // MARK: - Integrations and app access

    /// Setup declarations, Marketplace installs, agent grants and the app event
    /// feed. The OAuth ledger owns every row; only the human session lookup
    /// belongs to an unmigrated domain.
    public var integrationsAndAppAccess: IntegrationsAndAppAccessService {
        IntegrationsAndAppAccessService(
            oauth: oauth,
            sessionUserId: { [self] authorization in
                sessionUserId(authorization: authorization)
            }
        )
    }

    /// Scoped attachment comments. The session, the agent credential, the
    /// feature-flag gate, the attachment visibility rules, the thread lookup and
    /// the mention-row writer belong to unmigrated domains and enter as closures.
    public var attachmentComments: AttachmentCommentsService {
        AttachmentCommentsService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            profiles: authProfileStore,
            oauth: oauth,
            dependencies: AttachmentCommentsDependencies(
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                commentsEnabled: { [self] serverId, userId in
                    attachmentCommentsEnabled(serverId: serverId, userId: userId)
                },
                visibleAttachment: { [self] userId, serverId, attachment in
                    visibleAttachment(userId: userId, serverId: serverId, attachment: attachment)
                },
                visibleAttachmentUnlocked: { [self] userId, serverId, attachment in
                    visibleAttachmentUnlocked(userId: userId, serverId: serverId, attachment: attachment)
                },
                agentCredential: { [self] authorization in
                    agentCredentialAgent(authorization)
                },
                agentVisibleAttachment: { [self] agentId, serverId, attachmentId in
                    agentVisibleAttachment(agentId: agentId, serverId: serverId, attachmentId: attachmentId)
                },
                agentHistoryThread: { [self] parentId, anchorMessageId in
                    agentHistoryThread(parentId: parentId, anchorMessageId: anchorMessageId)
                },
                recordMemberMentionRows: { [self] messageId, channelId, mentions in
                    recordMemberMentionRows(messageId: messageId, channelId: channelId, mentions: mentions)
                }
            )
        )
    }

    /// The agent integration-app surface. The agent credential and the
    /// Marketplace install card (target resolution plus card write, both owned by
    /// the action-card domain) enter as closures.
    public var agentIntegrationApps: AgentIntegrationAppsService {
        AgentIntegrationAppsService(
            oauth: oauth,
            logins: managedMCPAndCardsStore,
            dependencies: AgentIntegrationAppsDependencies(
                agentCredential: { [self] authorization in
                    agentCredentialAgent(authorization)
                },
                prepareMarketplaceInstallCard: { [self] agent, client, scopes, target in
                    guard let resolved = actionCardTarget(
                        serverId: agent.serverId, agentId: agent.id, target: target
                    ) else { return nil }
                    return actionCardIntegrationRegister.prepareMarketplaceInstallCard(
                        serverId: agent.serverId,
                        agent: agent,
                        client: client,
                        scopes: scopes,
                        target: resolved
                    )
                }
            )
        )
    }

    /// The agent mention-delivery and message-resolve lookups. The agent
    /// credential and the shared message-visibility rule (owned by the migrated
    /// search service) enter as closures.
    public var agentMessageLookup: AgentMessageLookupService {
        let search = searchMentions
        return AgentMessageLookupService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            profiles: authProfileStore,
            oauth: oauth,
            dependencies: AgentMessageLookupDependencies(
                agentCredential: { [self] authorization in
                    agentCredentialAgent(authorization)
                },
                messageVisible: { channelId, serverId, agentId in
                    search.messageVisible(messageChannelId: channelId, serverId: serverId, viewer: .agent(agentId))
                }
            )
        )
    }

    // MARK: - Attachment-comment helpers with callers in other domains
    //
    // Moved unchanged from the retired integrations extension: the feature-flag
    // gate is read by search and the profile/files accessor, and the two chip
    // projections are read by search and the auth-core human message surface.

    /// Feature flag gate shared by the attachment-comment routes. It answers
    /// before body validation so a disabled server sees one uniform 403.
    public func attachmentCommentsEnabled(serverId: String, userId: String? = nil) -> Bool {
        evaluateFeatureFlagKey(
            key: "attachment_comments_v0",
            userId: userId ?? "",
            serverId: serverId,
            platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        ).enabled
    }

    /// Attachment projection with the scoped comment count; a viewer who cannot
    /// use attachment comments always observes zero, never a hint.
    func messageAttachmentsJSONLocked(_ ids: [String], commentsVisible: Bool) -> String {
        ids.map { id -> String in
            let count = commentsVisible ? (attachmentCommentRecords[id]?.count ?? 0) : 0
            return "{\"id\":\(jsonString(id)),\"commentCount\":\(count)}"
        }.joined(separator: ",")
    }

    /// Scoped commentRef projection. Callers hold the directory lock. The chip
    /// payload carries the host coordinates the client routes with; it is only
    /// emitted to viewers who may see the scoped comment.
    func commentRefJSONLocked(messageId: String) -> String? {
        for (attachmentId, records) in attachmentCommentRecords {
            guard let record = records.first(where: { $0.id == messageId }),
                  let hostMessageId = record.hostMessageId,
                  let hostChannelId = record.hostChannelId
            else { continue }
            let threadJSON = record.threadChannelId.map(jsonString) ?? "null"
            return "{\"attachmentId\":\(jsonString(attachmentId)),\"hostMessageId\":\(jsonString(hostMessageId)),\"hostSource\":{\"type\":\"channel\",\"routeKind\":\"channel\",\"channelId\":\(jsonString(hostChannelId)),\"rootThreadChannelId\":\(threadJSON)}}"
        }
        return nil
    }
}
