import Foundation
import RaftShared

// MARK: - Lenient request reading
//
// The retired handlers read each body through the untyped Foundation parser and
// a per-field `as?` cast. A body that is not a JSON object read as an empty object, and a
// value of the wrong JSON type read as absent. `LegacyJSONObject` keeps that
// tolerance on top of `Decodable`, including the Foundation bridging the casts
// had: a JSON boolean reads as `Int` 1/0 and a JSON number of exactly 0 or 1
// reads as `Bool`.

struct LegacyJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// One JSON scalar as the retired `as?` casts saw it.
private enum LegacyJSONScalar: Decodable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case other

    init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int.self) {
            self = .int(value)
        } else if let value = try? single.decode(Double.self) {
            self = .double(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }
}

/// A JSON object read with the legacy per-field casts.
struct LegacyJSONObject {
    private let container: KeyedDecodingContainer<LegacyJSONKey>?

    init(_ decoder: any Decoder) {
        container = try? decoder.container(keyedBy: LegacyJSONKey.self)
    }

    private init(container: KeyedDecodingContainer<LegacyJSONKey>?) {
        self.container = container
    }

    private func key(_ name: String) -> LegacyJSONKey? { LegacyJSONKey(stringValue: name) }

    /// The key is present, whatever its value (JSON `null` included).
    func has(_ name: String) -> Bool {
        guard let container, let key = key(name) else { return false }
        return container.contains(key)
    }

    /// The key is present and JSON `null` (the `NSNull` case).
    func isNull(_ name: String) -> Bool {
        guard let container, let key = key(name) else { return false }
        return (try? container.decodeNil(forKey: key)) ?? false
    }

    func string(_ name: String) -> String? {
        guard let container, let key = key(name) else { return nil }
        return (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    func int(_ name: String) -> Int? {
        guard let container, let key = key(name),
              let scalar = (try? container.decodeIfPresent(LegacyJSONScalar.self, forKey: key)) ?? nil
        else { return nil }
        switch scalar {
        case .bool(let value): return value ? 1 : 0
        case .int(let value): return value
        case .double(let value):
            guard value.rounded() == value, value >= Double(Int.min), value < Double(Int.max) else { return nil }
            return Int(value)
        case .string, .other: return nil
        }
    }

    func bool(_ name: String) -> Bool? {
        guard let container, let key = key(name),
              let scalar = (try? container.decodeIfPresent(LegacyJSONScalar.self, forKey: key)) ?? nil
        else { return nil }
        switch scalar {
        case .bool(let value): return value
        case .int(let value): return value == 0 ? false : (value == 1 ? true : nil)
        case .double(let value): return value == 0 ? false : (value == 1 ? true : nil)
        case .string, .other: return nil
        }
    }

    /// A nested JSON object (an `as?` dictionary cast).
    func object(_ name: String) -> LegacyJSONObject? {
        guard let container, let key = key(name),
              let nested = try? container.nestedContainer(keyedBy: LegacyJSONKey.self, forKey: key)
        else { return nil }
        return LegacyJSONObject(container: nested)
    }

    /// A JSON object kept whole, for a member the service only stores.
    func jsonObject(_ name: String) -> [String: JSONValue]? {
        guard let container, let key = key(name) else { return nil }
        return (try? container.decodeIfPresent([String: JSONValue].self, forKey: key)) ?? nil
    }

    /// The string elements of a JSON array (`(as? [Any])?.compactMap { as? String }`).
    func strings(_ name: String) -> [String]? {
        guard let container, let key = key(name),
              let elements = (try? container.decodeIfPresent([JSONValue].self, forKey: key)) ?? nil
        else { return nil }
        return elements.compactMap { element in
            if case .string(let value) = element { return value }
            return nil
        }
    }
}

// MARK: - Request bodies

/// A body that carries only `migrationGeneration` (`start-transfer`, `flip-machine`).
public struct MigrationGenerationRequest: Decodable, Sendable, Equatable {
    public var migrationGeneration: String?

    public init(migrationGeneration: String? = nil) {
        self.migrationGeneration = migrationGeneration
    }

    public init(from decoder: any Decoder) throws {
        migrationGeneration = LegacyJSONObject(decoder).string("migrationGeneration")
    }
}

/// An optional string member of the arrival body: absent or `null`, a value, or
/// a present value that is not a non-empty string.
public enum MigrationReportField: Sendable, Equatable {
    case absent
    case value(String)
    case invalid

    init(_ object: LegacyJSONObject, _ name: String) {
        guard object.has(name), !object.isNull(name) else {
            self = .absent
            return
        }
        if let text = object.string(name), !text.isEmpty {
            self = .value(text)
        } else {
            self = .invalid
        }
    }
}

/// `POST /internal/computer/agent-migrations/by-id/:id/arrived`.
public struct MigrationArrivalRequest: Decodable, Sendable, Equatable {
    public var migrationGeneration: String?
    public var reportPath: MigrationReportField
    public var reportSha256: MigrationReportField

    public init(
        migrationGeneration: String? = nil,
        reportPath: MigrationReportField = .absent,
        reportSha256: MigrationReportField = .absent
    ) {
        self.migrationGeneration = migrationGeneration
        self.reportPath = reportPath
        self.reportSha256 = reportSha256
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        migrationGeneration = object.string("migrationGeneration")
        reportPath = MigrationReportField(object, "reportPath")
        reportSha256 = MigrationReportField(object, "reportSha256")
    }
}

/// `POST /internal/computer/agent-migrations/by-id/:id/transport-lost`.
public struct MigrationTransportLostRequest: Decodable, Sendable, Equatable {
    public var code: String?
    public var message: String?
    public var detailCode: String?
    public var transportGeneration: String?

    public init(
        code: String? = nil,
        message: String? = nil,
        detailCode: String? = nil,
        transportGeneration: String? = nil
    ) {
        self.code = code
        self.message = message
        self.detailCode = detailCode
        self.transportGeneration = transportGeneration
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        code = object.string("code")
        message = object.string("message")
        detailCode = object.string("detailCode")
        transportGeneration = object.string("transportGeneration")
    }
}

/// `POST /internal/computer/agent-migrations/by-id/:id/cancel-ack`.
public struct MigrationCancelAckRequest: Decodable, Sendable, Equatable {
    public var migrationRef: String?
    public var transportGeneration: String?
    public var cancelGeneration: String?
    public var role: String?
    public var outcome: String?

    public init(
        migrationRef: String? = nil,
        transportGeneration: String? = nil,
        cancelGeneration: String? = nil,
        role: String? = nil,
        outcome: String? = nil
    ) {
        self.migrationRef = migrationRef
        self.transportGeneration = transportGeneration
        self.cancelGeneration = cancelGeneration
        self.role = role
        self.outcome = outcome
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        migrationRef = object.string("migrationRef")
        transportGeneration = object.string("transportGeneration")
        cancelGeneration = object.string("cancelGeneration")
        role = object.string("role")
        outcome = object.string("outcome")
    }
}

/// `POST /internal/computer/agent-migrations/by-id/:id/resumable/source-quiesced`.
public struct MigrationSourceQuiescedRequest: Decodable, Sendable, Equatable {
    /// The `receipt` object, kept whole; any other value reads as absent.
    public var receipt: [String: JSONValue]?

    public init(receipt: [String: JSONValue]? = nil) {
        self.receipt = receipt
    }

    public init(from decoder: any Decoder) throws {
        receipt = LegacyJSONObject(decoder).jsonObject("receipt")
    }
}

/// `POST …/resumable/chunks/:index/receipt`.
public struct MigrationChunkReceiptRequest: Decodable, Sendable, Equatable {
    public var sha256: String?

    public init(sha256: String? = nil) {
        self.sha256 = sha256
    }

    public init(from decoder: any Decoder) throws {
        sha256 = LegacyJSONObject(decoder).string("sha256")
    }
}

/// One chunk of the resumable control manifest as the Computer declared it.
public struct MigrationManifestChunk: Decodable, Sendable, Equatable {
    public var index: Int?
    public var sizeBytes: Int?
    public var sha256: String?

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        index = object.int("index")
        sizeBytes = object.int("sizeBytes")
        sha256 = object.string("sha256")
    }
}

/// The `bundle.chunks` table of `POST …/resumable/control`. The route stores the
/// raw body text, so this type only reads it for validation; a body that is not
/// an object with a `bundle.chunks` array reads as `nil`.
public struct MigrationControlManifestRequest: Decodable, Sendable, Equatable {
    public var chunks: [MigrationManifestChunk]?

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: LegacyJSONKey.self)
        let bundle = try? root.nestedContainer(keyedBy: LegacyJSONKey.self, forKey: LegacyJSONKey(stringValue: "bundle")!)
        chunks = (try? bundle?.decodeIfPresent([MigrationManifestChunk].self, forKey: LegacyJSONKey(stringValue: "chunks")!)) ?? nil
    }
}

/// The `machineId` member of the assign-machine body.
public enum AgentAssignMachineField: Sendable, Equatable {
    /// The key is missing: `machineId is required`.
    case missing
    /// JSON `null`: clear the assignment.
    case unassign
    case machine(String)
    /// Present but neither `null` nor a non-empty string.
    case invalid
}

/// `POST /api/agents/:id/assign-machine`.
public struct AgentAssignMachineRequest: Decodable, Sendable, Equatable {
    public var machineId: AgentAssignMachineField

    public init(machineId: AgentAssignMachineField = .missing) {
        self.machineId = machineId
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        guard object.has("machineId") else {
            machineId = .missing
            return
        }
        if object.isNull("machineId") {
            machineId = .unassign
        } else if let value = object.string("machineId"), !value.isEmpty {
            machineId = .machine(value)
        } else {
            machineId = .invalid
        }
    }
}

/// `POST /api/agents/:id/credentials`.
public struct AgentCredentialIssueRequest: Decodable, Sendable, Equatable {
    public var scopes: [String]

    public init(scopes: [String] = []) {
        self.scopes = scopes
    }

    public init(from decoder: any Decoder) throws {
        scopes = LegacyJSONObject(decoder).strings("scopes") ?? []
    }
}

// MARK: - Responses

/// The view of a migration row the target Computer reads back.
public struct MigrationTargetView: Sendable, Equatable {
    public var migrationRef: String
    public var agentId: String
    public var state: String
    public var migrationGeneration: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var failureReason: String?
    public var transportErrorCode: String?
    public var transportErrorMessage: String?
    public var autoStartFailureStage: String?
    public var autoStartFailureCode: String?
    public var completedAt: String?

    init(_ record: MachineMigrationRecord) {
        migrationRef = record.supportRef
        agentId = record.agentId
        state = record.state
        migrationGeneration = record.transportGeneration
        sourceMachineId = record.sourceMachineId
        targetMachineId = record.targetMachineId
        failureReason = record.failureReason
        transportErrorCode = record.transportErrorCode
        transportErrorMessage = record.transportErrorMessage
        autoStartFailureStage = record.autoStartFailureStage
        autoStartFailureCode = record.autoStartFailureCode
        completedAt = AgentMigrationTimestamps.string(record.completedAt)
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("migrationRef", migrationRef),
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("state", state),
            OrderedJSONField("migrationGeneration", migrationGeneration),
            OrderedJSONField("sourceMachineId", sourceMachineId),
            OrderedJSONField("targetMachineId", targetMachineId),
            OrderedJSONField("canDriveTargetImport", true),
            OrderedJSONField("failureReason", optional: failureReason),
            OrderedJSONField("transportErrorCode", optional: transportErrorCode),
            OrderedJSONField("transportErrorMessage", optional: transportErrorMessage),
            OrderedJSONField("autoStartFailureStage", optional: autoStartFailureStage),
            OrderedJSONField("autoStartFailureCode", optional: autoStartFailureCode),
            OrderedJSONField("completedAt", optional: completedAt),
        ])
    }
}

/// `{"ok":true,"migration":{…}}` for every target-view callback.
public struct MigrationTargetViewResponse: JSONBodyConvertible, Sendable, Equatable {
    public var migration: MigrationTargetView

    init(_ record: MachineMigrationRecord) {
        migration = MigrationTargetView(record)
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("migration", migration.jsonBody),
        ])
    }
}

/// `GET …/resumable/control`: `{"manifest": <registered manifest text>}`.
public struct MigrationControlManifestResponse: JSONBodyConvertible, Sendable, Equatable {
    /// The manifest exactly as the Computer registered it.
    public var manifest: String

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("manifest", .raw(manifest))])
    }
}

/// `POST …/resumable/control`: `{"ok":true,"manifest": <the body text>}`.
public struct MigrationControlManifestStoredResponse: JSONBodyConvertible, Sendable, Equatable {
    public var manifest: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("manifest", .raw(manifest)),
        ])
    }
}

/// `POST …/resumable/chunks/:index/receipt`.
public struct MigrationChunkReceiptResponse: JSONBodyConvertible, Sendable, Equatable {
    public var chunkIndex: Int
    public var sha256: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("chunkIndex", chunkIndex),
            OrderedJSONField("sha256", sha256),
        ])
    }
}

/// `GET …/resumable/chunks`.
public struct MigrationChunkStatusResponse: JSONBodyConvertible, Sendable, Equatable {
    public var chunks: [Int]
    public var received: [Int]
    public var missing: [Int]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("chunks", .array(chunks.map(OrderedJSON.int))),
            OrderedJSONField("received", .array(received.map(OrderedJSON.int))),
            OrderedJSONField("missing", .array(missing.map(OrderedJSON.int))),
        ])
    }
}

/// `POST …/resumable/upload-complete`: `{"ok":true,"state":"transfer_complete"}`.
public struct MigrationUploadCompleteResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var state: String

    public init(ok: Bool = true, state: String = "transfer_complete") {
        self.ok = ok
        self.state = state
    }
}

/// `POST …/cancel-ack`.
public struct MigrationCancelAckResponse: JSONBodyConvertible, Sendable, Equatable {
    public var migrationRef: String
    public var state: String
    public var revision: Int
    public var disposition: String

    init(_ view: MachineMigrationCancelAckView) {
        migrationRef = view.supportRef
        state = view.state
        revision = view.revision
        disposition = view.disposition
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("migration", .object([
                OrderedJSONField("migrationRef", migrationRef),
                OrderedJSONField("state", state),
                OrderedJSONField("revision", revision),
                OrderedJSONField("disposition", disposition),
            ])),
        ])
    }
}

/// `POST …/resumable/source-quiesced`.
public struct MigrationSourceQuiescedResponse: JSONBodyConvertible, Sendable, Equatable {
    public var migrationGeneration: String
    public var leaseId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("migrationGeneration", migrationGeneration),
            OrderedJSONField("leaseId", leaseId),
        ])
    }
}

/// `POST …/resumable/source-progress`.
public struct MigrationSourceProgressResponse: JSONBodyConvertible, Sendable, Equatable {
    public var prepDeadlineAt: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("advanced", true),
            OrderedJSONField("prepDeadlineAt", prepDeadlineAt),
        ])
    }
}

/// `POST /api/agents/:id/credentials` (`201`).
public struct AgentCredentialIssuedResponse: JSONBodyConvertible, Sendable, Equatable {
    public var credentialId: String
    public var apiKey: String
    public var agentId: String
    public var serverId: String
    public var scopes: [String]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("credentialId", credentialId),
            OrderedJSONField("apiKey", apiKey),
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
        ])
    }
}

/// One masked credential row of the inventory.
public struct AgentCredentialRow: Sendable, Equatable {
    public var id: String
    public var maskedToken: String
    public var name: String
    public var scopes: [String]
    public var createdAt: String
    public var lastUsedAt: String?
    public var revokedAt: String?

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("maskedToken", maskedToken),
            OrderedJSONField("name", name),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
            OrderedJSONField("createdAt", createdAt),
            OrderedJSONField("lastUsedAt", optional: lastUsedAt),
            OrderedJSONField("revokedAt", optional: revokedAt),
        ])
    }
}

/// `GET /api/agents/:id/credentials`.
public struct AgentCredentialListResponse: JSONBodyConvertible, Sendable, Equatable {
    public var credentials: [AgentCredentialRow]

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("credentials", .array(credentials.map(\.jsonBody)))])
    }
}
