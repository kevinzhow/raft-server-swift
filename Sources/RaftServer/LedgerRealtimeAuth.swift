import RaftHTTP
import RaftRealtime

/// Bridges the in-memory session and channel ledgers onto the realtime server.
struct LedgerRealtimeAuth: RealtimeAuthorizing {
    let authCore: AuthCoreService
    let membership: SocketMembershipService

    func userId(forAccessToken token: String) -> String? {
        authCore.sessionIdentity(accessToken: token)?.userId
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        authCore.sessionIdentity(accessToken: token)?.familyId
    }

    func serverRole(serverId: String, userId: String) -> String? {
        membership.serverRole(serverId: serverId, userId: userId)
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }

    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        membership.syncMessages(
            serverId: serverId,
            userId: userId,
            lastSeq: lastSeq,
            limit: limit
        )?.jsonBody()
    }
}
