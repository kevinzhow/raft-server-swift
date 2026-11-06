import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `POST /api/auth/login`.
///
/// A non-string or empty email or password is refused before any account lookup.
/// A missing account and a wrong password share one 401, and neither issues a session.
///
/// This type is the composition root for the HTTP surface: the directory lock,
/// the lock-guarded relay slots, one store per ledger family, and the OAuth
/// ledger. Store forwarding accessors live in
/// `EmailLogin+StoreForwarders.swift`; domain services live under
/// `Services/`; test seams belong in the `TestSupport` target.
public final class EmailLoginDirectory: @unchecked Sendable {
    let lock = NSLock()

    // Domain stores. Each owns one ledger family behind its own lock, and the
    // forwarding accessors keep the extension files' property names while this
    // body stays a composition root.
    let authProfileStore = AuthProfileStore()
    let notificationsStore = NotificationsStore()
    let productEventStore = ProductEventStore()
    let inboxFactStore = InboxFactStore()
    let threadFollowStore = ThreadFollowStore()
    let messagesAndThreadsStore = MessagesAndThreadsStore()
    let agentsRuntimeStore = AgentsRuntimeStore()
    let tasksAndRemindersStore = TasksAndRemindersStore()
    let machinesAndComputersStore = MachinesAndComputersStore()
    let serversAndChannelsStore = ServersAndChannelsStore()
    let managedMCPAndCardsStore = ManagedMCPAndCardsStore()
    let feedbackStore = FeedbackStore()

    /// Human authorization codes and the token endpoint. The same ledger the HTTP routes exchange.
    public let oauth = OAuthLedger()

    /// Serializes the two relay slots whose stored values live in the domain
    /// stores. The locks stay here so this body holds no relay state.
    let agentConnectionLock = NSLock()
    let realtimeEmitterLock = NSLock()
    /// Serializes the freshness gate with the commit it protects, so two
    /// concurrent first replies cannot both pass the gate before either lands.
    let sendFreshnessCommitLock = NSLock()

    public init() {}
}
