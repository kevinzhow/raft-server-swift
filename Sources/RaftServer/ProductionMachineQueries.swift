import Foundation
import RaftHTTP
import RaftMachineSocket

/// Only an adapter over the retained machine Registry. It has no channel,
/// provider, cache, execution owner, worker or parallel business state of its own.
struct ProductionMachineQueries: MachineQuerying {
    let registry: MachineCommandRegistry

    private func query(_ request: MachineQueryRequest, authority: MachineQueryAuthority) async throws -> Data {
        do {
            let timeout: Duration
            switch request {
            case .runtimeModels: timeout = .seconds(20)
            case .workspaceScan, .workspaceFiles, .workspaceRead: timeout = .seconds(15)
            }
            let reply = try await registry.query(request, machineId: authority.machineId, serverId: authority.serverId,
                expectedConnectionEpochId: authority.connectionEpochId, timeout: timeout)
            guard reply.connectionEpochId == authority.connectionEpochId else { throw MachineQueryError.offline }
            return reply.payload
        } catch is CancellationError { throw CancellationError() }
        catch MachineCommandError.timedOut { throw MachineQueryError.timedOut }
        catch MachineCommandError.disconnected { throw MachineQueryError.offline }
        catch MachineCommandError.machineOffline { throw MachineQueryError.offline }
        catch { throw MachineQueryError.invalidReply }
    }

    func machineWorkspaces(authority: MachineQueryAuthority) async throws -> [MachineWorkspaceDirectory] {
        struct Reply: Decodable { let directories: [MachineWorkspaceDirectory] }
        let data = try await query(.workspaceScan, authority: authority)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.directories.allSatisfy({ !$0.directoryName.isEmpty && $0.totalSizeBytes >= 0
                  && $0.fileCount >= 0 && !$0.lastModified.isEmpty }) else {
            throw MachineQueryError.invalidReply
        }
        return reply.directories
    }

    func runtimeModels(authority: MachineQueryAuthority, runtime: String, force: Bool) async throws -> MachineRuntimeModelSource {
        struct Reply: Decodable {
            let outcome: MachineRuntimeModelSource?
            let models: [MachineRuntimeModelSource.Model]?
            let defaultModel: String?
            let error: String?
            enum CodingKeys: String, CodingKey { case outcome, models, defaultModel = "default", error }
        }
        let data = try await query(.runtimeModels(runtime: runtime, force: force), authority: authority)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw MachineQueryError.invalidReply }
        if let source = reply.outcome {
            guard source.kind != .live || source.value != nil,
                  source.kind != .error || source.retryable != nil else { throw MachineQueryError.invalidReply }
            return source
        }
        if let error = reply.error, !error.isEmpty {
            return error == "unsupported" ? .init(kind: .unsupported) : .init(kind: .error, retryable: true)
        }
        guard let models = reply.models, !models.isEmpty else { return .init(kind: .no_models) }
        return .init(kind: .live, value: .init(models: models, defaultModel: reply.defaultModel))
    }

    private struct FileNode: Decodable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int
        let modifiedAt: String
        let isHidden: Bool?
        let children: [FileNode]?
        var jsonBody: OrderedJSON {
            var body = OrderedJSONObject()
            body.append("name", name); body.append("path", path); body.append("isDirectory", isDirectory)
            body.append("size", size); body.append("modifiedAt", modifiedAt)
            body.append("isHidden", ifPresent: isHidden)
            body.append("children", ifPresent: children.map { .array($0.map(\.jsonBody)) })
            return body.json
        }
    }

    func workspaceFiles(authority: MachineQueryAuthority, agentId: String, dirPath: String?, includeHidden: Bool) async throws -> OrderedJSON {
        struct Reply: Decodable { let files: [FileNode] }
        let data = try await query(.workspaceFiles(agentId: agentId, dirPath: dirPath, includeHidden: includeHidden), authority: authority)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw MachineQueryError.invalidReply }
        return .array(reply.files.map(\.jsonBody))
    }

    func workspaceRead(authority: MachineQueryAuthority, agentId: String, path: String) async throws -> OrderedJSON {
        struct Reply: Decodable {
            let content: String?
            let binary: Bool
            let size: Int?
            let mimeType: String?
            let encoding: String?
        }
        let data = try await query(.workspaceRead(agentId: agentId, path: path), authority: authority)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw MachineQueryError.invalidReply }
        var body = OrderedJSONObject()
        body.append("path", path); body.append("content", optional: reply.content); body.append("binary", reply.binary)
        let fallbackSize: Int
        if let content = reply.content {
            if reply.encoding == "base64" {
                var base64 = content.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 = String(base64.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") })
                while base64.utf8.count % 4 != 0 { base64.append("=") }
                fallbackSize = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)?.count ?? 0
            } else { fallbackSize = content.utf8.count }
        } else { fallbackSize = 0 }
        body.append("size", reply.size ?? fallbackSize); body.append("mimeType", ifPresent: reply.mimeType); body.append("encoding", ifPresent: reply.encoding)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        body.append("modifiedAt", formatter.string(from: Date()))
        return body.json
    }
}
