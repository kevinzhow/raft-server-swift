import Foundation

/// Agent-facing human sender naming uses the retained account handle
/// (`users.name`), the same fact the pinned `getSenderIdentity` reads
/// (`packages/server/src/services/messageService.ts:2203-2215`). A profile
/// `displayName` can still hold the pre-profile `pending_…` placeholder after
/// completion; it is never a substitute for the handle in a delivery frame.
enum AgentSenderNaming {
    static func humanName(_ account: Account?) -> String {
        guard let account, !account.name.isEmpty else { return "Unknown" }
        return account.name
    }
}
