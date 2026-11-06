import Foundation

/// The system-notice write and acting agent's born-read cursor use the existing
/// Messages transaction, including its shared allocator and OAuth mirror.
struct SystemNoticeAppender: Sendable {
    private let messages: MessagesAndThreadsStore
    private let ledger: MessageLedgerPort

    init(messages: MessagesAndThreadsStore, ledger: MessageLedgerPort) {
        self.messages = messages
        self.ledger = ledger
    }

    @discardableResult
    func append(_ message: StoredHumanMessage, _ bornReadAgentId: String?) -> Int {
        messages.appendMessage(message, ledger: ledger, bornReadAgentId: bornReadAgentId)
    }
}
