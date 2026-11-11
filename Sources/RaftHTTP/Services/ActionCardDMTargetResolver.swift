import Foundation

/// Resolves the `dm:@peer` / `dm:@peer:shortId` carrier of an `agent:create`
/// action card, mirroring pinned `resolveWritableAgentTarget` and
/// `resolveOrCreateThreadTarget` for the DM arm
/// (`routes/agentWritableTarget.ts`).
///
/// The card is posted into the resolved DM or DM thread. A thread suffix is a
/// thread id only when it is a full eight-hex message short id
/// (`channelService.parseChannelRef`); any other `:...` stays in the peer name
/// and resolves like an ordinary peer, so a malformed target can never create
/// a DM or a thread. The typed peer rules themselves come from
/// `AgentDMPeerResolver`, the same implementation history, search and send use.
struct ActionCardDMTargetResolver: Sendable {
    let oauth: OAuthLedger
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let accounts: AuthProfileStore
    let agents: AgentsRuntimeStore
    let addPostableChannel: @Sendable (
        _ serverId: String,
        _ channelId: String,
        _ memberId: String,
        _ kind: String,
        _ parentChannelId: String?,
        _ parentMessageId: String?,
        _ name: String?
    ) -> Void

    /// `nil` when the ref is not a DM target at all (the caller falls through
    /// to the channel target path). A thrown error is the published refusal.
    func resolve(serverId: String, agentId: String, rawTarget: String) throws -> String? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.hasPrefix("dm:@") || target.hasPrefix("DM:@") else { return nil }
        let parsed = AgentChannelRef.parse(target)
        let rawPeer = String(parsed.baseRef.dropFirst("dm:@".count))

        // `dm:@reminders` is read-only for its agent, before any peer-kind
        // parsing; only a trailing lowercase/uppercase `~agent`/`~human` is
        // stripped first (`resolveWritableAgentTarget`).
        let reminderRef = rawPeer.replacingOccurrences(
            of: #"~(agent|human)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if reminderRef.lowercased() == AgentChannelRef.remindersPeer {
            throw ActionCardIntegrationRegisterError.dmTargetNotSendable
        }

        // `resolveWritableAgentTarget` treats any-length hex after a colon as
        // the thread-shaped arm. Such a ref never takes the create-a-DM
        // branch; it only reuses an existing DM (or is the generic unresolved
        // target), exactly like the pinned fallback.
        let threadShaped = parsed.threadShortId == nil
            && AgentChannelRef.isThreadShapedPeer(rawPeer)
        let peer: (name: String, kind: String?)
        switch AgentChannelRef.parsePeer(rawPeer) {
        case .unknownKind(let suffix):
            throw ActionCardIntegrationRegisterError.dmTargetInvalidPeerKind(
                rawPeer: rawPeer, suffix: suffix
            )
        case .emptyName:
            // `parseDmPeerRef`'s empty name is a neutral miss in the pinned
            // resolver; a thread ref keeps the route's generic unresolved 400.
            if parsed.threadShortId != nil || threadShaped {
                throw ActionCardIntegrationRegisterError.couldNotResolveTarget(target: rawTarget)
            }
            throw ActionCardIntegrationRegisterError.dmPeerNotFound(peer: rawPeer)
        case .ok(let name, let kind):
            peer = (name, kind)
        }

        let resolver = AgentDMPeerResolver(oauth: oauth, channels: channels, accounts: accounts)
        let resolution = resolver.resolvePeer(
            serverId: serverId, agentId: agentId, name: peer.name, kind: peer.kind
        )
        let peerId: String
        let peerKind: String
        let peerName: String
        switch resolution {
        case .resolved(let id, let kind, let name):
            (peerId, peerKind, peerName) = (id, kind, name)
        case .ambiguous(let name):
            throw ActionCardIntegrationRegisterError.dmTargetAmbiguous(name: name)
        case .invalidKind(let suffix, _):
            throw ActionCardIntegrationRegisterError.dmTargetInvalidPeerKind(
                rawPeer: rawPeer, suffix: suffix
            )
        case .notFound:
            if threadShaped {
                throw ActionCardIntegrationRegisterError.couldNotResolveTarget(target: rawTarget)
            }
            if peer.kind != "human", !peer.name.isEmpty,
               let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
               agent.serverId == serverId, agent.name == peer.name {
                if parsed.threadShortId != nil {
                    throw ActionCardIntegrationRegisterError.couldNotResolveTarget(target: rawTarget)
                }
                throw ActionCardIntegrationRegisterError.selfDM
            }
            if parsed.threadShortId != nil {
                throw ActionCardIntegrationRegisterError.couldNotResolveTarget(target: rawTarget)
            }
            throw ActionCardIntegrationRegisterError.dmPeerNotFound(peer: rawPeer)
        }

        let post = AgentPostAuthority(oauth: oauth, channels: channels, agents: agents)
        if threadShaped {
            guard let dmId = resolver.channelId(
                serverId: serverId, agentId: agentId, peerId: peerId,
                peerKind: peerKind, peerName: peerName
            ) else {
                throw ActionCardIntegrationRegisterError.couldNotResolveTarget(target: rawTarget)
            }
            guard post.canPost(serverId: serverId, agentId: agentId, channelId: dmId) else {
                throw ActionCardIntegrationRegisterError.targetNotWritable
            }
            return dmId
        }
        if let suffix = parsed.threadShortId {
            // A thread target resolves through its parent DM, which must
            // already exist: creating a DM here would leave a phantom DM when
            // the anchor is missing.
            guard let dmId = resolver.channelId(
                serverId: serverId, agentId: agentId, peerId: peerId,
                peerKind: peerKind, peerName: peerName
            ) else {
                throw ActionCardIntegrationRegisterError.couldNotResolveTarget(target: rawTarget)
            }
            guard let anchorId = threadAnchor(
                serverId: serverId, dmId: dmId, suffix: suffix
            ) else {
                throw ActionCardIntegrationRegisterError.couldNotResolveTarget(target: rawTarget)
            }
            guard post.canPost(serverId: serverId, agentId: agentId, channelId: dmId) else {
                throw ActionCardIntegrationRegisterError.targetNotWritable
            }
            if let existing = channels.actionCardThreadChannel(
                parentChannelId: dmId, parentMessageId: anchorId
            ) {
                return existing
            }
            let threadId = oauth.createThreadChannel(
                parentChannelId: dmId, parentMessageId: anchorId
            )
            addPostableChannel(serverId, threadId, agentId, "thread", dmId, anchorId, "thread")
            addPostableChannel(serverId, threadId, peerId, "thread", dmId, anchorId, "thread")
            return threadId
        }

        // A migration receipt is a one-way notice: the pinned writable-target
        // resolver answers the read-only conflict before the DM is posted in.
        if peerKind == "agent", peerId == agentId,
           peerName.hasPrefix(AgentChannelRef.migrationReceiptPrefix) {
            throw ActionCardIntegrationRegisterError.migrationReceiptReadOnly(target: target)
        }
        if let existing = resolver.channelId(
            serverId: serverId, agentId: agentId, peerId: peerId,
            peerKind: peerKind, peerName: peerName
        ) {
            guard post.canPost(serverId: serverId, agentId: agentId, channelId: existing) else {
                throw ActionCardIntegrationRegisterError.targetNotWritable
            }
            return existing
        }

        // RFC 074 §2: an assistant may open a DM only with its raw owner. The
        // binding is retained regardless of the `identity_borrowing` flag.
        if let owner = AssistantOwnershipQuery(agents: agents, oauth: oauth)
            .rawOwner(agentId: agentId), peerId != owner {
            throw ActionCardIntegrationRegisterError.targetNotWritable
        }
        guard oauth.agentRuntimeInfo(id: agentId)?.deleted == false else {
            throw ActionCardIntegrationRegisterError.requesterAgentNotFound
        }
        let dmId = oauth.createDirectChannel(
            serverId: serverId,
            firstUserId: agentId,
            secondUserId: peerId,
            firstKind: .agent,
            secondKind: peerKind == "agent" ? .agent : .human
        )
        addPostableChannel(serverId, dmId, agentId, "dm", nil, nil, "dm")
        addPostableChannel(serverId, dmId, peerId, "dm", nil, nil, "dm")
        if peerKind == "human" {
            oauth.addChannelHuman(channelId: dmId, userId: peerId)
        }
        return dmId
    }

    /// The anchor message and the thread-id fallback, exactly like
    /// `resolveOrCreateThreadTarget`: the suffix first names a unique parent
    /// message in the DM, then a unique live thread under that DM whose channel
    /// id starts with the suffix (`threadId=`).
    private func threadAnchor(serverId: String, dmId: String, suffix: String) -> String? {
        let prefix = suffix.lowercased()
        var messageHits = Set<String>()
        for message in oauth.historyMessages(channelId: dmId)
        where message.id.lowercased().hasPrefix(prefix) {
            messageHits.insert(message.id)
        }
        for row in messages.humanMessageRows
        where row.channelId == dmId && row.id.lowercased().hasPrefix(prefix) {
            messageHits.insert(row.id)
        }
        if messageHits.count == 1 { return messageHits.first }

        let state = channels.state
        let threadHits = state.postableChannels.filter { id, channel in
            channel.serverId == serverId && channel.kind == "thread" && channel.deletedAt == nil
                && channel.parentChannelId == dmId
                && id.lowercased().hasPrefix(prefix)
                && channel.parentMessageId != nil
        }
        guard threadHits.count == 1, let thread = threadHits.first else { return nil }
        return thread.value.parentMessageId
    }
}
