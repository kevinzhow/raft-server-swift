/// The fixed OAuth membership leaf a Channels transaction may enter. This
/// capability retains the actual owner without querying or caching memberships
/// at construction; each call reads the live ledger at the caller's lock point.
struct ServerMembershipQuery: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    func memberServerIds(userId: String) -> [String] {
        oauth.serverIdsForMember(userId: userId)
    }
}
