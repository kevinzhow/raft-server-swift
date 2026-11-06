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
