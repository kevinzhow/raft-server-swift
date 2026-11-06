import Foundation

extension ServersAndChannelsStore {
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

    private static func joinLinkExpired(_ link: JoinLinkRecord, now: Date) -> Bool {
        if let expiresAt = link.expiresAt, expiresAt <= now { return true }
        return false
    }

    private static func joinLinkExhausted(_ link: JoinLinkRecord) -> Bool {
        if let maxUses = link.maxUses, link.useCount >= maxUses { return true }
        return false
    }
}
