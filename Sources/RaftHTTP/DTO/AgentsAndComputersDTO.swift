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
