/// The fixed OAuth channel write a Channels thread transaction may enter.
/// Construction retains the actual ledger without reading facts; the command
/// mints and appends the thread record while the caller keeps its Channels lock.
struct ThreadChannelCommand: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    func createThreadChannel(parentChannelId: String, parentMessageId: String) -> String {
        oauth.createThreadChannel(parentChannelId: parentChannelId, parentMessageId: parentMessageId)
    }
}
