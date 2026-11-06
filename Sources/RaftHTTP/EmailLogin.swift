/// Shared owner instances for the HTTP service factories.
///
/// Stores own mutable records and callback slots behind checked Mutex state.
/// Message commits and DM preparation use explicit typed owner transactions;
/// this root supplies no shared lock or per-field forwarding surface.
///
/// Checked Sendable validates these stored references. Factory extensions still
/// capture this transitional root and must move to explicit service assembly.
public final class EmailLoginDirectory: Sendable {
    // Each domain owns one ledger family; factories share these instances.
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

    /// Shared OAuth protocol state and the exact message mirror.
    public let oauth = OAuthLedger()

    public init() {}
}
