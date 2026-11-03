import Foundation

/// Identity resolved from a legacy machine API key or a machine id.
/// The NIO `/daemon/connect` listener maps this onto `MatchedMachine`.
public struct MachineCredentialIdentity: Sendable, Equatable {
    public var machineId: String
    public var serverId: String
    /// Set once the row was adopted into a Computer attachment; the legacy key
    /// must then be refused with `legacy_machine_key_migrated`.
    public var legacyKeyMigratedAt: Date?

    public init(machineId: String, serverId: String, legacyKeyMigratedAt: Date? = nil) {
        self.machineId = machineId
        self.serverId = serverId
        self.legacyKeyMigratedAt = legacyKeyMigratedAt
    }
}

/// In-memory answer for a presented Computer credential.
/// The NIO listener maps these cases onto `ComputerAuthResolution`.
public enum ComputerCredentialLookup: Sendable, Equatable {
    case linked(computerId: String, machineId: String)
    case notFound
    case revoked
    case machineUnlinked
    case keyMismatch
}

/// Result of a manual runtime-account usage refresh against a Computer.
public enum RuntimeAccountUsageManualResult: Sendable, Equatable {
    case snapshot(json: String)
    case timeout
    case offline
}

/// One call to a hosted runtime provider's connections surface. `action` names
/// the provider operation; the body is the JSON sent upstream, if any.
public struct AgentConnectionProviderRequest: Sendable, Equatable {
    public var method: String
    public var action: String
    public var provider: String
    public var agentId: String
    public var body: String?

    public init(method: String, action: String, provider: String, agentId: String, body: String? = nil) {
        self.method = method
        self.action = action
        self.provider = provider
        self.agentId = agentId
        self.body = body
    }
}

/// Provider answer for a connections call. A body is only meaningful with a
/// response; `unavailable` stands in for a transport failure.
public enum AgentConnectionProviderResult: Sendable, Equatable {
    case response(status: Int, body: String)
    case empty(status: Int)
    case unavailable
}
