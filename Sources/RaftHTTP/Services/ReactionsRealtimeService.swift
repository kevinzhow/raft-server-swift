import Foundation

/// The agent credential facts the mentions inbox reads.
struct ReactionsAgentCredential: Sendable, Equatable {
    var agentId: String
    var scopes: Set<String>
}

/// Every cross-domain decision this service needs, as injected closures.
///
/// The message, channel, inbox-fact and card rows live in their own stores and
/// the OAuth ledger owns read state, so the service reads those directly.
/// Session lookup, the agent read credential (which records a credential use),
/// the mentions-scope credential lookup, guest scope visibility and account
/// display names belong to unmigrated domains and enter here;
/// `live(directory:)` wires them to the existing directory entry points.
struct ReactionsRealtimeDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var agentReadOutcome: @Sendable (String?) -> ProfileAgentReadOutcome
    var agentCredential: @Sendable (_ token: String) -> ReactionsAgentCredential?
    var guestCanSeeScope: @Sendable (_ scopeId: String) -> Bool
    var userName: @Sendable (_ userId: String) -> String?
    var now: @Sendable () -> Date

    static func live(directory source: EmailLoginDirectory) -> ReactionsRealtimeDependencies {
        ReactionsRealtimeDependencies(
            sessionUserId: { source.sessionUserId(authorization: $0) },
            agentReadOutcome: { source.profileAgentReadOutcome($0) },
            agentCredential: { token in
                source.agentCredentials[token].map {
                    ReactionsAgentCredential(agentId: $0.agentId, scopes: $0.scopes)
                }
            },
            guestCanSeeScope: { source.guestCanSeeScopeLocked($0) },
            userName: { userId in source.accounts.values.first { $0.id == userId }?.name },
            now: { Date() }
        )
    }
}

/// The inbox-read and wake boundary: Done/Undone per scope, read-all, the
/// Activity page and the agent mention, wake-hint and event reads.
///
/// The service returns published `JSONBodyConvertible` DTOs and throws
/// `ReactionsRealtimeError`; it builds no HTTP reply, header set or dictionary
/// payload. Each Done/Undone/read-all write and each agent inbox drain is one
/// `MessagesAndThreadsStore` critical section. Channel facts (kind, parent
/// visibility) are read from `ServersAndChannelsStore` just before the write;
/// they live in a different store, so the check and the write are two
/// sections, not one.
public struct ReactionsRealtimeService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let inboxFacts: InboxFactStore
    let cards: ManagedMCPAndCardsStore
    let oauth: OAuthLedger
    let dependencies: ReactionsRealtimeDependencies

    public init(directory source: EmailLoginDirectory) {
        self.init(
            messages: source.messagesAndThreadsStore,
            channels: source.serversAndChannelsStore,
            inboxFacts: source.inboxFactStore,
            cards: source.managedMCPAndCardsStore,
            oauth: source.oauth,
            dependencies: .live(directory: source)
        )
    }

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        inboxFacts: InboxFactStore,
        cards: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        dependencies: ReactionsRealtimeDependencies
    ) {
        self.messages = messages
        self.channels = channels
        self.inboxFacts = inboxFacts
        self.cards = cards
        self.oauth = oauth
        self.dependencies = dependencies
    }

    /// The largest Done frontier the int4 authority column can hold.
    static let doneFrontierInt4Limit = 2_147_483_647

    // MARK: - POST /api/channels/inbox/undone

    public func inboxUndone(
        authorization: String?,
        serverId: String?,
        body: InboxScopeRequest?
    ) throws -> OkResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ReactionsRealtimeError.unauthorized
        }
        guard let channelId = body?.channelId else {
            throw ReactionsRealtimeError.invalidUndoneRequest
        }
        guard channels.postableChannels[channelId]?.kind != "thread" else {
            throw ReactionsRealtimeError.scopeNotFound
        }
        messages.clearInboxDone(userId: userId, scopeId: channelId)
        return OkResponse()
    }

    // MARK: - POST /api/channels/threads/undone

    public func threadInboxUndone(
        authorization: String?,
        serverId: String?,
        body: InboxScopeRequest?
    ) throws -> OkResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ReactionsRealtimeError.unauthorized
        }
        guard let threadId = body?.threadChannelId else {
            throw ReactionsRealtimeError.invalidUndoneRequest
        }
        let snapshot = channels.postableChannels
        guard snapshot[threadId]?.kind == "thread",
              Self.threadParentVisible(threadId: threadId, userId: userId, channels: snapshot)
        else {
            throw ReactionsRealtimeError.scopeNotFound
        }
        messages.clearInboxDone(userId: userId, scopeId: threadId)
        return OkResponse()
    }

    // MARK: - POST /api/channels/inbox/done

    public func channelInboxDone(
        authorization: String?,
        serverId: String?,
        body: InboxScopeRequest?
    ) throws -> OkResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ReactionsRealtimeError.unauthorized
        }
        guard let body, let channelId = body.channelId else {
            throw ReactionsRealtimeError.invalidDoneRequest
        }
        let frontier = try resolveDoneFrontier(body, scopeId: channelId)
        guard channels.postableChannels[channelId]?.kind != "thread" else {
            throw ReactionsRealtimeError.scopeNotFound
        }
        messages.markInboxDone(
            userId: userId,
            scopeId: channelId,
            frontier: frontier,
            at: dependencies.now()
        )
        return OkResponse()
    }

    // MARK: - POST /api/channels/threads/done

    public func threadInboxDone(
        authorization: String?,
        serverId: String?,
        body: InboxScopeRequest?
    ) throws -> OkResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ReactionsRealtimeError.unauthorized
        }
        guard let body, let threadId = body.threadChannelId else {
            throw ReactionsRealtimeError.invalidDoneRequest
        }
        let frontier = try resolveDoneFrontier(body, scopeId: threadId)
        let snapshot = channels.postableChannels
        guard let thread = snapshot[threadId], serverId == nil || thread.serverId == serverId else {
            throw ReactionsRealtimeError.scopeNotFound
        }
        if thread.kind != "thread" {
            let visible = thread.kind == "channel" || thread.memberIds.contains(userId)
            throw visible ? ReactionsRealtimeError.notAThread : ReactionsRealtimeError.scopeNotFound
        }
        if thread.deletedAt != nil {
            // A deleted thread keeps its Done only for a viewer who still owns a
            // fact, follows it or has a read cursor; Done then just advances the
            // read cursor past the latest owned message.
            let ownedFacts = inboxFacts.all().filter {
                $0.receiverType == "user" && $0.receiverId == userId && $0.channelId == threadId
            }
            let hasReadCursor = oauth.channelUnreadInfo(channelId: threadId, userId: userId).maxReadSeq > 0
            let deleted = messages.deletedThreadScope(
                serverId: serverId,
                userId: userId,
                threadId: threadId,
                latestOwnedMessageId: ownedFacts.last?.messageId
            )
            guard !ownedFacts.isEmpty || deleted.followed || hasReadCursor else {
                throw ReactionsRealtimeError.scopeNotFound
            }
            if let seq = deleted.ownedMessageSeq {
                oauth.setChannelReadCursor(channelId: threadId, userId: userId, seq: seq)
            }
            return OkResponse()
        }
        guard Self.threadParentVisible(threadId: threadId, userId: userId, channels: snapshot) else {
            throw ReactionsRealtimeError.scopeNotFound
        }
        messages.markInboxDone(
            userId: userId,
            scopeId: threadId,
            frontier: frontier,
            at: dependencies.now()
        )
        return OkResponse()
    }

    // MARK: - POST /api/channels/inbox/read-all

    public func inboxReadAll(authorization: String?, serverId: String?) throws -> InboxReadAllResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ReactionsRealtimeError.unauthorized
        }
        guard let serverId, oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ReactionsRealtimeError.notServerMember
        }
        let factScopeIds = Set(
            inboxFacts.all()
                .filter { $0.receiverId == userId && $0.serverId == serverId }
                .compactMap(\.channelId)
        )
        let marks = messages.markAllInboxDone(
            userId: userId,
            serverId: serverId,
            factScopeIds: factScopeIds,
            now: dependencies.now()
        ) { scopeId in
            let latest = oauth.channelUnreadInfo(channelId: scopeId, userId: userId).latestSeq ?? 0
            oauth.setChannelReadCursor(channelId: scopeId, userId: userId, seq: latest)
            return latest
        }
        return InboxReadAllResponse(scopes: marks.map {
            InboxReadAllResponse.Scope(
                scopeId: $0.scopeId,
                maxReadSeq: $0.maxReadSeq,
                readStateVersion: $0.readStateVersion
            )
        })
    }

    // MARK: - Done frontier

    /// Resolves the Done frontier for a scope. An explicit frontier must be
    /// canonical and inside the int4 authority; an omitted frontier snapshots
    /// the latest activity. The persisted frontier is the admission snapshot.
    private func resolveDoneFrontier(_ body: InboxScopeRequest, scopeId: String) throws -> Int {
        switch body.frontierSpace {
        case .absent, .null, .string("storage"):
            break
        case .string, .other:
            throw ReactionsRealtimeError.doneFrontierUnmappable
        }
        // An explicit frontier is validated whenever the key is present; JSON
        // null is an invalid frontier, not an omitted one.
        let explicit = body.throughActivitySeq != .absent
        var frontier = 0
        if explicit {
            guard case .string(let raw) = body.throughActivitySeq,
                  let parsed = Self.canonicalDoneFrontier(raw)
            else {
                throw ReactionsRealtimeError.doneFrontierRequired
            }
            frontier = parsed
        }
        let latest = oauth.channelUnreadInfo(channelId: scopeId, userId: "").latestSeq ?? 0
        if !explicit { frontier = latest }
        guard frontier <= Self.doneFrontierInt4Limit else {
            throw ReactionsRealtimeError.doneFrontierAboveInt4
        }
        // Keep the permissive contract for scopes with no real activity;
        // elsewhere an explicit frontier beyond the latest is rejected before
        // any write, so a rejected Done never admits a mutation.
        if explicit, latest > 0, frontier > latest {
            throw ReactionsRealtimeError.doneFrontierBeyondLatest
        }
        return frontier
    }

    /// Canonical `throughActivitySeq`: a decimal string in (0, Int64.max] with
    /// no leading zero. Anything else is DONE_FRONTIER_REQUIRED.
    static func canonicalDoneFrontier(_ text: String) -> Int? {
        guard !text.isEmpty,
              text.count <= 19,
              text.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
              let value = Int(text), value > 0
        else { return nil }
        return value
    }

    /// A thread is readable only through its parent's current visibility.
    static func threadParentVisible(
        threadId: String,
        userId: String,
        channels: [String: PostableChannel]
    ) -> Bool {
        guard let thread = channels[threadId], thread.kind == "thread" else { return false }
        guard let parentId = thread.parentChannelId else { return true }
        guard let parent = channels[parentId] else { return false }
        return parent.kind == "channel" || parent.memberIds.contains(userId)
    }
}
