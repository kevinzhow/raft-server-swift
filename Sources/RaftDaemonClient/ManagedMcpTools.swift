import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Managed MCP tools for Pi: the server's `/mcp/tools` catalog is frozen into
/// tool definitions that proxy calls through `/mcp/call` with the catalog
/// versions as a fence. Failures are non-fatal and bounded; remote names and
/// descriptions are flattened so they cannot break out of the prompt snippet.
/// Ported from the upstream daemon helper.
public struct ManagedMcpToolContent: Sendable, Equatable {
    public var type: String
    public var text: String

    public init(type: String, text: String) {
        self.type = type
        self.text = text
    }
}

public final class ManagedMcpTool: @unchecked Sendable {
    public let name: String
    public let label: String
    public let promptSnippet: String
    private let serverUrl: String
    private let agentCredentialKey: String
    private let mcpServerId: String
    private let toolName: String
    private let configVersion: Int
    private let assignmentVersion: Int
    private let transport: ManagedMcpTools.Transport

    init(
        name: String, label: String, promptSnippet: String, serverUrl: String, agentCredentialKey: String,
        mcpServerId: String, toolName: String, configVersion: Int, assignmentVersion: Int,
        transport: @escaping ManagedMcpTools.Transport
    ) {
        self.name = name
        self.label = label
        self.promptSnippet = promptSnippet
        self.serverUrl = serverUrl
        self.agentCredentialKey = agentCredentialKey
        self.mcpServerId = mcpServerId
        self.toolName = toolName
        self.configVersion = configVersion
        self.assignmentVersion = assignmentVersion
        self.transport = transport
    }

    /// Executes the tool through the agent-api; remote errors are thrown with
    /// bounded text, and a transport failure reads as outcome unknown.
    public func execute(arguments: [String: Any]) async throws -> [ManagedMcpToolContent] {
        guard let url = URL(string: serverUrl + "/mcp/call") else {
            throw ManagedMcpToolError.text(ManagedMcpTools.outcomeUnknownText)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(agentCredentialKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "mcpServerId": mcpServerId,
            "toolName": toolName,
            "arguments": arguments,
            "expectedConfigVersion": configVersion,
            "expectedAssignmentVersion": assignmentVersion,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let response: (status: Int, body: Data)
        do {
            response = try await transport(request)
        } catch {
            throw ManagedMcpToolError.text(ManagedMcpTools.outcomeUnknownText)
        }
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        if response.status >= 200, response.status < 300 {
            let isError = object["isError"] as? Bool ?? false
            let contents = (object["content"] as? [[String: Any]]) ?? []
            if isError {
                let text = contents.compactMap { $0["text"] as? String }.joined()
                if text.isEmpty { throw ManagedMcpToolError.text("\(name) failed") }
                if text.count > 4_000 {
                    throw ManagedMcpToolError.text(String(text.prefix(4_000)) + "…[truncated]")
                }
                throw ManagedMcpToolError.text(text)
            }
            return contents.compactMap { item in
                guard let type = item["type"] as? String, let text = item["text"] as? String else { return nil }
                return ManagedMcpToolContent(type: type, text: text)
            }
        }
        if let code = object["code"] as? String, let error = object["error"] as? String {
            throw ManagedMcpToolError.text(error)
        }
        throw ManagedMcpToolError.text(ManagedMcpTools.outcomeUnknownText)
    }
}

public struct ManagedMcpToolError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
    static func text(_ value: String) -> ManagedMcpToolError { .init(message: value) }
}

public enum ManagedMcpTools {
    public typealias Transport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    public static let outcomeUnknownText = "The connection to Raft failed during this call, so it may already have taken effect. Check whether it did before calling the tool again; if you can't check, tell the person who asked instead of calling it again."

    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    /// Loads the frozen MCP catalog; a failed snapshot is non-fatal (empty list
    /// plus one bounded warning).
    public static func create(
        serverUrl: String,
        agentCredentialKey: String?,
        transport: @escaping Transport = defaultTransport,
        onWarning: ((String) -> Void)? = nil
    ) async -> [ManagedMcpTool] {
        guard let agentCredentialKey, !agentCredentialKey.isEmpty else { return [] }
        guard let url = URL(string: serverUrl + "/mcp/tools") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(agentCredentialKey)", forHTTPHeaderField: "Authorization")
        let response: (status: Int, body: Data)
        do {
            response = try await transport(request)
        } catch {
            onWarning?("Managed MCP tools unavailable: \(error.localizedDescription)".prefix(290).description)
            return []
        }
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        guard response.status == 200, let tools = object["tools"] as? [[String: Any]] else {
            let code = object["code"] as? String ?? "unknown"
            onWarning?("Managed MCP tools unavailable: \(code) (\(response.status))")
            return []
        }
        return tools.compactMap { item in
            guard let serverId = item["mcpServerId"] as? String,
                  let toolName = item["toolName"] as? String,
                  let runtimeName = item["runtimeName"] as? String,
                  let serverName = item["serverName"] as? String,
                  let configVersion = (item["configVersion"] as? NSNumber)?.intValue,
                  let assignmentVersion = (item["assignmentVersion"] as? NSNumber)?.intValue
            else { return nil }
            let flatTool = flatten(toolName)
            let flatServer = flatten(serverName)
            let description = (item["description"] as? String).map(flatten)
            let snippet: String
            let label: String
            if let description, !description.isEmpty {
                snippet = "\(runtimeName): \(description)"
                label = "\(runtimeName)"
            } else {
                snippet = "\(runtimeName): Call \"\(flatTool)\" on \"\(flatServer)\""
                label = "\"\(flatServer)\": \"\(flatTool)\""
            }
            return ManagedMcpTool(
                name: runtimeName, label: label, promptSnippet: snippet,
                serverUrl: serverUrl, agentCredentialKey: agentCredentialKey,
                mcpServerId: serverId, toolName: toolName,
                configVersion: configVersion, assignmentVersion: assignmentVersion,
                transport: transport
            )
        }
    }

    /// Collapses every splitlines separator (and surrounding whitespace) into a
    /// single space so remote text cannot forge a following line.
    static func flatten(_ value: String) -> String {
        value.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.newlines.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}" {
                result.append(" ")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        .split(whereSeparator: { $0 == " " || $0 == "\t" })
        .joined(separator: " ")
    }
}
