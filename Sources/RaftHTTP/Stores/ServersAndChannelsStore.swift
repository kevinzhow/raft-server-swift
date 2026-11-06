import Foundation

/// Owns the server-membership, sidebar and channel-authority rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class ServersAndChannelsStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var postableChannels: [String: PostableChannel] = [:]
        var threadOrder: [String] = []
        var serverMemberRoles: [String: String] = [:]
        var hideHumansFromMembers: [String: Bool] = [:]
        var serverMemberStatuses: [String: String] = [:]
        var membershipAgreementAudits: [(serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)] = []
        var jointProjections: [JointChannelLink] = []
        var serverMemberEvents: [ServerMemberEvent] = []
        var deletedServerIds: Set<String> = []
        var removedServerMembers: Set<String> = []
        var serverPlans: [String: String] = [:]
        var serverLabsState: [String: ServerLabsState] = [:]
        var serverInvites: [(id: String, serverId: String, email: String, role: String, tokenHash: String?)] = []
        var serverSwitcherOrders: [String: (ids: [String], version: Int)] = [:]
        var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] = [:]
        /// Per-member onboarding progress, keyed `serverId\nuserId`. It lives
        /// beside the per-server rows so one patch updates both in a single
        /// critical section.
        var userOnboardingSettings: [String: UserOnboarding] = [:]
        var setupPhases: [String: String] = [:]
        var setupHandoffs: Set<String> = []
        var guestRoleServers: Set<String> = []
        var proSeats: [String: Int] = [:]
        var joinLinks: [String: JoinLinkRecord] = [:]
        var usageLimitAttentionServers: Set<String> = []
        var guestVisibleChannels: [String: Bool] = [:]
        var guestJoinableChannels: [String: Bool] = [:]
        var readReceiptsServers: Set<String> = []
        var channelHumanRoles: [String: String] = [:]
        var channelAuthorityRevisions: [String: Int] = [:]
        var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] = [:]
        var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] = [:]
        var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] = [:]
        var sidebarReadAllEnabled: Bool = false
        var jointInvites: [(id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String)] = []
        var composerResourceServers: Set<String> = []
        var installedServerApps: [String: Set<String>] = [:]
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var postableChannels: [String: PostableChannel] {
        get { state.postableChannels }
        set { state.postableChannels = newValue }
    }

    var threadOrder: [String] {
        get { state.threadOrder }
        set { state.threadOrder = newValue }
    }

    var serverMemberRoles: [String: String] {
        get { state.serverMemberRoles }
        set { state.serverMemberRoles = newValue }
    }

    var hideHumansFromMembers: [String: Bool] {
        get { state.hideHumansFromMembers }
        set { state.hideHumansFromMembers = newValue }
    }

    var serverMemberStatuses: [String: String] {
        get { state.serverMemberStatuses }
        set { state.serverMemberStatuses = newValue }
    }

    var membershipAgreementAudits: [(serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)] {
        get { state.membershipAgreementAudits }
        set { state.membershipAgreementAudits = newValue }
    }

    var jointProjections: [JointChannelLink] {
        get { state.jointProjections }
        set { state.jointProjections = newValue }
    }

    var serverMemberEvents: [ServerMemberEvent] {
        get { state.serverMemberEvents }
        set { state.serverMemberEvents = newValue }
    }

    var deletedServerIds: Set<String> {
        get { state.deletedServerIds }
        set { state.deletedServerIds = newValue }
    }

    var removedServerMembers: Set<String> {
        get { state.removedServerMembers }
        set { state.removedServerMembers = newValue }
    }

    var serverPlans: [String: String] {
        get { state.serverPlans }
        set { state.serverPlans = newValue }
    }

    var serverLabsState: [String: ServerLabsState] {
        get { state.serverLabsState }
        set { state.serverLabsState = newValue }
    }

    var serverInvites: [(id: String, serverId: String, email: String, role: String, tokenHash: String?)] {
        get { state.serverInvites }
        set { state.serverInvites = newValue }
    }

    var serverSwitcherOrders: [String: (ids: [String], version: Int)] {
        get { state.serverSwitcherOrders }
        set { state.serverSwitcherOrders = newValue }
    }

    var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] {
        get { state.serverOnboardingSettings }
        set { state.serverOnboardingSettings = newValue }
    }

    var setupPhases: [String: String] {
        get { state.setupPhases }
        set { state.setupPhases = newValue }
    }

    var setupHandoffs: Set<String> {
        get { state.setupHandoffs }
        set { state.setupHandoffs = newValue }
    }

    var guestRoleServers: Set<String> {
        get { state.guestRoleServers }
        set { state.guestRoleServers = newValue }
    }

    var proSeats: [String: Int] {
        get { state.proSeats }
        set { state.proSeats = newValue }
    }

    var joinLinks: [String: JoinLinkRecord] {
        get { state.joinLinks }
        set { state.joinLinks = newValue }
    }

    var usageLimitAttentionServers: Set<String> {
        get { state.usageLimitAttentionServers }
        set { state.usageLimitAttentionServers = newValue }
    }

    var guestVisibleChannels: [String: Bool] {
        get { state.guestVisibleChannels }
        set { state.guestVisibleChannels = newValue }
    }

    var guestJoinableChannels: [String: Bool] {
        get { state.guestJoinableChannels }
        set { state.guestJoinableChannels = newValue }
    }

    var readReceiptsServers: Set<String> {
        get { state.readReceiptsServers }
        set { state.readReceiptsServers = newValue }
    }

    var channelHumanRoles: [String: String] {
        get { state.channelHumanRoles }
        set { state.channelHumanRoles = newValue }
    }

    var channelAuthorityRevisions: [String: Int] {
        get { state.channelAuthorityRevisions }
        set { state.channelAuthorityRevisions = newValue }
    }

    var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] {
        get { state.sidebarModes }
        set { state.sidebarModes = newValue }
    }

    var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] {
        get { state.sidebarSections }
        set { state.sidebarSections = newValue }
    }

    var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] {
        get { state.sidebarPinnedRefs }
        set { state.sidebarPinnedRefs = newValue }
    }

    var sidebarReadAllEnabled: Bool {
        get { state.sidebarReadAllEnabled }
        set { state.sidebarReadAllEnabled = newValue }
    }

    var jointInvites: [(id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String)] {
        get { state.jointInvites }
        set { state.jointInvites = newValue }
    }

    var composerResourceServers: Set<String> {
        get { state.composerResourceServers }
        set { state.composerResourceServers = newValue }
    }

    var installedServerApps: [String: Set<String>] {
        get { state.installedServerApps }
        set { state.installedServerApps = newValue }
    }

    // MARK: - Socket room membership

    /// Read-only view the `sync:resume` visibility rules need: channels and the
    /// guest-visibility flags observed in the same critical section.
    struct ChannelReadSnapshot {
        let channels: [String: PostableChannel]
        let guestVisibleChannels: [String: Bool]
    }

    /// Channel ids the guest gate currently marks visible.
    func guestVisibleChannelIds(_ channelIds: [String]) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(channelIds.filter { storage.guestVisibleChannels[$0] == true })
    }

    /// One locked snapshot for the viewer-filtered `sync:resume` replay.
    func channelReadSnapshot() -> ChannelReadSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ChannelReadSnapshot(
            channels: storage.postableChannels,
            guestVisibleChannels: storage.guestVisibleChannels
        )
    }

    /// `channel:<id>` plus every child thread room, in one critical section.
    func channelRoomIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var rooms = ["channel:\(channelId)"]
        for (id, channel) in storage.postableChannels
        where channel.kind == "thread" && channel.parentChannelId == channelId {
            rooms.append("channel:\(id)")
        }
        return rooms
    }

    /// Cascade of a departed server member over the channel rows this store
    /// owns: every channel loses the member, and thread keys hanging off a
    /// private/DM parent are returned in the same critical section for the
    /// thread-follow store to delete.
    struct MembershipRevocation {
        let channelIds: [String]
        let threadKeys: [String]
    }

    func revokeMembership(serverId: String, userId: String) -> MembershipRevocation {
        lock.lock()
        defer { lock.unlock() }
        let channels = storage.postableChannels
        var channelIds: [String] = []
        var threadKeys: [String] = []
        for (id, channel) in channels where channel.serverId == serverId {
            channelIds.append(id)
            storage.postableChannels[id]?.memberIds.remove(userId)
            // Mirrors `removeMember`: only follows hanging off a private/DM
            // parent die with the server membership; public-parent follows
            // survive so the thread stays in Activity after a rejoin.
            guard channel.kind == "thread",
                  let parentId = channel.parentChannelId,
                  let parent = channels[parentId],
                  parent.kind == "private" || parent.kind == "dm"
            else { continue }
            threadKeys.append("\(serverId)\n\(userId)\n\(id)")
        }
        return MembershipRevocation(channelIds: channelIds, threadKeys: threadKeys)
    }

    // MARK: - Action-card thread carriers

    /// The `dm` channel between one agent and one human, in one critical
    /// section. Dictionary order is the legacy first-match order.
    func actionCardDMChannel(agentId: String, peerId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels.first { _, channel in
            channel.kind == "dm"
                && channel.memberIds.contains(agentId)
                && channel.memberIds.contains(peerId)
        }?.key
    }

    /// The thread under `parentChannelId` whose parent message is exactly
    /// `parentMessageId`, in one critical section.
    func actionCardThreadChannel(parentChannelId: String, parentMessageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels.first { _, channel in
            channel.kind == "thread"
                && channel.parentChannelId == parentChannelId
                && channel.parentMessageId == parentMessageId
        }?.key
    }

    /// Whether a live channel or private channel already uses `name` on the
    /// server, in one critical section.
    func isDuplicateActionCardChannelName(serverId: String, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels.values.contains {
            $0.serverId == serverId && $0.name == name && $0.deletedAt == nil
                && ($0.kind == "channel" || $0.kind == "private")
        }
    }

    /// Finds or creates the reply thread under `storageChannelId` for the
    /// action-card message, plus one projection thread per Joint link, all in
    /// one critical section.
    ///
    /// The thread ids come from `createThread` (the OAuth ledger owns the
    /// channel record) while this store's lock is held, so two concurrent
    /// executes cannot create two canonical threads for the same card. Returns
    /// the canonical thread id, or `nil` when the storage channel disappeared.
    func findOrCreateActionCardReplyThread(
        storageChannelId: String,
        messageId: String,
        requesterAgentId: String,
        confirmerUserId: String,
        fallbackServerId: String,
        createThread: (String, String) -> String
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let storageServerId = storage.postableChannels[storageChannelId]?.serverId ?? fallbackServerId
        var canonicalThread = storage.postableChannels.first { _, channel in
            channel.kind == "thread"
                && channel.parentChannelId == storageChannelId
                && channel.parentMessageId == messageId
        }?.key
        if canonicalThread == nil {
            let threadId = createThread(storageChannelId, messageId)
            var thread = storage.postableChannels[threadId]
                ?? PostableChannel(serverId: storageServerId, memberIds: [])
            thread.serverId = storageServerId
            thread.kind = "thread"
            thread.parentChannelId = storageChannelId
            thread.parentMessageId = messageId
            thread.name = "thread"
            thread.memberIds.insert(requesterAgentId)
            thread.memberIds.insert(confirmerUserId)
            if let parentMembers = storage.postableChannels[storageChannelId]?.memberIds {
                thread.memberIds.formUnion(parentMembers)
            }
            storage.postableChannels[threadId] = thread
            canonicalThread = threadId
        }
        guard let threadId = canonicalThread else { return nil }
        // Give each Joint projection its own thread row pointing at the
        // canonical thread, so either human surface can read the reply. The
        // legacy loop appended to `jointProjections` while iterating the same
        // array value; `for` captures the original slice, so the new links are
        // not revisited.
        for link in storage.jointProjections where link.canonicalChannelId == storageChannelId {
            let existing = storage.postableChannels.first { _, channel in
                channel.kind == "thread"
                    && channel.parentChannelId == link.localChannelId
                    && channel.parentMessageId == messageId
            }?.key
            let localThreadId: String
            if let existing {
                localThreadId = existing
            } else {
                let created = createThread(link.localChannelId, messageId)
                var thread = storage.postableChannels[created]
                    ?? PostableChannel(serverId: link.serverId, memberIds: [])
                thread.serverId = link.serverId
                thread.kind = "thread"
                thread.parentChannelId = link.localChannelId
                thread.parentMessageId = messageId
                thread.name = "thread"
                thread.memberIds.insert(requesterAgentId)
                thread.memberIds.insert(confirmerUserId)
                if let parentMembers = storage.postableChannels[link.localChannelId]?.memberIds {
                    thread.memberIds.formUnion(parentMembers)
                }
                storage.postableChannels[created] = thread
                storage.jointProjections.append(JointChannelLink(
                    localChannelId: created,
                    canonicalChannelId: threadId,
                    serverId: link.serverId
                ))
                localThreadId = created
            }
            if localThreadId != threadId {
                storage.postableChannels[localThreadId]?.memberIds.insert(requesterAgentId)
                storage.postableChannels[localThreadId]?.memberIds.insert(confirmerUserId)
            }
        }
        return threadId
    }

    // MARK: - Agent send delivery channel resolution

    /// The live channel a `#name` send target resolves to, in one critical
    /// section. Dictionary order is the legacy first-match order.
    func postableChannel(serverId: String, name: String) -> (id: String, channel: PostableChannel)? {
        lock.lock()
        defer { lock.unlock() }
        for (id, channel) in storage.postableChannels
        where channel.serverId == serverId && channel.name == name && channel.deletedAt == nil {
            return (id, channel)
        }
        return nil
    }

    /// The live thread under `parentChannelId` whose parent message text starts
    /// with `shortId`, in one critical section.
    func threadChannel(
        serverId: String,
        parentChannelId: String,
        shortId: String
    ) -> (id: String, channel: PostableChannel)? {
        lock.lock()
        defer { lock.unlock() }
        for (id, channel) in storage.postableChannels
        where channel.serverId == serverId
            && channel.kind == "thread"
            && channel.parentChannelId == parentChannelId
            && (channel.parentMessageId?.hasPrefix(shortId) ?? false)
            && channel.deletedAt == nil {
            return (id, channel)
        }
        return nil
    }

    /// A thread reference that does not filter server or deletion, matching the
    /// legacy `threads/unfollow` `#name:short` lookup.
    func threadChannel(parentChannelId: String, shortId: String) -> (id: String, channel: PostableChannel)? {
        lock.lock()
        defer { lock.unlock() }
        for (id, channel) in storage.postableChannels
        where channel.kind == "thread"
            && channel.parentChannelId == parentChannelId
            && (channel.parentMessageId?.hasPrefix(shortId) ?? false) {
            return (id, channel)
        }
        return nil
    }

    /// One channel row by id, in one critical section.
    func postableChannel(id: String) -> PostableChannel? {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels[id]
    }

    /// Channels, joint links and thread slices for the delivery-ack read in
    /// one locked snapshot instead of one lock per lookup.
    struct DeliveryAckChannelSnapshot {
        let channels: [String: PostableChannel]
        let jointProjections: [JointChannelLink]
    }

    func deliveryAckChannelSnapshot() -> DeliveryAckChannelSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DeliveryAckChannelSnapshot(
            channels: storage.postableChannels,
            jointProjections: storage.jointProjections
        )
    }

    /// The legacy `threads/unfollow` parent lookup ignores `deletedAt`; this is
    /// the same first-match order without the live filter.
    func postableChannelIncludingDeleted(serverId: String, name: String) -> (id: String, channel: PostableChannel)? {
        lock.lock()
        defer { lock.unlock() }
        for (id, channel) in storage.postableChannels
        where channel.serverId == serverId && channel.name == name {
            return (id, channel)
        }
        return nil
    }

    // MARK: - Join links, email invites and server setup

    /// One pending email invite. `tokenHash` is nil until an acceptance token
    /// is minted (tests poke it through the TestSupport seam).
    struct ServerInviteRow: Sendable, Equatable {
        var id: String
        var serverId: String
        var email: String
        var role: String
        var tokenHash: String?
    }

    /// Outcome of one join-link acceptance decision and write. The decision
    /// (validity, seat limit, agreement) and the use-count increment happen in
    /// the same critical section, so two concurrent requests cannot both spend
    /// the last use.
    enum JoinLinkAcceptance: Sendable, Equatable {
        case invalid
        case seatLimit(String)
        case agreementRequired(ServerAgreementDTO)
        case agreementChanged(ServerAgreementDTO)
        case accepted(serverId: String, role: String)
    }

    /// Outcome of one email-invite acceptance. The invite removal and the
    /// agreement audit write are part of the same critical section as the
    /// decision.
    enum ServerInviteAcceptance: Sendable, Equatable {
        case invalid
        case seatLimit(String)
        case agreementRequired(ServerAgreementDTO)
        case agreementChanged(ServerAgreementDTO)
        case accepted(serverId: String, role: String)
    }

    func setSeats(serverId: String, seats: Int) {
        lock.lock()
        storage.proSeats[serverId] = seats
        lock.unlock()
    }

    func insertJoinLink(_ link: JoinLinkRecord) {
        lock.lock()
        storage.joinLinks[link.token] = link
        lock.unlock()
    }

    func joinLink(token: String) -> JoinLinkRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.joinLinks[token.lowercased()]
    }

    /// Unexpired, unrevoked, not-yet-exhausted links for one server, newest
    /// first.
    func activeJoinLinks(serverId: String, now: Date) -> [JoinLinkRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.joinLinks.values
            .filter { $0.serverId == serverId && $0.revokedAt == nil }
            .filter { !Self.joinLinkExpired($0, now: now) && !Self.joinLinkExhausted($0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func revokeJoinLink(id: String, serverId: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard let key = storage.joinLinks.first(where: { $0.value.id == id && $0.value.serverId == serverId })?.key
        else { return }
        storage.joinLinks[key]?.revokedAt = now
    }

    /// Decides and spends one join-link use under a single lock. The two
    /// closures read the OAuth ledger (seat holders and the active agreement)
    /// while this store lock is held, which is the same order the retired
    /// directory lock used: directory -> OAuth ledger.
    func acceptJoinLink(
        token: String,
        userId: String,
        requestedAgreementId: String?,
        now: Date,
        usedSeats: @Sendable (String) -> Int,
        activeAgreement: @Sendable (String) -> ServerAgreementDTO?
    ) -> JoinLinkAcceptance {
        lock.lock()
        defer { lock.unlock() }
        guard let link = storage.joinLinks[token.lowercased()],
              link.revokedAt == nil,
              !Self.joinLinkExpired(link, now: now),
              !Self.joinLinkExhausted(link)
        else { return .invalid }
        if let message = seatLimitMessageLocked(serverId: link.serverId, usedSeats: usedSeats) {
            return .seatLimit(message)
        }
        if let agreement = activeAgreement(link.serverId) {
            guard let requested = requestedAgreementId else {
                return .agreementRequired(agreement)
            }
            guard requested == agreement.id else {
                return .agreementChanged(agreement)
            }
            storage.membershipAgreementAudits.append((
                serverId: link.serverId,
                subjectId: userId,
                actorUserId: userId,
                source: "invite",
                agreementId: agreement.id,
                agreementVersion: agreement.version
            ))
        }
        storage.joinLinks[token.lowercased()]?.useCount += 1
        return .accepted(serverId: link.serverId, role: link.role)
    }

    /// The published seat-limit message, or nil when the server has no seat cap
    /// or still has room. One critical section for the cap and the caller's
    /// holder count.
    func seatLimitMessage(
        serverId: String,
        usedSeats: @Sendable (String) -> Int
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return seatLimitMessageLocked(serverId: serverId, usedSeats: usedSeats)
    }

    private func seatLimitMessageLocked(
        serverId: String,
        usedSeats: @Sendable (String) -> Int
    ) -> String? {
        guard let seats = storage.proSeats[serverId] else { return nil }
        let used = usedSeats(serverId)
        guard used >= seats else { return nil }
        return "Seat limit reached (\(used)/\(seats) on Pro plan)"
    }

    func insertServerInvite(id: String, serverId: String, email: String, role: String) {
        lock.lock()
        storage.serverInvites.append((
            id: id,
            serverId: serverId,
            email: email,
            role: role,
            tokenHash: nil
        ))
        lock.unlock()
    }

    func inviteRecord(tokenHash: String) -> ServerInviteRow? {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverInvites
            .first { $0.tokenHash == tokenHash }
            .map { ServerInviteRow(id: $0.id, serverId: $0.serverId, email: $0.email, role: $0.role, tokenHash: $0.tokenHash) }
    }

    func serverInviteRows(serverId: String) -> [ServerInviteRow] {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverInvites
            .filter { $0.serverId == serverId }
            .map { ServerInviteRow(id: $0.id, serverId: $0.serverId, email: $0.email, role: $0.role, tokenHash: $0.tokenHash) }
    }

    func setInviteTokenHash(id: String, tokenHash: String) {
        lock.lock()
        if let index = storage.serverInvites.firstIndex(where: { $0.id == id }) {
            storage.serverInvites[index].tokenHash = tokenHash
        }
        lock.unlock()
    }

    func removeServerInvite(id: String, serverId: String) {
        lock.lock()
        storage.serverInvites.removeAll { $0.id == id && $0.serverId == serverId }
        lock.unlock()
    }

    /// Decides and spends one email invite under a single lock: the invite
    /// match, the address check, the seat limit, the agreement audit and the
    /// removal all happen before the caller writes the membership.
    func acceptServerInvite(
        tokenHash: String,
        userEmail: String,
        userId: String,
        requestedAgreementId: String?,
        usedSeats: @Sendable (String) -> Int,
        activeAgreement: @Sendable (String) -> ServerAgreementDTO?
    ) -> ServerInviteAcceptance {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.serverInvites.firstIndex(where: { $0.tokenHash == tokenHash })
        else { return .invalid }
        let invite = storage.serverInvites[index]
        guard userEmail == invite.email.lowercased() else { return .invalid }
        if let message = seatLimitMessageLocked(serverId: invite.serverId, usedSeats: usedSeats) {
            return .seatLimit(message)
        }
        if let agreement = activeAgreement(invite.serverId) {
            guard let requested = requestedAgreementId else {
                return .agreementRequired(agreement)
            }
            guard requested == agreement.id else {
                return .agreementChanged(agreement)
            }
            storage.membershipAgreementAudits.append((
                serverId: invite.serverId,
                subjectId: userId,
                actorUserId: userId,
                source: "invite",
                agreementId: agreement.id,
                agreementVersion: agreement.version
            ))
        }
        storage.serverInvites.remove(at: index)
        return .accepted(serverId: invite.serverId, role: invite.role)
    }

    func isGuestRoleEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.guestRoleServers.contains(serverId)
    }

    func enableGuestRole(serverId: String) {
        lock.lock()
        storage.guestRoleServers.insert(serverId)
        lock.unlock()
    }

    func hideHumans(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.hideHumansFromMembers[serverId] == true
    }

    func setupPhase(serverId: String, userId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage.setupPhases["\(serverId)\n\(userId)"] ?? "not_started"
    }

    /// Writes one setup phase and returns the new value in the same critical
    /// section, so the transition reply cannot observe a torn state.
    func setSetupPhase(serverId: String, userId: String, phase: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        storage.setupPhases["\(serverId)\n\(userId)"] = phase
        return phase
    }

    /// Clears every setup phase and the handoff marker for one server in one
    /// critical section.
    func clearSetupState(serverId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.setupPhases = storage.setupPhases.filter { !$0.key.hasPrefix("\(serverId)\n") }
        storage.setupHandoffs.remove(serverId)
    }

    func setSetupHandoff(serverId: String) {
        lock.lock()
        storage.setupHandoffs.insert(serverId)
        lock.unlock()
    }

    func appendServerMemberEvent(
        serverId: String,
        eventType: String,
        subjectType: String,
        subjectId: String,
        provenanceJSON: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId,
            eventType: eventType,
            subjectType: subjectType,
            subjectId: subjectId,
            provenanceJSON: provenanceJSON,
            deliveryQueued: true
        ))
    }

    /// The member-leaves write: status row, removed-member marker and the
    /// queued member event are one critical section.
    func markMemberLeft(serverId: String, userId: String, provenanceJSON: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberStatuses["\(serverId)\n\(userId)"] = "left"
        storage.removedServerMembers.insert("\(serverId)\n\(userId)")
        storage.serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId,
            eventType: "server.member_removed",
            subjectType: "member",
            subjectId: userId,
            provenanceJSON: provenanceJSON,
            deliveryQueued: true
        ))
    }

    /// The soft-delete decision and write are one critical section.
    ///
    /// `DELETE /api/channels/:channelId` used to read the row, check the role
    /// and write `deletedAt` under the directory lock. `memberRole` is fetched
    /// by the service before this call because it lives in the OAuth ledger,
    /// not in this store; everything that depends on the channel row stays in
    /// this one locked value.
    func softDeleteChannel(
        channelId: String,
        serverId: String?,
        userId: String,
        memberRole: String?,
        now: Date
    ) -> SoftDeleteChannelOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var channel = storage.postableChannels[channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return .notFound }
        if let memberRole {
            guard memberRole == "owner" || memberRole == "admin" else { return .forbidden }
        } else if !channel.memberIds.contains(userId) {
            return .forbidden
        }
        channel.deletedAt = now
        storage.postableChannels[channelId] = channel
        return .deleted
    }

    /// Records a channel the owner can post in. Resource-reference checks run
    /// only after this membership is visible.
    func addPostableChannel(
        serverId: String,
        channelId: String,
        memberId: String,
        kind: String = "channel",
        parentChannelId: String? = nil,
        parentMessageId: String? = nil,
        name: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        var channel = storage.postableChannels[channelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        if channel.kind == "channel" || kind != "channel" {
            channel.kind = kind
        }
        if let parentChannelId {
            channel.parentChannelId = parentChannelId
        }
        if let parentMessageId {
            channel.parentMessageId = parentMessageId
        }
        if let name {
            channel.name = name
        }
        storage.postableChannels[channelId] = channel
    }

    /// Server role used by the hidden human directory. Only `member` is hidden
    /// on #all.
    func setServerMemberRole(serverId: String, userId: String, role: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberRoles["\(serverId)\n\(userId)"] = role
    }

    func setHideHumansFromMembers(serverId: String, hidden: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.hideHumansFromMembers[serverId] = hidden
    }

    /// Links a server's local joint channel to the canonical channel that
    /// stores the messages.
    func addJointChannelProjection(localChannelId: String, canonicalChannelId: String, serverId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.jointProjections.append(JointChannelLink(
            localChannelId: localChannelId,
            canonicalChannelId: canonicalChannelId,
            serverId: serverId
        ))
    }

    /// A thread whose messages hang off one parent message. Context short links
    /// on the parent channel can land here.
    func addThreadChannel(
        serverId: String,
        threadChannelId: String,
        parentChannelId: String,
        parentMessageId: String,
        memberId: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        var channel = storage.postableChannels[threadChannelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        channel.kind = "thread"
        channel.parentChannelId = parentChannelId
        channel.parentMessageId = parentMessageId
        storage.postableChannels[threadChannelId] = channel
    }

    /// A user-to-user DM. Only the two participants may be notified by a
    /// mention.
    func addDirectMessage(serverId: String, channelId: String, participantIds: [String], agentId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId] = PostableChannel(
            serverId: serverId,
            memberIds: Set(participantIds),
            kind: "dm",
            agentId: agentId
        )
    }


    // MARK: - Sidebar order

    /// One sidebar sort-mode row.
    struct SidebarModesRow: Sendable, Equatable {
        var channel: String
        var joint: String
        var dm: String
        var pinned: String
        var channelTabs: [String]
        var agentTabs: [String]

        static let defaults = SidebarModesRow(
            channel: "manual",
            joint: "manual",
            dm: "manual",
            pinned: "manual",
            channelTabs: ["chat"],
            agentTabs: ["activity", "profile"]
        )
    }

    struct SidebarSectionRow: Sendable, Equatable {
        var id: String
        var name: String
        var emoji: String?
        var sortMode: String
    }

    struct SidebarPlacementRow: Sendable, Equatable {
        var kind: String
        var id: String
        var sectionId: String
        var position: Int
    }

    struct SidebarSectionsRow: Sendable, Equatable {
        var sections: [SidebarSectionRow]
        var order: [String]
        var placements: [SidebarPlacementRow]
        var version: Int

        /// The retired handler's first-read default: no custom sections and the
        /// four system sections in their published order.
        static let defaults = SidebarSectionsRow(
            sections: [],
            order: ["system:pinned", "system:joint", "system:channels", "system:dms"],
            placements: [],
            version: 0
        )
    }

    struct SidebarPinRow: Sendable, Equatable {
        var kind: String
        var id: String
    }

    struct SidebarPinnedRow: Sendable, Equatable {
        var refs: [SidebarPinRow]
        var channelIds: [String]
        var agentIds: [String]
        var version: Int
    }

    /// The three sidebar rows one request reads; `pinned` is nil when the
    /// caller has never written the pinned ledger.
    struct SidebarSnapshot: Sendable, Equatable {
        var modes: SidebarModesRow
        var sections: SidebarSectionsRow
        var pinned: SidebarPinnedRow?
    }

    enum SidebarApplyResult: Sendable, Equatable {
        case applied
        case sectionsConflict(currentVersion: Int)
    }

    /// One locked read of the three sidebar rows the legacy handler read under
    /// the directory lock.
    func sidebarSnapshot(serverId: String, userId: String) -> SidebarSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(serverId)\n\(userId)"
        let modes = storage.sidebarModes[key].map {
            SidebarModesRow(
                channel: $0.channel,
                joint: $0.joint,
                dm: $0.dm,
                pinned: $0.pinned,
                channelTabs: $0.channelTabs,
                agentTabs: $0.agentTabs
            )
        } ?? .defaults
        let sections = storage.sidebarSections[key].map {
            SidebarSectionsRow(
                sections: $0.sections.map {
                    SidebarSectionRow(id: $0.id, name: $0.name, emoji: $0.emoji, sortMode: $0.sortMode)
                },
                order: $0.order,
                placements: $0.placements.map {
                    SidebarPlacementRow(kind: $0.kind, id: $0.id, sectionId: $0.sectionId, position: $0.position)
                },
                version: $0.version
            )
        } ?? .defaults
        let pinned = storage.sidebarPinnedRefs[key].map {
            SidebarPinnedRow(
                refs: $0.refs.map { SidebarPinRow(kind: $0.kind, id: $0.id) },
                channelIds: $0.channelIds,
                agentIds: $0.agentIds,
                version: $0.version
            )
        }
        return SidebarSnapshot(modes: modes, sections: sections, pinned: pinned)
    }

    /// The sidebar write: the version check and every row write happen in one
    /// critical section, so two concurrent patches cannot both accept the same
    /// `sectionsVersion`.
    func applySidebarOrder(
        serverId: String,
        userId: String,
        modes: SidebarModesRow,
        sections: SidebarSectionsRow?,
        pinned: SidebarPinnedRow?,
        expectedSectionsVersion: Int?
    ) -> SidebarApplyResult {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(serverId)\n\(userId)"
        if let expectedSectionsVersion {
            let current = storage.sidebarSections[key]?.version ?? 0
            guard current == expectedSectionsVersion else {
                return .sectionsConflict(currentVersion: current)
            }
        }
        storage.sidebarModes[key] = (
            channel: modes.channel,
            joint: modes.joint,
            dm: modes.dm,
            pinned: modes.pinned,
            channelTabs: modes.channelTabs,
            agentTabs: modes.agentTabs
        )
        if let sections {
            storage.sidebarSections[key] = (
                sections: sections.sections.map { ($0.id, $0.name, $0.emoji, $0.sortMode) },
                order: sections.order,
                placements: sections.placements.map { ($0.kind, $0.id, $0.sectionId, $0.position) },
                version: sections.version
            )
        }
        if let pinned {
            storage.sidebarPinnedRefs[key] = (
                refs: pinned.refs.map { ($0.kind, $0.id) },
                channelIds: pinned.channelIds,
                agentIds: pinned.agentIds,
                version: pinned.version
            )
        }
        return .applied
    }

    /// The channel ids that still have a live row, in the caller's order. A
    /// missing row survives, exactly as the legacy
    /// `postableChannels[id]?.deletedAt == nil` filter did.
    func liveChannelIds(_ channelIds: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return channelIds.filter { storage.postableChannels[$0]?.deletedAt == nil }
    }

    /// Whether a channel row exists and is not soft-deleted.
    func liveChannelExists(_ channelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels[channelId] != nil && storage.postableChannels[channelId]?.deletedAt == nil
    }

    // MARK: - Server labs

    /// One locked read of a server's lab state, defaulted like the retired
    /// handler's `serverLabsState[serverId] ?? ServerLabsState()`.
    func serverLabs(serverId: String) -> ServerLabsState {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverLabsState[serverId] ?? ServerLabsState()
    }

    enum LabsApplyResult: Sendable, Equatable {
        case applied(state: ServerLabsState, changed: Bool)
        case versionConflict(currentVersion: Int)
    }

    enum LabEnrollmentApplyResult: Sendable, Equatable {
        case applied(state: ServerLabsState, changed: Bool)
        case versionConflict(currentVersion: Int)
        case accessDisabled
        case labNotOpen
    }

    /// The master-switch decision: expected-version check, toggle and version
    /// bump in one critical section.
    func applyLabsAccess(serverId: String, enabled: Bool, expectedVersion: Int) -> LabsApplyResult {
        lock.lock()
        defer { lock.unlock() }
        var state = storage.serverLabsState[serverId] ?? ServerLabsState()
        guard expectedVersion == state.version else {
            return .versionConflict(currentVersion: state.version)
        }
        let changed = state.accessEnabled != enabled
        if changed {
            state.accessEnabled = enabled
            state.version += 1
        }
        storage.serverLabsState[serverId] = state
        return .applied(state: state, changed: changed)
    }

    /// The enrollment decision: expected-version, master switch, lab state and
    /// the enrollment write in one critical section, in the published order.
    func applyLabEnrollment(
        serverId: String,
        labKey: String,
        enabled: Bool,
        expectedVersion: Int,
        labOpen: Bool,
        now: Date
    ) -> LabEnrollmentApplyResult {
        lock.lock()
        defer { lock.unlock() }
        var state = storage.serverLabsState[serverId] ?? ServerLabsState()
        guard expectedVersion == state.version else {
            return .versionConflict(currentVersion: state.version)
        }
        guard state.accessEnabled else { return .accessDisabled }
        guard labOpen else { return .labNotOpen }
        let enrolled = state.enrolled.contains(labKey)
        let changed = enrolled != enabled
        if changed {
            if enabled {
                state.enrolled.insert(labKey)
                state.updatedAt[labKey] = now
            } else {
                state.enrolled.remove(labKey)
            }
            state.version += 1
        }
        storage.serverLabsState[serverId] = state
        return .applied(state: state, changed: changed)
    }

    // MARK: - Server member removal

    /// The member-removal write: status row, removed-member marker and the
    /// queued event are one critical section, matching the one directory lock
    /// the retired handler held across them.
    func markMemberRemoved(serverId: String, userId: String, provenanceJSON: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberStatuses["\(serverId)\n\(userId)"] = "removed"
        storage.removedServerMembers.insert("\(serverId)\n\(userId)")
        storage.serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId,
            eventType: "server.member_removed",
            subjectType: "member",
            subjectId: userId,
            provenanceJSON: provenanceJSON,
            deliveryQueued: true
        ))
    }

    /// Queues the member-removed events for a whole server deletion in one
    /// critical section.
    func appendServerMemberEvents(_ events: [ServerMemberEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberEvents.append(contentsOf: events)
    }

    func isServerDeleted(_ serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.deletedServerIds.contains(serverId)
    }

    func markServerDeleted(_ serverId: String) {
        lock.lock()
        storage.deletedServerIds.insert(serverId)
        lock.unlock()
    }

    /// The migration receipt DM: one agent-only direct channel named
    /// `name` whose member set is exactly `memberId`, in one critical section.
    func directChannelId(name: String, memberId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels.first {
            $0.value.kind == "dm" && $0.value.name == name && $0.value.memberIds == [memberId]
        }?.key
    }

    // MARK: - Server switcher order

    /// The caller's stored switcher order intersected with their live
    /// memberships, plus the version. `memberIds` runs inside the critical
    /// section so the order and the membership it is sanitized against are one
    /// read.
    func serverOrder(userId: String, memberIds: () -> [String]) -> (ids: [String], version: Int) {
        lock.lock()
        defer { lock.unlock() }
        let members = Set(memberIds())
        let ordered = Self.sanitizedServerOrder(
            stored: storage.serverSwitcherOrders[userId]?.ids ?? [],
            requested: nil,
            memberIds: members
        )
        return (ordered, storage.serverSwitcherOrders[userId]?.version ?? 0)
    }

    /// Replaces the caller's switcher order. The version moves only when the
    /// sanitized list differs from the stored one; comparing, bumping and
    /// storing are one critical section, so two concurrent patches cannot both
    /// read the same version.
    func updateServerOrder(
        userId: String,
        requested: [String],
        memberIds: () -> [String]
    ) -> (ids: [String], version: Int) {
        lock.lock()
        defer { lock.unlock() }
        let members = Set(memberIds())
        let stored = storage.serverSwitcherOrders[userId]
        let current = stored?.ids ?? Self.sanitizedServerOrder(stored: [], requested: nil, memberIds: members)
        let ordered = Self.sanitizedServerOrder(stored: stored?.ids ?? [], requested: requested, memberIds: members)
        var version = stored?.version ?? 0
        if ordered != current {
            version += 1
        }
        storage.serverSwitcherOrders[userId] = (ordered, version)
        return (ordered, version)
    }

    /// Requested (or stored) ids the caller still belongs to, de-duplicated in
    /// order, then every remaining membership in sorted order.
    private static func sanitizedServerOrder(
        stored: [String],
        requested: [String]?,
        memberIds: Set<String>
    ) -> [String] {
        let base = requested ?? stored
        var seen = Set<String>()
        var ordered: [String] = []
        for id in base where memberIds.contains(id) && !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        for id in memberIds.sorted() where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    // MARK: - Server profile reads and writes

    /// Whether the composer resource references (and therefore the apps list)
    /// are enabled for the server.
    func isComposerResourceEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.composerResourceServers.contains(serverId)
    }

    /// Applies the optional human-directory flag and returns the value the
    /// server now has, in one critical section.
    func updateHideHumans(serverId: String, hidden: Bool?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let hidden {
            storage.hideHumansFromMembers[serverId] = hidden
        }
        return storage.hideHumansFromMembers[serverId] == true
    }

    /// Whether the member was removed from the server (and not re-added).
    func isMemberRemoved(serverId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.removedServerMembers.contains("\(serverId)\n\(userId)")
    }

    /// The local channel an active joint projection of `canonicalChannelId`
    /// publishes inside `serverId`.
    func activeJointLocalChannelId(canonicalChannelId: String, serverId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.jointProjections.first {
            $0.canonicalChannelId == canonicalChannelId
                && $0.serverId == serverId
                && $0.status == "active"
        }?.localChannelId
    }

    private static func joinLinkExpired(_ link: JoinLinkRecord, now: Date) -> Bool {
        if let expiresAt = link.expiresAt, expiresAt <= now { return true }
        return false
    }

    private static func joinLinkExhausted(_ link: JoinLinkRecord) -> Bool {
        if let maxUses = link.maxUses, link.useCount >= maxUses { return true }
        return false
    }

    // MARK: - Onboarding settings

    /// One server row plus one member row, read together.
    struct OnboardingSnapshot {
        let agentId: String?
        let greeting: Bool
        let user: UserOnboarding
    }

    /// What `PATCH .../onboarding-settings` writes. `serverChange` is applied
    /// only for an owner or admin; the member row is always written.
    struct OnboardingPatch {
        enum Change<Value: Sendable>: Sendable {
            case keep
            case set(Value)
            case clear
        }

        var isAdmin: Bool
        var agentId: Change<String> = .keep
        var greeting: Bool? = nil
        var reminderOptOut: Bool? = nil
        var currentStep: Change<String> = .keep
        /// Wizard step names whose dismissal timestamp is stamped when unset.
        var dismissedSteps: [String] = []
    }

    /// The server and member onboarding rows read in one critical section.
    func onboardingSnapshot(serverId: String, userId: String) -> OnboardingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let server = storage.serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
        let user = storage.userOnboardingSettings["\(serverId)\n\(userId)"] ?? UserOnboarding()
        return OnboardingSnapshot(agentId: server.agentId, greeting: server.greeting, user: user)
    }

    /// Makes `agentId` the server's onboarding agent. The greeting flag is kept
    /// (it defaults on), so the read and the write are one critical section.
    func bindOnboardingAgent(serverId: String, agentId: String) {
        lock.lock()
        defer { lock.unlock() }
        let greeting = storage.serverOnboardingSettings[serverId]?.greeting ?? true
        storage.serverOnboardingSettings[serverId] = (agentId: agentId, greeting: greeting)
    }

    /// The whole onboarding patch as one critical section: the server row (for
    /// an admin) and the member row are read, updated and written together,
    /// and the stored result is returned so the reply reflects exactly it.
    func applyOnboardingPatch(
        serverId: String,
        userId: String,
        patch: OnboardingPatch,
        now: Date
    ) -> OnboardingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var server = storage.serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
        if patch.isAdmin {
            switch patch.agentId {
            case .keep: break
            case .clear: server.agentId = nil
            case .set(let agentId): server.agentId = agentId
            }
            if let greeting = patch.greeting {
                server.greeting = greeting
            }
            storage.serverOnboardingSettings[serverId] = server
        }
        let key = "\(serverId)\n\(userId)"
        var user = storage.userOnboardingSettings[key] ?? UserOnboarding()
        if let optOut = patch.reminderOptOut {
            user.reminderOptOut = optOut
        }
        switch patch.currentStep {
        case .keep: break
        case .clear: user.currentStep = nil
        case .set(let step): user.currentStep = step
        }
        for step in patch.dismissedSteps where user.dismissed[step] == nil {
            user.dismissed[step] = now
        }
        storage.userOnboardingSettings[key] = user
        return OnboardingSnapshot(agentId: server.agentId, greeting: server.greeting, user: user)
    }
}

/// The decision `DELETE /api/channels/:channelId` makes while holding the
/// channel store lock. The channel row is written in the same critical
/// section as the decision.
enum SoftDeleteChannelOutcome: Sendable, Equatable {
    case deleted
    case notFound
    case forbidden
}

// MARK: - Channel archive, membership and agent channel management

extension ServersAndChannelsStore {
    /// The two facts the archive route reads before it decides: whether the
    /// caller is a channel admin and whether the channel is a joint projection.
    func archivePolicy(channelId: String, userId: String) -> (channelAdmin: Bool, jointArchive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            storage.channelHumanRoles["\(channelId)\n\(userId)"] == "admin",
            storage.jointProjections.contains { $0.localChannelId == channelId }
        )
    }

    /// Marks one channel and every thread under it archived (or not) in one
    /// critical section.
    func setArchived(channelId: String, archived: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.archived = archived
        for (id, var postable) in storage.postableChannels where postable.parentChannelId == channelId {
            postable.archived = archived
            storage.postableChannels[id] = postable
        }
    }

    /// The archive flag of exactly one projection (no thread cascade).
    func setArchivedFlag(channelId: String, archived: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.archived = archived
    }

    func setPostableName(channelId: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.name = name
    }

    /// The final name/kind write of a channel update.
    func updatePostable(channelId: String, name: String, kind: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.name = name
        storage.postableChannels[channelId]?.kind = kind
    }

    func isGuestJoinable(channelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.guestJoinableChannels[channelId] ?? false
    }

    /// The local channel ids that share the joint canonical channel of
    /// `channelId` (empty for a non-joint channel), from one snapshot.
    func jointLinkIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let canonical = storage.jointProjections
            .first(where: { $0.localChannelId == channelId })?.canonicalChannelId
        else { return [] }
        return storage.jointProjections.filter { $0.canonicalChannelId == canonical }.map(\.localChannelId)
    }

    /// Removes one agent from the posting set and answers the channel kind, in
    /// one critical section.
    func removeAgentMember(channelId: String, agentId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.memberIds.remove(agentId)
        return storage.postableChannels[channelId]?.kind ?? "channel"
    }

    func markChannelDeleted(channelId: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.deletedAt = now
    }

    func removeMember(channelId: String, memberId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.memberIds.remove(memberId)
    }

    /// Adds one human to the posting set, creating the row when the channel has
    /// none.
    func insertMember(channelId: String, serverId: String, userId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId, default: PostableChannel(serverId: serverId, memberIds: [])]
            .memberIds.insert(userId)
    }

    /// Replaces the posting row of a freshly created channel.
    func insertCreatedChannel(channelId: String, serverId: String, kind: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId] = PostableChannel(
            serverId: serverId, memberIds: [], kind: kind, name: name
        )
    }
}

// MARK: - Managed MCP lifecycle: channel and joint-invite sections

/// One joint invite row, copied out of the ledger.
struct JointInviteSnapshot: Sendable, Equatable {
    let id: String
    let hostServerId: String
    let hostChannelId: String
    let targetServerId: String
    let targetChannelId: String
    let targetOwnerId: String
    let status: String
}

/// What changing a channel's visibility left behind for the follow cleanup.
struct ChannelVisibilityChange: Sendable, Equatable {
    /// The posting members at the moment the kind changed.
    let memberIds: Set<String>
    /// The thread channels whose parent is the changed channel.
    let threadChannelIds: Set<String>
}

/// Per-channel facts the channel list projects, from one snapshot.
struct ChannelListFacts: Sendable {
    let guestVisible: [String: Bool]
    let humanRoles: [String: String]
    let jointLocalChannelIds: Set<String>
}

extension ServersAndChannelsStore {
    /// One channel's human-access facts for a user: whether the posting set or
    /// the kind admits them, from one snapshot.
    func postableMembership(channelId: String, userId: String) -> (isMember: Bool, kind: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = storage.postableChannels[channelId] else { return nil }
        return (channel.memberIds.contains(userId), channel.kind)
    }

    /// Whether the posting row lists `userId` as a member.
    func isPostableMember(channelId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels[channelId]?.memberIds.contains(userId) == true
    }

    /// The facts `GET /api/channels` projects for every row, read once.
    func channelListFacts() -> ChannelListFacts {
        lock.lock()
        defer { lock.unlock() }
        return ChannelListFacts(
            guestVisible: storage.guestVisibleChannels,
            humanRoles: storage.channelHumanRoles,
            jointLocalChannelIds: Set(storage.jointProjections.map(\.localChannelId))
        )
    }

    /// One invite by id.
    func jointInvite(id: String) -> JointInviteSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storage.jointInvites.first { $0.id == id }.map {
            JointInviteSnapshot(
                id: $0.id, hostServerId: $0.hostServerId, hostChannelId: $0.hostChannelId,
                targetServerId: $0.targetServerId, targetChannelId: $0.targetChannelId,
                targetOwnerId: $0.targetOwnerId, status: $0.status
            )
        }
    }

    /// Accepts the invite and admits `userId` to the target channel's posting
    /// set in one critical section; answers the channel name (empty when the
    /// posting row is missing).
    func acceptJointInvite(id: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.jointInvites.firstIndex(where: { $0.id == id }) else { return nil }
        let targetChannelId = storage.jointInvites[index].targetChannelId
        storage.jointInvites[index].status = "accepted"
        storage.postableChannels[targetChannelId]?.memberIds.insert(userId)
        return storage.postableChannels[targetChannelId]?.name ?? ""
    }

    /// Creates the two posting rows, the two joint projections and the pending
    /// invite of a joint channel in one critical section.
    func createJointChannelPair(
        hostServerId: String,
        hostChannelId: String,
        hostUserId: String,
        targetServerId: String,
        targetChannelId: String,
        targetOwnerId: String,
        name: String,
        inviteId: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        storage.jointProjections.append(JointChannelLink(
            localChannelId: hostChannelId, canonicalChannelId: hostChannelId, serverId: hostServerId
        ))
        storage.jointProjections.append(JointChannelLink(
            localChannelId: targetChannelId, canonicalChannelId: hostChannelId, serverId: targetServerId
        ))
        storage.postableChannels[hostChannelId] = PostableChannel(
            serverId: hostServerId, memberIds: [hostUserId], kind: "joint", name: name
        )
        storage.postableChannels[targetChannelId] = PostableChannel(
            serverId: targetServerId, memberIds: [], kind: "joint", name: name
        )
        storage.jointInvites.append((
            inviteId, hostServerId, hostChannelId, targetServerId, targetChannelId, targetOwnerId, "pending"
        ))
    }

    /// An existing live public/private channel of the same name, and whether
    /// `userId` could unarchive it (it is archived and they administer it).
    func channelNameCollision(serverId: String, name: String, userId: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let collision = storage.postableChannels.first { _, channel in
            channel.serverId == serverId && channel.name == name && channel.deletedAt == nil
                && (channel.kind == "channel" || channel.kind == "private")
        }
        guard let collision else { return nil }
        return (collision.value.archived
            && storage.channelHumanRoles["\(collision.key)\n\(userId)"] == "admin")
    }

    /// Records a freshly created public channel with its creator as member.
    func insertOwnedChannel(channelId: String, serverId: String, userId: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId] = PostableChannel(
            serverId: serverId, memberIds: [userId], name: name
        )
    }

    /// Sets the guest visibility/joinability flags that were supplied and
    /// answers both current values, in one critical section.
    func applyGuestFlags(
        channelId: String,
        visible: Bool?,
        joinable: Bool?
    ) -> (visible: Bool, joinable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let visible { storage.guestVisibleChannels[channelId] = visible }
        if let joinable { storage.guestJoinableChannels[channelId] = joinable }
        return (storage.guestVisibleChannels[channelId] ?? false, storage.guestJoinableChannels[channelId] ?? false)
    }

    /// Sets the posting kind and answers the members and child threads the
    /// follow cleanup needs, in one critical section.
    func applyChannelVisibility(channelId: String, kind: String) -> ChannelVisibilityChange {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.kind = kind
        let members = storage.postableChannels[channelId]?.memberIds ?? []
        let threads = Set(storage.postableChannels.filter {
            $0.value.kind == "thread" && $0.value.parentChannelId == channelId
        }.keys)
        return ChannelVisibilityChange(memberIds: members, threadChannelIds: threads)
    }

    /// The acting user's channel role from one snapshot.
    func channelHumanRole(channelId: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.channelHumanRoles["\(channelId)\n\(userId)"]
    }

    /// The posting row's kind, when present.
    func postableKind(channelId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.postableChannels[channelId]?.kind
    }

    /// Thread parent facts for the unread summary, from one snapshot.
    func threadParentSnapshot(channelId: String) -> (kind: String, parentChannelId: String?, parentMessageId: String?, parentDeleted: Bool?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = storage.postableChannels[channelId] else { return nil }
        let parentDeleted: Bool? = channel.parentChannelId.flatMap { parentId in
            storage.postableChannels[parentId].map { $0.deletedAt != nil }
        }
        return (channel.kind, channel.parentChannelId, channel.parentMessageId, parentDeleted)
    }

    /// The posting rows, joint projections and hidden-human flags the agent
    /// channel-membership read consults, from one snapshot.
    func postableAndJointSnapshot() -> (postable: [String: PostableChannel], joint: [JointChannelLink], hideHumans: [String: Bool]) {
        lock.lock()
        defer { lock.unlock() }
        return (storage.postableChannels, storage.jointProjections, storage.hideHumansFromMembers)
    }
}

// MARK: - Human message create: channel membership grant

extension ServersAndChannelsStore {
    /// A claimed `add` mention action makes a human target a channel member.
    func addChannelMember(channelId: String, userId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.postableChannels[channelId]?.memberIds.insert(userId)
    }
}
