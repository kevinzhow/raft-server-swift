import Foundation

/// The agent-facing channel/DM ref grammar and the canonical DM label.
///
/// Pinned sources (tag `v1.21.23-source.1`):
/// - `packages/server/src/services/channelService.ts:7256-7275`
///   `parseChannelRef`: the ONLY thread-suffix rule. The suffix must be a full
///   eight-hex message short id (`MESSAGE_SHORT_ID_RE`, case-insensitive); any
///   other `:...` stays part of the base ref instead of becoming a thread.
/// - `packages/server/src/services/channelService.ts:7346-7397`
///   `resolveThreadByShortId`: the 8-hex suffix contract the resolver acts on.
/// - `packages/shared/src/dmPeerRef.ts:29-39` `parseDmPeerRef`: the first `~`
///   separates the peer kind, and only the exact lowercase `agent` / `human`
///   are kinds. An unknown suffix is refused, never read as a bare name.
/// - `packages/server/src/services/channelService.ts:7457-7530`
///   `resolveDMByPeerName`: the exact canonical peer rules.
/// - `packages/server/src/services/channelService.ts:6778-6812`
///   `findCrossKindTwinPeerNames` / `agentFacingDmRef`: a name held by both a
///   human member and a live agent is labelled with the peer's kind.
enum AgentChannelRef {
    /// `AGENT_REMINDERS_DM_PEER` (agentPrivateSurfaces.ts:9).
    static let remindersPeer = "reminders"
    /// `MIGRATION_RECEIPT_CHANNEL_PREFIX` (channelService.ts:7451).
    static let migrationReceiptPrefix = "migration-receipt-"

    /// `MESSAGE_SHORT_ID_RE = /^[0-9a-f]{8}$/i` (lib/messageId.ts:12). The
    /// shape is case-insensitive; the resolver lowercases the UUID range.
    static func isMessageShortId(_ value: String) -> Bool {
        guard value.utf8.count == 8 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)      // 0-9
                || (byte >= 0x61 && byte <= 0x66) // a-f
                || (byte >= 0x41 && byte <= 0x46) // A-F
        }
    }

    struct ParsedRef: Equatable {
        var baseRef: String
        var threadShortId: String?
    }

    /// `channelService.parseChannelRef`. The prefix is preserved exactly as the
    /// caller wrote it (`DM:@` / `dm:@` / `#`); callers that publish a target
    /// re-project it through the canonical label instead of echoing this.
    static func parse(_ channelRef: String) -> ParsedRef {
        func withSuffix(_ prefix: String, _ rest: String) -> ParsedRef {
            guard let lastColon = rest.lastIndex(of: ":"),
                  rest.distance(from: rest.startIndex, to: lastColon) > 0 else {
                return ParsedRef(baseRef: prefix + rest, threadShortId: nil)
            }
            let shortId = String(rest[rest.index(after: lastColon)...])
            guard isMessageShortId(shortId) else {
                return ParsedRef(baseRef: prefix + rest, threadShortId: nil)
            }
            return ParsedRef(baseRef: prefix + String(rest[..<lastColon]), threadShortId: shortId)
        }
        if channelRef.hasPrefix("DM:@") {
            return withSuffix("DM:@", String(channelRef.dropFirst(4)))
        }
        if channelRef.hasPrefix("dm:@") {
            return withSuffix("dm:@", String(channelRef.dropFirst(4)))
        }
        if channelRef.hasPrefix("#") {
            return withSuffix("#", String(channelRef.dropFirst()))
        }
        return ParsedRef(baseRef: channelRef, threadShortId: nil)
    }

    enum PeerParse: Equatable {
        case ok(name: String, kind: String?)
        case emptyName
        case unknownKind(String)
    }

    /// `shared/src/dmPeerRef.ts:parseDmPeerRef` over the part after `dm:@`
    /// (and before any eight-hex thread suffix).
    static func parsePeer(_ raw: String) -> PeerParse {
        guard let tilde = raw.firstIndex(of: "~") else {
            return raw.isEmpty ? .emptyName : .ok(name: raw, kind: nil)
        }
        let name = String(raw[..<tilde])
        let suffix = String(raw[raw.index(after: tilde)...])
        guard !name.isEmpty else { return .emptyName }
        guard suffix == "agent" || suffix == "human" else { return .unknownKind(suffix) }
        return .ok(name: name, kind: suffix)
    }

    static func formatPeer(_ name: String, kind: String?) -> String {
        guard let kind else { return name }
        return "\(name)~\(kind)"
    }

    static func dmRef(name: String, kind: String?) -> String {
        "dm:@\(formatPeer(name, kind: kind))"
    }
}

/// The server-scoped directory facts the canonical DM label needs.
///
/// The twin rule is a fact about the directory, not about which DM rows exist,
/// so a label is stable before the second DM is created
/// (`findCrossKindTwinPeerNames`, channelService.ts:6778-6798). Human names are
/// the canonical `users.name` of server members; agent names are the canonical
/// `agents.name` of non-deleted agents in the server. A display name is never
/// a handle.
struct AgentDMRefDirectory: Sendable, Equatable {
    var humanMemberNames: Set<String>
    var agentNames: Set<String>

    init(humanMemberNames: Set<String>, agentNames: Set<String>) {
        self.humanMemberNames = humanMemberNames
        self.agentNames = agentNames
    }

    init(serverId: String, oauth: OAuthLedger, humanName: @Sendable (String) -> String?) {
        self.humanMemberNames = Set(
            oauth.memberRoles(serverId: serverId).compactMap { humanName($0.userId) }
        )
        self.agentNames = Set(oauth.serverAgents(serverId: serverId).map(\.name))
    }

    /// `findCrossKindTwinPeerNames`: a human member and a live agent share the
    /// exact canonical name.
    func hasTwin(_ name: String) -> Bool {
        humanMemberNames.contains(name) && agentNames.contains(name)
    }

    /// `agentFacingDmRef`: the bare form unless the name is a cross-kind twin.
    func label(name: String, kind: String) -> String {
        AgentChannelRef.dmRef(name: name, kind: hasTwin(name) ? kind : nil)
    }
}

/// The canonical agent-facing target of one DM channel.
///
/// Mirrors `channelService.resolveAgentFacingChannelRef`'s DM arm over the
/// retained typed membership rows (this port has no `dm_channel_identities`
/// table): the reminder surface, a migration receipt, then the single other
/// native participant named by `users.name` / `agents.name`. A peer that
/// cannot be named from the typed rows yields nil, exactly like an
/// unresolvable/invisible target.
enum AgentFacingDMRef {
    static func canonical(
        serverId: String,
        agentId: String,
        channelId: String,
        channel: PostableChannel,
        humanIds: [String],
        agentIds: [String],
        reminderSurfaceId: String?,
        labels: AgentDMRefDirectory,
        humanName: (String) -> String?,
        agentName: (String) -> String?
    ) -> String? {
        guard channel.serverId == serverId, channel.kind == "dm", channel.deletedAt == nil,
              channel.memberIds.contains(agentId), agentIds.contains(agentId) else { return nil }
        if reminderSurfaceId == channelId {
            guard channel.memberIds == [agentId], agentIds == [agentId], humanIds.isEmpty else {
                return nil
            }
            return AgentChannelRef.dmRef(name: AgentChannelRef.remindersPeer, kind: nil)
        }
        if channel.name.hasPrefix(AgentChannelRef.migrationReceiptPrefix) {
            guard channel.memberIds == [agentId], agentIds == [agentId], humanIds.isEmpty else {
                return nil
            }
            return AgentChannelRef.dmRef(name: channel.name, kind: nil)
        }
        var peers: [(name: String, kind: String)] = []
        for peerId in humanIds where peerId != agentId {
            guard let name = humanName(peerId) else { return nil }
            peers.append((name, "human"))
        }
        for peerId in agentIds where peerId != agentId {
            guard let name = agentName(peerId) else { return nil }
            peers.append((name, "agent"))
        }
        guard peers.count == 1, let peer = peers.first, !peer.name.isEmpty else { return nil }
        return labels.label(name: peer.name, kind: peer.kind)
    }
}

/// The exact DM peer rules (`resolveDMByPeerName`, `findHumanPeerDm`,
/// `findAgentPeerDm`) over the retained typed rows.
///
/// The resolver owns no state: the OAuth ledger, channel store and account
/// store own it. It is shared by the send, history and search domains so the
/// canonical-name, typed-kind and stable-twin rules have one implementation.
struct AgentDMPeerResolver: Sendable {
    let oauth: OAuthLedger
    let channels: ServersAndChannelsStore
    let accounts: AuthProfileStore

    /// `channelService.resolveDMByPeerName` minus the reminders/app-DM arms,
    /// which the owning surfaces resolve themselves:
    ///
    /// - an owned `migration-receipt-` ref resolves the owning agent's hidden
    ///   receipt first, then falls through to the ordinary peer rules when this
    ///   agent owns no receipt by that exact name;
    /// - `~agent` / `~human` must be the exact lowercase suffix;
    /// - the peer name matches the canonical `users.name` / `agents.name`
    ///   exactly;
    /// - a bare name held by BOTH a human member and a live agent is ambiguous
    ///   regardless of which DM exists today.
    func resolvePeer(
        serverId: String,
        agentId: String,
        name rawName: String,
        kind rawKind: String?
    ) -> DMPeerResolution {
        // Callers split the ref at the first `~`; reconstruct the upstream raw
        // spelling so the receipt prefix test sees what the caller wrote.
        let rawPeer = rawKind.map { "\(rawName)~\($0)" } ?? rawName
        if rawPeer.hasPrefix(AgentChannelRef.migrationReceiptPrefix) {
            let postable = channels.postableChannels
            let owned = postable.first { id, channel in
                channel.serverId == serverId && channel.deletedAt == nil
                    && channel.kind == "dm" && channel.name == rawPeer && channel.memberIds == [agentId]
                    && oauth.channelAgentIds(channelId: id) == [agentId]
                    && oauth.channelHumanIds(channelId: id).isEmpty
            }
            if let owned {
                return .resolved(peerId: agentId, peerKind: "agent", name: rawPeer)
            }
            // No receipt for this agent: keep going to the peer rules below.
        }
        let kind: String?
        switch rawKind {
        case nil:
            kind = nil
        case "agent", "human":
            kind = rawKind
        case .some(let invalid):
            return .invalidKind(invalid, rawName)
        }
        // `parseDmPeerRef` refuses an empty name instead of matching an empty
        // display name; keep the neutral not-found.
        guard !rawName.isEmpty else { return .notFound }
        let humans = accounts.accounts.values.filter {
            $0.name == rawName && oauth.memberRole(serverId: serverId, userId: $0.id) != nil
        }.map(\.id)
        let agents = oauth.serverAgents(serverId: serverId)
            .filter { $0.id != agentId && $0.name == rawName }
            .map(\.id)
        switch kind {
        case "agent":
            guard let id = agents.first else { return .notFound }
            return .resolved(peerId: id, peerKind: "agent", name: rawName)
        case "human":
            guard let id = humans.first else { return .notFound }
            return .resolved(peerId: id, peerKind: "human", name: rawName)
        default:
            // `findCrossKindTwinPeerNames` counts every non-deleted agent in
            // the server, including the caller's own row.
            if !humans.isEmpty,
               oauth.serverAgents(serverId: serverId).contains(where: { $0.name == rawName }) {
                return .ambiguous(rawName)
            }
            if let id = humans.first { return .resolved(peerId: id, peerKind: "human", name: rawName) }
            if let id = agents.first { return .resolved(peerId: id, peerKind: "agent", name: rawName) }
            return .notFound
        }
    }

    /// `findOrCreateDM`'s existing-row half: the live DM between the agent and
    /// the exact typed peer.
    func channelId(
        serverId: String,
        agentId: String,
        peerId: String,
        peerKind: String,
        peerName: String? = nil
    ) -> String? {
        if peerKind == "agent", peerId == agentId {
            // A receipt is a retained named singleton surface, not a self DM.
            // Resolve only its verified original identity; never manufacture one.
            guard let peerName, peerName.hasPrefix(AgentChannelRef.migrationReceiptPrefix) else {
                return nil
            }
            return channels.postableChannels.first { id, channel in
                channel.serverId == serverId && channel.deletedAt == nil && channel.kind == "dm"
                    && channel.name == peerName && channel.memberIds == [agentId]
                    && oauth.channelAgentIds(channelId: id) == [agentId]
                    && oauth.channelHumanIds(channelId: id).isEmpty
            }?.key
        }
        guard let id = oauth.directChannelId(serverId: serverId, firstUserId: agentId,
            secondUserId: peerId, firstKind: .agent, secondKind: peerKind == "agent" ? .agent : .human),
              let channel = channels.postableChannel(id: id), channel.serverId == serverId,
              channel.kind == "dm", channel.deletedAt == nil,
              channel.memberIds.contains(agentId), channel.memberIds.contains(peerId) else { return nil }
        return id
    }

    func agentName(serverId: String, agentId: String) -> String? {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
              agent.serverId == serverId else { return nil }
        return agent.name
    }

    func humanName(serverId: String, userId: String) -> String? {
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else { return nil }
        return accounts.account(userId: userId)?.name
    }

    func directory(serverId: String) -> AgentDMRefDirectory {
        AgentDMRefDirectory(
            serverId: serverId, oauth: oauth,
            humanName: { [accounts] userId in accounts.account(userId: userId)?.name }
        )
    }

    /// The canonical target of one DM channel, resolved from the channel's own
    /// typed rows (never from the caller's spelling).
    func canonicalRef(
        serverId: String,
        agentId: String,
        channelId: String,
        channel: PostableChannel,
        reminderSurfaceId: String?,
        labels: AgentDMRefDirectory? = nil
    ) -> String? {
        let labels = labels ?? self.directory(serverId: serverId)
        return AgentFacingDMRef.canonical(
            serverId: serverId,
            agentId: agentId,
            channelId: channelId,
            channel: channel,
            humanIds: oauth.channelHumanIds(channelId: channelId),
            agentIds: oauth.channelAgentIds(channelId: channelId),
            reminderSurfaceId: reminderSurfaceId,
            labels: labels,
            humanName: { [accounts, oauth] userId in
                guard oauth.memberRole(serverId: serverId, userId: userId) != nil else { return nil }
                return accounts.account(userId: userId)?.name
            },
            agentName: { [oauth] peerId in
                guard let peer = oauth.agentRuntimeInfo(id: peerId), !peer.deleted,
                      peer.serverId == serverId else { return nil }
                return peer.name
            }
        )
    }
}
