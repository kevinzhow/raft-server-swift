/// The outcome of one store-guarded migration cancel.
///
/// The two migration record families live in different stores, so each store
/// owns the presence, revision and terminal-state checks for its own rows and
/// writes the cancelled record in the same locked critical section it validated.
enum AgentMigrationCancelOutcome<Record> {
    /// No row with this agent/Server/migration reference.
    case missing
    /// The row exists but its revision is not the requested one.
    case stale
    /// The row exists and matches, but its state can no longer be canceled.
    case terminal
    /// The row was written; the value is the updated record.
    case canceled(Record)
}

/// The published state sets the cancel route depends on.
enum AgentMigrationCancelPolicy {
    /// States the route refuses with `MIGRATION_NOT_CANCELABLE`.
    static let terminalStates: Set<String> = [
        "canceled_pre_flip", "arrived", "completed", "aborted", "failed",
    ]

    /// States that make a Computer cancel target-authoritative even when the
    /// record carries no flip timestamp.
    static let postFlipStates: Set<String> = ["arriving", "starting", "completed"]
}
