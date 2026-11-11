import Foundation

/// The one write path for persisted system notices.
///
/// The notice write and the acting agent's born-read cursor use the existing
/// Messages transaction, including its shared allocator and OAuth mirror. After
/// the row commits, the same persisted-frontend publisher ordinary messages use
/// emits upstream `broadcastSystemMessage`'s frames: `message:new` (and
/// `dm:new` for a DM), with the DM-human / thread-follower room joins first.
struct SystemNoticeAppender: Sendable {
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let ledger: MessageLedgerPort
    private let emit: @Sendable (_ room: String, _ event: String, _ payload: String) -> Void

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        ledger: MessageLedgerPort,
        emit: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in }
    ) {
        self.messages = messages
        self.channels = channels
        self.profiles = profiles
        self.oauth = oauth
        self.ledger = ledger
        self.emit = emit
    }

    @discardableResult
    func append(_ message: StoredHumanMessage, _ bornReadAgentId: String?) -> Int {
        var committed = message
        committed.seq = messages.appendMessage(
            message, ledger: ledger, bornReadAgentId: bornReadAgentId
        )
        let realtime = MessageRealtimeService(
            messages: messages, channels: channels, profiles: profiles, oauth: oauth
        )
        for frame in realtime.systemFrames(for: committed) {
            emit(frame.room, frame.event, frame.payload)
        }
        return committed.seq
    }
}
