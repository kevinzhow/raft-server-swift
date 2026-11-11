import Foundation

/// The agent task credential and channel-reference policy shared by every
/// service that serves the agent task routes (`ActionCardExecuteService`,
/// `ActionCardMarketplaceService`) and, through the directory forwarders, the
/// services that have not migrated yet. One copy of the legacy
/// `agentTaskAuth` / `agentTaskWriter` / `agentTaskChannel` decisions.
struct AgentTaskCredentials: Sendable {
    enum AuthOutcome: Sendable, Equatable {
        case missingAuthorization
        case invalidCredential
        case ok(agentId: String, serverId: String)
    }

    /// The published outcome of one channel-reference resolution.
    ///
    /// `notFound` is the neutral miss; the DM arm additionally has the two
    /// caller-fixable failures upstream publishes as `DmTargetResolutionError`
    /// (an ambiguous bare peer name and an unknown `~kind` suffix). Collapsing
    /// those into a miss is what made a display-name alias look like a valid
    /// conversation and hid the actionable body from the agent.
    enum ChannelResolution: Sendable, Equatable {
        case resolved(String)
        case notFound
        case ambiguous(peerName: String)
        case invalidPeerKind(rawPeer: String, suffix: String?)
    }

    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let channels: ServersAndChannelsStore
    private let cards: ManagedMCPAndCardsStore
    private let oauth: OAuthLedger
    private let accounts: AuthProfileStore
    /// The agent's durable reminders surface, when one exists. The private
    /// surface is written by the server only; naming it resolves the channel
    /// (upstream `getAgentPrivateSurfaceChannelId`), and the task-write gate
    /// then refuses it like every other non-postable DM.
    private let reminderSurface: @Sendable (_ agentId: String) -> String?

    init(
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        cards: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        accounts: AuthProfileStore,
        reminderSurface: @escaping @Sendable (_ agentId: String) -> String? = { _ in nil }
    ) {
        self.agents = agents
        self.machines = machines
        self.channels = channels
        self.cards = cards
        self.oauth = oauth
        self.accounts = accounts
        self.reminderSurface = reminderSurface
    }

    private var machineGate: LegacyAgentMachineGate {
        LegacyAgentMachineGate(agents: agents, machines: machines, oauth: oauth, cards: cards)
    }

    /// The legacy `agentTaskAuth` reading order: the path-agent machine route
    /// runs `requireMachineAuth` + `requireAgentScope`, while the id-less
    /// `/internal/agent-api/*` twin reads a live `sk_agent_*` credential (a
    /// credential without `tasks` is the published capability 403 in the
    /// caller; here it is the same invalid-token outcome as before).
    func auth(authorization: String?, legacyAgentId: String?) -> AuthOutcome {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missingAuthorization }
        if let legacyAgentId {
            guard let actor = try? machineGate.actor(
                authorization: authorization,
                agentId: legacyAgentId,
                requiredScope: nil
            ) else {
                return .invalidCredential
            }
            return .ok(agentId: actor.agent.id, serverId: actor.serverId)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredential(token: token), credential.revokedAt == nil else {
            return .invalidCredential
        }
        guard credential.scopes.contains("tasks") else { return .invalidCredential }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .invalidCredential
        }
        return .ok(agentId: agent.id, serverId: agent.serverId)
    }

    /// The legacy `agentTaskWriter`: write routes on the legacy path agent surface
    /// accept the machine key that owns the agent; their `/internal/agent-api/*`
    /// twin accepts the bound `sk_agent_*` credential.
    func writer(authorization: String?, legacyAgentId: String?) -> (agentId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        if let legacyAgentId {
            guard let actor = try? machineGate.actor(
                authorization: authorization,
                agentId: legacyAgentId,
                requiredScope: nil
            ) else {
                return nil
            }
            return (actor.agent.id, actor.serverId)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredential(token: token), credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return nil
        }
        return (agent.id, agent.serverId)
    }

    /// The legacy `agentTaskChannel` reference resolution.
    ///
    /// Upstream resolves every task-channel reference through
    /// `channelService.resolveChannelByName`, which accepts `#name`, `dm:@peer`
    /// and a raw channel id. The DM arm is load-bearing for the claim-before-work
    /// prompt: an agent that receives an actionable top-level DM message claims
    /// it by `--target dm:@<peer> --message-id <id>` before running any tool. A
    /// resolver that only knew `#name` and raw ids answered that claim with
    /// `400 Invalid task claim request`, and the prompt then forbids the agent
    /// from starting the work at all.
    func channel(serverId: String, agentId: String, reference: String) -> String? {
        guard case .resolved(let channelId) = resolution(
            serverId: serverId, agentId: agentId, reference: reference, allowThread: false
        ) else {
            return nil
        }
        return channelId
    }

    /// The channel-reference resolution with the caller-fixable DM failures
    /// retained. `allowThread` makes the `:<8-hex>` suffix arm available; the
    /// claim route needs it to publish the pinned thread refusal, while the
    /// remaining task routes keep their pre-existing target grammar.
    func resolution(
        serverId: String,
        agentId: String,
        reference: String,
        allowThread: Bool
    ) -> ChannelResolution {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        if trimmed.hasPrefix("dm:@") || trimmed.hasPrefix("DM:@") {
            let rawPeerRef = String(trimmed.dropFirst(4))
            if allowThread, let split = Self.splitThreadSuffix(rawPeerRef) {
                return dmThreadResolution(
                    serverId: serverId,
                    agentId: agentId,
                    rawPeer: split.base,
                    shortId: split.shortId
                )
            }
            return dmPeerResolution(serverId: serverId, agentId: agentId, rawPeer: rawPeerRef)
        }
        if trimmed.hasPrefix("#") {
            let rawChannelRef = String(trimmed.dropFirst())
            if allowThread, let split = Self.splitThreadSuffix(rawChannelRef) {
                guard let threadId = threadChannel(
                    serverId: serverId, agentId: agentId, shortId: split.shortId
                ) else {
                    return .notFound
                }
                return .resolved(threadId)
            }
            for (id, channel) in channels.postableChannels {
                guard channel.serverId == serverId, channel.name == rawChannelRef, channel.deletedAt == nil else {
                    continue
                }
                if canAgentAccess(channelId: id, channel: channel, agentId: agentId) {
                    return .resolved(id)
                }
            }
            return .notFound
        }
        guard channels.postableChannels[trimmed]?.serverId == serverId else { return .notFound }
        return .resolved(trimmed)
    }

    // MARK: - Task-write policy

    /// Upstream `channelService.canAgentPostToChannel`: the enabled `#all`
    /// surface is open to every live agent in the server, a thread borrows its
    /// parent's access, the private reminder surface is server-only, and every
    /// other channel needs an actual agent membership.
    func canAgentPost(serverId: String, agentId: String, channelId: String) -> Bool {
        guard let channel = channels.postableChannel(id: channelId), channel.serverId == serverId,
              channel.deletedAt == nil else {
            return false
        }
        if reminderSurface(agentId) == channelId { return false }
        let name = oauth.channelInfo(id: channelId)?.name ?? channel.name
        let type = oauth.channelType(id: channelId) ?? channel.kind
        if name == "all", type == "channel" || type == "private" {
            guard type == "channel" else { return false }
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
                return false
            }
            return true
        }
        if type == "thread", channel.parentChannelId != nil {
            return channel.parentChannelId.map {
                canAgentPost(serverId: serverId, agentId: agentId, channelId: $0)
            } ?? false
        }
        return channel.memberIds.contains(agentId)
            || oauth.channelAgentIds(channelId: channelId).contains(agentId)
    }

    /// Upstream `isChannelArchived` reads the durable channel row.
    func isChannelArchived(_ channelId: String) -> Bool {
        channels.postableChannel(id: channelId)?.archived == true
            || oauth.channelArchivedAt(id: channelId) != nil
    }

    // MARK: - Channel-reference parsing

    /// Upstream `parseChannelRef`: a trailing `:<8-hex>` is the thread short-id
    /// suffix only when the colon is not the first character (so `#:abcd1234`
    /// stays a channel named `:abcd1234`).
    static func splitThreadSuffix(_ rest: String) -> (base: String, shortId: String)? {
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let base = String(rest[..<colon])
        guard !base.isEmpty else { return nil }
        let shortId = String(rest[rest.index(after: colon)...])
        guard shortId.count == 8, shortId.allSatisfy({ $0.isHexDigit }) else { return nil }
        return (base, shortId.lowercased())
    }

    /// Upstream `parseDmPeerRef`: the first `~` separates the name from the
    /// optional kind; an unknown kind is a caller error, not a bare name.
    private enum PeerParse {
        case ok(name: String, kind: String?)
        case emptyName
        case invalidKind(rawPeer: String, suffix: String)
    }

    private func parsePeer(_ rawPeer: String) -> PeerParse {
        guard let tilde = rawPeer.firstIndex(of: "~") else {
            return rawPeer.isEmpty ? .emptyName : .ok(name: rawPeer, kind: nil)
        }
        let name = String(rawPeer[..<tilde])
        guard !name.isEmpty else { return .emptyName }
        let suffix = String(rawPeer[rawPeer.index(after: tilde)...])
        guard suffix == "agent" || suffix == "human" else {
            return .invalidKind(rawPeer: rawPeer, suffix: suffix)
        }
        return .ok(name: name, kind: suffix)
    }

    // MARK: - Thread targets

    /// Upstream `resolveThreadByShortId`: the suffix names a thread by its
    /// parent-message short id (`thread-<short>`) or, failing that, the unique
    /// thread channel id with that short prefix. Both are server-scoped and
    /// gated by the same access rule as the parent.
    private func threadChannel(serverId: String, agentId: String, shortId: String) -> String? {
        let threads = channels.postableChannels.filter {
            $0.value.serverId == serverId && $0.value.kind == "thread" && $0.value.deletedAt == nil
        }
        if let anchor = threads.first(where: { $0.value.parentMessageId?.hasPrefix(shortId) == true }),
           canAgentAccess(channelId: anchor.key, channel: anchor.value, agentId: agentId) {
            return anchor.key
        }
        let idMatches = threads.filter { $0.key.hasPrefix(shortId) }
        guard idMatches.count == 1, let match = idMatches.first,
              canAgentAccess(channelId: match.key, channel: match.value, agentId: agentId) else {
            return nil
        }
        return match.key
    }

    /// `dm:@peer:<short>` resolves the thread by its short id. An explicit peer
    /// kind additionally pins the thread's parent to the DM that kind names.
    private func dmThreadResolution(
        serverId: String,
        agentId: String,
        rawPeer: String,
        shortId: String
    ) -> ChannelResolution {
        let parsed = parsePeer(rawPeer)
        if case .invalidKind(let raw, let suffix) = parsed {
            return .invalidPeerKind(rawPeer: raw, suffix: suffix)
        }
        if case .emptyName = parsed { return .notFound }
        guard let threadId = threadChannel(serverId: serverId, agentId: agentId, shortId: shortId) else {
            return .notFound
        }
        guard case .ok(let peerName, let kind) = parsed, let kind else {
            return .resolved(threadId)
        }
        switch dmChannel(serverId: serverId, agentId: agentId, peerName: peerName, kind: kind) {
        case .resolved(let dmChannelId):
            guard let thread = channels.postableChannel(id: threadId),
                  thread.parentChannelId == dmChannelId else {
                return .notFound
            }
            return .resolved(threadId)
        case .notFound:
            return .notFound
        case .ambiguous, .invalidPeerKind:
            return .notFound
        }
    }

    /// Access uses the same parent-recursion as upstream
    /// `canAgentAccessChannel`: a public channel is open, a thread borrows its
    /// parent's access, and every other type needs an agent membership.
    private func canAgentAccess(channelId: String, channel: PostableChannel, agentId: String) -> Bool {
        var seen: Set<String> = []
        var currentId = channelId
        var current = channel
        for _ in 0..<8 {
            guard seen.insert(currentId).inserted, current.deletedAt == nil else { return false }
            if current.memberIds.contains(agentId) || oauth.channelAgentIds(channelId: currentId).contains(agentId) {
                return true
            }
            if current.kind == "channel" { return true }
            guard current.kind == "thread", let parentId = current.parentChannelId,
                  let parent = channels.postableChannel(id: parentId) else {
                return false
            }
            currentId = parentId
            current = parent
        }
        return false
    }

    // MARK: - DM targets

    /// Resolves one `dm:@rawPeer` task reference.
    ///
    /// The peer rules mirror the pinned `channelService.resolveChannelByName`:
    /// `dm:@reminders` is the agent's private surface, a `migration-receipt-`
    /// prefix resolves the owning agent's receipt and otherwise falls through to
    /// ordinary peers, a bare name held by both a human and an agent is the
    /// ambiguous refusal, `~human`/`~agent` pins the kind, and names match the
    /// canonical `users.name` / `agents.name` exactly (never a display name and
    /// never case-folded).
    private func dmPeerResolution(serverId: String, agentId: String, rawPeer: String) -> ChannelResolution {
        // `dm:@reminders` names the agent's own private reminder conversation.
        // The handle is reserved, so it precedes every peer rule.
        if rawPeer.lowercased() == "reminders" {
            guard let remindersId = reminderSurface(agentId),
                  let reminders = channels.postableChannel(id: remindersId),
                  reminders.serverId == serverId, reminders.deletedAt == nil else {
                return .notFound
            }
            return .resolved(remindersId)
        }
        // A migration receipt lives in a hidden DM whose only member is the
        // agent. It resolves for that agent and falls through to the ordinary
        // peer rules for everyone else (including a missing receipt row).
        if rawPeer.hasPrefix("migration-receipt-") {
            if let receipt = channels.postableChannels.first(where: { id, channel in
                channel.serverId == serverId && channel.deletedAt == nil
                    && channel.kind == "dm" && channel.name == rawPeer
                    && channel.memberIds == [agentId]
                    && oauth.channelAgentIds(channelId: id) == [agentId]
                    && oauth.channelHumanIds(channelId: id).isEmpty
            }) {
                return .resolved(receipt.key)
            }
        }
        switch parsePeer(rawPeer) {
        case .emptyName:
            return .notFound
        case .invalidKind(let raw, let suffix):
            return .invalidPeerKind(rawPeer: raw, suffix: suffix)
        case .ok(let peerName, let kind):
            return dmChannel(serverId: serverId, agentId: agentId, peerName: peerName, kind: kind)
        }
    }

    /// The exact-name peer match and DM lookup.
    private func dmChannel(
        serverId: String,
        agentId: String,
        peerName: String,
        kind: String?
    ) -> ChannelResolution {
        let humans = accounts.accounts.values.filter {
            $0.name == peerName && oauth.memberRole(serverId: serverId, userId: $0.id) != nil
        }.map(\.id)
        let agentPeers = oauth.serverAgents(serverId: serverId)
            .filter { $0.id != agentId && $0.name == peerName }
            .map(\.id)
        let peerId: String
        let peerKind: String
        switch kind {
        case "human":
            guard let id = humans.first else { return .notFound }
            peerId = id
            peerKind = "human"
        case "agent":
            guard let id = agentPeers.first else { return .notFound }
            peerId = id
            peerKind = "agent"
        default:
            // A bare name held by both kinds is ambiguous regardless of which
            // DM exists today; resolving it would let the same target name two
            // different conversations over time.
            if !humans.isEmpty, !agentPeers.isEmpty { return .ambiguous(peerName: peerName) }
            if let id = humans.first {
                peerId = id
                peerKind = "human"
            } else if let id = agentPeers.first {
                peerId = id
                peerKind = "agent"
            } else {
                return .notFound
            }
        }
        guard let channelId = oauth.directChannelId(
            serverId: serverId,
            firstUserId: agentId,
            secondUserId: peerId,
            firstKind: .agent,
            secondKind: peerKind == "agent" ? .agent : .human
        ), let channel = channels.postableChannel(id: channelId),
            channel.serverId == serverId, channel.kind == "dm", channel.deletedAt == nil,
            channel.memberIds.contains(agentId), channel.memberIds.contains(peerId)
        else { return .notFound }
        return .resolved(channelId)
    }
}
