@testable import RaftHTTP

extension EmailLoginDirectory {
    public var sessionCount: Int { authProfileStore.state.withLock { $0.accountSurface.sessions.count } }
    public var userCount: Int { authProfileStore.state.withLock { $0.accountSurface.accounts.count } }
    public var legalAcceptanceCount: Int { authProfileStore.state.withLock { $0.legalAcceptances.count } }
    public var emailVerificationCount: Int { authProfileStore.state.withLock { $0.accountSurface.emailVerifications } }
    public var retirementReceiptCount: Int { authProfileStore.state.withLock { $0.accountSurface.retirementReceipts.count } }
    public var mobileOAuthRequestCount: Int { authProfileStore.state.withLock { $0.accountSurface.mobileRequests.count } }
    public var humanMessageCount: Int { messagesAndThreadsStore.humanMessageRows.count }
}
