import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Integrations, app-access and attachment-comment accessors, moved out of
/// `DirectoryServiceAccessors.swift` (pure move) to keep that file under the
/// Services line ceiling.
extension EmailLoginDirectory {
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
                    messageReadProjection.commentsEnabled(serverId: serverId, userId: userId)
                },
                visibleAttachment: { [self] userId, serverId, attachment in
                    visibleAttachment(userId: userId, serverId: serverId, attachment: attachment)
                },
                visibleAttachmentUnlocked: { [self] userId, serverId, attachment in
                    visibleAttachmentUnlocked(userId: userId, serverId: serverId, attachment: attachment)
                },
                agentCredential: { [lookup = agentCredentialLookup] authorization in
                    lookup.agentCredentialAgent(authorization)
                },
                agentVisibleAttachment: { [agentAttachments] agentId, serverId, attachmentId in
                    agentAttachments.visibleAttachment(agentId: agentId, serverId: serverId, attachmentId: attachmentId)
                },
                agentHistoryThread: { [serversAndChannelsStore] parentId, anchorMessageId in
                    serversAndChannelsStore.historyThread(parentId: parentId, anchorMessageId: anchorMessageId)
                },
                recordMemberMentionRows: { [self] messageId, channelId, mentions in
                    messageMentions.register(messageId: messageId, channelId: channelId, mentions: mentions)
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
                lookup: agentCredentialLookup,
                register: actionCardIntegrationRegister
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
                agentCredential: { [lookup = agentCredentialLookup] authorization in
                    lookup.agentCredentialAgent(authorization)
                },
                messageVisible: { channelId, serverId, agentId in
                    search.messageVisible(messageChannelId: channelId, serverId: serverId, viewer: .agent(agentId))
                }
            )
        )
    }

    var messageReadProjection: MessageReadProjection {
        MessageReadProjection(messages: messagesAndThreadsStore, channels: serversAndChannelsStore,
            profiles: authProfileStore, agents: agentsRuntimeStore, oauth: oauth)
    }

    var messageMentions: MessageMentionsService {
        MessageMentionsService(messages: messagesAndThreadsStore, channels: serversAndChannelsStore,
            profiles: authProfileStore, agents: agentsRuntimeStore, oauth: oauth)
    }
}
