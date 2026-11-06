import Foundation
import RaftShared

// Request and response shapes for the managed MCP control plane
// (`/api/mcp/*`). Requests read each member with the legacy lenient casts;
// every response owns its published member order as an `OrderedJSON` tree.

// MARK: - Requests

/// `POST /api/mcp/servers`.
public struct ManagedMCPServerCreateRequest: Decodable, Sendable, Equatable {
    public var name: String?
    public var endpointUrl: String?
    /// Trimmed provider.
    public var provider: String?
    /// Trimmed auth mode.
    public var authMode: String?
    /// The `headers` object, when the member is an object.
    public var headers: [String: JSONValue]?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        name = members["name"]?.castString
        endpointUrl = members["endpointUrl"]?.castString
        provider = members["provider"]?.castString?.trimmingCharacters(in: .whitespacesAndNewlines)
        authMode = members["authMode"]?.castString?.trimmingCharacters(in: .whitespacesAndNewlines)
        headers = members["headers"]?.castObject
    }
}

/// `PATCH /api/mcp/servers/:id`.
public struct ManagedMCPServerPatchRequest: Decodable, Sendable, Equatable {
    public struct CredentialPatch: Sendable, Equatable {
        public var removeHeaderNames: [JSONValue]?
        public var upsertHeaders: [String: JSONValue]?
    }

    public var name: String?
    public var endpointUrl: String?
    public var credentialPatch: CredentialPatch?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        name = members["name"]?.castString
        endpointUrl = members["endpointUrl"]?.castString
        credentialPatch = members["credentialPatch"]?.castObject.map {
            CredentialPatch(
                removeHeaderNames: $0["removeHeaderNames"]?.castArray,
                upsertHeaders: $0["upsertHeaders"]?.castObject
            )
        }
    }
}

/// `POST /api/mcp/servers/test-configuration`.
public struct ManagedMCPTestConfigurationRequest: Decodable, Sendable, Equatable {
    public var endpointUrl: String?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        endpointUrl = members["endpointUrl"]?.castString
    }
}

/// One assignment as the body carries it. `mcpServerId` is nil when the entry
/// is not an object or names no string id.
public struct ManagedMCPAssignmentEntry: Sendable, Equatable {
    public var mcpServerId: String?
    public var enabled: Bool
    public var allowedTools: [String]?

    init(_ value: JSONValue) {
        let members = value.castObject
        mcpServerId = members?["mcpServerId"]?.castString
        enabled = members?["enabled"]?.castBool ?? true
        allowedTools = members?["allowedTools"]?.castArray?.compactMap(\.castString)
    }
}

/// `PUT /api/mcp/agents/:agentId/assignments`. `assignments` is nil when the
/// member is missing or not an array.
public struct ManagedMCPAssignmentsRequest: Decodable, Sendable, Equatable {
    public var assignments: [ManagedMCPAssignmentEntry]?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        assignments = members["assignments"]?.castArray?.map(ManagedMCPAssignmentEntry.init)
    }
}

/// `PUT /api/mcp/agents/:agentId/assignments/:mcpServerId`.
public struct ManagedMCPSingleAssignmentRequest: Decodable, Sendable, Equatable {
    public var enabled: Bool
    public var allowedTools: [String]?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        enabled = members["enabled"]?.castBool ?? true
        allowedTools = members["allowedTools"]?.castArray?.compactMap(\.castString)
    }
}

// MARK: - Responses

/// One managed MCP server row.
public struct ManagedMCPServerResponse: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var name: String
    public var provider: String?
    public var authMode: String?
    public var oauthStatus: String?
    /// The endpoint with query, fragment and credentials removed.
    public var endpointUrl: String
    public var hasCredentials: Bool
    public var credentialHeaderNames: [String]

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("name", name)
        body.append("provider", optional: provider)
        body.append("authMode", optional: authMode)
        body.append("oauthStatus", optional: oauthStatus)
        body.append("endpointUrl", endpointUrl)
        body.append("hasCredentials", hasCredentials)
        body.append("credentialHeaderNames", .array(credentialHeaderNames.map(OrderedJSON.string)))
        body.append("assignment", .null)
        return body.json
    }
}

/// `GET /api/mcp/servers`.
public struct ManagedMCPServerListResponse: JSONBodyConvertible, Sendable, Equatable {
    public var servers: [ManagedMCPServerResponse]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("servers", .array(servers.map(\.jsonBody))),
            OrderedJSONField("recommendations", .array([
                .object([OrderedJSONField("id", "notion")]),
                .object([OrderedJSONField("id", "linear")]),
            ])),
        ])
    }
}

/// `GET /api/mcp/agents/:agentId`.
public struct ManagedMCPAgentCatalogResponse: JSONBodyConvertible, Sendable, Equatable {
    public var agentId: String
    public var agentName: String
    public var agentDisplayName: String
    public var servers: [ManagedMCPServerResponse]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agent", .object([
                OrderedJSONField("id", agentId),
                OrderedJSONField("name", agentName),
                OrderedJSONField("displayName", agentDisplayName),
            ])),
            OrderedJSONField("servers", .array(servers.map(\.jsonBody))),
        ])
    }
}

/// One stored assignment.
public struct ManagedMCPAssignmentResponse: JSONBodyConvertible, Sendable, Equatable {
    public var mcpServerId: String
    public var enabled: Bool
    public var allowedTools: [String]?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("mcpServerId", mcpServerId),
            OrderedJSONField("enabled", enabled),
            OrderedJSONField("allowedTools", allowedTools.map { .array($0.map(OrderedJSON.string)) } ?? .null),
        ])
    }
}

/// `PUT …/assignments`: `{"ok":true,"assignments":[…]}`.
public struct ManagedMCPAssignmentsResponse: JSONBodyConvertible, Sendable, Equatable {
    public var assignments: [ManagedMCPAssignmentResponse]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("assignments", .array(assignments.map(\.jsonBody))),
        ])
    }
}

/// `PUT …/assignments/:mcpServerId`: `{"assignment":{…}}`.
public struct ManagedMCPSingleAssignmentResponse: JSONBodyConvertible, Sendable, Equatable {
    public var assignment: ManagedMCPAssignmentResponse

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("assignment", assignment)])
    }
}

/// `GET /api/mcp/oauth/client-metadata`. Published with `Cache-Control: no-store`.
public struct ManagedMCPOAuthClientMetadataResponse: JSONBodyConvertible, Sendable, Equatable {
    public var clientId: String
    public var redirectUri: String

    public var jsonBody: OrderedJSON {
        // The legacy body printed the redirect between literal quotes without
        // escaping, so the fragment stays as it was.
        .object([
            OrderedJSONField("client_id", clientId),
            OrderedJSONField("redirect_uris", .array([.raw("\"\(redirectUri)\"")])),
        ])
    }
}

/// `GET /api/mcp/oauth/callback`: the static "not connected" page, published as
/// a `400` HTML document with its own header set.
public struct ManagedMCPOAuthCallbackPage: JSONBodyConvertible, Sendable, Equatable {
    public static let status: UInt = 400

    public init() {}

    public var jsonBody: OrderedJSON {
        .raw("""
        <!doctype html><html><head><title>RAFT MCP</title></head><body><main><h1>RAFT</h1><p>MCP was not connected.</p><p>Close window</p><div id=\"raft-managed-mcp-oauth-result\"></div><script type=\"application/json\" id=\"managed-mcp-oauth-result\">{}</script></main></body></html>
        """)
    }

    public var headers: ResponseHeaders {
        .exact([
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
            "Cache-Control": "no-store",
        ])
    }
}
