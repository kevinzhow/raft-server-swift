import Foundation

// MARK: - Phase 5 typed request bodies (Batch E)
//
// Wire shapes for the `api/agent`, `api/agents`, `api/computer`,
// `api/integrations` and `internal/agent` JSON bodies registered by
// `AgentsFeature`, `ComputersFeature`, `IntegrationsFeature` and
// `InternalAdminFeature`. Each route decodes the typed shape with
// `request.content.decode`; a body that does not decode keeps the directory's
// raw parser, so the upstream status/JSON projection is unchanged for untyped
// or malformed requests.
//
// `encodedBody()` re-encodes the decoded value back into the canonical JSON the
// directory parser reads, which keeps one validation path in
// `EmailLoginDirectory` instead of a second copy in the feature.
//
// Two routes need the body's *key presence* rather than only its values:
// `assign-machine` distinguishes `{"machineId": null}` (unassign) from `{}`
// (missing key, 400), and the hosted-model and provider-connection bodies read
// `NSNull` as a present key. Those DTOs record which keys the request carried
// and re-emit `null` for them, so the raw parser sees exactly what it saw
// before.

/// A published JSON request body that already has a typed model.
///
/// The directory keeps its raw-body parsers because those parsers publish the
/// upstream `error` bodies for every malformed shape. `encodedBody()` hands the
/// parser back the canonical JSON for the shape that was just decoded, so the
/// typed route and the raw fallback read exactly the same keys.
///
/// Only fields the directory actually reads belong in a conforming type: a key
/// the parser ignores is dropped by the round trip, which cannot change a
/// reply.
public protocol AgentsAndComputersRequestDTO: Codable, Sendable, Equatable {
    /// Canonical JSON for the shape that was just decoded.
    func encodedBody() -> String
}

public extension AgentsAndComputersRequestDTO {
    /// Sorted keys make the round trip deterministic, so the body the raw
    /// parser sees is stable across processes.
    func encodedBody() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A JSON object key used to reject requests whose keys the raw parser would
/// have refused. `allKeys` enumerates the keys actually present in the body.
private struct AnyJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// `POST /api/agent/login` request body.
///
/// `bootstrapToken` is the only key the route reads. The directory trims it and
/// answers `missing_bootstrap_token` for an empty or absent value, so an
/// omitted key keeps the raw path and its 400.
public struct AgentLoginRequestDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var bootstrapToken: String?

    public init(bootstrapToken: String? = nil) {
        self.bootstrapToken = bootstrapToken
    }
}

/// `PATCH /api/agents/:id/creator` request body.
///
/// `creatorType` must be `user` and `creatorId` must name a member of the
/// Server; the directory enforces both and answers `Invalid creator` for
/// anything else, so an unknown or missing pair keeps the raw 400.
public struct AgentCreatorPatchDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var creatorType: String?
    public var creatorId: String?

    public init(creatorType: String? = nil, creatorId: String? = nil) {
        self.creatorType = creatorType
        self.creatorId = creatorId
    }
}

/// `POST /api/agents/:id/assign-machine` request body.
///
/// The directory requires the `machineId` key to be present: `null` clears the
/// assignment and a string assigns a Computer. `includesMachineID` records that
/// presence so the round trip can re-emit `{"machineId":null}` instead of
/// dropping the key and turning an unassign into `machineId is required`.
public struct AgentAssignMachineDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var machineId: String?
    /// `true` when the request carried the `machineId` key, including `null`.
    public var includesMachineID: Bool

    private enum CodingKeys: String, CodingKey {
        case machineId
    }

    public init(machineId: String?) {
        self.machineId = machineId
        self.includesMachineID = true
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includesMachineID = container.contains(.machineId)
        machineId = includesMachineID ? try container.decodeIfPresent(String.self, forKey: .machineId) : nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard includesMachineID else { return }
        if let machineId {
            try container.encode(machineId, forKey: .machineId)
        } else {
            try container.encodeNil(forKey: .machineId)
        }
    }
}

/// `PUT /api/agents/:id/hosted-runtime/model` request body.
///
/// The directory reads `model` as a model id or `null`, and treats a missing
/// key as `hosted_runtime_model_invalid`. `includesModel` keeps `null`
/// (reset to the default) distinct from `{}`.
public struct AgentHostedModelDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var model: String?
    /// `true` when the request carried the `model` key, including `null`.
    public var includesModel: Bool

    private enum CodingKeys: String, CodingKey {
        case model
    }

    public init(model: String?) {
        self.model = model
        self.includesModel = true
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includesModel = container.contains(.model)
        model = includesModel ? try container.decodeIfPresent(String.self, forKey: .model) : nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard includesModel else { return }
        if let model {
            try container.encode(model, forKey: .model)
        } else {
            try container.encodeNil(forKey: .model)
        }
    }
}

/// `PATCH /api/provider-connections/:id` request body.
///
/// The route refuses a body with any key outside
/// `name|providerId|apiKey|endpointUrl|supportsImageInput|authMethod`, and
/// refuses `apiKey` together with `providerId` because a credential rotates on
/// its own route. Both checks read key *presence* (a `null` counts), so
/// `presentKeys` re-emits `null` for every key the request carried and
/// `init(from:)` rejects an unknown key so the raw parser keeps its 400.
public struct ProviderConnectionToggleDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var name: String?
    public var providerId: String?
    public var apiKey: String?
    public var endpointUrl: String?
    public var supportsImageInput: Bool?
    public var authMethod: String?
    /// Keys the request carried, including those whose value is `null`.
    public var presentKeys: Set<String>

    public static let allowedKeys: Set<String> = [
        "name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod",
    ]

    private enum CodingKeys: String, CodingKey {
        case name, providerId, apiKey, endpointUrl, supportsImageInput, authMethod
    }

    public init(
        name: String? = nil,
        providerId: String? = nil,
        apiKey: String? = nil,
        endpointUrl: String? = nil,
        supportsImageInput: Bool? = nil,
        authMethod: String? = nil,
        presentKeys: Set<String>? = nil
    ) {
        self.name = name
        self.providerId = providerId
        self.apiKey = apiKey
        self.endpointUrl = endpointUrl
        self.supportsImageInput = supportsImageInput
        self.authMethod = authMethod
        if let presentKeys {
            self.presentKeys = presentKeys
        } else {
            var inferred: Set<String> = []
            if name != nil { inferred.insert("name") }
            if providerId != nil { inferred.insert("providerId") }
            if apiKey != nil { inferred.insert("apiKey") }
            if endpointUrl != nil { inferred.insert("endpointUrl") }
            if supportsImageInput != nil { inferred.insert("supportsImageInput") }
            if authMethod != nil { inferred.insert("authMethod") }
            self.presentKeys = inferred
        }
    }

    public init(from decoder: any Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyJSONKey.self)
        let keys = Set(dynamic.allKeys.map(\.stringValue))
        guard keys.isSubset(of: Self.allowedKeys) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown provider connection key"
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presentKeys = keys
        name = keys.contains("name") ? try container.decodeIfPresent(String.self, forKey: .name) : nil
        providerId = keys.contains("providerId") ? try container.decodeIfPresent(String.self, forKey: .providerId) : nil
        apiKey = keys.contains("apiKey") ? try container.decodeIfPresent(String.self, forKey: .apiKey) : nil
        endpointUrl = keys.contains("endpointUrl") ? try container.decodeIfPresent(String.self, forKey: .endpointUrl) : nil
        supportsImageInput = keys.contains("supportsImageInput")
            ? try container.decodeIfPresent(Bool.self, forKey: .supportsImageInput)
            : nil
        authMethod = keys.contains("authMethod") ? try container.decodeIfPresent(String.self, forKey: .authMethod) : nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if presentKeys.contains("name") { try encodeOptional(name, into: &container, forKey: .name) }
        if presentKeys.contains("providerId") { try encodeOptional(providerId, into: &container, forKey: .providerId) }
        if presentKeys.contains("apiKey") { try encodeOptional(apiKey, into: &container, forKey: .apiKey) }
        if presentKeys.contains("endpointUrl") { try encodeOptional(endpointUrl, into: &container, forKey: .endpointUrl) }
        if presentKeys.contains("supportsImageInput") {
            if let supportsImageInput {
                try container.encode(supportsImageInput, forKey: .supportsImageInput)
            } else {
                try container.encodeNil(forKey: .supportsImageInput)
            }
        }
        if presentKeys.contains("authMethod") { try encodeOptional(authMethod, into: &container, forKey: .authMethod) }
    }

    private func encodeOptional(
        _ value: String?,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

/// `POST /api/integrations/agents/:agentId/grants` request body.
///
/// `clientId` names the installed App and `scopes` is the requested capability
/// set. The directory drops non-string scope elements and answers
/// `clientId is required` when the App is absent, so a missing client keeps the
/// raw 400.
public struct AgentGrantCreateDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var clientId: String
    public var scopes: [String]?

    public init(clientId: String, scopes: [String]? = nil) {
        self.clientId = clientId
        self.scopes = scopes
    }
}

/// `POST /api/integrations/requests/:requestId/approve` request body.
///
/// `remember` is the only key the route reads; anything that is not a Boolean
/// keeps the raw parser's `false` fallback.
public struct AgentAccessRequestApproveDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var remember: Bool?

    public init(remember: Bool? = nil) {
        self.remember = remember
    }
}

/// `POST /internal/agent/:agentId/runtime-profile/migration-done` request body.
///
/// The runtime-profile migration acknowledgment is deprecated: the route reads
/// `migrationKey` only to decide between the "no pending migration" and the
/// generic deprecated reply, and a missing or non-string key reads as empty.
public struct AgentRuntimeProfileMigrationDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var migrationKey: String?

    public init(migrationKey: String? = nil) {
        self.migrationKey = migrationKey
    }
}

/// `PATCH /internal/agent/:agentId/server` request body.
///
/// `name` is the only key the legacy agent surface reads; the directory answers
/// `Invalid server update` when it is absent or not a string, so an omitted key
/// keeps the raw 400.
public struct LegacyAgentServerPatchDTO: Codable, Sendable, Equatable, AgentsAndComputersRequestDTO {
    public var name: String?

    public init(name: String? = nil) {
        self.name = name
    }
}
