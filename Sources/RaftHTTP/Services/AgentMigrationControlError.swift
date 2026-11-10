import Foundation

/// Every published refusal of the hosted/machine migration transport, the
/// migration control plane and the agent routes that share its authority rules.
///
/// The retired handlers printed these bodies by hand and the key order is part
/// of the contract: the transport and agent routes print `code` before `error`,
/// the hosted-migration refusals print `error`, `code` and a `details` object,
/// and the archive/runtime routes print `error` before `code`. `shape` owns the
/// order for each case; `Respond.swift` renders `errorBody`.
public enum AgentMigrationControlError: DomainError, Equatable {
    // Plain `{"error": …}` authority failures.
    case unauthorized
    case agentNotFound
    case notAMember
    case forbidden
    case externalCannotAssign
    case machineIdRequired
    case machineIdInvalid
    case credentialNotFound
    case externalAgentsHaveNoRuntimeLifecycle
    case controlRuntimeDenied
    case deleteAgentDenied
    case resetWorkspaceDenied
    case archivedWorkspaceForbidden

    // Code first: `{"code": …, "error": …}`.
    case agentMissing
    case insufficientRole
    case agentNotExternal
    case builtinCatalogUnavailable
    case assignAlreadyInProgress
    case assignmentExecutionRequiresRecovery
    case resetInProgress
    case resetMigrationInProgress
    case agentScopesUnsupported
    case invalidReplicaReplaySignature
    case machineOfflineOwnerNotLocal
    case machineUnassigned
    case machineOffline(action: String)
    case daemonTimeout(action: String)
    case daemonOffline

    // Transport callbacks (Computer credential), code first.
    case transportTokenInvalid
    case migrationMissing
    case controlManifestMissing
    case streamedChunkInvalid
    case chunkReceiptMismatch
    case chunksMissing([Int])
    case generationRequired
    case generationStale
    case notReady
    case notFlippable
    case sourceMachineMismatch
    case notArriving
    case reportPathInvalid
    case reportSha256Invalid
    case notActive
    case cancelAckInputRequired
    case cancelGenerationStale
    case cancelNotRequested
    case cancelOutcomeMismatch
    case sourceQuiesceReceiptRequired
    case manifestTooLarge
    case manifestInvalid
    case manifestConflict

    // Hosted migration: `{"error", "code", "details": {"failureReason"}}`.
    case agentMigrationUiDisabled
    case hostedAgentNotFound
    case migrateAgentsNotSupported
    case hostedTargetDisabled
    case hostedRuntimeDisabled
    case hostedUnknownProvider
    case hostedModelInvalid
    case hostedModelPickerDisabled
    case migrationRefInvalid
    case migrationRevisionInvalid
    case hostedMigrationNotFound
    case migrationRevisionStale
    case hostedReviewNotReady
    case hostedReviewSourceMoved
    case hostedTargetAlreadyUsed
    case agentHasNoSourceMachine
    case migrationAlreadyInProgress

    // Computer migration start.
    case machineMigrationNotSupported
    case agentHasNoSourceComputer
    case computerMigrationAlreadyInProgress
    case targetComputerNotFound
    case resumableCapabilityRequired(side: String)
    case computerCapabilityInsufficient(failures: [CapabilityFailure])
    case targetComputerOffline
    case targetRuntimeDetectionPending(runtime: String, detectionStatus: String)
    case migrationProPlanRequired
    case transportProvisionFailed

    // Archive workspace.
    case archivedAgentNotFound
    case archiveActionInvalid
    case archiveWorkspaceUnavailable
    case archiveOpPending
    case archiveWorkspaceChoiceInvalid
    case agentHasNoWorkspace
    case archiveMigrationActive

    // Workspace files, file read and runtime lifecycle.
    case workspaceFilesMachineOffline
    case workspaceFilesTimeout
    case workspaceReadMachineOffline
    case workspaceReadTimeout
    case noMachineAssigned
    case startMachineOffline

    /// One side of a runtime capability failure of a Computer migration.
    public struct CapabilityFailure: Sendable, Equatable {
        public enum Side: String, Sendable { case source, target }
        public var side: Side
        public var reasonRuntimeUnconfirmed: Bool
        public var runtime: String

        public init(side: Side, reasonRuntimeUnconfirmed: Bool, runtime: String) {
            self.side = side
            self.reasonRuntimeUnconfirmed = reasonRuntimeUnconfirmed
            self.runtime = runtime
        }
    }

    public var status: UInt { shape.status }

    public var errorMessage: String { shape.message }

    public var errorBody: OrderedJSON? { shape.body }

    // MARK: - Shapes

    private struct Shape {
        var status: UInt
        var message: String
        var body: OrderedJSON?

        static func plain(_ status: UInt, _ message: String) -> Shape {
            Shape(status: status, message: message, body: nil)
        }

        static func codeFirst(_ status: UInt, _ code: String, _ message: String) -> Shape {
            Shape(status: status, message: message, body: .object([
                OrderedJSONField("code", code),
                OrderedJSONField("error", message),
            ]))
        }

        static func errorFirst(_ status: UInt, _ message: String, _ code: String) -> Shape {
            Shape(status: status, message: message, body: .object([
                OrderedJSONField("error", message),
                OrderedJSONField("code", code),
            ]))
        }

        /// The hosted-migration refusal: message, code, then the failure reason.
        static func hosted(_ status: UInt, _ code: String, _ message: String) -> Shape {
            Shape(status: status, message: message, body: .object([
                OrderedJSONField("error", message),
                OrderedJSONField("code", code),
                OrderedJSONField("details", .object([OrderedJSONField("failureReason", code)])),
            ]))
        }
    }

    private var shape: Shape {
        switch self {
        case .unauthorized: .plain(401, "Unauthorized")
        case .agentNotFound: .plain(404, "Agent not found")
        case .notAMember: .plain(403, "Not a member of this server")
        case .forbidden: .plain(403, "Forbidden")
        case .externalCannotAssign: .plain(400, "External agents cannot be assigned to a Computer")
        case .machineIdRequired: .plain(400, "machineId is required")
        case .machineIdInvalid: .plain(400, "machineId must be a Computer id or null")
        case .credentialNotFound: .plain(404, "Credential not found")
        case .externalAgentsHaveNoRuntimeLifecycle:
            .plain(400, "External agents do not use Raft-managed runtime lifecycle")
        case .controlRuntimeDenied:
            .plain(403, "The `controlAgentRuntime` capability or human creator authority is required to control agents")
        case .deleteAgentDenied:
            .plain(403, "The `deleteAgents` capability or human creator authority is required to delete agents")
        case .resetWorkspaceDenied:
            .plain(403, "The `resetAgentWorkspace` capability or human creator authority is required to reset agent workspaces")
        case .archivedWorkspaceForbidden:
            .plain(403, "You cannot manage this archived agent's workspace")

        case .agentMissing: .codeFirst(404, "agent_missing", "Agent not found")
        case .insufficientRole:
            .codeFirst(403, "insufficient_role", "issueAgentCredentials requires human creator authority")
        case .agentNotExternal: .codeFirst(400, "agent_not_external", "Only external Agents get credentials")
        case .builtinCatalogUnavailable:
            .codeFirst(
                409, "builtin_catalog_unavailable",
                "The target Computer's Built-in model catalog is unavailable. Retry after the Computer reconnects."
            )
        case .assignAlreadyInProgress:
            .codeFirst(409, "MIGRATION_ALREADY_IN_PROGRESS", "Agent already has an active migration")
        case .assignmentExecutionRequiresRecovery:
            .codeFirst(409, "agent_execution_recovery_required", "Agent execution history requires recovery before changing its machine")
        case .resetInProgress: .codeFirst(409, "agent_reset_in_progress", "Agent reset is in progress")
        case .resetMigrationInProgress: .codeFirst(409, "agent_migration_in_progress", "Agent migration is in progress")
        case .agentScopesUnsupported:
            .codeFirst(422, "agent_scopes_unsupported", "Agent scopes are managed for external agents only")
        case .invalidReplicaReplaySignature:
            Shape(status: 400, message: "Invalid internal replay signature", body: .object([
                OrderedJSONField("code", "invalid_replica_replay_signature"),
                OrderedJSONField("machineAffinityRoute", "owner_not_local"),
                OrderedJSONField("error", "Invalid internal replay signature"),
            ]))
        case .machineOfflineOwnerNotLocal:
            Shape(
                status: 409,
                message: "Machine is offline — the agent's Computer is not connected to this replica",
                body: .object([
                    OrderedJSONField("code", "machine_offline"),
                    OrderedJSONField("machineAffinityRoute", "owner_missing"),
                    OrderedJSONField(
                        "error",
                        "Machine is offline — the agent's Computer is not connected to this replica"
                    ),
                ])
            )
        case .machineUnassigned: .codeFirst(409, "machine_unassigned", "Agent has no connected machine")
        case .machineOffline(let action):
            .codeFirst(409, "machine_offline", "Failed to send \(action) request to daemon")
        case .daemonTimeout(let action): .codeFirst(504, "daemon_timeout", "\(action) request timed out")
        case .daemonOffline: .codeFirst(503, "daemon_offline", "Agent has no connected machine")

        case .transportTokenInvalid:
            .codeFirst(401, "migration_transport_token_invalid", "Migration transport token is invalid")
        case .migrationMissing: .codeFirst(404, "migration_missing", "Migration not found")
        case .controlManifestMissing:
            .codeFirst(409, "migration_control_manifest_missing", "Migration control manifest is not registered")
        case .streamedChunkInvalid:
            .codeFirst(400, "migration_streamed_chunk_invalid", "Streamed chunk is invalid")
        case .chunkReceiptMismatch:
            .codeFirst(
                409, "migration_chunk_receipt_mismatch",
                "Migration chunk receipt does not match the active control manifest"
            )
        case .chunksMissing(let missing):
            Shape(status: 409, message: "Migration chunks are still missing", body: .object([
                OrderedJSONField("code", "migration_chunks_missing"),
                OrderedJSONField("error", "Migration chunks are still missing"),
                OrderedJSONField("missing", .array(missing.map(OrderedJSON.int))),
            ]))
        case .generationRequired:
            .codeFirst(400, "migration_generation_required", "migrationGeneration is required")
        case .generationStale: .codeFirst(409, "migration_generation_stale", "Migration generation is stale")
        case .notReady: .codeFirst(409, "migration_not_ready", "Migration is not ready for transfer")
        case .notFlippable: .codeFirst(409, "migration_not_flippable", "Migration is not ready to flip")
        case .sourceMachineMismatch:
            .codeFirst(409, "migration_source_machine_mismatch", "Source machine no longer owns the agent")
        case .notArriving: .codeFirst(409, "migration_not_arriving", "Migration is not arriving")
        case .reportPathInvalid: .codeFirst(400, "report_path_invalid", "reportPath must be a non-empty string")
        case .reportSha256Invalid:
            .codeFirst(400, "report_sha256_invalid", "reportSha256 must be a non-empty string")
        case .notActive: .codeFirst(409, "migration_not_active", "Migration is not active")
        case .cancelAckInputRequired:
            .codeFirst(
                400, "migration_cancel_ack_input_required",
                "migrationRef, transportGeneration, cancelGeneration, role, and outcome are required"
            )
        case .cancelGenerationStale:
            .codeFirst(409, "migration_cancel_generation_stale", "Migration cancel generation is stale")
        case .cancelNotRequested:
            .codeFirst(409, "migration_cancel_not_requested", "Migration cancellation was not requested")
        case .cancelOutcomeMismatch:
            .codeFirst(
                409, "migration_cancel_outcome_mismatch",
                "Migration cancel outcome does not match the frozen disposition"
            )
        case .sourceQuiesceReceiptRequired:
            .codeFirst(400, "migration_source_quiesce_receipt_required", "receipt is required")
        case .manifestTooLarge:
            .codeFirst(413, "migration_control_manifest_too_large", "Migration control manifest exceeds its fixed budget")
        case .manifestInvalid:
            .codeFirst(400, "migration_control_manifest_invalid", "Migration control manifest is invalid")
        case .manifestConflict:
            .codeFirst(
                409, "migration_control_manifest_conflict",
                "Migration control manifest conflicts with the active generation"
            )

        case .agentMigrationUiDisabled:
            .hosted(403, "agent_migration_ui_disabled", "Agent migration UI is not enabled on this server")
        case .hostedAgentNotFound: .hosted(404, "AGENT_NOT_FOUND", "Agent not found")
        case .migrateAgentsNotSupported:
            .hosted(
                403, "not_supported",
                "The `migrateAgents` capability or human creator authority is required to confirm an agent migration"
            )
        case .hostedTargetDisabled:
            .hosted(403, "HOSTED_TARGET_UNAVAILABLE", "Moving agents to the cloud is not enabled on this server")
        case .hostedRuntimeDisabled:
            .hosted(409, "HOSTED_TARGET_UNAVAILABLE", "Cloud agents are not enabled for this server")
        case .hostedUnknownProvider: .hosted(422, "HOSTED_TARGET_UNAVAILABLE", "Unknown cloud provider")
        case .hostedModelInvalid:
            .hosted(400, "HOSTED_TARGET_MODEL_INVALID", "`target.hostedModel` must be a model id or null")
        case .hostedModelPickerDisabled:
            .hosted(
                422, "HOSTED_TARGET_MODEL_INVALID",
                "This model cannot be used for a cloud agent here (picker_disabled)"
            )
        case .migrationRefInvalid: .hosted(400, "MIGRATION_REF_INVALID", "migrationRef is required")
        case .migrationRevisionInvalid:
            .hosted(400, "MIGRATION_REVISION_INVALID", "expectedRevision must be a positive integer")
        case .hostedMigrationNotFound: .hosted(404, "MIGRATION_NOT_FOUND", "Migration to the cloud not found")
        case .migrationRevisionStale:
            .hosted(409, "MIGRATION_REVISION_STALE", "The migration changed since this review was shown")
        case .hostedReviewNotReady:
            .hosted(409, "HOSTED_REVIEW_NOT_READY", "The move to the cloud is not waiting for confirmation")
        case .hostedReviewSourceMoved:
            .hosted(
                409, "HOSTED_REVIEW_NOT_READY",
                "The agent is no longer on the migration's source computer"
            )
        case .hostedTargetAlreadyUsed:
            .hosted(409, "HOSTED_TARGET_ALREADY_USED", "This agent has already run in the cloud")
        case .agentHasNoSourceMachine:
            .hosted(409, "AGENT_HAS_NO_SOURCE_MACHINE", "Agent has no source computer")
        case .migrationAlreadyInProgress:
            .hosted(409, "MIGRATION_ALREADY_IN_PROGRESS", "Agent already has an active migration")

        case .machineMigrationNotSupported:
            .codeFirst(403, "not_supported", "Agent migration requires creator or server admin authority")
        case .agentHasNoSourceComputer:
            .codeFirst(409, "AGENT_HAS_NO_SOURCE_MACHINE", "Agent has no source computer")
        case .computerMigrationAlreadyInProgress:
            .codeFirst(409, "MIGRATION_ALREADY_IN_PROGRESS", "Agent already has an active migration")
        case .targetComputerNotFound: .codeFirst(404, "TARGET_COMPUTER_NOT_FOUND", "Target computer not found")
        case .resumableCapabilityRequired(let side):
            Self.capabilityRequired(side: side)
        case .computerCapabilityInsufficient(let failures):
            Self.capabilityInsufficient(failures: failures)
        case .targetComputerOffline:
            Shape(status: 409, message: "Target computer is not online", body: .object([
                OrderedJSONField("error", "Target computer is not online"),
                OrderedJSONField("code", "TARGET_COMPUTER_OFFLINE"),
                OrderedJSONField("details", .object([
                    OrderedJSONField("failureReason", "TARGET_COMPUTER_OFFLINE"),
                ])),
            ]))
        case .targetRuntimeDetectionPending(let runtime, let detectionStatus):
            Shape(
                status: 409,
                message: "The target computer is still detecting its runtimes; try again in a moment",
                body: .object([
                    OrderedJSONField("error", "The target computer is still detecting its runtimes; try again in a moment"),
                    OrderedJSONField("code", "TARGET_RUNTIME_DETECTION_PENDING"),
                    OrderedJSONField("details", .object([
                        OrderedJSONField("failureReason", "TARGET_RUNTIME_DETECTION_PENDING"),
                        OrderedJSONField("side", "target"),
                        OrderedJSONField("runtime", runtime),
                        OrderedJSONField("detectionStatus", detectionStatus),
                        OrderedJSONField("retryable", true),
                    ])),
                ])
            )
        case .migrationProPlanRequired:
            Shape(status: 403, message: "Agent migration requires the Pro plan.", body: .object([
                OrderedJSONField("error", "Agent migration requires the Pro plan."),
                OrderedJSONField("code", "MIGRATION_PRO_PLAN_REQUIRED"),
                OrderedJSONField("details", .object([
                    OrderedJSONField("failureReason", "MIGRATION_PRO_PLAN_REQUIRED"),
                ])),
            ]))
        case .transportProvisionFailed:
            .codeFirst(422, "MIGRATION_TRANSPORT_PROVISION_FAILED", "Migration transport provisioning failed")

        case .archivedAgentNotFound: .errorFirst(404, "Archived agent not found", "agent_not_archived")
        case .archiveActionInvalid:
            .errorFirst(400, "action must be delete", "archive_workspace_action_invalid")
        case .archiveWorkspaceUnavailable:
            .errorFirst(409, "The workspace is not on a Computer.", "archive_workspace_unavailable")
        case .archiveOpPending:
            .errorFirst(409, "Another workspace operation is still running.", "archive_op_pending")
        case .archiveWorkspaceChoiceInvalid:
            .errorFirst(400, "workspace must be keep or delete", "archive_workspace_choice_invalid")
        case .agentHasNoWorkspace:
            .errorFirst(409, "This agent has no workspace on a Computer.", "archive_workspace_unavailable")
        case .archiveMigrationActive:
            .errorFirst(
                409,
                "This agent is being migrated. Wait for the migration to finish or cancel it first.",
                "archive_migration_active"
            )

        case .workspaceFilesMachineOffline:
            .errorFirst(409, "Agent has no connected machine", "machine_offline")
        case .workspaceFilesTimeout:
            .errorFirst(504, "Workspace file tree request timed out", "daemon_timeout")
        case .workspaceReadMachineOffline: .errorFirst(409, "Agent file read failed", "machine_offline")
        case .workspaceReadTimeout:
            .errorFirst(504, "Workspace file read request timed out", "daemon_timeout")
        case .noMachineAssigned:
            .errorFirst(
                409, "No machine assigned. Please assign a machine to this agent first.", "machine_unassigned"
            )
        case .startMachineOffline:
            Shape(status: 409, message: "Machine is offline", body: .object([
                OrderedJSONField("error", "Machine is offline"),
                OrderedJSONField("code", "machine_offline"),
                OrderedJSONField("machineAffinityRoute", "owner_missing"),
            ]))
        }
    }

    private static func capabilityRequired(side: String) -> Shape {
        let message = "Both source and target computers must run a Raft Computer that supports migration/v3; "
            + "upgrade the \(side == "both" ? "source and target" : side) computer"
        return Shape(status: 422, message: message, body: .object([
            OrderedJSONField("error", message),
            OrderedJSONField("code", "MIGRATION_RESUMABLE_CAPABILITY_REQUIRED"),
            OrderedJSONField("details", .object([
                OrderedJSONField("side", side),
                OrderedJSONField("reason", "capability_missing"),
                OrderedJSONField("failureReason", "MIGRATION_RESUMABLE_CAPABILITY_REQUIRED"),
            ])),
        ]))
    }

    private static func capabilityInsufficient(failures: [CapabilityFailure]) -> Shape {
        let message = "Both source and target computers must support the agent's runtime"
        let rows = failures.map { failure -> OrderedJSON in
            .object([
                OrderedJSONField("side", failure.side.rawValue),
                OrderedJSONField("reason", failure.reasonRuntimeUnconfirmed ? "runtime_unconfirmed" : "runtime_missing"),
                OrderedJSONField("runtime", failure.runtime),
            ])
        }
        return Shape(status: 422, message: message, body: .object([
            OrderedJSONField("error", message),
            OrderedJSONField("code", "COMPUTER_CAPABILITY_INSUFFICIENT"),
            OrderedJSONField("details", .object([
                OrderedJSONField("failureReason", "COMPUTER_CAPABILITY_INSUFFICIENT"),
                OrderedJSONField("failures", .array(rows)),
            ])),
        ]))
    }
}
