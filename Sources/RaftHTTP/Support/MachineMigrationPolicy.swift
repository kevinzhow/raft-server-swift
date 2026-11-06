import Foundation

public enum MachineMigrationPolicy {
    static func migrationSourceArchiveBackoff(attempts: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(0, attempts - 1))), 6 * 60 * 60)
    }

    static func migrationArchiveFailureCode(_ error: Error) -> String {
        if let typed = error as? MachineMigrationArchiveFailure,
           typed.code.range(of: "^[A-Za-z0-9_:.-]{1,160}$", options: .regularExpression) != nil {
            return typed.code
        }
        return "MIGRATION_SOURCE_WORKSPACE_ARCHIVE_FAILED"
    }

    static let deprecatedAgentRuntimes: Set<String> = ["kimi", "gemini", "antigravity", "copilot"]

    static let migrationTerminalFailureCodes: Set<String> = [
        "MIGRATION_TRANSPORT_LOST",
        "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE",
        "MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE",
        "MIGRATION_OBJECT_STORE_INSUFFICIENT_DISK",
        "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED",
        "MIGRATION_WORKSPACE_ALREADY_EXISTS",
        "MIGRATION_WORKSPACE_COMPLETE_OLD_COPY",
        "MIGRATION_CHUNK_DIGEST_MISMATCH",
        "MIGRATION_WHOLE_BUNDLE_DIGEST_MISMATCH",
        "MIGRATION_LEASE_EXPIRED",
        "MIGRATION_GENERATION_STALE",
        "MIGRATION_CONTROL_MANIFEST_INVALID",
        "MIGRATION_CONTROL_MANIFEST_TOO_LARGE",
    ]

    static let migrationSourceArchiveMaxAttempts = 12

    static let migrationSourceArchiveMovedCodes: Set<String> = [
        "MIGRATION_WORKSPACE_ARCHIVE_AGENT_RUNNING",
        "MIGRATION_WORKSPACE_ARCHIVE_NEWER_OWNER",
    ]

    static let migrationAutoStartLease: TimeInterval = 30
}
