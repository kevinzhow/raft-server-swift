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
