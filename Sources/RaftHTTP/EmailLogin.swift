import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dependency assembly for the HTTP domain services.
///
/// Services implement authentication and domain decisions; stores own state.
/// A global transaction lock still protects unmigrated directory operations.
///
/// The root holds immutable references to its stores, OAuth ledger, and locks.
/// Checked Sendable validates those references; it does not remove the
/// transaction coordination still used by the directory's remaining helpers.
/// Store forwarding accessors live in `Stores/DirectoryStoreForwarders.swift`;
/// domain services live under `Services/`, with test seams in `TestSupport`.
public final class EmailLoginDirectory: Sendable {
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
