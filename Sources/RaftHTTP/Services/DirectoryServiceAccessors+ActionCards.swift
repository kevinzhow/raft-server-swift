import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Feedback-transport and action-card service accessors, moved out of
/// `DirectoryServiceAccessors.swift` (pure move) to keep that file under the
/// Services line ceiling.
extension EmailLoginDirectory {
    /// The Hands upstream transport, route binding and reporter sessions. The
    /// ledger lives in `FeedbackStore`; the conversation-session seam and the
    /// warning sink belong to the account store and the `product_feedback_multi_app`
    /// flag decision to the feature-flag ledger, so they enter as closures.
    var feedbackTransport: FeedbackService {
        FeedbackService(
            store: feedbackStore,
            dependencies: FeedbackService.Dependencies(
                conversationSessionEnabled: { [authProfileStore] in
                    authProfileStore.handsConversationSessionEnabled
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
                deliverWarning: { [authProfileStore] message in
                    guard let sink = authProfileStore.handsFeedbackWarningSink else { return false }
                    sink(message)
                    return true
                }
            )
        )
    }

    // MARK: - Action cards and the agent task surface

    /// The prepared-card `metadata` projection the message readers embed.
    var actionCardMetadata: ActionCardMetadataProjection {
        ActionCardMetadataProjection(cards: managedMCPAndCardsStore, oauth: oauth)
    }

    /// Agent task create/convert/delete/assign/resource-receipt and the agent
    /// inbox conversation list. The directory supplies the domain stores and
    /// the OAuth ledger; the message-append policy (messaging) is a
    /// not-yet-migrated dependency and enters as a closure. The idempotency
    /// ledger is `ActionCardTaskIdempotencyLedger` over the cards store.
    public var actionCardMarketplace: ActionCardMarketplaceService {
        ActionCardMarketplaceService(
            tasks: tasksAndRemindersStore,
            messages: messagesAndThreadsStore,
            inboxFacts: inboxFactStore,
            channels: serversAndChannelsStore,
            accounts: authProfileStore,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            cards: managedMCPAndCardsStore,
            oauth: oauth,
            locator: feedbackLocators,
            idempotency: ActionCardTaskIdempotencyLedger.port(cards: managedMCPAndCardsStore),
            appendHumanMessage: { [messages = messagesAndThreadsStore, ledger = MessageLedgerPort(oauth: oauth)] message in
                messages.appendMessage(message, ledger: ledger)
            },
            serializeReceipt: MarketplaceReceiptProjection.renderObjectReceipt
        )
    }

    /// Action-card prepare/execute and the integration app-registration
    /// surface. The directory supplies the stores and the OAuth ledger; the
    /// human session ledger, the message append that stamps a server sequence,
    /// the channel roster write and the realtime relay enter as closures.
    public var actionCardIntegrationRegister: ActionCardIntegrationRegisterService {
        ActionCardIntegrationRegisterService(
            cards: managedMCPAndCardsStore,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            inboxFacts: inboxFactStore,
            accounts: authProfileStore,
            agents: agentsRuntimeStore,
            oauth: oauth,
            dependencies: ActionCardIntegrationRegisterDependencies(
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                agentCredential: { [lookup = agentCredentialLookup] authorization in
                    lookup.agentCredentialAgent(authorization)
                },
                identityResolution: { [self] authorization, capability in
                    FeedbackLocatorService(
                        feedback: feedbackStore,
                        agents: agentsRuntimeStore,
                        channels: serversAndChannelsStore,
                        cards: managedMCPAndCardsStore,
                        oauth: oauth
                    ).identityResolution(authorization: authorization, capability: capability)
                },
                appendHumanMessage: { [messages = messagesAndThreadsStore, ledger = MessageLedgerPort(oauth: oauth)] message in
                    messages.appendMessage(message, ledger: ledger)
                },
                addPostableChannel: { [self] serverId, channelId, memberId, kind, parentChannelId, parentMessageId, name in
                    serversAndChannelsStore.addPostableChannel(
                        serverId: serverId,
                        channelId: channelId,
                        memberId: memberId,
                        kind: kind,
                        parentChannelId: parentChannelId,
                        parentMessageId: parentMessageId,
                        name: name
                    )
                },
                emitRealtime: { [self] room, event, payload in
                    realtimeRelay.emit(room, event, payload)
                },
                marketplaceInstallableClient: { [self] recordId in
                    oauth.marketplaceInstallableClientIdentity(recordId: recordId)
                },
                publicIntegrationClient: { [self] clientId in
                    oauth.publicIntegrationClientIdentity(clientId: clientId)
                }
            )
        )
    }
}
