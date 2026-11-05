import RaftHTTP
import RaftRealtime

/// Bridges the in-memory session and channel ledgers onto the realtime server.
struct LedgerRealtimeAuth: RealtimeAuthorizing {
    let accounts: EmailLoginDirectory

    func userId(forAccessToken token: String) -> String? {
        accounts.sessionIdentity(accessToken: token)?.userId
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        accounts.sessionIdentity(accessToken: token)?.familyId
    }

    func serverRole(serverId: String, userId: String) -> String? {
        accounts.oauth.memberRole(serverId: serverId, userId: userId)
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        accounts.realtimeVisibleChannelIds(serverId: serverId, userId: userId)
    }

    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        accounts.realtimeSyncMessagesPayload(
            serverId: serverId,
            userId: userId,
            lastSeq: lastSeq,
            limit: limit
        )
    }
}
