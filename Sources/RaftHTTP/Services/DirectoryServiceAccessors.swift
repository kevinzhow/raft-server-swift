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

    func agentMessageSuppressedLocked(_ message: StoredHumanMessage, agentId: String) -> Bool {
        managedMCPToolExecution.agentMessageSuppressed(message, agentId: agentId)
    }

    func announcementVisibleLocked(
        _ announcement: (id: String, title: String, pages: [String], startsAt: Date, expiresAt: Date?, status: String, publishedAt: Date?, imageId: String?, audienceServerIds: [String]),
        userId: String,
        serverId: String?
    ) -> Bool {
        managedMCPToolExecution.announcementVisible(
            audienceServerIds: announcement.audienceServerIds,
            userId: userId,
            serverId: serverId
        )
    }
}
