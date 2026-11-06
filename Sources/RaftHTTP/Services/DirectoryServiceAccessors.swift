import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Domain service accessors. Each accessor wires one migrated service from the
/// directory's stores and the OAuth ledger.
extension EmailLoginDirectory {
    /// Provider discovery, the web and mobile OAuth legs, the native-Apple
    /// handoff, the installation lookup and the feature-flag evaluation. The
    /// directory supplies the stores and the OAuth ledger; nothing crosses a
    /// domain boundary.
    public var oauthFlows: OAuthFlowsService {
        OAuthFlowsService(
            store: OAuthFlowsStore(profiles: authProfileStore),
            flags: agentsRuntimeStore,
            oauth: oauth
        )
    }

    /// One flag's rollout decision for the unmigrated callers that still ask
    /// per key (`FeedbackService`, the integrations gate). The decision lives in
    /// `AgentsRuntimeStore`.
    func evaluateFeatureFlagKey(
        key: String,
        userId: String,
        serverId: String?,
        platform: String?,
        client: FeatureFlagClientFacts
    ) -> (enabled: Bool, reason: String) {
        agentsRuntimeStore.evaluateFeatureFlag(
            key: key, userId: userId, serverId: serverId, platform: platform, client: client
        )
    }

    public var realtimeRelay: RealtimeRelayService {
        RealtimeRelayService(messages: messagesAndThreadsStore)
    }

    public var agentConnectionRelay: AgentConnectionRelayService {
        AgentConnectionRelayService(agents: agentsRuntimeStore)
    }

    /// Fleet owners and named capabilities; decisions and DTO projections stay
    /// in the domain dependencies.
    public var computersFleet: ComputersFleetService {
        ComputersFleetService(
            machines: machinesAndComputersStore,
            agents: agentsRuntimeStore,
            profiles: authProfileStore,
            oauth: oauth,
            dependencies: ComputersFleetDependencies(
                auth: authCore,
                realtime: realtimeRelay,
                lifecycle: agentsLifecycle,
                agents: agentsRuntimeStore,
                machines: machinesAndComputersStore
            )
        )
    }

    /// Product feedback locators for `POST/GET /internal/agent-api/feedback-locators`
    /// plus the agent credential/grant decisions the rest of the agent API
    /// shares. The directory only supplies its stores and the OAuth ledger.
    public var feedbackLocators: FeedbackLocatorService {
        FeedbackLocatorService(
            feedback: feedbackStore,
            agents: agentsRuntimeStore,
            channels: serversAndChannelsStore,
            cards: managedMCPAndCardsStore,
            oauth: oauth
        )
    }

    /// The served-inbox surface: the channel message page and its sync cursor,
    /// the mention-delivery diagnostics and the Done inbox page. The directory
    /// supplies the message and channel stores, the OAuth ledger, and the
    /// cross-domain closures the service takes at `init`.
    public var inboxAndWake: InboxAndWakeService {
        InboxAndWakeService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            oauth: oauth,
            dependencies: InboxAndWakeDependencies(
                auth: authCore,
                profiles: authProfileStore,
                channelProbeAccess: agentsLifecycle.channelProbeAccess,
                guestCanSeeScope: agentsLifecycle.guestCanSeeScope,
                search: searchMentions,
                projection: messageReadProjection,
                cards: actionCardMetadata
            )
        )
    }

    /// Machine credentials, hosted runtime and provider connections, composed
    /// from their owners and the current relay capabilities.
    public var machinesAndHostedRuntime: MachinesAndHostedRuntimeService {
        MachinesAndHostedRuntimeService(
            auth: authCore,
            oauth: oauth,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            channels: serversAndChannelsStore,
            profiles: authProfileStore,
            realtime: realtimeRelay,
            provider: agentConnectionRelay
        )
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

    /// Agent records and private surfaces, composed from their actual owners,
    /// session authentication, credential use and existing domain capabilities.
    public var agentSurface: AgentPrivateSurfaceService {
        AgentPrivateSurfaceService(
            auth: authCore,
            oauth: oauth,
            agents: agentsRuntimeStore,
            credentialUse: agentCredentialUse,
            machines: machinesAndComputersStore,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            cards: managedMCPAndCardsStore,
            realtime: realtimeRelay,
            prepare: actionCardPrepare,
            reactions: reactionsRealtime,
            notices: agentRoleNotices
        )
    }

    var agentCredentialUse: AgentCredentialUseService {
        AgentCredentialUseService(agents: agentsRuntimeStore, oauth: oauth, realtime: realtimeRelay)
    }

    var agentCredentialLookup: AgentCredentialLookup {
        AgentCredentialLookup(agents: agentsRuntimeStore, channels: agentChannels, credentialUse: agentCredentialUse)
    }

    /// The Done/Undone, read-all, Activity page and agent mention, wake-hint and
    /// event surface. The directory supplies its stores and the OAuth ledger;
    /// the session lookup, the agent read credential, guest scope visibility and
    /// account names enter as closures.
    public var reactionsRealtime: ReactionsRealtimeService {
        ReactionsRealtimeService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            inboxFacts: inboxFactStore,
            cards: managedMCPAndCardsStore,
            oauth: oauth,
            dependencies: ReactionsRealtimeDependencies(
                auth: authCore,
                credentials: agentCredentialLookup,
                agents: agentsRuntimeStore,
                profiles: authProfileStore,
                guestCanSeeScope: agentsLifecycle.guestCanSeeScope
            )
        )
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

    /// Role-change notices own their DM preparation and use the same message
    /// commit as ordinary sends.
    var agentRoleNotices: AgentRoleNoticeService {
        AgentRoleNoticeService(profiles: authProfileStore, channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore, oauth: oauth)
    }

    /// Human message create, the sender-side mention actions and the forward
    /// write. The directory supplies the message, channel, agent and profile
    /// stores and the OAuth ledger; the message append, mention resolution and
    /// the forwarded-item projection still belong to unmigrated domains and
    /// enter as closures.
    public var humanMessageCreate: HumanMessageCreateService {
        HumanMessageCreateService(
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            agents: agentsRuntimeStore,
            profiles: authProfileStore,
            oauth: oauth,
            dependencies: HumanMessageCreateDependencies(
                credentials: agentCredentialLookup,
                writer: HumanMessageCommitService(
                    messages: messagesAndThreadsStore,
                    channels: serversAndChannelsStore,
                    ledger: MessageLedgerPort(oauth: oauth),
                    emit: { [relay = realtimeRelay] in relay.emit($0, $1, $2) }
                ),
                mentions: messageMentions,
                channels: serversAndChannelsStore,
                search: searchMentions
            )
        )
    }

    /// Agent lifecycle: the access-token and credential gates, attachment upload
    /// and read, channel files, client product events, the Computer preflight
    /// and the runtime-provider probe. The directory supplies its stores and the
    /// OAuth ledger; the credential-use stamp (agent private surface) and the
    /// joint-channel projection lookup enter as closures.
    public var agentsLifecycle: AgentsLifecycleService {
        AgentsLifecycleService(
            profiles: authProfileStore,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            inboxFacts: inboxFactStore,
            productEvents: productEventStore,
            oauth: oauth,
            dependencies: AgentsLifecycleDependencies(
                recordAgentCredentialUse: { [credentialUse = agentCredentialUse] token in
                    credentialUse.record(token: token)
                },
                jointLocalChannelId: messageReadProjection.localChannel
            )
        )
    }

    // Forwarders for the lifecycle helpers that unmigrated services still call.

    /// The user id behind a live access token. A missing or unknown bearer is nil.
    public func sessionUserId(authorization: String?) -> String? {
        agentsLifecycle.sessionUserId(authorization: authorization)
    }

    /// Access-token identity used by the socket layer. The family id scopes
    /// revocation to the connection family that owns the token.
    public func sessionIdentity(accessToken: String) -> (userId: String, familyId: String?)? {
        authProfileStore.pushPrincipal(accessToken: accessToken)
    }

    /// Resolve a `push/family-revoke` capability without consuming it.
    public func familyRevokeTarget(capability: String) -> (userId: String, familyId: String)? {
        authProfileStore.familyRevokeTarget(capability: capability)
    }

    func guestCanSeeScopeLocked(_ scopeId: String) -> Bool {
        agentsLifecycle.guestCanSeeScope(scopeId)
    }

    func channelProbeAccessLocked(channelId: String, serverId: String, userId: String) -> ChannelProbeAccess {
        agentsLifecycle.channelProbeAccess(channelId: channelId, serverId: serverId, userId: userId)
    }

    func visibleAttachment(userId: String, serverId: String?, attachment: ChannelAttachment) -> Bool {
        agentsLifecycle.canSeeAttachment(userId: userId, serverId: serverId, attachment: attachment)
    }

    func visibleAttachmentUnlocked(userId: String, serverId: String?, attachment: ChannelAttachment) -> Bool {
        agentsLifecycle.canSeeAttachmentIgnoringJoint(userId: userId, serverId: serverId, attachment: attachment)
    }

    /// The session core: provider completion, register, staging retirement,
    /// device grants, refresh and logout. Every row lives in the account store,
    /// so the accessor needs no cross-domain closure.
    public var authCore: AuthCoreService {
        AuthCoreService(store: authProfileStore)
    }

    /// `requireVerified` reads this from the profile store; the unmigrated
    /// OAuth flows and the inbox closure call it by this name.
    public func isEmailVerified(userId: String) -> Bool {
        authProfileStore.isEmailVerified(userId: userId)
    }

    /// Email-verification policy for `POST /api/auth/verify-email` and
    /// `POST /api/auth/resend-verification`. The feature calls this service;
    /// the directory only supplies the profile store it reads.
    public var authVerification: AuthVerificationService {
        AuthVerificationService(store: authProfileStore)
    }

    /// The message-send boundary: the attachment download URL, the
    /// thread-follower undo routes and the migration receipt DM. It reads the
    /// message/channel/profile stores and the OAuth ledger directly; the
    /// attachment-visibility policy, the socket emitter and the serialized
    /// message append still live in unmigrated directory code and enter as
    /// closures (`MessageSendService.live`).
    public var messageSend: MessageSendService {
        MessageSendService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            profiles: authProfileStore,
            oauth: oauth,
            visibleAttachment: { [self] userId, serverId, attachment in
                visibleAttachment(userId: userId, serverId: serverId, attachment: attachment)
            },
            emitRealtime: { [self] room, event, payload in
                realtimeRelay.emit(room, event, payload)
            },
            registerPostableChannel: { [self] serverId, channelId, memberId, kind, name in
                serversAndChannelsStore.addPostableChannel(
                    serverId: serverId,
                    channelId: channelId,
                    memberId: memberId,
                    kind: kind,
                    name: name
                )
            },
            appendHumanMessage: { [messages = messagesAndThreadsStore, ledger = MessageLedgerPort(oauth: oauth)] message in
                messages.appendMessage(message, ledger: ledger)
            }
        )
    }

    /// Socket room membership: connect-time visibility, thread-room
    /// enumeration, `sync:resume` catch-up and membership revocation. The
    /// directory supplies the channel/message stores and the OAuth ledger; the
    /// attachment-comments feature flag is owned by the unmigrated integrations
    /// domain, so it enters the service as a closure.
    public var socketMembership: SocketMembershipService {
        SocketMembershipService(
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            oauth: oauth,
            attachmentCommentsEnabled: { [self] serverId, userId in
                messageReadProjection.commentsEnabled(serverId: serverId, userId: userId)
            }
        )
    }

    /// Server usage, system attention, mention-delivery diagnostics, session
    /// transcripts, transcript feedback and share artifacts. The directory
    /// supplies the machine/agent/message stores and the OAuth ledger; session
    /// lookup and the unmigrated channel access policy enter as closures.
    public var runtimeUsageAttestations: RuntimeUsageAndAttestationsService {
        RuntimeUsageAndAttestationsService(
            machines: machinesAndComputersStore,
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            agents: agentsRuntimeStore,
            oauth: oauth,
            sessionUserId: { [self] authorization in
                sessionUserId(authorization: authorization)
            },
            channelAccess: { [catalog = taskCatalog] serverId, channelId, userId in
                catalog.canReadChannel(serverId: serverId, channelId: channelId, userId: userId)
            }
        )
    }

    /// Account-profile policy for `POST /api/auth/reset-password`,
    /// `POST /api/auth/pending-link/cancel` and
    /// `POST /api/auth/me/timezone-observation`. The feature calls this
    /// service; the directory only supplies the profile store it reads.
    public var authProfile: AuthProfileService {
        AuthProfileService(store: authProfileStore)
    }

    /// Session, identity, app-login and profile operations: identity list and
    /// unlink, password login, the HarmonyOS app-login handoff, `GET`/`PATCH`
    /// `/api/auth/me`, the avatar upload and the integration settings list. The
    /// directory supplies the profile store and the OAuth ledger.
    public var authIdentities: AuthIdentitiesService {
        AuthIdentitiesService(store: authProfileStore, oauth: oauth)
    }

    /// Agent migration status, cancellation, provider position and the external
    /// diagnostics view. The service owns the three published operations; the
    /// directory supplies the agent runtime store (both migration families), the OAuth ledger, and the
    /// realtime/cancel relay seams the unmigrated migration domains own.
    public var agentMigrationStatus: AgentMigrationStatusService {
        AgentMigrationStatusService(
            auth: authCore,
            oauth: oauth,
            agents: agentsRuntimeStore,
            realtime: realtimeRelay
        )
    }

    /// Agent send, delivery-ack, activity, thread-follow and integration
    /// operations. The directory supplies the stores; the closures bridge the
    /// not-yet-migrated message-visibility, message-append and OAuth
    /// integration-projection domains.
    public var agentSendDelivery: AgentSendDeliveryService {
        AgentSendDeliveryService(
            machines: machinesAndComputersStore,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            agents: agentsRuntimeStore,
            threadFollows: threadFollowStore,
            managedMCP: managedMCPAndCardsStore,
            oauth: oauth,
            search: searchMentions,
            ledger: MessageLedgerPort(oauth: oauth)
        )
    }

    /// Message reactions, the reaction viewer/actor pages, both agent reaction
    /// routes and the managed-daemon third-party delivery report. The directory
    /// supplies the stores; the session and agent-credential/grant decisions and
    /// the attachment-comment projections belong to unmigrated domains and enter
    /// as closures.
    public var profileAndChannelFiles: ProfileAndChannelFilesService {
        ProfileAndChannelFilesService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            accounts: authProfileStore,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            oauth: oauth,
            dependencies: ProfileAndChannelFilesDependencies(
                auth: authCore,
                lookup: agentCredentialLookup,
                locator: feedbackLocators,
                realtime: realtimeRelay,
                projection: messageReadProjection
            )
        )
    }

    /// Action-card prepare, the agent context / app-config surface, and the
    /// agent-target projections the execute/send domains still call. The
    /// service reads the domain stores; the session lookup remains a closure,
    /// and assistant ownership uses only its agent and OAuth owners.
    public var actionCardPrepare: ActionCardPrepareService {
        ActionCardPrepareService(
            oauth: oauth,
            cards: managedMCPAndCardsStore,
            feedback: feedbackStore,
            agents: agentsRuntimeStore,
            channels: serversAndChannelsStore,
            accounts: authProfileStore,
            messages: messagesAndThreadsStore,
            sessionUserId: { [auth = authCore] authorization in try? auth.authenticate(authorization) },
            assistantOwner: { [ownership = AssistantOwnershipQuery(agents: agentsRuntimeStore, oauth: oauth)] agentId, serverId in
                ownership.liveOwner(agentId: agentId, serverId: serverId)
            }
        )
    }

    /// Agent task, execute and send policy stays in its service; this accessor
    /// supplies owners and the existing domain capabilities.
    public var actionCardExecute: ActionCardExecuteService {
        ActionCardExecuteService(
            tasks: tasksAndRemindersStore,
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            oauth: oauth,
            feedbackLocators: feedbackLocators,
            cards: managedMCPAndCardsStore,
            prepare: actionCardPrepare,
            ownership: AssistantOwnershipQuery(agents: agentsRuntimeStore, oauth: oauth),
            suppression: MessageSuppressionService(messages: messagesAndThreadsStore, oauth: oauth),
            mentions: messageMentions,
            ledger: MessageLedgerPort(oauth: oauth)
        )
    }

    /// Message search, the stored context fallback, the shared message
    /// visibility policy and channel soft-delete. The directory supplies the
    /// domain stores and the OAuth ledger; the not-yet-migrated session,
    /// machine/agent credential, attachment/action-card and thread-summary
    /// projections enter as closures.
    public var searchMentions: SearchMentionsService {
        SearchMentionsService(
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            profiles: authProfileStore,
            machines: machinesAndComputersStore,
            agents: agentsRuntimeStore,
            tasks: tasksAndRemindersStore,
            feedback: feedbackStore,
            oauth: oauth,
            dependencies: SearchMentionsDependencies(
                auth: authCore,
                credentials: agentCredentialLookup,
                machineIdForCredential: machinesAndHostedRuntime.machineIdForCredential,
                canMachineServeAgent: machinesAndHostedRuntime.canMachineServeAgent,
                projection: messageReadProjection,
                cards: actionCardMetadata
            )
        )
    }

    /// Product-feedback submission and onboarding-wizard event recording. The
    /// Hands transport and route binding are still owned by the not-yet-migrated
    /// `FeedbackService`, so they enter as closures; the account row, the
    /// feature-flag decision and product-event rows come from their stores.
    public var productFeedbackSubmissions: ProductFeedbackSubmissionService {
        let feedback = feedbackTransport
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
                        key: FeedbackService.productFeedbackMultiAppFlag,
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
                    try FeedbackRouting.feedbackMultiRouteEnvironment(
                        source: source,
                        appsJSON: appsJSON,
                        environment: environment
                    )
                },
                legacyRouteEnvironment: { environment in
                    FeedbackRouting.feedbackLegacyRouteEnvironment(environment)
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

    /// Thread projections and follow state use the current channel owners.
    public func threads(
        publishFollowersUpdated: @escaping @Sendable (ThreadFollowersUpdatedPayload) -> Void = { _ in }
    ) -> ThreadsService {
        ThreadsService(
            store: messagesAndThreadsStore,
            dependencies: ThreadsDependencies(
                auth: authCore,
                channels: serversAndChannelsStore,
                profiles: authProfileStore,
                tasks: tasksAndRemindersStore,
                oauth: oauth,
                channelProbeAccess: agentsLifecycle.channelProbeAccess,
                guestCanSeeScope: agentsLifecycle.guestCanSeeScope,
                visibility: ManagedMCPChannelVisibility(oauth: oauth, channels: serversAndChannelsStore)
            ),
            publishFollowersUpdated: publishFollowersUpdated
        )
    }

    /// Server member roles/removal, server deletion, the sidebar order ledger,
    /// server labs and the task snapshot/period aggregates. The directory
    /// supplies the two domain stores and the OAuth ledger; the session lookup,
    /// the human-name check and the realtime emitter enter as closures because
    /// they belong to domains that have not migrated yet.
    public var serverMembersAndSidebar: ServerMembersAndSidebarService {
        ServerMembersAndSidebarService(dependencies: ServerMembersAndSidebarDependencies(
            auth: authCore,
            realtime: realtimeRelay,
            profiles: authProfileStore,
            oauth: oauth,
            channels: serversAndChannelsStore,
            tasks: tasksAndRemindersStore
        ))
    }

    /// Task creation and live catalog projections share the existing owners.
    public var taskCatalog: TaskCatalogService {
        TaskCatalogService(tasks: tasksAndRemindersStore, profiles: authProfileStore, oauth: oauth)
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

    /// The notice, mirror and acting agent's born-read cursor share one
    /// Messages transaction; external effects run after that transaction returns.
    var systemNoticeAppender: @Sendable (StoredHumanMessage, String?) -> Int {
        { [messages = messagesAndThreadsStore, ledger = MessageLedgerPort(oauth: oauth)] message, bornReadAgentId in
            messages.appendMessage(message, ledger: ledger, bornReadAgentId: bornReadAgentId)
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
                auth: authCore,
                agents: agentsRuntimeStore,
                realtime: realtimeRelay,
                messageSend: messageSend
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
                emitRealtime: { [self] room, event, payload in realtimeRelay.emit(room, event, payload) }
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

    /// Runtime forms, probes, settings and machine registration, composed from
    /// their owners, session authentication and realtime delivery capability.
    public var runtimeFormsAndProbes: RuntimeFormsAndProbesService {
        RuntimeFormsAndProbesService(
            auth: authCore,
            oauth: oauth,
            machines: machinesAndComputersStore,
            servers: serversAndChannelsStore,
            notifications: notificationsStore,
            agents: agentsRuntimeStore,
            realtime: realtimeRelay
        )
    }

    /// Server profile, switcher order, pre-join agreement, translation, the
    /// member directory, scope attestations and the share-artifact pages. The
    /// directory supplies the stores and the OAuth ledger; the session and
    /// machine-credential lookups enter as closures.
    public var serverProfileAndOrder: ServerProfileAndOrderService {
        ServerProfileAndOrderService(dependencies: ServerProfileAndOrderDependencies(
            auth: authCore,
            machineIdForCredential: machinesAndHostedRuntime.machineIdForCredential,
            oauth: oauth,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            profiles: authProfileStore,
            machines: machinesAndComputersStore,
            agents: agentsRuntimeStore
        ))
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
        let feedback = feedbackTransport
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
                threadByAnchor: { [serversAndChannelsStore] parentId, anchorMessageId in
                    serversAndChannelsStore.historyThread(parentId: parentId, anchorMessageId: anchorMessageId)
                },
                threadById: { [serversAndChannelsStore] parentId, suffix in
                    serversAndChannelsStore.historyThread(parentId: parentId, idPrefix: suffix)
                },
                threadByAnchorPrefix: { [serversAndChannelsStore] parentId, suffix in
                    serversAndChannelsStore.historyThread(parentId: parentId, anchorPrefix: suffix)
                },
                agentReadUpdated: { [notificationsStore] serverId, channelId, agentId, seq in
                    notificationsStore.onAgentReadUpdated?(serverId, channelId, agentId, seq)
                }
            )
        )
    }

    // MARK: - Native notifications, agent attachments and integration tokens

    /// Native notification enrollment, devices, credentials, the stream open and
    /// the event ledger. The rows live in the notifications store's native
    /// store; the kill switch and attestation policy in the notifications store;
    /// the sessions come from the profile store.
    public var nativeNotifications: NativeNotificationsService {
        NativeNotificationsService(
            rows: notificationsStore.native,
            settings: notificationsStore,
            profiles: authProfileStore
        )
    }

    /// The agent attachment download, the minted download URL and the shared
    /// agent visibility rule. The credential decision belongs to the feedback
    /// locator service.
    public var agentAttachments: AgentAttachmentsService {
        AgentAttachmentsService(
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            agents: agentsRuntimeStore,
            oauth: oauth,
            locators: feedbackLocators
        )
    }

    /// `POST /internal/agent-api/integrations/token`.
    public var agentIntegrationTokens: AgentIntegrationTokenService {
        AgentIntegrationTokenService(
            agents: agentsRuntimeStore,
            grants: managedMCPAndCardsStore,
            profiles: authProfileStore,
            oauth: oauth
        )
    }
}
