/// The two fixed OAuth leaves a Channels admission transaction may enter.
/// Construction retains the actual owner without caching either fact. The
/// caller keeps its seat decision and later agreement read as separate queries.
struct ServerAdmissionQuery: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    func usedSeats(serverId: String) -> Int {
        oauth.memberIdsWithRoles(serverId: serverId).filter { $0.role != "guest" }.count
    }

    func activeAgreement(serverId: String) -> ServerAgreementDTO? {
        oauth.activeServerAgreement(serverId: serverId).map(ServerAgreementDTO.init)
    }
}
