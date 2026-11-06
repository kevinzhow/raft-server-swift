import Foundation

/// Everything the server-profile surface reads that another domain owns.
///
/// The ledgers belong to their stores and the OAuth ledger; the human session
/// lookup and the machine-credential lookup belong to domains that have not
/// migrated, and the wall clock, the id generator and the process environment
/// are injected so the byte-exact attestation and translation paths can be
/// tested. Production binding takes explicit owners and machine authority.
struct ServerProfileAndOrderDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var machineIdForCredential: @Sendable (String?) -> String?
    var oauth: OAuthLedger
    var channels: ServersAndChannelsStore
    var messages: MessagesAndThreadsStore
    var profiles: AuthProfileStore
    var machines: MachinesAndComputersStore
    var agents: AgentsRuntimeStore
    var environment: @Sendable () -> [String: String]
    var now: @Sendable () -> Date
    var makeUUID: @Sendable () -> String
}

extension ServerProfileAndOrderDependencies {
    init(
        auth: AuthCoreService,
        machineIdForCredential: @escaping @Sendable (String?) -> String?,
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        profiles: AuthProfileStore,
        machines: MachinesAndComputersStore,
        agents: AgentsRuntimeStore,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            machineIdForCredential: machineIdForCredential,
            oauth: oauth,
            channels: channels,
            messages: messages,
            profiles: profiles,
            machines: machines,
            agents: agents,
            environment: environment,
            now: now,
            makeUUID: makeUUID
        )
    }
}
