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
        OAuthFlowsService(directory: self)
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
                    agentsLifecycle.computerAttachEnabled()
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
                recordAgentCredentialUse: { [self] token in
                    recordAgentCredentialUse(token: token)
                },
                jointLocalChannelId: { [self] canonicalChannelId, serverId, userId in
                    jointLocalChannelIdLocked(
                        canonicalChannelId: canonicalChannelId,
                        serverId: serverId,
                        userId: userId
                    )
                }
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

    /// The bearer access-token check the domain services that have not migrated
    /// yet still share. The decision is `AuthCoreService.authenticate`; this
    /// forwarder only maps it to the `Auth` value those callers consume.
    func authorize(_ authorization: String?) -> Auth {
        do {
            return .user(try authCore.authenticate(authorization))
        } catch AuthCoreError.missingAuthorization {
            return .rejected(Self.missingAuthorization)
        } catch {
            return .rejected(Self.invalidToken)
        }
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
                emitRealtime(room, event, payload)
            },
            registerPostableChannel: { [self] serverId, channelId, memberId, kind, name in
                addPostableChannel(
                    serverId: serverId,
                    channelId: channelId,
                    memberId: memberId,
                    kind: kind,
                    name: name
                )
            },
            appendHumanMessage: { [self] message in
                // The append still serializes with every other message writer
                // under the directory lock until the channel-message domain
                // moves its seq stamping into `MessagesAndThreadsStore`.
                lock.lock()
                defer { lock.unlock() }
                return appendHumanMessageLocked(message)
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
                attachmentCommentsEnabled(serverId: serverId, userId: userId)
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
            channelAccess: { [self] serverId, channelId, userId in
                switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
                case .missing: false
                case .readOnly, .write: true
                }
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
        let accounts = self
        return AgentMigrationStatusService(
            sessionUserId: { accounts.sessionUserId(authorization: $0) },
            oauth: oauth,
            agents: agentsRuntimeStore,
            emitRealtime: { room, event, payload in
                accounts.emitRealtime(room, event, payload)
            },
            cancelDispatch: { machineId, role, migrationRef, transportGeneration, stopAgent in
                accounts.agentMigrationCancelDispatch?(
                    machineId,
                    role,
                    migrationRef,
                    transportGeneration,
                    stopAgent
                )
            }
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
            searchVisible: { [self] messageChannelId, serverId, viewer in
                searchMentions.messageVisible(
                    messageChannelId: messageChannelId,
                    serverId: serverId,
                    viewer: viewer
                )
            },
            appendHumanMessage: { [self] message in
                lock.lock()
                let seq = appendHumanMessageLocked(message)
                lock.unlock()
                return seq
            },
            integrationServices: { [self] serverId in
                oauth.integrationServices(serverId: serverId).map(AgentIntegrationProjection.snapshot)
            }
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
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                agentRead: { [self] authorization in
                    profileAgentReadOutcome(authorization)
                },
                capabilityDenial: { [self] authorization, capability in
                    switch FeedbackLocatorService(directory: self)
                        .capabilityDecision(authorization: authorization, capability: capability) {
                    case .allowed:
                        return nil
                    case .denied(let denied):
                        return denied
                    }
                },
                emitRealtime: { [self] room, event, payload in
                    emitRealtime(room, event, payload)
                },
                attachmentCommentsEnabled: { [self] serverId, userId in
                    attachmentCommentsEnabled(serverId: serverId, userId: userId)
                },
                attachmentsJSON: { [self] ids, commentsVisible in
                    lock.lock()
                    defer { lock.unlock() }
                    return "[" + messageAttachmentsJSONLocked(ids, commentsVisible: commentsVisible) + "]"
                },
                commentRefJSON: { [self] messageId in
                    lock.lock()
                    defer { lock.unlock() }
                    return commentRefJSONLocked(messageId: messageId)
                }
            )
        )
    }

    /// Action-card prepare, the agent context / app-config surface, and the
    /// agent-target projections the execute/send domains still call. The
    /// service reads the domain stores; the session lookup and the
    /// assistant-owner policy belong to unmigrated domains and enter as
    /// closures.
    public var actionCardPrepare: ActionCardPrepareService {
        ActionCardPrepareService(
            oauth: oauth,
            cards: managedMCPAndCardsStore,
            feedback: feedbackStore,
            agents: agentsRuntimeStore,
            channels: serversAndChannelsStore,
            accounts: authProfileStore,
            messages: messagesAndThreadsStore,
            sessionUserId: { self.sessionUserId(authorization: $0) },
            assistantOwner: { [self] agentId, serverId in
                assistantOwnerFor(agentId: agentId, serverId: serverId)
            }
        )
    }

    /// Agent task list, claim and update-status. The service owns the task
    /// policy and reads the task/message/channel/agent/machine stores; the
    /// directory accessor stays here so the feature layer never touches the
    /// composition root.
    public var actionCardExecute: ActionCardExecuteService {
        ActionCardExecuteService(directory: self)
    }

    /// Message search, the stored context fallback, the shared message
    /// visibility policy and channel soft-delete. The directory supplies the
    /// domain stores and the OAuth ledger; the not-yet-migrated session,
    /// machine/agent credential, attachment/action-card and thread-summary
    /// projections enter as closures.
    public var searchMentions: SearchMentionsService {
        SearchMentionsService(directory: self)
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
    var systemNoticeAppender: @Sendable (StoredHumanMessage, String?) -> Int {
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
