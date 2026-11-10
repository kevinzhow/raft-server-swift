import RaftConnectAuth
import RaftHTTP
import RaftRealtime

/// Realtime admission sees one committed revision per synchronous decision and
/// refuses new reads after loss of the fenced writer. No pending UoW is exposed.
struct ProductionRealtimeAuth: RealtimeAuthorizing {
    let base: LedgerRealtimeAuth
    let runtime: BusinessPersistenceRuntime

    func sessionIdentity(forAccessToken token: String) -> RealtimeSessionIdentity? {
        try? runtime.withCommittedReadView { base.sessionIdentity(forAccessToken: token) }
    }
    func userId(forAccessToken token: String) -> String? {
        try? runtime.withCommittedReadView { base.userId(forAccessToken: token) }
    }
    func sessionFamilyId(forAccessToken token: String) -> String? {
        try? runtime.withCommittedReadView { base.sessionFamilyId(forAccessToken: token) }
    }
    func serverRole(serverId: String, userId: String) -> String? {
        try? runtime.withCommittedReadView { base.serverRole(serverId: serverId, userId: userId) }
    }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        (try? runtime.withCommittedReadView { base.visibleChannelIds(serverId: serverId, userId: userId) }) ?? []
    }
    func syncResumePayload(serverId: String, userId: String, lastSeq: Int, limit: Int) -> String? {
        try? runtime.withCommittedReadView {
            base.syncResumePayload(serverId: serverId, userId: userId, lastSeq: lastSeq, limit: limit)
        }
    }
}

/// Credential lookups can update last-used facts. Complete their PG commit
/// before the transport is allowed to grant the corresponding credential.
struct ProductionMachineLookup: MachineCredentialLooking {
    let base: LedgerMachineLookup
    let runtime: BusinessPersistenceRuntime

    func findComputer(apiKey: String) async throws -> ComputerAuthResolution {
        try await runtime.execute { try await base.findComputer(apiKey: apiKey) }
    }
    func machine(id: String) async throws -> MatchedMachine? {
        try await runtime.execute { try await base.machine(id: id) }
    }
    func serverExists(id: String) async throws -> Bool {
        try await runtime.execute { try await base.serverExists(id: id) }
    }
    func machine(apiKey: String) async throws -> MatchedMachine? {
        try await runtime.execute { try await base.machine(apiKey: apiKey) }
    }
}
