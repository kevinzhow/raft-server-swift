import Foundation

// MARK: - Request bodies
//
// The retired handlers read these bodies with the raw object cast plus per-field
// `as? String` checks. The decoders below keep that tolerance: a value of the
// wrong JSON type reads as absent, so a request the old routes accepted cannot
// become a 400. A body that is not a JSON object fails to decode and the route
// falls back to the empty request, which is the `?? [:]` the old parser used.

fileprivate struct AnyFleetKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyFleetKey {
    fileprivate func lenientString(_ key: String) -> String? {
        guard let key = AnyFleetKey(stringValue: key) else { return nil }
        return (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    fileprivate func presence(_ key: String) -> Bool {
        guard let key = AnyFleetKey(stringValue: key) else { return false }
        return contains(key)
    }

    fileprivate func decodesNil(_ key: String) -> Bool {
        guard let key = AnyFleetKey(stringValue: key) else { return false }
        return (try? decodeNil(forKey: key)) ?? false
    }
}

/// The optional `name` member of the adopt and runner-credential bodies.
///
/// The retired handlers skipped the member when it was absent or JSON `null`,
/// and answered `name_invalid` for any other value that was not a string.
public enum FleetNameField: Sendable, Equatable {
    case absent
    case value(String)
    case invalid
}

private func decodeFleetName(_ container: KeyedDecodingContainer<AnyFleetKey>) -> FleetNameField {
    guard container.presence("name"), !container.decodesNil("name") else { return .absent }
    if let text = container.lenientString("name") { return .value(text) }
    return .invalid
}

/// `POST /api/computer/attach` request body.
public struct ComputerAttachRequest: Sendable, Equatable, Decodable {
    public var serverSlug: String?
    public var name: String?

    public init(serverSlug: String? = nil, name: String? = nil) {
        self.serverSlug = serverSlug
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyFleetKey.self)
        serverSlug = container.lenientString("serverSlug")
        name = container.lenientString("name")
    }
}

/// `POST /api/computer/adopt-legacy` request body.
///
/// One of three selectors identifies the legacy daemon: the raw
/// `legacyApiKey`, the fingerprint roster triple (`serverSlug` +
/// `legacyMachineId` + `apiKeyFingerprint`), or `serverSlug` + `daemonId`. Each
/// selector reads as absent when it is not a non-empty string.
public struct ComputerAdoptLegacyRequest: Sendable, Equatable, Decodable {
    public var legacyApiKey: String?
    public var serverSlug: String?
    public var legacyMachineId: String?
    public var apiKeyFingerprint: String?
    public var daemonId: String?
    public var name: FleetNameField

    public init(
        legacyApiKey: String? = nil,
        serverSlug: String? = nil,
        legacyMachineId: String? = nil,
        apiKeyFingerprint: String? = nil,
        daemonId: String? = nil,
        name: FleetNameField = .absent
    ) {
        self.legacyApiKey = legacyApiKey
        self.serverSlug = serverSlug
        self.legacyMachineId = legacyMachineId
        self.apiKeyFingerprint = apiKeyFingerprint
        self.daemonId = daemonId
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyFleetKey.self)
        func text(_ key: String) -> String? {
            guard let value = container.lenientString(key), !value.isEmpty else { return nil }
            return value
        }
        legacyApiKey = text("legacyApiKey")
        serverSlug = text("serverSlug")
        legacyMachineId = text("legacyMachineId")
        apiKeyFingerprint = text("apiKeyFingerprint")
        daemonId = text("daemonId")
        name = decodeFleetName(container)
    }
}

/// The `scopes` member of the runner-credential body: absent, a list of strings,
/// or any other JSON value (which the retired handler rejected).
public enum FleetScopesField: Sendable, Equatable {
    case absent
    case list([String])
    case invalid
}

/// `POST /internal/computer/runners/:agentId/credentials` request body.
public struct ComputerRunnerCredentialRequest: Sendable, Equatable, Decodable {
    public var scopes: FleetScopesField
    public var name: FleetNameField

    public init(scopes: FleetScopesField = .absent, name: FleetNameField = .absent) {
        self.scopes = scopes
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyFleetKey.self)
        if container.presence("scopes"), let key = AnyFleetKey(stringValue: "scopes") {
            if let list = try? container.decode([String].self, forKey: key) {
                scopes = .list(list)
            } else {
                scopes = .invalid
            }
        } else {
            scopes = .absent
        }
        name = decodeFleetName(container)
    }
}

/// `PATCH /api/servers/:id/machines/:machineId` request body. A `description`
/// that is not a string leaves the stored description untouched.
public struct MachineDescriptionRequest: Sendable, Equatable, Decodable {
    public var description: String?

    public init(description: String? = nil) {
        self.description = description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyFleetKey.self)
        description = container.lenientString("description")
    }
}

/// `POST /api/servers/:id/machines/:machineId/computer/:action` request body;
/// only the `upgrade` action reads `targetVersion`.
public struct ComputerActionRequest: Sendable, Equatable, Decodable {
    public var targetVersion: String?

    public init(targetVersion: String? = nil) {
        self.targetVersion = targetVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyFleetKey.self)
        targetVersion = container.lenientString("targetVersion")
    }
}

/// `POST /api/servers/:id/machines/:machineId/computer-lifecycle-operations`
/// request body. `completionMode` is tracked by presence: any value, `null`
/// included, makes the member present.
public struct ComputerLifecycleRequest: Sendable, Equatable, Decodable {
    public var action: String?
    public var operationId: String?
    public var parentOperationId: String?
    public var targetVersion: String?
    public var completionModePresent: Bool
    public var completionMode: String?

    public init(
        action: String? = nil,
        operationId: String? = nil,
        parentOperationId: String? = nil,
        targetVersion: String? = nil,
        completionModePresent: Bool = false,
        completionMode: String? = nil
    ) {
        self.action = action
        self.operationId = operationId
        self.parentOperationId = parentOperationId
        self.targetVersion = targetVersion
        self.completionModePresent = completionModePresent
        self.completionMode = completionMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyFleetKey.self)
        action = container.lenientString("action")
        operationId = container.lenientString("operationId")
        parentOperationId = container.lenientString("parentOperationId")
        targetVersion = container.lenientString("targetVersion")
        completionModePresent = container.presence("completionMode")
        completionMode = container.lenientString("completionMode")
    }
}

// MARK: - Response bodies

/// One creator reference on a machine roster row.
public struct ServerMachineCreator: Sendable, Equatable {
    public var id: String
    public var name: String
    public var displayName: String?
    public var avatarUrl: String?
    public var gravatarHash: String

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("type", "human"),
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("displayName", optional: displayName),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
            OrderedJSONField("gravatarHash", gravatarHash),
        ])
    }
}

/// One row of `GET /api/servers/:id/machines`.
public struct ServerMachineEntry: Sendable, Equatable {
    public var id: String
    public var name: String
    public var userId: String
    public var description: String?
    public var isComputer: Bool
    public var computerAttachedByCurrentUser: Bool
    public var agentCount: Int
    public var creator: ServerMachineCreator?
    public var status: String
    public var statusVersion: Int
    public var runtimes: [String]
    /// `nil` publishes JSON `null` (the machine is not a Computer).
    public var computerUpgradeAvailable: Bool?
    public var computerBroadcastPolicy: OrderedJSON
    public var runtimeVersions: [String: String] = [:]
    public var runtimeDetection: MachineRuntimeDetectionFact? = nil
    public var hostname: String? = nil
    public var lastHeartbeat: String? = nil

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("userId", userId),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("isComputer", isComputer),
            OrderedJSONField("computerAttachedByCurrentUser", computerAttachedByCurrentUser),
            OrderedJSONField("agentCount", agentCount),
            OrderedJSONField("creator", creator?.jsonBody ?? .null),
            OrderedJSONField("status", status),
            OrderedJSONField("statusVersion", statusVersion),
            OrderedJSONField("runtimes", .array(runtimes.map(OrderedJSON.string))),
            OrderedJSONField("runtimeVersions", .object(runtimeVersions.sorted { $0.key < $1.key }.map { .init($0.key, $0.value) })),
            OrderedJSONField("runtimeDetection", runtimeDetection?.jsonBody ?? .null),
            OrderedJSONField("hostname", optional: hostname),
            OrderedJSONField("lastHeartbeat", optional: lastHeartbeat),
            OrderedJSONField("computerUpgradeAvailable", optional: computerUpgradeAvailable),
            OrderedJSONField("computerBroadcastPolicy", computerBroadcastPolicy),
        ])
    }
}

/// `GET /api/servers/:id/machines`.
public struct ServerMachinesResponse: Sendable, Equatable, JSONBodyConvertible {
    public var machines: [ServerMachineEntry]
    public var latestComputerVersion: String?
    /// The stored release-notes fragment, already valid JSON text.
    public var latestComputerReleaseNotesJSON: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("machines", .array(machines.map(\.jsonBody))),
            OrderedJSONField("latestComputerVersion", optional: latestComputerVersion),
            OrderedJSONField(
                "latestComputerReleaseNotes",
                latestComputerReleaseNotesJSON.map(OrderedJSON.raw) ?? .null
            ),
        ])
    }
}

/// `PATCH /api/servers/:id/machines/:machineId`: `id`, `name`, `description`.
public struct MachineDescriptionResponse: Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var name: String
    public var description: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("description", optional: description),
        ])
    }
}

/// `POST /api/servers/:id/machines/:machineId/rotate-key`.
public struct MachineKeyRotationResponse: Codable, Sendable, Equatable {
    public var apiKey: String
}

/// `POST /api/computer/attach` (201).
public struct ComputerAttachResponse: Sendable, Equatable, JSONBodyConvertible {
    public var apiKey: String
    public var serverMachineId: String
    public var machineId: String
    public var serverId: String
    public var serverSlug: String
    public var name: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("apiKey", apiKey),
            OrderedJSONField("serverMachineId", serverMachineId),
            OrderedJSONField("machineId", machineId),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("serverSlug", serverSlug),
            OrderedJSONField("name", name),
            OrderedJSONField("resumed", false),
        ])
    }
}

/// `POST /api/computer/adopt-legacy` (201).
public struct ComputerAdoptResponse: Sendable, Equatable, JSONBodyConvertible {
    public var apiKey: String
    public var computerId: String
    public var machineId: String
    public var serverId: String
    public var resumed: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("apiKey", apiKey),
            OrderedJSONField("computerId", computerId),
            OrderedJSONField("machineId", machineId),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("resumed", resumed),
        ])
    }
}

/// One row of `GET /api/computer/legacy-machines`.
public struct LegacyMachineEntry: Sendable, Equatable {
    public var daemonId: String
    public var machineName: String
    public var hostname: String?
    public var lastSeenAt: String?
    public var hasFingerprint: Bool
    public var legacyKeyMigratedAt: String?
    /// Published only when the roster is not `includeAll` and the row has one.
    public var apiKeyFingerprint: String?

    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("daemonId", daemonId)
        body.append("machineName", machineName)
        body.append("hostname", optional: hostname)
        body.append("lastSeenAt", optional: lastSeenAt)
        body.append("hasFingerprint", hasFingerprint)
        body.append("legacyKeyMigratedAt", optional: legacyKeyMigratedAt)
        body.append("apiKeyFingerprint", ifPresent: apiKeyFingerprint)
        return body.json
    }
}

/// `GET /api/computer/legacy-machines`.
public struct LegacyMachinesResponse: Sendable, Equatable, JSONBodyConvertible {
    public var serverId: String
    public var serverSlug: String
    public var entries: [LegacyMachineEntry]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("serverSlug", serverSlug),
            OrderedJSONField("entries", .array(entries.map(\.jsonBody))),
        ])
    }
}

/// `POST /internal/computer/runners/:agentId/credentials` (201).
public struct ComputerRunnerCredentialResponse: Sendable, Equatable, JSONBodyConvertible {
    public var credentialId: String
    public var apiKey: String
    public var scopes: [String]
    public var agentId: String
    public var agentName: String
    public var serverId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("credentialId", credentialId),
            OrderedJSONField("apiKey", apiKey),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("agentName", agentName),
            OrderedJSONField("serverId", serverId),
        ])
    }
}

/// One whitelisted runner row. The whitelist is the projection: no other agent
/// field can reach the wire.
public struct ComputerRunnerEntry: Sendable, Equatable {
    public var agentId: String
    public var name: String
    public var status: String
    public var model: String
    public var runtime: String

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("name", name),
            OrderedJSONField("status", status),
            OrderedJSONField("model", model),
            OrderedJSONField("runtime", runtime),
        ])
    }
}

/// `GET /internal/computer/runners`.
public struct ComputerRunnersResponse: Sendable, Equatable, JSONBodyConvertible {
    public static let whitelist = ["agentId", "name", "status", "model", "runtime"]
    public var runners: [ComputerRunnerEntry]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("whitelist", .array(Self.whitelist.map(OrderedJSON.string))),
            OrderedJSONField("runners", .array(runners.map(\.jsonBody))),
        ])
    }
}

/// `POST /internal/computer/runners/:agentId/stop`.
public struct ComputerRunnerStopResponse: Codable, Sendable, Equatable {
    public var agentId: String
}

/// `DELETE /internal/computer/runners/:agentId/credentials/:credentialId`.
public struct ComputerRunnerCredentialRevokeResponse: Codable, Sendable, Equatable {
    public var agentId: String
    public var credentialId: String
    public var revoked: Bool
}

/// `POST /api/servers/:id/machines/:machineId/computer/:action`.
public struct ComputerActionResponse: Sendable, Equatable, JSONBodyConvertible {
    public var action: String
    public var requestId: String
    public var operationId: String
    public var computerVersion: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("action", action),
            OrderedJSONField("requestId", requestId),
            OrderedJSONField("operationId", operationId),
            OrderedJSONField("computerVersion", computerVersion),
        ])
    }
}

/// `POST /api/servers/:id/machines/:machineId/runtimes/rescan`.
public struct MachineRuntimeRescanResponse: Codable, Sendable, Equatable {
    public var requested: Bool

    public init(requested: Bool = true) {
        self.requested = requested
    }
}

/// One model row of the label catalog.
public struct ModelLabelCatalogModel: Sendable, Equatable {
    public var id: String
    public var label: String
}

/// One runtime of one machine in the label catalog.
public struct ModelLabelCatalogRuntime: Sendable, Equatable {
    public var runtime: String
    public var models: [ModelLabelCatalogModel]
    public var updatedAt: String
}

/// One machine of the label catalog.
public struct ModelLabelCatalogMachine: Sendable, Equatable {
    public var machineId: String
    public var runtimes: [ModelLabelCatalogRuntime]
}

/// `GET /api/servers/:id/model-label-catalog`.
public struct ModelLabelCatalogResponse: Sendable, Equatable, JSONBodyConvertible {
    public var machines: [ModelLabelCatalogMachine]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("machines", .object(machines.map { machine in
                OrderedJSONField(machine.machineId, .object([
                    OrderedJSONField("runtimes", .object(machine.runtimes.map { runtime in
                        OrderedJSONField(runtime.runtime, .object([
                            OrderedJSONField("models", .array(runtime.models.map { model in
                                .object([
                                    OrderedJSONField("id", model.id),
                                    OrderedJSONField("label", model.label),
                                ])
                            })),
                            OrderedJSONField("updatedAt", runtime.updatedAt),
                        ]))
                    })),
                ]))
            })),
        ])
    }
}

/// `POST /api/servers/:id/machines/:machineId/computer-lifecycle-operations`
/// (201).
public struct ComputerLifecycleOperationResponse: Sendable, Equatable, JSONBodyConvertible {
    public var operationId: String
    public var parentOperationId: String
    public var serverId: String
    public var machineId: String
    public var actorUserId: String
    public var action: String
    public var targetVersion: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("operationId", operationId),
            OrderedJSONField("parentOperationId", parentOperationId),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("machineId", machineId),
            OrderedJSONField("actorUserId", actorUserId),
            OrderedJSONField("action", action),
            OrderedJSONField("dispatchMode", "local"),
            OrderedJSONField("connectionEpochBefore", .null),
            OrderedJSONField("targetVersion", optional: targetVersion),
        ])
    }
}
