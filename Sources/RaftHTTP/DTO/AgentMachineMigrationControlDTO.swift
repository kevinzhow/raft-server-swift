import Foundation

// MARK: - Request bodies
//
// Each decoder keeps the retired per-field `as?` tolerance through
// `LegacyJSONObject` (see `AgentHostedMigrationDTO.swift`): a body that is not a
// JSON object reads as empty and a value of the wrong type reads as absent.

/// The optional `target.hostedModel` member: absent, a value, or a present
/// value that is not a string (JSON `null` included).
public enum HostedTargetModelField: Sendable, Equatable {
    case absent
    case value(String)
    case invalid
}

/// The hosted target of a migrate request.
public struct HostedMigrationTarget: Sendable, Equatable {
    /// `target.provider` when it is a string; the default provider otherwise.
    public var provider: String?
    public var hostedModel: HostedTargetModelField

    public init(provider: String? = nil, hostedModel: HostedTargetModelField = .absent) {
        self.provider = provider
        self.hostedModel = hostedModel
    }
}

/// `POST /api/agents/:id/migrate`.
public struct AgentMigrateRequest: Decodable, Sendable, Equatable {
    /// Set when `target.kind` is `hosted`.
    public var hostedTarget: HostedMigrationTarget?
    public var targetComputer: String?

    public init(hostedTarget: HostedMigrationTarget? = nil, targetComputer: String? = nil) {
        self.hostedTarget = hostedTarget
        self.targetComputer = targetComputer
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        targetComputer = object.string("targetComputer")
        if let target = object.object("target"), target.string("kind") == "hosted" {
            let model: HostedTargetModelField
            if target.has("hostedModel") {
                model = target.string("hostedModel").map(HostedTargetModelField.value) ?? .invalid
            } else {
                model = .absent
            }
            hostedTarget = HostedMigrationTarget(provider: target.string("provider"), hostedModel: model)
        }
    }
}

/// `PUT /api/agents/:id/scopes`.
public struct AgentScopesUpdateRequest: Decodable, Sendable, Equatable {
    public var mode: String?

    public init(mode: String? = nil) {
        self.mode = mode
    }

    public init(from decoder: any Decoder) throws {
        mode = LegacyJSONObject(decoder).string("mode")
    }
}

/// `POST /api/agents/:id/archive/workspace`.
public struct AgentArchiveWorkspaceRequest: Decodable, Sendable, Equatable {
    public var action: String?

    public init(action: String? = nil) {
        self.action = action
    }

    public init(from decoder: any Decoder) throws {
        action = LegacyJSONObject(decoder).string("action")
    }
}

/// `DELETE /api/agents/:id`.
public struct AgentDeleteRequest: Decodable, Sendable, Equatable {
    public var workspace: String?

    public init(workspace: String? = nil) {
        self.workspace = workspace
    }

    public init(from decoder: any Decoder) throws {
        workspace = LegacyJSONObject(decoder).string("workspace")
    }
}

/// `POST /api/agents/:id/reset`.
public struct AgentResetRequest: Decodable, Sendable, Equatable {
    public var mode: String?
    public var clearWorkspace: Bool?

    public init(mode: String? = nil, clearWorkspace: Bool? = nil) {
        self.mode = mode
        self.clearWorkspace = clearWorkspace
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        mode = object.string("mode")
        clearWorkspace = object.bool("clearWorkspace")
    }
}

// MARK: - Responses

/// `{"migration": <hosted status>}` for the hosted confirmation.
public struct HostedMigrationConfirmedResponse: JSONBodyConvertible, Sendable, Equatable {
    public var migration: HostedAgentMigrationStatus

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("migration", migration.jsonBody)])
    }
}

/// The reply that starts a hosted migration.
public struct HostedMigrationStartedResponse: Sendable, Equatable {
    public var migrationRef: String
    public var state: String
    public var sourceMachineId: String?
    public var deadlineAt: String

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("migrationRef", migrationRef),
            OrderedJSONField("state", state),
            OrderedJSONField("targetKind", "hosted"),
            OrderedJSONField("sourceMachineId", optional: sourceMachineId),
            OrderedJSONField("targetMachineId", .null),
            OrderedJSONField("prepDeadlineAt", deadlineAt),
            OrderedJSONField("transferDeadlineAt", deadlineAt),
            OrderedJSONField("arrivalDeadlineAt", deadlineAt),
        ])
    }
}

/// The reply that starts a Computer migration.
public struct MachineMigrationStartedResponse: Sendable, Equatable {
    public var migrationRef: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var deadlineAt: String

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("migrationRef", migrationRef),
            OrderedJSONField("state", "provisioning"),
            OrderedJSONField("sourceMachineId", sourceMachineId),
            OrderedJSONField("targetMachineId", targetMachineId),
            OrderedJSONField("targetKind", "computer"),
            OrderedJSONField("prepDeadlineAt", deadlineAt),
            OrderedJSONField("transferDeadlineAt", deadlineAt),
            OrderedJSONField("arrivalDeadlineAt", deadlineAt),
        ])
    }
}

/// The answer to `POST /api/agents/:id/migrate`: the status differs per variant.
public enum AgentMigrateResponse: JSONBodyConvertible, Sendable, Equatable {
    case hosted(HostedMigrationStartedResponse)
    case computer(MachineMigrationStartedResponse)
    /// Neither a hosted target nor a target Computer: accepted, nothing queued.
    case accepted

    public var status: UInt {
        switch self {
        case .hosted, .computer: 200
        case .accepted: 202
        }
    }

    public var jsonBody: OrderedJSON {
        switch self {
        case .hosted(let started): started.jsonBody
        case .computer(let started): started.jsonBody
        case .accepted:
            .object([OrderedJSONField("ok", true), OrderedJSONField("status", "accepted")])
        }
    }
}

/// `{"ok":true,"status":"accepted"}` (`202`).
public struct AgentAcceptedResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var status: String

    public init(ok: Bool = true, status: String = "accepted") {
        self.ok = ok
        self.status = status
    }
}

/// `{"activity":"idle","detail":""}`.
public struct AgentIdleActivityResponse: Codable, Sendable, Equatable {
    public var activity: String
    public var detail: String

    public init(activity: String = "idle", detail: String = "") {
        self.activity = activity
        self.detail = detail
    }
}

/// A body the machine-backed provider already rendered, published unchanged
/// (the activity log, the summaries and the skills list, or their empty
/// defaults).
public struct AgentSurfaceBodyResponse: JSONBodyConvertible, Sendable, Equatable {
    public var body: String

    public init(body: String) {
        self.body = body
    }

    public var jsonBody: OrderedJSON { .raw(body) }
}

/// `{"files": <tree the Computer returned>}`.
public struct AgentWorkspaceFilesResponse: JSONBodyConvertible, Sendable, Equatable {
    public var files: String

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("files", .raw(files))])
    }
}

/// One DM row of `GET /api/agents/:id/agent-dms`.
public struct AgentDirectMessageRow: Sendable, Equatable {
    public var id: String
    public var peerId: String
    public var peerName: String
    public var lastMessagePreview: String?

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("peerId", peerId),
            OrderedJSONField("peerName", peerName),
            OrderedJSONField("lastMessagePreview", optional: lastMessagePreview),
        ])
    }
}

/// `GET /api/agents/:id/agent-dms`: a bare array.
public struct AgentDirectMessagesResponse: JSONBodyConvertible, Sendable, Equatable {
    public var rows: [AgentDirectMessageRow]

    public var jsonBody: OrderedJSON {
        .array(rows.map(\.jsonBody))
    }
}

/// `GET`/`PUT /api/agents/:id/scopes`.
public struct AgentScopesResponse: JSONBodyConvertible, Sendable, Equatable {
    public var agentId: String
    public var mode: String
    public var scopes: [String]
    public var revision: Int

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("mode", mode),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
            OrderedJSONField("revision", revision),
        ])
    }
}

/// The archived-workspace projection.
public struct AgentArchiveView: Sendable, Equatable {
    public var agentId: String
    public var archivedAt: String
    public var archivedByUserId: String
    public var machineId: String?
    public var machineName: String?
    public var workspaceState: String
    public var pendingOp: String?
    public var waitingForComputer: Bool
    public var lastErrorCode: String?
    public var lastErrorAt: String?

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("archivedAt", archivedAt),
            OrderedJSONField("archivedByUserId", archivedByUserId),
            OrderedJSONField("machineId", optional: machineId),
            OrderedJSONField("machineName", optional: machineName),
            OrderedJSONField("workspaceState", workspaceState),
            OrderedJSONField("pendingOp", optional: pendingOp),
            OrderedJSONField("waitingForComputer", waitingForComputer),
            OrderedJSONField("lastErrorCode", optional: lastErrorCode),
            OrderedJSONField("lastErrorAt", optional: lastErrorAt),
        ])
    }
}

/// `{"archive": …}`.
public struct AgentArchiveResponse: JSONBodyConvertible, Sendable, Equatable {
    public var archive: AgentArchiveView

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("archive", archive.jsonBody)])
    }
}

/// One row of `GET /api/agents/:id/channels`.
public struct AgentChannelRow: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public var type: String
    public var createdAt: String
    public var activityMuted: Bool
    public var muteFromSeq: Int?

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("type", type),
            OrderedJSONField("createdAt", createdAt),
            OrderedJSONField("archivedAt", .null),
            OrderedJSONField("activityMuted", activityMuted),
            OrderedJSONField("muteFromSeq", optional: muteFromSeq),
        ])
    }
}

/// `GET /api/agents/:id/channels`: a bare array.
public struct AgentChannelsResponse: JSONBodyConvertible, Sendable, Equatable {
    public var rows: [AgentChannelRow]

    public var jsonBody: OrderedJSON {
        .array(rows.map(\.jsonBody))
    }
}
