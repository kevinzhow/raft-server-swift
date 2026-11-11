import Foundation
import RaftShared

/// Request body for `POST /api/actions/:messageId/mark-executed`.
///
/// A malformed or empty body decodes to the empty value, so the service still
/// answers the upstream `A result is required` 400.
public struct MarkActionCardExecutedRequest: Codable, Sendable, Equatable {
    public var result: MarkActionCardExecutedResult?

    public init(result: MarkActionCardExecutedResult? = nil) {
        self.result = result
    }
}

/// The `result` member of the mark-executed body. Only `kind` is policy input;
/// every other member stays the caller's payload and is never echoed.
public struct MarkActionCardExecutedResult: Codable, Sendable, Equatable {
    public var kind: String?

    public init(kind: String? = nil) {
        self.kind = kind
    }
}

/// `POST /api/actions/:messageId/mark-executed` success body.
public struct MarkActionCardExecutedResponse: Codable, Sendable, Equatable {
    public var messageId: String
    public var metadata: ActionCardMetadata

    public init(messageId: String, metadata: ActionCardMetadata = ActionCardMetadata()) {
        self.messageId = messageId
        self.metadata = metadata
    }
}

/// The executed marker a plain action-card row projects.
///
/// Only `actionCardRecords` rows reach the mark-executed route; prepared
/// marketplace and integration-registration cards live in their own maps, so
/// the legacy metadata lookup always took this fallback shape.
public struct ActionCardMetadata: Codable, Sendable, Equatable {
    public var kind: String
    public var state: String

    public init(kind: String = "action-card", state: String = "executed") {
        self.kind = kind
        self.state = state
    }
}

/// Request body for `POST /internal/agent-api/mcp/call`.
///
/// A malformed or empty body decodes to the empty value, which the service
/// refuses as `managed_mcp_invalid_request`.
public struct ManagedMCPToolCallRequest: Codable, Sendable, Equatable {
    public var mcpServerId: String?
    public var toolName: String?
    public var expectedConfigVersion: Int?
    public var expectedAssignmentVersion: Int?

    public init(
        mcpServerId: String? = nil,
        toolName: String? = nil,
        expectedConfigVersion: Int? = nil,
        expectedAssignmentVersion: Int? = nil
    ) {
        self.mcpServerId = mcpServerId
        self.toolName = toolName
        self.expectedConfigVersion = expectedConfigVersion
        self.expectedAssignmentVersion = expectedAssignmentVersion
    }
}

/// `GET /internal/agent-api/mcp/tools` success body.
public struct ManagedMCPToolsResponse: Codable, Sendable, Equatable {
    public var catalogVersion: Int
    public var tools: [ManagedMCPTool]
    /// Omitted from the body when every connector is usable.
    public var unavailable: [ManagedMCPUnavailable]?

    public init(
        catalogVersion: Int,
        tools: [ManagedMCPTool],
        unavailable: [ManagedMCPUnavailable]? = nil
    ) {
        self.catalogVersion = catalogVersion
        self.tools = tools
        self.unavailable = unavailable
    }
}

/// One callable tool row. `inputSchema` is the connector's published JSON
/// schema, kept as a JSON tree so the service never hand-builds JSON.
public struct ManagedMCPTool: Codable, Sendable, Equatable {
    public var mcpServerId: String
    public var serverName: String
    public var toolName: String
    public var inputSchema: JSONValue
    public var assignmentVersion: Int
    public var catalogVersion: Int

    public init(
        mcpServerId: String,
        serverName: String,
        toolName: String,
        inputSchema: JSONValue,
        assignmentVersion: Int,
        catalogVersion: Int
    ) {
        self.mcpServerId = mcpServerId
        self.serverName = serverName
        self.toolName = toolName
        self.inputSchema = inputSchema
        self.assignmentVersion = assignmentVersion
        self.catalogVersion = catalogVersion
    }
}

/// One connector that must be reconnected before its tools are offered.
public struct ManagedMCPUnavailable: Codable, Sendable, Equatable {
    public var mcpServerId: String
    public var serverName: String
    public var status: String

    public init(mcpServerId: String, serverName: String, status: String) {
        self.mcpServerId = mcpServerId
        self.serverName = serverName
        self.status = status
    }
}

/// The published `{"error": …, "code": …}` object used by action cards,
/// provider connections and the agent-credential refusals.
public struct ActionCardErrorBody: Codable, Sendable, Equatable {
    public var error: String
    public var code: String?
    public var requiredCapability: String?

    public init(error: String, code: String? = nil, requiredCapability: String? = nil) {
        self.error = error
        self.code = code
        self.requiredCapability = requiredCapability
    }
}

/// The published `{"code": …, "error": …}` object used by the managed-MCP
/// routes, optionally with the upstream `suggestedNextAction` hint.
public struct ManagedMCPErrorBody: Codable, Sendable, Equatable {
    public var code: String
    public var error: String
    public var suggestedNextAction: String?

    public init(code: String, error: String, suggestedNextAction: String? = nil) {
        self.code = code
        self.error = error
        self.suggestedNextAction = suggestedNextAction
    }
}

/// The published `{"error": …, "errorCode": …}` object used by typed action-card
/// errors (the conversion-frozen refusal).
public struct ActionCardTypedErrorBody: Codable, Sendable, Equatable {
    public var error: String
    public var errorCode: String

    public init(error: String, errorCode: String) {
        self.error = error
        self.errorCode = errorCode
    }
}
