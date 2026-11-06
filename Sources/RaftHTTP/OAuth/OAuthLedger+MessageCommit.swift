import Foundation

extension OAuthLedger {
    /// This leaf takes a checked record value, never a closure or message-store
    /// reference. It is entered only after Messages assigned the final seq.
    func appendMessageCommitMirror(_ record: ChannelMessageRecord) {
        state.withLock { ledgerState in
            if !ledgerState.channelMessages.contains(where: { $0.id == record.id }) {
                ledgerState.channelMessages.append(record)
            }
        }
    }
    /// The sender's frontier after a Messages commit. Messages owns the outer
    /// transaction; this leaf operation only enters OAuth's record Mutex.
    func advanceReadCursorAfterMessageCommit(channelId: String, userId: String, seq: Int) {
        state.withLock { ledgerState in
            let key = "\(channelId)\n\(userId)"
            if seq > (ledgerState.channelReadCursors[key] ?? 0) {
                ledgerState.channelReadCursors[key] = seq
            }
        }
    }
}
