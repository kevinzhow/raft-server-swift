import Foundation
import RaftObjectStorage
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The agent attachment surface: byte download, minted download URL and the
/// visibility rule the attachment-comment routes share.
///
/// The service returns published DTOs or throws a `DomainError`; it never
/// builds a reply. A refused credential throws the `FeedbackLocatorError` the
/// rest of the agent API publishes.
public struct AgentAttachmentsService: Sendable {
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let agents: AgentsRuntimeStore
    private let oauth: OAuthLedger
    private let locators: FeedbackLocatorService
    private let now: @Sendable () -> Date

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        agents: AgentsRuntimeStore,
        oauth: OAuthLedger,
        locators: FeedbackLocatorService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.messages = messages
        self.channels = channels
        self.agents = agents
        self.oauth = oauth
        self.locators = locators
        self.now = now
    }

    /// The attachment when the agent may see it: the channel is in the agent's
    /// Server and live, and is a public channel, a member channel or one the
    /// agent was added to.
    func visibleAttachment(agentId: String, serverId: String, attachmentId: String) -> ChannelAttachment? {
        guard let attachment = messages.channelAttachments[attachmentId],
              AgentChannelAccessQuery(channels: channels, messages: messages, oauth: oauth)
                  .canAccess(channelId: attachment.channelId, serverId: serverId, agentId: agentId)
        else { return nil }
        return attachment
    }

    /// `GET /internal/agent-api/attachments/:attachmentId`.
    public func download(authorization: String?, attachmentId: String) async throws -> AgentAttachmentDownload {
        let identity = try requireIdentity(authorization)
        guard let attachment = visibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            throw AgentAttachmentsError.unavailable
        }
        let captured = messages.withState { state in
            (state.attachmentObjectReferences[attachmentId], state.attachmentObjectStorage,
             state.developmentAttachmentBytes[attachmentId], state.requiresDurableAttachmentStorage)
        }
        let bytes: Data
        if let reference = captured.0 {
            guard let storage = captured.1 else { throw AttachmentContentError.downloadsNotConfigured }
            do { bytes = try await storage.get(reference) }
            catch AttachmentStorageError.notFound { throw AgentAttachmentsError.unavailable }
            catch { throw AttachmentContentError.downloadFailed }
            guard messages.withState({ $0.attachmentObjectReferences[attachmentId] }) == reference else {
                throw AgentAttachmentsError.unavailable
            }
        } else {
            guard !captured.3 else { throw AttachmentContentError.downloadsNotConfigured }
            guard let stored = captured.2 ?? agents.agentAttachmentBytes[attachmentId] else {
                throw AgentAttachmentsError.unavailable
            }
            bytes = stored
        }
        let current = try requireIdentity(authorization)
        guard current.agentId == identity.agentId, current.serverId == identity.serverId,
              visibleAttachment(agentId: current.agentId, serverId: current.serverId, attachmentId: attachmentId) != nil else {
            throw AgentAttachmentsError.unavailable
        }
        if let size = attachment.sizeBytes, bytes.count != size { throw AttachmentContentError.downloadFailed }
        return AgentAttachmentDownload(
            bytes: bytes, mimeType: attachment.mimeType ?? "application/octet-stream",
            filename: attachment.filename, encodedFilename: AttachmentPresentationRules.encodedFilename(
                AttachmentPresentationRules.normalizedFilename(attachment.filename))
        )
    }

    /// `GET /internal/agent-api/attachments/:attachmentId/url`.
    public func downloadURL(authorization: String?, attachmentId: String) throws -> AgentAttachmentDownloadURL {
        let identity = try requireIdentity(authorization)
        guard let attachment = visibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            throw AgentAttachmentsError.unavailable
        }
        guard let presign = agents.agentAttachmentPresign else {
            throw AgentAttachmentsError.downloadURLUnavailable
        }
        let ext = (attachment.filename as NSString).pathExtension
        let storageKey = attachment.storageKey ?? (ext.isEmpty ? "\(identity.serverId)/\(attachmentId)" : "\(identity.serverId)/\(attachmentId).\(ext)")
        let filename = attachment.filename
        let mimeType = attachment.mimeType ?? "application/octet-stream"
        let disposition = AttachmentPresentationRules.defaultDisposition(filename: filename, mimeType: mimeType)
        let url: String
        do {
            url = try presign(storageKey, 300, disposition, AttachmentPresentationRules.contentType(mimeType))
        } catch {
            throw AgentAttachmentsError.mintFailed
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return AgentAttachmentDownloadURL(
            url: url,
            expiresAt: formatter.string(from: now().addingTimeInterval(300)),
            filename: filename,
            mimeType: mimeType
        )
    }

    private func requireIdentity(_ authorization: String?) throws -> (agentId: String, serverId: String) {
        switch locators.identityResolution(authorization: authorization, capability: "read") {
        case .success(let agentId, let serverId):
            return (agentId, serverId)
        case .missingAuthorization:
            throw AgentCredentialAuthError.missingCredential
        case .invalidAccessToken:
            throw FeedbackLocatorError.invalidAccessToken
        case .capabilityNotAuthorized(let capability):
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: capability)
        case .invalidAgentCredential:
            throw FeedbackLocatorError.invalidAgentCredential
        }
    }
}
