import Foundation

/// Domain failure for the Computer fleet: the machine roster, Computer
/// attach/adoption, the lifecycle controls and the runner control plane.
///
/// Every case is one published refusal. The retired handlers built each body by
/// hand; `Respond.swift` renders them from `errorMessage` and `errorCode`
/// (`error`, then `code`), and `errorBody` where the published object carries
/// more keys (the lifecycle `broadcast_disabled` policy).
public enum ComputersFleetError: DomainError, Equatable {
    case unauthorized
    case serverNotFound
    case machineNotFoundInServer
    case workspaceDeleteForbidden
    case workspaceNotFound
    case forbidden
    case notAMember
    case machineNotFound
    case computerNotFound
    /// The device-login gate: `attach`, `adopt-legacy` and `legacy-machines`.
    case attachDisabled
    case attachAuthRequired
    case adoptAuthRequired
    case serverSlugRequired
    case notAuthorized
    case attachRequiresAdmin
    case computerNameCollision
    case legacyIdentityRequired
    case nameInvalid
    case legacyKeyInvalid
    case adoptNotAuthorized
    case legacyMachineNotFound
    case adoptRequiresAdmin
    case legacyMachineKeyMigrated
    case invalidComputerCredential
    case agentMissing
    case scopesInvalid(message: String)
    case scopesEmpty
    case credentialMissing
    case unknownAction
    case remoteUpgradeDisabled
    case invalidTargetVersion
    case notAComputer
    case computerOffline
    case computerControlUnsupported
    case runtimeRescanForbidden
    case runtimeRescanOffline
    case machineHasActiveMigration
    case machineHasActiveRuntimeProfile
    case lifecycleUnknownAction
    case invalidOperationId
    case invalidParentOperationId
    case lifecycleBroadcastDisabled
    case lifecycleInvalidTargetVersion
    case invalidCompletionMode
    case lifecycleForbidden
    case lifecycleNotAComputer
    case computerAlreadyOnline
    case lifecycleComputerNotOnline
    case computerUpgradeUnavailable
    case lifecycleCompletionReadyPending

    public var status: UInt {
        switch self {
        case .unauthorized, .attachAuthRequired, .adoptAuthRequired, .legacyKeyInvalid,
             .invalidComputerCredential:
            401
        case .workspaceDeleteForbidden, .forbidden, .notAMember, .notAuthorized,
             .attachRequiresAdmin, .adoptNotAuthorized, .adoptRequiresAdmin,
             .remoteUpgradeDisabled, .runtimeRescanForbidden, .lifecycleForbidden:
            403
        case .serverNotFound, .machineNotFoundInServer, .workspaceNotFound, .machineNotFound,
             .computerNotFound, .attachDisabled, .legacyMachineNotFound, .agentMissing,
             .credentialMissing:
            404
        case .serverSlugRequired, .legacyIdentityRequired, .nameInvalid, .scopesInvalid,
             .scopesEmpty, .unknownAction, .invalidTargetVersion, .lifecycleUnknownAction,
             .invalidOperationId, .invalidParentOperationId, .lifecycleInvalidTargetVersion,
             .invalidCompletionMode:
            400
        case .computerNameCollision, .legacyMachineKeyMigrated, .notAComputer, .computerOffline,
             .computerControlUnsupported, .runtimeRescanOffline, .machineHasActiveMigration,
             .machineHasActiveRuntimeProfile, .lifecycleBroadcastDisabled,
             .lifecycleNotAComputer, .computerAlreadyOnline, .lifecycleComputerNotOnline,
             .computerUpgradeUnavailable, .lifecycleCompletionReadyPending:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized, .attachAuthRequired:
            "Unauthorized"
        case .serverNotFound:
            "Server not found"
        case .machineNotFoundInServer:
            "Machine not found in this server"
        case .workspaceDeleteForbidden:
            "The `controlComputers` capability or machine creator authority is required to delete machine workspaces"
        case .workspaceNotFound:
            "Workspace not found"
        case .forbidden:
            "Forbidden"
        case .notAMember:
            "Not a member of this server"
        case .machineNotFound:
            "Machine not found"
        case .computerNotFound:
            "Computer not found"
        case .attachDisabled:
            "Not found"
        case .adoptAuthRequired:
            "Authentication required"
        case .serverSlugRequired:
            "serverSlug is required"
        case .notAuthorized:
            "Not authorized"
        case .attachRequiresAdmin:
            "This action requires an admin or the owner"
        case .computerNameCollision:
            "A Computer with this name already exists"
        case .legacyIdentityRequired:
            "legacyApiKey, fingerprint roster identity, or daemonId identity is required"
        case .nameInvalid:
            "name must be a non-empty string up to 200 chars"
        case .legacyKeyInvalid:
            "Invalid legacy machine key"
        case .adoptNotAuthorized:
            "Not authorized to adopt this machine"
        case .legacyMachineNotFound:
            "Legacy machine was not found on this server"
        case .adoptRequiresAdmin:
            "Adopting a Computer requires the admin or owner role on this server"
        case .legacyMachineKeyMigrated:
            "This machine has already been migrated to a Computer attachment"
        case .invalidComputerCredential:
            "Invalid computer credential"
        case .agentMissing:
            "Agent not found"
        case .scopesInvalid(let message):
            message
        case .scopesEmpty:
            "scopes must include at least one capability"
        case .credentialMissing:
            "Credential not found"
        case .unknownAction:
            "Unknown computer action"
        case .remoteUpgradeDisabled:
            "Remote upgrade is disabled for this server"
        case .invalidTargetVersion:
            "targetVersion is required"
        case .notAComputer:
            "Machine is not a Computer"
        case .computerOffline, .runtimeRescanOffline:
            "Computer is offline"
        case .computerControlUnsupported:
            "Raft couldn't verify the Computer version. Reconnect the Computer, then try again."
        case .runtimeRescanForbidden:
            "The `editMachines` capability or machine creator authority is required to rescan runtimes"
        case .machineHasActiveMigration:
            "Cannot delete computer while an agent migration is in progress. Wait for it to finish or abort it first."
        case .machineHasActiveRuntimeProfile:
            "Cannot delete computer while runtime profiles still reference active agents. Remove or migrate related agents first."
        case .lifecycleUnknownAction:
            "Unknown Computer lifecycle action"
        case .invalidOperationId:
            "A valid operationId is required"
        case .invalidParentOperationId:
            "A valid parentOperationId is required"
        case .lifecycleBroadcastDisabled, .computerUpgradeUnavailable:
            "Hands could not select a newer alpha release for this Computer."
        case .lifecycleInvalidTargetVersion:
            "A valid targetVersion is required only for upgrade"
        case .invalidCompletionMode:
            "Unknown Computer lifecycle completion mode"
        case .lifecycleForbidden:
            "The `controlComputers` capability or machine creator authority is required to control Computers"
        case .lifecycleNotAComputer:
            "Lifecycle operations are only available for managed Computers"
        case .computerAlreadyOnline:
            "Computer is already online"
        case .lifecycleComputerNotOnline:
            "Computer is not online"
        case .lifecycleCompletionReadyPending:
            "The live Computer ready attestation is not visible yet."
        }
    }

    public var errorCode: String? {
        switch self {
        case .attachDisabled:
            "not_found"
        case .attachAuthRequired, .adoptAuthRequired:
            "auth_required"
        case .serverSlugRequired:
            "server_slug_required"
        case .notAuthorized, .adoptNotAuthorized:
            "not_authorized"
        case .attachRequiresAdmin, .adoptRequiresAdmin:
            "requires_admin"
        case .computerNameCollision:
            "COMPUTER_NAME_COLLISION"
        case .legacyIdentityRequired:
            "legacy_api_key_required"
        case .nameInvalid:
            "name_invalid"
        case .legacyKeyInvalid:
            "legacy_key_invalid"
        case .legacyMachineNotFound:
            "legacy_machine_not_found"
        case .legacyMachineKeyMigrated:
            "legacy_machine_key_migrated"
        case .agentMissing:
            "agent_missing"
        case .scopesInvalid:
            "scopes_invalid"
        case .scopesEmpty:
            "scopes_empty"
        case .credentialMissing:
            "credential_missing"
        case .unknownAction:
            "unknown_action"
        case .remoteUpgradeDisabled:
            "remote_upgrade_disabled"
        case .invalidTargetVersion:
            "invalid_target_version"
        case .notAComputer, .lifecycleNotAComputer:
            "not_a_computer"
        case .computerOffline, .lifecycleComputerNotOnline:
            "computer_offline"
        case .computerControlUnsupported:
            "computer_control_unsupported"
        case .machineHasActiveMigration:
            "MACHINE_HAS_ACTIVE_MIGRATION"
        case .machineHasActiveRuntimeProfile:
            "MACHINE_HAS_ACTIVE_RUNTIME_PROFILE"
        case .lifecycleUnknownAction:
            "unknown_action"
        case .invalidOperationId:
            "invalid_operation_id"
        case .invalidParentOperationId:
            "invalid_parent_operation_id"
        case .lifecycleBroadcastDisabled:
            "broadcast_disabled"
        case .lifecycleInvalidTargetVersion:
            "invalid_target_version"
        case .invalidCompletionMode:
            "invalid_completion_mode"
        case .computerAlreadyOnline:
            "computer_already_online"
        case .computerUpgradeUnavailable:
            "computer_upgrade_unavailable"
        case .lifecycleCompletionReadyPending:
            "computer_lifecycle_completion_ready_pending"
        case .unauthorized, .serverNotFound, .machineNotFoundInServer, .workspaceDeleteForbidden,
             .workspaceNotFound, .forbidden, .notAMember, .machineNotFound, .computerNotFound,
             .invalidComputerCredential, .runtimeRescanForbidden, .runtimeRescanOffline,
             .lifecycleForbidden:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        guard case .lifecycleBroadcastDisabled = self else { return nil }
        return .object([
            OrderedJSONField("error", errorMessage),
            OrderedJSONField("code", "broadcast_disabled"),
            OrderedJSONField("policy", .object([
                OrderedJSONField("eligibility", "no_broadcast"),
                OrderedJSONField("reasonCode", "broadcast_disabled"),
            ])),
        ])
    }
}
