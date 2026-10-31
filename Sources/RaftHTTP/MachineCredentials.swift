/// Identity resolved from a legacy machine API key or a machine id.
/// The NIO `/daemon/connect` listener maps this onto `MatchedMachine`.
public struct MachineCredentialIdentity: Sendable, Equatable {
    public var machineId: String
    public var serverId: String

    public init(machineId: String, serverId: String) {
        self.machineId = machineId
        self.serverId = serverId
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
