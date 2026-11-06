// Test seams for join links and invites: audits, invite token pokes and the
// seat/guest configuration the route tests used to set through production
// extension helpers.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func membershipAgreementAuditsForTesting(serverId: String, subjectId: String) -> [(
        source: String, actorUserId: String, agreementId: String?, agreementVersion: Int?
    )] {
        lock.lock()
        defer { lock.unlock() }
        return membershipAgreementAudits
            .filter { $0.serverId == serverId && $0.subjectId == subjectId }
            .map { ($0.source, $0.actorUserId, $0.agreementId, $0.agreementVersion) }
    }

    public func joinLinkUseCountForTesting(token: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return joinLinks[token.lowercased()]?.useCount
    }

    public func setServerHideHumansForTesting(serverId: String, hidden: Bool) {
        lock.lock()
        hideHumansFromMembers[serverId] = hidden
        lock.unlock()
    }

    public func setServerInviteTokenForTesting(inviteId: String, token: String) {
        serversAndChannelsStore.setInviteTokenHash(id: inviteId, tokenHash: AuthTokenCodec.sha256(token))
    }

    /// Test-only seat cap. The production route set never writes the Pro seat
    /// count directly; the store owns the row.
    public func setServerSeats(serverId: String, seats: Int) {
        serversAndChannelsStore.setSeats(serverId: serverId, seats: seats)
    }

    /// Test-only guest-role gate. The production route that flips it is owned
    /// by the unmigrated server-settings surface.
    public func enableGuestRoleTransitions(serverId: String) {
        serversAndChannelsStore.enableGuestRole(serverId: serverId)
    }
}
