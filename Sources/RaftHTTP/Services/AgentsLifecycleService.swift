import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftShared

// MARK: - Injected dependencies

/// What the agent lifecycle surface needs from domains that have not migrated.
///
/// The agent credential use stamp belongs to the agent private surface, and the
/// joint-channel projection lookup to the profile/channel-files helpers; both
/// enter as closures wired by `EmailLoginDirectory.agentsLifecycle`. The
/// environment and the clock are injectable so a test can pin them.
struct AgentsLifecycleDependencies: Sendable {
    var recordAgentCredentialUse: @Sendable (_ token: String) -> Void
    var jointLocalChannelId: @Sendable (_ canonicalChannelId: String, _ serverId: String?, _ userId: String) -> String?
    var environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    var now: @Sendable () -> Date = { Date() }
}

// MARK: - Service

/// Agent lifecycle: the session and credential gates the runtime routes consult,
/// attachment upload/visibility/read, channel files, client product events, the
/// Computer preflight and the runtime-provider probe.
///
/// The service owns the orchestration and returns the published DTOs; every
/// refusal is an `AgentsLifecycleError`. It builds no HTTP reply or header set.
/// A multi-row write (the client-event admission, the session rotation, the
/// analytics id mint) is one store critical section.
public struct AgentsLifecycleService: Sendable {
    let profiles: AuthProfileStore
    let agents: AgentsRuntimeStore
    let machines: MachinesAndComputersStore
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let inboxFacts: InboxFactStore
    let productEvents: ProductEventStore
    let oauth: OAuthLedger
    let dependencies: AgentsLifecycleDependencies

    init(
        profiles: AuthProfileStore,
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        inboxFacts: InboxFactStore,
        productEvents: ProductEventStore,
        oauth: OAuthLedger,
        dependencies: AgentsLifecycleDependencies
    ) {
        self.profiles = profiles
        self.agents = agents
        self.machines = machines
        self.channels = channels
        self.messages = messages
        self.inboxFacts = inboxFacts
        self.productEvents = productEvents
        self.oauth = oauth
        self.dependencies = dependencies
    }

    // MARK: - Shared gates

    private static let bearerPrefix = "Bearer "

    static func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix(bearerPrefix) else { return nil }
        return String(authorization.dropFirst(bearerPrefix.count))
    }

    /// The user id behind a live access token. A missing or unknown bearer, or a
    /// revoked session family, is nil. The decision is
    /// `AuthCoreService.authenticate`; this is the optional-valued view of it.
    public func sessionUserId(authorization: String?) -> String? {
        try? AuthCoreService(store: profiles).authenticate(authorization)
    }

    func requireUser(_ authorization: String?) throws -> String {
        guard let userId = sessionUserId(authorization: authorization) else {
            throw AgentsLifecycleError.unauthorized
        }
        return userId
    }

    /// The bearer credential of an agent, marking its use.
    func agentCredential(_ authorization: String?) -> (agentId: String, scopes: [String])? {
        guard let token = Self.bearerToken(authorization) else { return nil }
        return agents.useAgentCredential(token: token, now: dependencies.now())
    }

    func requireUploadsEnabled() throws {
        let gate = (dependencies.environment()["ATTACHMENT_UPLOAD_ENABLED"] ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["false", "0", "off"].contains(gate) { throw AgentsLifecycleError.uploadsDisabled }
    }

    func uploadLimit(serverId: String) -> Int {
        let plan = oauth.serverProfile(id: serverId)?.plan ?? "free"
        return plan == "free" ? 50 * 1024 * 1024 : 200 * 1024 * 1024
    }

    private func insertAttachment(
        channelId: String,
        uploaderId: String,
        uploaderType: String = "user",
        filename: String,
        mimeType: String?,
        sizeBytes: Int
    ) -> String {
        let id = UUID().uuidString.lowercased()
        messages.insertAttachment(ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: nil,
            messagePosition: nil,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            uploaderType: uploaderType
        ))
        return id
    }

    // MARK: - Agent credential identity

    /// Typed credential resolution for the knowledge routes.
    public func resolveAgentApiIdentity(authorization: String?) throws -> AgentApiIdentityDTO {
        try agentApiIdentity(authorization: authorization).identity
    }

    /// `GET /internal/agent-api`. The credential use is recorded after the token
    /// check and before the agent lookup, as upstream does.
    public func agentApiIdentity(authorization: String?) throws -> AgentApiCredentialResponse {
        guard let token = Self.bearerToken(authorization) else {
            throw AgentsLifecycleError.invalidOrExpiredToken
        }
        guard let credential = agents.agentCredentials[token], credential.revokedAt == nil else {
            throw AgentsLifecycleError.invalidOrExpiredToken
        }
        dependencies.recordAgentCredentialUse(token)
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            throw AgentsLifecycleError.invalidOrExpiredToken
        }
        return AgentApiCredentialResponse(
            agentId: credential.agentId,
            credentialId: credential.id,
            serverId: agent.serverId,
            scopes: credential.scopes.sorted()
        )
    }

    // MARK: - Attachment upload

    /// `POST /internal/agent-api/upload`.
    public func uploadAgentAttachmentIdless(
        authorization: String?,
        channelId: String,
        filename: String,
        mimeType: String?,
        sizeBytes: Int,
        bytes: Data
    ) throws -> AgentAttachmentUploadResponse {
        guard !messages.withState({ $0.requiresDurableAttachmentStorage }) else {
            throw AttachmentContentError.uploadFailed
        }
        try requireUploadsEnabled()
        guard let credential = agentCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              credential.scopes.contains("send") || credential.scopes.contains("write")
        else {
            throw AgentsLifecycleError.capabilityNotAuthorized
        }
        let channel = channels.postableChannels[channelId]
        guard let channel, channel.serverId == agent.serverId, channel.deletedAt == nil,
              channel.kind == "channel"
                || channel.memberIds.contains(agent.id)
                || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
        else {
            throw AgentsLifecycleError.channelNotFound
        }
        guard sizeBytes > 0 else { throw AgentsLifecycleError.emptyFile }
        let maxBytes = uploadLimit(serverId: agent.serverId)
        if sizeBytes > maxBytes { throw AgentsLifecycleError.fileTooLarge(maxBytes: maxBytes) }
        let id = insertAttachment(
            channelId: channelId,
            uploaderId: agent.id,
            uploaderType: "agent",
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
        agents.storeAgentAttachmentBytes(id: id, bytes: bytes)
        return AgentAttachmentUploadResponse(id: id, filename: filename, mimeType: mimeType, sizeBytes: sizeBytes)
    }

    /// `GET /internal/agent-api/attachment-upload-capabilities`.
    public func agentAttachmentUploadCapabilities(
        authorization: String?
    ) throws -> AttachmentUploadCapabilitiesResponse {
        guard let credential = agentCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              let profile = oauth.serverProfile(id: agent.serverId)
        else {
            throw AgentsLifecycleError.invalidOrExpiredToken
        }
        return AttachmentUploadCapabilitiesResponse(maxBytes: profile.plan == "free" ? 50 * 1024 * 1024 : 90 * 1024 * 1024)
    }

    /// `POST /api/attachments/upload`.
    public func uploadAttachments(
        authorization: String?,
        serverId: String,
        channelId: String,
        files: [AttachmentUploadFile]
    ) throws -> AttachmentUploadListResponse {
        guard !messages.withState({ $0.requiresDurableAttachmentStorage }) else {
            throw AttachmentContentError.uploadFailed
        }
        try requireUploadsEnabled()
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw AgentsLifecycleError.notAMember
        }
        let channel = channels.postableChannels[channelId]
        guard let channel, channel.serverId == serverId, channel.deletedAt == nil,
              channel.kind == "channel" || channel.memberIds.contains(userId)
        else {
            throw AgentsLifecycleError.channelNotFound
        }
        guard files.count <= 10 else { throw AgentsLifecycleError.tooManyFiles }
        if files.contains(where: { $0.sizeBytes <= 0 }) { throw AgentsLifecycleError.emptyFile }
        let maxBytes = uploadLimit(serverId: serverId)
        if files.contains(where: { $0.sizeBytes > maxBytes }) {
            throw AgentsLifecycleError.fileTooLarge(maxBytes: maxBytes)
        }
        let rows = files.map { file in
            AttachmentUploadListResponse.Row(
                id: insertAttachment(
                    channelId: channelId,
                    uploaderId: userId,
                    filename: file.filename,
                    mimeType: file.mimeType,
                    sizeBytes: file.sizeBytes
                ),
                filename: file.filename
            )
        }
        return AttachmentUploadListResponse(attachments: rows)
    }

    /// `POST /internal/agent/:agentId/upload`: the Computer-side machine key.
    public func uploadAgentAttachment(
        authorization: String?,
        agentId: String,
        channelId: String,
        filename: String,
        mimeType: String?,
        sizeBytes: Int
    ) throws -> AttachmentUploadListResponse {
        guard !messages.withState({ $0.requiresDurableAttachmentStorage }) else {
            throw AttachmentContentError.uploadFailed
        }
        try requireUploadsEnabled()
        guard let token = Self.bearerToken(authorization) else { throw AgentsLifecycleError.unauthorized }
        let machine = machines.machines.first { $0.apiKey == token }
        let agent = oauth.agentRuntimeInfo(id: agentId)
        let assigned = agents.agentMachineIds[agentId]
        let channel = channels.postableChannels[channelId]
        guard let agent, !agent.deleted else { throw AgentsLifecycleError.agentMissing }
        guard let machine, machine.serverId == agent.serverId, assigned == machine.id else {
            throw AgentsLifecycleError.forbidden
        }
        guard let channel, channel.serverId == agent.serverId, channel.deletedAt == nil,
              channel.kind == "channel"
                || channel.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: channelId).contains(agentId)
        else {
            throw AgentsLifecycleError.channelNotFound
        }
        guard sizeBytes > 0 else { throw AgentsLifecycleError.emptyFile }
        let maxBytes = uploadLimit(serverId: agent.serverId)
        if sizeBytes > maxBytes { throw AgentsLifecycleError.fileTooLarge(maxBytes: maxBytes) }
        let id = insertAttachment(
            channelId: channelId,
            uploaderId: agentId,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
        return AttachmentUploadListResponse(attachments: [.init(id: id, filename: filename)])
    }

    /// `POST /api/attachments/upload-sessions`: direct uploads are not offered,
    /// so a member is always refused.
    public func attachmentUploadSessionCreate(authorization: String?, serverId: String) throws -> Never {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw AgentsLifecycleError.notAMember
        }
        throw AgentsLifecycleError.uploadForbidden
    }

    /// Every other upload-session verb: a session never exists.
    public func attachmentUploadSessionMissing(authorization: String?, uploadId: String) throws -> Never {
        _ = try requireUser(authorization)
        throw AgentsLifecycleError.uploadSessionNotFound
    }

    /// `GET /api/attachments/upload-capabilities`.
    public func attachmentUploadCapabilities(
        authorization: String?,
        serverId: String
    ) throws -> AttachmentUploadCapabilitiesResponse {
        let userId = try requireUser(authorization)
        guard let profile = oauth.serverProfile(id: serverId),
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            throw AgentsLifecycleError.notAMember
        }
        return AttachmentUploadCapabilitiesResponse(maxBytes: profile.plan == "free" ? 50 * 1024 * 1024 : 90 * 1024 * 1024)
    }

    // MARK: - Attachment and channel visibility

    /// Visibility for callers that only follow the message into its own channel
    /// (no joint-channel projection).
    func canSeeAttachmentIgnoringJoint(userId: String, serverId: String?, attachment: ChannelAttachment) -> Bool {
        let rows = messages.humanMessageRows
        let channelRows = channels.postableChannels
        let effectiveChannelId = attachment.messageId.flatMap { messageId in
            rows.first { $0.id == messageId }?.channelId
        } ?? attachment.channelId
        if let channel = channelRows[effectiveChannelId],
           channel.serverId == serverId,
           channel.deletedAt == nil {
            return channel.kind == "channel" || channel.memberIds.contains(userId)
        }
        guard let serverId, attachment.messageId != nil else { return false }
        return oauth.memberRole(serverId: serverId, userId: userId) != nil
    }

    /// The attachment-visibility policy. A linked attachment follows its message
    /// into a joint canonical channel; an unlinked draft stays on its upload
    /// channel.
    func canSeeAttachment(userId: String, serverId: String?, attachment: ChannelAttachment) -> Bool {
        let rows = messages.humanMessageRows
        let channelState = channels.state
        let channelRows = channelState.postableChannels
        let projections = channelState.jointProjections
        let effectiveChannelId = attachment.messageId.flatMap { messageId in
            rows.first { $0.id == messageId }?.channelId
        } ?? attachment.channelId
        if let channel = channelRows[effectiveChannelId],
           channel.serverId == serverId,
           channel.deletedAt == nil {
            return channel.kind == "channel" || channel.memberIds.contains(userId)
        }
        guard let serverId, let messageId = attachment.messageId else { return false }
        let canonicalId: String?
        if let link = projections.first(where: { $0.localChannelId == effectiveChannelId }) {
            canonicalId = link.canonicalChannelId
        } else if projections.contains(where: { $0.canonicalChannelId == effectiveChannelId }) {
            canonicalId = effectiveChannelId
        } else {
            canonicalId = nil
        }
        guard let canonicalId,
              rows.contains(where: { $0.id == messageId && $0.channelId == canonicalId }),
              let localId = dependencies.jointLocalChannelId(canonicalId, serverId, userId),
              let local = channelRows[localId],
              local.deletedAt == nil
        else { return false }
        return true
    }

    /// A probe on a channel the caller cannot currently read. Missing and hidden
    /// answer the same way; receiver-owned residue is acknowledged with a
    /// distinct answer so the caller can clear Activity.
    func channelProbeAccess(channelId: String, serverId: String, userId: String) -> ChannelProbeAccess {
        ChannelProbeAccessQuery(channels: channels, messages: messages, inboxFacts: inboxFacts, oauth: oauth)
            .access(channelId: channelId, serverId: serverId, userId: userId)
    }

    /// Whether a guest can see a scope: a thread follows its parent channel.
    func guestCanSeeScope(_ scopeId: String) -> Bool {
        let state = channels.state
        if state.postableChannels[scopeId]?.kind == "thread",
           let parentId = state.postableChannels[scopeId]?.parentChannelId {
            return state.guestVisibleChannels[parentId] ?? true
        }
        return state.guestVisibleChannels[scopeId] ?? true
    }

    // MARK: - Channel files

    private struct ChannelFilesCursor: Decodable {
        let createdAt: String
        let id: String
    }

    /// `GET /api/channels/:channelId/files`.
    public func channelFiles(
        authorization: String?,
        serverId: String,
        channelId: String,
        limit rawLimit: String? = nil,
        cursor rawCursor: String? = nil
    ) throws -> ChannelFilesResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw AgentsLifecycleError.notAMember
        }
        let readAccess = HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: agents)
        let readable = readAccess.authority(channelId: channelId, serverId: serverId, userId: userId) != nil
            || (channels.postableChannel(id: channelId) == nil
                && LedgerChannelReadFallback.canReadHuman(
                    channelId: channelId, serverId: serverId, userId: userId, oauth: oauth))
        guard readable else {
            if readAccess.hasPriorRelationship(channelId: channelId, serverId: serverId, userId: userId) {
                throw AgentsLifecycleError.forbidden
            }
            throw AgentsLifecycleError.channelNotFound
        }
        let limit = ChannelFileRules.channelFilesLimit(rawLimit)
        let cursor: (createdAt: Date, id: String)?
        if let rawCursor, !rawCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let decoded = ChannelFileRules.channelFilesBase64URLDecode(rawCursor),
                  let object = try? JSONDecoder().decode(ChannelFilesCursor.self, from: Data(decoded.utf8)),
                  let createdAt = DateText.isoDate(object.createdAt)
            else {
                throw AgentsLifecycleError.invalidCursor
            }
            cursor = (createdAt, object.id)
        } else {
            cursor = nil
        }

        let channelRows = channels.postableChannels
        let messageState = messages.state
        var scopeChannels: Set<String> = [channelId]
        for (id, candidate) in channelRows
        where candidate.serverId == serverId && candidate.kind == "thread"
            && candidate.parentChannelId == channelId && candidate.deletedAt == nil {
            scopeChannels.insert(id)
        }
        var files: [ChannelAttachment] = []
        for attachment in messageState.channelAttachments.values {
            guard scopeChannels.contains(attachment.channelId) else { continue }
            if let messageId = attachment.messageId,
               !messageState.humanMessageRows.contains(where: { $0.id == messageId && $0.channelId == attachment.channelId }) {
                continue
            }
            if let cursor {
                if attachment.createdAt > cursor.createdAt { continue }
                if attachment.createdAt == cursor.createdAt && attachment.id >= cursor.id { continue }
            }
            files.append(attachment)
        }
        files.sort { left, right in
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id > right.id
        }
        let page = Array(files.prefix(limit))
        let nextCursor: String?
        if files.count > limit, let last = page.last {
            let encoded = OrderedJSON.object([
                OrderedJSONField("createdAt", DateText.isoString(last.createdAt)),
                OrderedJSONField("id", last.id),
            ]).render()
            nextCursor = ChannelFileRules.channelFilesBase64URLEncode(encoded)
        } else {
            nextCursor = nil
        }
        let rows = page.map { attachment -> ChannelFilesResponse.File in
            let source = channelRows[attachment.channelId]
            let isThread = source?.kind == "thread"
            let parentMessageId = isThread ? source?.parentMessageId : nil
            let uploaderName: String?
            let uploaderDisplay: String?
            if attachment.uploaderType == "agent" {
                let agent = oauth.agentRuntimeInfo(id: attachment.uploaderId)
                uploaderName = agent?.name
                uploaderDisplay = agent?.displayName
            } else if attachment.uploaderType == "user" {
                let account = profiles.account(userId: attachment.uploaderId)
                uploaderName = account?.name
                uploaderDisplay = account?.name
            } else {
                uploaderName = nil
                uploaderDisplay = nil
            }
            return ChannelFilesResponse.File(
                id: attachment.id,
                messageId: attachment.messageId ?? "",
                channelId: attachment.channelId,
                filename: attachment.filename,
                mimeType: ChannelFileRules.channelFileMimeType(filename: attachment.filename, stored: attachment.mimeType),
                sizeBytes: attachment.sizeBytes,
                width: attachment.width,
                height: attachment.height,
                thumbnailUrl: attachment.thumbnailKey.map { _ in "/api/attachments/\(attachment.id)/thumbnail" },
                createdAt: DateText.isoString(attachment.createdAt),
                uploader: ChannelFilesResponse.Uploader(
                    type: attachment.uploaderType == "agent" ? "agent" : "user",
                    id: attachment.uploaderId,
                    name: uploaderName,
                    displayName: uploaderDisplay ?? uploaderName
                ),
                source: ChannelFilesResponse.Source(
                    type: isThread ? "thread" : "channel",
                    channelId: attachment.channelId,
                    parentMessageId: parentMessageId,
                    parentMessageShortId: parentMessageId.map { String($0.prefix(8)) }
                )
            )
        }
        return ChannelFilesResponse(files: rows, nextCursor: nextCursor)
    }

    // MARK: - Attachment read

    /// `GET /api/attachments/:id?token=…`: the stored document, for a caller
    /// that carries the access token in the query.
    public func attachmentQueryTokenStream(
        attachmentId: String,
        token: String,
        serverId: String?
    ) throws -> AttachmentStreamBody {
        guard ServerScope.isUUID(attachmentId) else { throw AgentsLifecycleError.invalidAttachmentId }
        guard let userId = sessionUserId(authorization: "Bearer \(token)") else {
            throw AgentsLifecycleError.unauthorized
        }
        guard let serverId, !serverId.isEmpty else { throw AgentsLifecycleError.serverIdRequired }
        if !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            throw AgentsLifecycleError.notAMember
        }
        guard let attachment = messages.channelAttachments[attachmentId],
              canSeeAttachment(userId: userId, serverId: serverId, attachment: attachment)
        else {
            throw AgentsLifecycleError.attachmentNotFound
        }
        guard let body = messages.attachmentPreviewBody?(attachmentId) else {
            throw AgentsLifecycleError.attachmentNotFound
        }
        return AttachmentStreamBody(body: body)
    }

    /// Legacy range helper retained for existing service callers. Production
    /// previews use the bounded byte scanner in the HTTP response transport.
    static func cspMetaTagRange(in html: String) -> Range<String.Index>? {
        let lower = html.lowercased()
        guard let metaStart = lower.range(of: "<meta"),
              let csp = lower.range(of: "content-security-policy", range: metaStart.lowerBound..<lower.endIndex),
              let tagEnd = lower.range(of: ">", range: csp.upperBound..<lower.endIndex)
        else { return nil }
        return metaStart.lowerBound..<tagEnd.upperBound
    }

    /// Synchronous metadata admission used by ordinary byte downloads.
    public func readAttachment(
        authorization: String?, serverId: String?, attachmentId: String
    ) throws -> AttachmentReadResponse {
        guard ServerScope.isUUID(attachmentId) else { throw AgentsLifecycleError.invalidAttachmentId }
        if let token = Self.bearerToken(authorization), authorization?.hasPrefix("Bearer sk_computer_") == true {
            let computerServer = machines.computers.first { $0.apiKey == token && $0.revokedAt == nil }?.serverId
            let attachment = messages.channelAttachments[attachmentId]
            let channelServer = attachment.flatMap { channels.postableChannels[$0.channelId]?.serverId }
            guard let computerServer else { throw AgentsLifecycleError.unauthorized }
            let requested = serverId ?? computerServer
            guard requested == computerServer else { throw AgentsLifecycleError.notAMember }
            guard let attachment, channelServer == requested else { throw AgentsLifecycleError.attachmentNotFound }
            return .metadata(metadata(of: attachment))
        }
        let userId = try requireUser(authorization)
        guard profiles.account(userId: userId)?.retiredAt == nil else { throw AgentsLifecycleError.unauthorized }
        guard let serverId, !serverId.isEmpty else { throw AgentsLifecycleError.serverIdRequired }
        if !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil { throw AgentsLifecycleError.notAMember }
        guard let attachment = messages.channelAttachments[attachmentId],
              canSeeAttachment(userId: userId, serverId: serverId, attachment: attachment) else {
            throw AgentsLifecycleError.attachmentNotFound
        }
        return .metadata(metadata(of: attachment))
    }

    private func metadata(of attachment: ChannelAttachment) -> AttachmentMetadataResponse {
        AttachmentMetadataResponse(id: attachment.id, filename: attachment.filename, mimeType: attachment.mimeType)
    }

    // MARK: - Client product events

    /// `GET /api/product-events/config`.
    public func clientEventsConfig(authorization: String?) throws -> ClientEventsConfigResponse {
        let userId = try requireUser(authorization)
        return ClientEventsConfigResponse(
            clientEventsAllowed: profiles.account(userId: userId)?.shareUsageData == true
        )
    }

    private static func isEventUUID(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
    }

    /// `POST /api/product-events/batch`. `body` is `nil` when the request carried
    /// no JSON object; the published 400 still follows the opt-in check.
    public func clientEventsBatch(
        authorization: String?,
        serverId: String,
        userAgent: String,
        country: String,
        body: ClientEventsBatchRequest?
    ) throws -> ClientEventsAcceptedResponse {
        let userId = try requireUser(authorization)
        guard profiles.account(userId: userId)?.shareUsageData == true else {
            return ClientEventsAcceptedResponse(accepted: 0)
        }
        guard let members = body?.members,
              members["source"]?.castString == "web",
              case .array(let rawEvents)? = members["events"], !rawEvents.isEmpty
        else {
            throw AgentsLifecycleError.invalidEventBatch
        }
        var events: [[String: JSONValue]] = []
        for raw in rawEvents {
            guard let event = raw.castObject else { throw AgentsLifecycleError.invalidEventBatch }
            events.append(event)
        }
        let appVersion = members["app_version"]?.castString
        if let appVersion, appVersion.wholeMatch(of: /^[0-9]+\.[0-9]+\.[0-9]+$/) == nil {
            throw AgentsLifecycleError.invalidAppVersion
        }
        let now = dependencies.now()
        let context = ClientEventDeviceContext(userAgent: userAgent, country: country)
        var candidates: [ProductEventStore.ClientEventCandidate] = []
        var batchSeen: Set<String> = []
        for event in events {
            guard let uuid = event["uuid"]?.castString, Self.isEventUUID(uuid),
                  let name = event["event"]?.castString,
                  let timestamp = event["timestamp"]?.castString,
                  let parsed = DateText.isoDate(timestamp),
                  let session = event["client_session_id"]?.castString,
                  Self.isEventUUID(session),
                  let properties = event["properties"]?.castObject
            else {
                throw AgentsLifecycleError.invalidEventBatch
            }
            if now.timeIntervalSince(parsed) > 7 * 24 * 60 * 60 { continue }
            if productEvents.containsSeenClientEvent(uuid) || !batchSeen.insert(uuid).inserted { continue }
            let allowedKeys: Set<String>
            if name == "activity_open" {
                allowedKeys = ["from"]
            } else if name == "activity_mark" {
                allowedKeys = ["action"]
            } else {
                continue
            }
            guard Set(properties.keys).isSubset(of: allowedKeys) else { continue }
            var sanitized: [String: ClientEventPropertyValue] = [:]
            for (key, value) in properties {
                if let text = value.castString { sanitized[key] = .text(text) }
            }
            for (key, value) in context.properties { sanitized[key] = value }
            candidates.append(ProductEventStore.ClientEventCandidate(
                eventId: uuid,
                record: ClientEventRecord(
                    event: name,
                    analyticsId: profiles.analyticsId(userId: userId),
                    serverId: serverId,
                    source: "web",
                    sessionId: session,
                    appVersion: appVersion,
                    propertiesJSON: Self.renderProperties(sanitized)
                )
            ))
        }
        let seenIDs: [String] = events.compactMap { event in
            guard let uuid = event["uuid"]?.castString, Self.isEventUUID(uuid) else { return nil }
            return uuid
        }
        let accepted = productEvents.admitClientEvents(candidates, seenIDs: seenIDs)
        return ClientEventsAcceptedResponse(accepted: accepted)
    }

    /// One value of the stored event properties: free text, or the numeric
    /// browser version.
    enum ClientEventPropertyValue: Encodable, Equatable {
        case text(String)
        case integer(Int)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            }
        }
    }

    /// The coarse device facts derived from the request headers. The raw user
    /// agent never reaches the store.
    struct ClientEventDeviceContext {
        let properties: [String: ClientEventPropertyValue]

        init(userAgent: String, country: String) {
            var context: [String: ClientEventPropertyValue] = [:]
            if let range = userAgent.range(of: "Chrome/") {
                let rest = userAgent[range.upperBound...]
                let major = rest.prefix(while: { $0 != "." && !$0.isWhitespace })
                context["$browser"] = .text("chrome")
                if let version = Int(major) { context["$browser_version"] = .integer(version) }
            } else if userAgent.contains("Firefox/") {
                context["$browser"] = .text("firefox")
            } else if userAgent.contains("Safari/") {
                context["$browser"] = .text("safari")
            } else {
                context["$browser"] = .text("unknown")
            }
            if userAgent.contains("Windows") {
                context["$os"] = .text("windows")
            } else if userAgent.contains("Mac OS X") {
                context["$os"] = .text("macos")
            } else if userAgent.contains("Android") {
                context["$os"] = .text("android")
            } else if userAgent.contains("iPhone") || userAgent.contains("iPad") {
                context["$os"] = .text("ios")
            } else if userAgent.contains("Linux") {
                context["$os"] = .text("linux")
            } else {
                context["$os"] = .text("unknown")
            }
            context["$device_type"] = .text(userAgent.contains("Mobile") ? "mobile" : "desktop")
            let normalizedCountry = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalizedCountry.wholeMatch(of: /^[A-Z]{2}$/) != nil {
                context["$country"] = .text(normalizedCountry)
            }
            self.properties = context
        }
    }

    /// The stored properties document: sorted keys, the legacy serializer's
    /// bytes.
    static func renderProperties(_ properties: [String: ClientEventPropertyValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(properties) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Computer gate and internal surfaces

    /// Whether the Computer attach flow is on: the injected override, else the
    /// device-login environment gate.
    public func computerAttachEnabled() -> Bool {
        if let override = machines.computerAttachEnabledOverride { return override }
        let raw = (dependencies.environment()["SLOCK_DEVICE_LOGIN_ENABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw != "false"
    }

    /// `POST /internal/computer/preflight`: a read-only principal check for an
    /// attached Computer credential. The route-auth projection is derived from
    /// the live router by the caller, so this surface describes what is actually
    /// registered instead of a parallel list.
    public func computerPreflight(
        authorization: String?,
        surface: InternalSurfaceSnapshot
    ) throws -> ComputerPreflightResponse {
        guard let token = Self.bearerToken(authorization) else {
            throw AgentsLifecycleError.computerUnauthorized
        }
        let computer = machines.computers.first { $0.apiKey == token && $0.revokedAt == nil }
        guard let computer, let details = oauth.serverDetailsValue(id: computer.serverId) else {
            throw AgentsLifecycleError.invalidPrincipal
        }
        return ComputerPreflightResponse(
            surface: surface,
            serverId: computer.serverId,
            serverSlug: details.slug,
            computerId: computer.id,
            computerName: computer.name
        )
    }

    /// `/internal/computer/*` for a path the surface registry does not claim: a
    /// live Computer principal is told the path is unregistered instead of
    /// receiving a routing 404.
    public func unregisteredInternalComputerSurface(authorization: String?) throws -> Never {
        guard let token = Self.bearerToken(authorization) else {
            throw AgentsLifecycleError.computerUnauthorized
        }
        let live = machines.computers.contains { $0.apiKey == token && $0.revokedAt == nil }
        guard live else { throw AgentsLifecycleError.invalidPrincipal }
        throw AgentsLifecycleError.surfaceUnregistered
    }

    /// `/internal/agent-api/*` and `/internal/agent/*` for a path the surface
    /// registry does not claim: a live agent credential is told the path is
    /// unregistered on the same envelope as the Computer surface, so a missing
    /// policy entry fails closed.
    public func unregisteredInternalAgentSurface(authorization: String?) throws -> Never {
        guard let token = Self.bearerToken(authorization) else {
            throw AgentsLifecycleError.computerUnauthorized
        }
        guard agents.agentCredentials[token] != nil else { throw AgentsLifecycleError.invalidPrincipal }
        throw AgentsLifecycleError.surfaceUnregistered
    }

    /// `GET /api/runtime-providers/:kind`.
    public func agentRuntimeProviderProbe(
        authorization: String?,
        serverId: String,
        kind: String
    ) throws -> RuntimeProviderProbeResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentsLifecycleError.notAMember
        }
        guard role == "owner" || role == "admin" else { throw AgentsLifecycleError.forbidden }
        guard kind == "antiproton" else { throw AgentsLifecycleError.unknownRuntimeProvider }
        return RuntimeProviderProbeResponse(available: agents.hostedProviderAvailable(serverId: serverId))
    }

    /// `GET /api/agent-runtime-providers/:kind/models`. The deployment has no
    /// hosted-runtime provider client (D5): an unavailable provider answers the
    /// upstream 404, and an available one answers the upstream provider-failure
    /// 502 instead of inventing a model list.
    public func agentRuntimeProviderModels(
        authorization: String?,
        serverId: String,
        kind: String
    ) throws -> OrderedBodyDTO {
        let userId = try requireUser(authorization)
        guard kind == "antiproton" else { throw AgentsLifecycleError.runtimeProviderModelsUnknown }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentsLifecycleError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw AgentsLifecycleError.runtimeProviderForbidden
        }
        guard agents.hostedProviderAvailable(serverId: serverId) else {
            throw AgentsLifecycleError.runtimeProviderUnavailable
        }
        throw AgentsLifecycleError.hostedRuntimeModelUnavailable
    }
}
