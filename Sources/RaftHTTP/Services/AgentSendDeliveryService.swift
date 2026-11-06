import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Domain failure for the agent send, delivery-ack, activity-ingest and
/// agent-thread operations.
///
/// `status`, `errorMessage` and `errorCode` are the published values; the
/// canonical `DomainError` body already prints `error` then the optional
/// `code`, so the legacy `{"error": …,"code": …}` bytes need no override.
public enum AgentSendDeliveryError: DomainError, Equatable {
    case missingAuthorization
    case invalidToken
    case agentNotFound
    case invalidTarget
    case agentNotParentMember
    case threadNotFound
    case channelNotFound
    case agentNotChannelMember
    case channelArchived
    case capabilityNotAuthorized
    case activityInvalid
    case transcriptPathForbidden
    case statusInvalid
    case detailInvalid
    case detailTooLong
    case invalidThreadUnfollow
    case targetMustBeThread
    case receiveAckEmpty

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken:
            401
        case .agentNotParentMember, .agentNotChannelMember, .capabilityNotAuthorized:
            403
        case .agentNotFound, .threadNotFound, .channelNotFound:
            404
        case .channelArchived:
            409
        case .invalidTarget, .activityInvalid, .transcriptPathForbidden, .statusInvalid,
             .detailInvalid, .detailTooLong, .invalidThreadUnfollow, .targetMustBeThread,
             .receiveAckEmpty:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidToken:
            "Invalid or expired token"
        case .agentNotFound:
            "Agent not found"
        case .invalidTarget:
            "Invalid target"
        case .agentNotParentMember:
            "Agent is not a member of the parent channel"
        case .threadNotFound:
            "Thread not found"
        case .channelNotFound:
            "Channel not found"
        case .agentNotChannelMember:
            "Agent is not a member of this channel"
        case .channelArchived:
            "This channel is archived"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .activityInvalid:
            "Invalid activity ingest"
        case .transcriptPathForbidden:
            "transcript_path is not accepted"
        case .statusInvalid:
            "Invalid agent status"
        case .detailInvalid:
            "Invalid status detail"
        case .detailTooLong:
            "Status detail is too long"
        case .invalidThreadUnfollow:
            "Invalid thread unfollow request"
        case .targetMustBeThread:
            "Target must be a thread"
        case .receiveAckEmpty:
            "seqs or messageIds must be a non-empty array"
        }
    }

    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken:
            "auth_required"
        case .channelArchived:
            "channel_archived"
        case .capabilityNotAuthorized:
            "capability_not_authorized"
        case .activityInvalid:
            "activity_invalid"
        case .transcriptPathForbidden:
            "transcript_path_forbidden"
        case .statusInvalid:
            "status_invalid"
        case .detailInvalid:
            "detail_invalid"
        case .detailTooLong:
            "detail_too_long"
        case .agentNotFound, .invalidTarget, .agentNotParentMember, .threadNotFound,
             .channelNotFound, .agentNotChannelMember, .invalidThreadUnfollow,
             .targetMustBeThread, .receiveAckEmpty:
            nil
        }
    }

}

/// Agent send, delivery ack, activity ingest, thread-follow and integration
/// routes.
///
/// Every operation used to live in a directory extension and take the
/// directory lock. Each now runs against the store that owns its rows:
/// machine credentials come from `MachinesAndComputersStore`, channels from
/// `ServersAndChannelsStore`, message/cursor rows from
/// `MessagesAndThreadsStore`, activity/credential/hosted rows from
/// `AgentsRuntimeStore`, thread follows from `ThreadFollowStore`, and
/// integration logins from `ManagedMCPAndCardsStore`.
///
/// Three bridges stay injected because those domains are not migrated yet:
/// `searchVisible` is the message-visibility policy in `SearchMentionsService`,
/// `appendHumanMessage` is the one append path that must stay serialized with
/// every other message writer under the directory lock, and
/// `integrationServices` is a typed projection of the OAuth ledger's client
/// rows, so this file never names an untyped JSON dictionary.
public struct AgentSendDeliveryService: Sendable {
    private let machines: MachinesAndComputersStore
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let agents: AgentsRuntimeStore
    private let threadFollows: ThreadFollowStore
    private let managedMCP: ManagedMCPAndCardsStore
    private let oauth: OAuthLedger
    private let searchVisible: @Sendable (_ messageChannelId: String, _ serverId: String?, _ viewer: SearchViewer) -> Bool
    private let appendHumanMessage: @Sendable (StoredHumanMessage) -> Int
    private let integrationServices: @Sendable (_ serverId: String) -> [AgentIntegrationServiceSnapshot]
    private let now: @Sendable () -> Date
    private let makeMessageId: @Sendable () -> String

    init(
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        agents: AgentsRuntimeStore,
        threadFollows: ThreadFollowStore,
        managedMCP: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        searchVisible: @escaping @Sendable (String, String?, SearchViewer) -> Bool,
        appendHumanMessage: @escaping @Sendable (StoredHumanMessage) -> Int,
        integrationServices: @escaping @Sendable (String) -> [AgentIntegrationServiceSnapshot],
        now: @escaping @Sendable () -> Date = { Date() },
        makeMessageId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.machines = machines
        self.channels = channels
        self.messages = messages
        self.agents = agents
        self.threadFollows = threadFollows
        self.managedMCP = managedMCP
        self.oauth = oauth
        self.searchVisible = searchVisible
        self.appendHumanMessage = appendHumanMessage
        self.integrationServices = integrationServices
        self.now = now
        self.makeMessageId = makeMessageId
    }

    // MARK: - POST /internal/agent/:agentId/send

    /// Posts an agent message to a `#channel` or `#channel:shortId` thread.
    ///
    /// The upstream order is machine credential (401), agent scope (404), body
    /// shape (400), parent membership (403), thread lookup (404), channel
    /// membership (403) and archived (409) before the append.
    public func agentSend(
        authorization: String?,
        agentId: String,
        body: AgentSendRequest?
    ) throws -> AgentSendResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentSendDeliveryError.missingAuthorization
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        let credential = machines.machineCredential(apiKey: apiKey, agentId: nil)
        guard let serverId = credential.machine?.serverId ?? credential.legacy?.serverId else {
            throw AgentSendDeliveryError.invalidToken
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            throw AgentSendDeliveryError.agentNotFound
        }
        guard let body,
              let target = body.target,
              let content = body.content,
              target.hasPrefix("#")
        else {
            throw AgentSendDeliveryError.invalidTarget
        }
        let rawName = String(target.dropFirst())
        let segments = rawName.split(separator: ":", maxSplits: 1).map(String.init)
        let name = segments.first ?? rawName
        let shortId = segments.count > 1 ? segments[1] : nil

        let candidate = channels.postableChannel(serverId: agent.serverId, name: name)
        var resolved: (id: String, channel: PostableChannel)? = candidate
        if let shortId, let parent = candidate {
            guard oauth.channelAgentIds(channelId: parent.id).contains(agent.id) else {
                throw AgentSendDeliveryError.agentNotParentMember
            }
            resolved = channels.threadChannel(
                serverId: agent.serverId,
                parentChannelId: parent.id,
                shortId: shortId
            )
            if resolved == nil {
                throw AgentSendDeliveryError.threadNotFound
            }
        }
        guard let (channelId, channel) = resolved else {
            throw AgentSendDeliveryError.channelNotFound
        }
        if shortId == nil, !oauth.channelAgentIds(channelId: channelId).contains(agent.id) {
            throw AgentSendDeliveryError.agentNotChannelMember
        }
        if channel.archived {
            throw AgentSendDeliveryError.channelArchived
        }
        let messageId = makeMessageId()
        _ = appendHumanMessage(StoredHumanMessage(
            id: messageId,
            channelId: channelId,
            senderId: agent.id,
            content: content,
            randomId: nil,
            senderType: "agent"
        ))
        return AgentSendResponse(id: messageId, channelId: channelId)
    }

    // MARK: - POST /internal/agent/:agentId/receive-ack

    /// `POST /internal/agent/:agentId/receive-ack` — legacy delivery ack.
    ///
    /// The volatile delivery buffer ack is not modeled here (the port has no
    /// orchestrator). Pre-model-seen daemons additionally get the per-channel
    /// usability checkpoint this route always kept; a daemon that advertises
    /// the model-seen boundary capability is a volatile ack only, so legacy
    /// state can never masquerade as freshness proof.
    ///
    /// The cursor decision and the version bump are one
    /// `MessagesAndThreadsStore` critical section.
    public func legacyAgentReceiveAck(
        authorization: String?,
        agentId: String,
        body: AgentReceiveAckRequest?
    ) throws -> OkResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentSendDeliveryError.missingAuthorization
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        let credential = machines.machineCredential(apiKey: apiKey, agentId: agentId)
        guard let serverId = credential.machine?.serverId ?? credential.legacy?.serverId else {
            throw AgentSendDeliveryError.invalidToken
        }
        if let legacy = credential.legacy, legacy.agentId != agentId {
            throw AgentSendDeliveryError.agentNotFound
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            throw AgentSendDeliveryError.agentNotFound
        }
        let request = body ?? AgentReceiveAckRequest()
        guard !request.seqs.isEmpty || !request.messageIds.isEmpty else {
            throw AgentSendDeliveryError.receiveAckEmpty
        }
        if credential.modelSeenCapability || request.seqs.isEmpty {
            return OkResponse()
        }

        let channelSnapshot = channels.deliveryAckChannelSnapshot()
        let messageSnapshot = messages.deliveryAckMessageSnapshot()
        var maxSeqByChannel: [String: Int] = [:]
        for seq in request.seqs {
            for row in messageSnapshot.rows where row.seq == seq {
                let storageId = row.channelId
                let localId = channelSnapshot.jointProjections.first {
                    $0.canonicalChannelId == storageId && $0.serverId == serverId
                }?.localChannelId ?? storageId
                guard let channel = channelSnapshot.channels[localId] else { continue }
                let isMember: Bool
                if channel.kind == "thread", let parentId = channel.parentChannelId {
                    isMember = channelSnapshot.channels[parentId]?.memberIds.contains(agentId) == true
                        || oauth.channelAgentIds(channelId: parentId).contains(agentId)
                        || messageSnapshot.threadFollows.values.contains {
                            $0.serverId == serverId && $0.userId == agentId && $0.threadChannelId == localId
                        }
                } else {
                    isMember = channel.memberIds.contains(agentId)
                        || oauth.channelAgentIds(channelId: localId).contains(agentId)
                }
                guard isMember else { continue }
                maxSeqByChannel[localId] = max(maxSeqByChannel[localId] ?? 0, seq)
            }
        }
        messages.advanceAgentReadCursors(agentId: agentId, maxSeqByChannel: maxSeqByChannel)
        return OkResponse()
    }

    // MARK: - POST /internal/agent/:agentId/runtime-profile/migration-done

    /// Deprecated acknowledgement. A missing `migrationKey` keeps the `noop`
    /// field; a present one (including an empty string decoded from a malformed
    /// body) omits it.
    public func runtimeProfileMigrationDone(
        authorization: String?,
        agentId: String,
        body: AgentRuntimeProfileMigrationDTO?
    ) throws -> AgentRuntimeProfileMigrationResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentSendDeliveryError.missingAuthorization
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        guard let machine = machines.machine(apiKey: apiKey) else {
            throw AgentSendDeliveryError.invalidToken
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machine.serverId else {
            throw AgentSendDeliveryError.agentNotFound
        }
        let migrationKey = body?.migrationKey ?? ""
        return AgentRuntimeProfileMigrationResponse(noop: migrationKey.isEmpty)
    }

    // MARK: - Hosted-agent flag

    /// Marks an agent as hosted by the profile/creation flows. This is not an
    /// HTTP operation; the test seam and the join-link policy share it.
    public func markAgentHosted(agentId: String) {
        agents.markHosted(agentId: agentId)
    }

    // MARK: - POST /internal/agent-api/activity

    /// `POST /internal/agent-api/activity`.
    ///
    /// The v1 schema only reports unknown fields (and rejects
    /// `transcript_path`); the standard schema folds status/hook events into the
    /// agent's presence rows. Status adoption, occurrence timestamps, activity
    /// detail and the dedupe set are applied by one `AgentsRuntimeStore`
    /// critical section, matching the legacy loop's partial-write behavior.
    public func agentActivityIngest(
        authorization: String?,
        body: AgentActivityIngestRequest?
    ) throws -> AgentActivityIngestResponse {
        guard let credential = useCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              credential.scopes.contains("read")
        else {
            throw AgentSendDeliveryError.capabilityNotAuthorized
        }
        guard let body else {
            throw AgentSendDeliveryError.activityInvalid
        }
        if body.schema == "raft-agent-activity-ingest.v1" {
            let allowed: Set<String> = [
                "eventId", "hookEventName", "toolName", "toolInput", "truncated",
                "tool_use_id", "exit_code", "ok", "subagent",
            ]
            var ignored: Set<String> = []
            for event in body.events {
                for key in event.fields.keys where !allowed.contains(key) {
                    if key == "transcript_path" {
                        throw AgentSendDeliveryError.transcriptPathForbidden
                    }
                    ignored.insert(key)
                }
            }
            return AgentActivityIngestResponse(
                acceptedCount: body.events.count,
                rejectedCount: 0,
                droppedCount: body.dropped,
                ignoredFields: ignored.sorted()
            )
        }
        switch agents.applyActivityIngest(agentId: agent.id, events: body.events, now: now) {
        case .applied(let accepted, let rejected):
            return AgentActivityIngestResponse(
                acceptedCount: accepted,
                rejectedCount: rejected,
                droppedCount: 0
            )
        case .invalidStatus:
            throw AgentSendDeliveryError.statusInvalid
        case .detailInvalid:
            throw AgentSendDeliveryError.detailInvalid
        case .detailTooLong:
            throw AgentSendDeliveryError.detailTooLong
        }
    }

    // MARK: - GET /internal/agent-api/threads

    /// Lists the agent's active, visible thread follows, newest first.
    public func agentThreadList(authorization: String?) throws -> AgentThreadListResponse {
        guard let credential = useCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentSendDeliveryError.invalidToken
        }
        guard credential.scopes.contains("read") else {
            throw AgentSendDeliveryError.capabilityNotAuthorized
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = threadFollows.all()
            .filter { $0.serverId == agent.serverId && $0.agentId == agent.id && $0.unfollowedAt == nil }
            .filter {
                searchVisible($0.threadChannelId, agent.serverId, .agent(agent.id))
            }
            .sorted { $0.followedAt > $1.followedAt }
            .compactMap { follow -> AgentThreadListEntry? in
                guard let thread = channels.postableChannel(id: follow.threadChannelId),
                      let parentChannelId = thread.parentChannelId,
                      let parent = channels.postableChannel(id: parentChannelId)
                else { return nil }
                let short = String(follow.parentMessageId.prefix(8))
                return AgentThreadListEntry(
                    target: "#\(parent.name):\(short)",
                    threadChannelId: follow.threadChannelId,
                    parentChannelRef: "#\(parent.name)",
                    parentMessageId: follow.parentMessageId,
                    parentMessageShortId: short,
                    followedAt: formatter.string(from: follow.followedAt),
                    reason: follow.reason,
                    doneAt: follow.doneAt.map { formatter.string(from: $0) }
                )
            }
        return AgentThreadListResponse(threads: rows)
    }

    // MARK: - POST /internal/agent/:agentId/threads/unfollow
    // MARK: - POST /internal/agent-api/threads/unfollow

    /// Unfollows one thread by id or `#channel:shortId` reference.
    public func agentThreadUnfollow(
        authorization: String?,
        body: AgentThreadUnfollowRequest?,
        legacyAgentId: String? = nil
    ) throws -> OkResponse {
        guard let writer = taskWriter(authorization, legacyAgentId: legacyAgentId),
              let agent = oauth.agentRuntimeInfo(id: writer.agentId), !agent.deleted
        else {
            throw AgentSendDeliveryError.invalidToken
        }
        if let credential = useCredential(authorization), !credential.scopes.contains("read") {
            throw AgentSendDeliveryError.capabilityNotAuthorized
        }
        guard let body, let threadRef = body.thread, !threadRef.isEmpty else {
            throw AgentSendDeliveryError.invalidThreadUnfollow
        }
        if threadRef.hasPrefix("#"), !threadRef.contains(":") {
            throw AgentSendDeliveryError.targetMustBeThread
        }
        var threadId: String?
        if threadRef.hasPrefix("#"), let colon = threadRef.firstIndex(of: ":") {
            let channelName = String(threadRef[threadRef.index(after: threadRef.startIndex)..<colon])
            let short = String(threadRef[threadRef.index(after: colon)...])
            if let parent = channels.postableChannelIncludingDeleted(serverId: agent.serverId, name: channelName) {
                threadId = channels.threadChannel(parentChannelId: parent.id, shortId: short)?.id
            }
        } else {
            threadId = threadRef
        }
        guard let resolved = threadId,
              let thread = channels.postableChannel(id: resolved),
              thread.serverId == agent.serverId,
              thread.kind == "thread",
              thread.deletedAt == nil
        else {
            throw AgentSendDeliveryError.threadNotFound
        }
        guard searchVisible(resolved, agent.serverId, .agent(agent.id)) else {
            throw AgentSendDeliveryError.threadNotFound
        }
        threadFollows.markUnfollowed(
            serverId: agent.serverId,
            agentId: agent.id,
            threadChannelId: resolved,
            at: now()
        )
        return OkResponse()
    }

    // MARK: - GET /internal/agent-api/integrations

    /// Lists the server's integration services plus the agent's active logins.
    public func agentIntegrationList(authorization: String?) throws -> AgentIntegrationListResponse {
        guard let credential = useCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentSendDeliveryError.invalidToken
        }
        let services = integrationServices(agent.serverId)
        let active = managedMCP.agentIntegrationLogins.values
            .filter { $0.serverId == agent.serverId && $0.agentId == agent.id }
            .sorted { $0.loggedInAt < $1.loggedInAt }
            .compactMap { login -> AgentIntegrationActiveLogin? in
                guard let service = services.first(where: { $0.id == login.clientId }) else { return nil }
                return AgentIntegrationActiveLogin(
                    clientId: service.clientId ?? "",
                    agentManifestUrl: service.agentManifestUrl,
                    agentManifestUrlSource: service.agentManifestUrlSource
                )
            }
        let resolved = services.map { service -> AgentIntegrationServiceSnapshot in
            guard let id = service.id,
                  let state = oauth.getAppInstallationSetup(clientRecordId: id, serverId: agent.serverId)
            else { return service }
            return service.withSetup(AgentIntegrationSetup(
                status: state.status.rawValue,
                url: state.url,
                description: state.description,
                revision: state.revision
            ))
        }
        return AgentIntegrationListResponse(services: resolved, activeLogins: active)
    }

    // MARK: - Credentials

    /// The shared `sk_agent_*` credential check: revoked or absent credentials
    /// are `nil`, a live one is marked used by the store in one critical section.
    private func useCredential(_ authorization: String?) -> (agentId: String, scopes: [String])? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return agents.useAgentCredential(token: token, now: now())
    }

    /// The write-route identity: an `sk_agent_*` credential, or the legacy
    /// machine key plus the path agent id.
    private func taskWriter(
        _ authorization: String?,
        legacyAgentId: String?
    ) -> (agentId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        if let credential = agents.agentCredential(token: token), credential.revokedAt == nil,
           let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted {
            return (agent.id, agent.serverId)
        }
        if let machine = machines.machine(apiKey: token),
           let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent.id, agent.serverId)
        }
        return nil
    }
}
