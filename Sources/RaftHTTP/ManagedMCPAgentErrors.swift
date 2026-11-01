import Foundation

/// Agent-facing text for managed MCP failures and the runtime tool-name format
/// from `packages/server/src/routes/managedMcpAgentErrors.ts` and
/// `packages/shared/src/managedMcp.ts`.
public enum ManagedMCPAgentErrors {
    public static let promptNameLimit = 80

    /// Remote text on one line: control, format and line/paragraph separator
    /// characters become spaces, then runs of whitespace collapse.
    public static func flattenPromptText(_ value: String) -> String {
        let withoutControls = value.replacingOccurrences(
            of: "[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]+",
            with: " ",
            options: .regularExpression
        )
        return withoutControls
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A connector or tool name as agents read it: one line, capped and quoted.
    public static func formatPromptName(_ value: String) -> String {
        let characters = Array(flattenPromptText(value))
        let capped = characters.count > promptNameLimit
            ? String(characters.prefix(promptNameLimit)) + "…"
            : String(characters)
        return jsonString(capped)
    }

    /// `mcp_<id8>_`: the prefix every runtime tool name of this connector uses.
    public static func runtimeToolPrefix(_ mcpServerId: String) -> String {
        let alphanumerics = mcpServerId.filter { $0.isLetter || $0.isNumber }
        let part = String(alphanumerics.prefix(8))
        return "mcp_\(part.isEmpty ? "server" : part)_"
    }

    public static func runtimeToolName(_ mcpServerId: String, _ toolName: String) -> String {
        let alphanumerics = mcpServerId.filter { $0.isLetter || $0.isNumber }
        let serverPart = String(alphanumerics.prefix(8))
        let normalized = toolName.decomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let toolPart = String(normalized.prefix(48))
        return "mcp_\(serverPart.isEmpty ? "server" : serverPart)_\(toolPart.isEmpty ? "tool" : toolPart)_\(stableHash("\(mcpServerId):\(toolName)"))"
    }

    /// FNV-1a over UTF-16 code units, 32-bit, zero-padded hex.
    static func stableHash(_ value: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for unit in value.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x01000193
        }
        return String(format: "%08x", hash)
    }

    private static let reconnectCodes: Set<String> = ["managed_mcp_oauth_required", "managed_mcp_oauth_invalid_state"]
    private static let credentialCodes: Set<String> = [
        "managed_mcp_auth_invalid", "managed_mcp_endpoint_auth_rejected", "managed_mcp_credential_invalid",
    ]
    private static let staleCodes: Set<String> = [
        "managed_mcp_config_stale", "managed_mcp_assignment_stale", "managed_mcp_tool_not_allowed",
    ]
    private static let unavailableCodes: Set<String> = ["managed_mcp_unreachable", "managed_mcp_oauth_busy"]
    private static let goneCodes: Set<String> = ["managed_mcp_server_not_found", "managed_mcp_server_disabled"]

    private static let handoff = "Tell the person who asked; retrying will not help until then."

    private static func promptName(_ value: String?) -> String? {
        guard let value, !flattenPromptText(value).isEmpty else { return nil }
        return formatPromptName(value)
    }

    /// The agent-facing message for `code`, or nil to keep the original one.
    public static func agentErrorMessage(
        code: String,
        serverName: String? = nil,
        toolName: String? = nil,
        mcpServerId: String? = nil
    ) -> String? {
        let server = promptName(serverName) ?? "This MCP connector"
        if reconnectCodes.contains(code) {
            return "\(server) is disconnected; someone who manages this server's integrations has to reconnect it in Raft. \(handoff)"
        }
        if credentialCodes.contains(code) {
            return "\(server) rejected the credentials Raft holds for it; someone who manages this server's integrations has to update them in Raft. \(handoff)"
        }
        if staleCodes.contains(code) {
            let tool = promptName(toolName)
            return "\(tool.map { "\($0) is" } ?? "This tool is") no longer offered by \(promptName(serverName) ?? "this MCP connector"); don't call it again. If you still need it, tell the person who asked."
        }
        if goneCodes.contains(code) {
            let prefix = mcpServerId.map { " (its tools' names contain \(runtimeToolPrefix($0)))" } ?? ""
            return "\(server)\(prefix) is no longer available to you; don't call its tools again. If you still need it, tell the person who asked."
        }
        if unavailableCodes.contains(code) {
            return "\(server) can't be reached right now; try again in a minute, and if it keeps failing, tell the person who asked."
        }
        return nil
    }
}
