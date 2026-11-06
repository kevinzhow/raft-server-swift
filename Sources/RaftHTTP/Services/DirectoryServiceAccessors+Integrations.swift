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
                agentVisibleAttachment: { [agentAttachments] agentId, serverId, attachmentId in
                    agentAttachments.visibleAttachment(agentId: agentId, serverId: serverId, attachmentId: attachmentId)
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
