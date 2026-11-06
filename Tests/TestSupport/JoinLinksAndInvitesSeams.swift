// Test seams for join links and invites: audits and invite token pokes.
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
        lock.lock()
        if let index = serverInvites.firstIndex(where: { $0.id == inviteId }) {
            serverInvites[index].tokenHash = Self.sha256(token)
        }
        lock.unlock()
    }
}
