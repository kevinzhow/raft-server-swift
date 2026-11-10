import Foundation

/// Closed queries on the existing machine connection. IDs are private pending
/// keys except where the pinned Node protocol explicitly carries requestId.
public enum MachineQueryRequest: Sendable {
    case workspaceScan
    case runtimeModels(runtime: String, force: Bool)
    case workspaceFiles(agentId: String, dirPath: String?, includeHidden: Bool)
    case workspaceRead(agentId: String, path: String)

    func encoded(requestId: String) throws -> Data {
        struct Wire: Encodable {
            let type: String
            var requestId: String?
            var runtime: String?
            var force: Bool?
            var agentId: String?
            var dirPath: String?
            var includeHidden: Bool?
            var path: String?
        }
        let wire: Wire
        switch self {
        case .workspaceScan:
            wire = .init(type: "machine:workspace:scan")
        case .runtimeModels(let runtime, let force):
            guard !runtime.isEmpty else { throw MachineCommandError.invalidCommand }
            wire = .init(type: "machine:runtime_models:detect", requestId: requestId, runtime: runtime, force: force ? true : nil)
        case .workspaceFiles(let agentId, let dirPath, let hidden):
            guard !agentId.isEmpty else { throw MachineCommandError.invalidCommand }
            wire = .init(type: "agent:workspace:list", agentId: agentId, dirPath: dirPath, includeHidden: hidden)
        case .workspaceRead(let agentId, let path):
            guard !agentId.isEmpty else { throw MachineCommandError.invalidCommand }
            wire = .init(type: "agent:workspace:read", requestId: requestId, agentId: agentId, path: path)
        }
        let data = try JSONEncoder().encode(wire)
        guard data.count <= 1_048_576 else { throw MachineCommandError.invalidCommand }
        return data
    }

    func matches(_ reply: MachineQueryReplyHeader, requestId: String) -> Bool {
        switch self {
        case .workspaceScan:
            return reply.type == "machine:workspace:scan_result"
        case .runtimeModels:
            return reply.type == "machine:runtime_models:result" && reply.requestId == requestId
        case .workspaceFiles(let agentId, let dirPath, let hidden):
            return reply.type == "agent:workspace:file_tree" && reply.agentId == agentId
                && reply.dirPath == dirPath && (reply.includeHidden ?? false) == hidden
        case .workspaceRead(let agentId, _):
            return reply.type == "agent:workspace:file_content" && reply.agentId == agentId && reply.requestId == requestId
        }
    }
}

struct MachineQueryReplyHeader: Decodable {
    let type: String
    let requestId: String?
    let agentId: String?
    let dirPath: String?
    let includeHidden: Bool?
}

public struct MachineQueryReply: Sendable {
    /// Full original reply. The Server adapter decodes the typed business DTO;
    /// the transport does not depend on HTTP or interpret model availability.
    public let payload: Data
    public let connectionEpochId: String
}
