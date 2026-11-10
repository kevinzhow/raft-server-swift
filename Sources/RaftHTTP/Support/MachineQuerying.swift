import Foundation

public struct MachineQueryAuthority: Sendable, Equatable {
    public let machineId: String
    public let serverId: String
    public let connectionEpochId: String
    public init(machineId: String, serverId: String, connectionEpochId: String) {
        self.machineId = machineId; self.serverId = serverId; self.connectionEpochId = connectionEpochId
    }
}

/// Observed filesystem metadata from the existing legacy workspace scan reply.
/// Required statistics have no defaults; an older daemon may omit displayPath.
public struct MachineWorkspaceDirectory: Codable, Sendable, Equatable {
    public let directoryName: String
    public let totalSizeBytes: Int
    public let lastModified: String
    public let fileCount: Int
    public let displayPath: String?

    public init(directoryName: String, totalSizeBytes: Int, lastModified: String,
                fileCount: Int, displayPath: String? = nil) {
        self.directoryName = directoryName
        self.totalSizeBytes = totalSizeBytes
        self.lastModified = lastModified
        self.fileCount = fileCount
        self.displayPath = displayPath
    }
}

/// A transient handle on the existing authenticated connection, not another
/// connection, execution owner, provider implementation, or background worker.
public protocol MachineQuerying: Sendable {
    func machineWorkspaces(authority: MachineQueryAuthority) async throws -> [MachineWorkspaceDirectory]
    func runtimeModels(authority: MachineQueryAuthority, runtime: String, force: Bool) async throws -> MachineRuntimeModelSource
    func workspaceFiles(authority: MachineQueryAuthority, agentId: String, dirPath: String?, includeHidden: Bool) async throws -> OrderedJSON
    func workspaceRead(authority: MachineQueryAuthority, agentId: String, path: String) async throws -> OrderedJSON
}

public enum MachineQueryError: Error, Sendable { case offline, timedOut, invalidReply }

public struct MachineRuntimeModelSource: Codable, Sendable, JSONBodyConvertible {
    public enum Kind: String, Codable, Sendable { case live, missing_config, no_models, unsupported, error }
    public struct Model: Codable, Sendable {
        public let id: String
        public let label: String
        public let supportedReasoningEfforts: [String]?
        public let defaultReasoningEffort: String?
        public let serviceTiers: [String]?
        public let defaultServiceTier: String?
        public let verified: String?
        var jsonBody: OrderedJSON {
            var body = OrderedJSONObject()
            body.append("id", id); body.append("label", label)
            body.append("supportedReasoningEfforts", ifPresent: supportedReasoningEfforts.map { .array($0.map(OrderedJSON.string)) })
            body.append("defaultReasoningEffort", ifPresent: defaultReasoningEffort)
            body.append("serviceTiers", ifPresent: serviceTiers.map { .array($0.map(OrderedJSON.string)) })
            body.append("defaultServiceTier", ifPresent: defaultServiceTier)
            body.append("verified", ifPresent: verified)
            return body.json
        }
        var probeModel: RuntimeModelProbeModel {
            .init(id: id, label: label, supportedReasoningEfforts: supportedReasoningEfforts, defaultReasoningEffort: defaultReasoningEffort)
        }
    }
    public struct Catalog: Codable, Sendable {
        public let protocolVersion: Int
        public let runtime: String
        public let runtimeVersion: String
        var jsonBody: OrderedJSON { .object([.init("protocolVersion", protocolVersion), .init("runtime", runtime), .init("runtimeVersion", runtimeVersion)]) }
    }
    public struct ModelSet: Codable, Sendable {
        public let models: [Model]
        public let defaultModel: String?
        public let catalog: Catalog?
        enum CodingKeys: String, CodingKey { case models, defaultModel = "default", catalog }
        public init(models: [Model], defaultModel: String?, catalog: Catalog? = nil) {
            self.models = models; self.defaultModel = defaultModel; self.catalog = catalog
        }
        var jsonBody: OrderedJSON {
            var body = OrderedJSONObject(); body.append("models", .array(models.map(\.jsonBody)))
            body.append("default", ifPresent: defaultModel); body.append("catalog", ifPresent: catalog?.jsonBody)
            return body.json
        }
    }
    public let kind: Kind
    public let value: ModelSet?
    public let recovery: String?
    public let retryable: Bool?
    public let code: String?
    public let reason: String?
    public init(kind: Kind, value: ModelSet? = nil, recovery: String? = nil,
                retryable: Bool? = nil, code: String? = nil, reason: String? = nil) {
        self.kind = kind; self.value = value; self.recovery = recovery
        self.retryable = retryable; self.code = code; self.reason = reason
    }
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject(); body.append("kind", kind.rawValue)
        body.append("value", ifPresent: value?.jsonBody); body.append("recovery", ifPresent: recovery)
        body.append("retryable", ifPresent: retryable); body.append("code", ifPresent: code); body.append("reason", ifPresent: reason)
        return body.json
    }
    var probeOutcome: RuntimeModelProbeOutcome {
        switch kind {
        case .live:
            guard let value else { return .failed }
            return .live(models: value.models.map(\.probeModel), default: value.defaultModel)
        case .missing_config: return .missingConfig
        case .no_models: return .noModels
        case .unsupported: return .unsupported
        case .error: return .error(code: code ?? "", retryable: retryable ?? true)
        }
    }
}

/// The public Node models GET adds legacy aliases to the actual typed outcome.
/// No default, login recovery, retryability or model metadata is invented.
public struct MachineRuntimeModelQueryResponse: JSONBodyConvertible, Sendable {
    let source: MachineRuntimeModelSource
    public var jsonBody: OrderedJSON {
        guard case .object(var fields) = source.jsonBody else { return source.jsonBody }
        if source.kind == .live, let value = source.value {
            fields.append(.init("models", .array(value.models.map(\.jsonBody))))
            if let model = value.defaultModel, !model.isEmpty { fields.append(.init("default", model)) }
        }
        return .object(fields)
    }
}

func machineQueryRead<Value>(persistence: BusinessPersistenceRuntime?, _ body: () throws -> Value) throws -> Value {
    // A nil writer is supported only for existing unsealed direct fixtures. A
    // production query still needs its real port; there is no cache-success shim.
    if let persistence { return try persistence.withCommittedReadView(body) }
    return try body()
}

func machineQueryAuthority(agents: AgentsRuntimeStore, machineId: String, serverId: String) throws -> MachineQueryAuthority {
    guard let connection = agents.state.execution.connections[machineId], connection.online,
          connection.serverId == serverId else { throw MachineQueryError.offline }
    return .init(machineId: machineId, serverId: serverId, connectionEpochId: connection.connectionEpochId)
}
