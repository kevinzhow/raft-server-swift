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

    private static func joinLinkExpired(_ link: JoinLinkRecord, now: Date) -> Bool {
        if let expiresAt = link.expiresAt, expiresAt <= now { return true }
        return false
    }

    private static func joinLinkExhausted(_ link: JoinLinkRecord) -> Bool {
        if let maxUses = link.maxUses, link.useCount >= maxUses { return true }
        return false
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
