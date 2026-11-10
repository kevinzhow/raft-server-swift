import Foundation
import RaftPersistence
import RaftShared

extension BusinessPersistenceRuntime {
    /// Claim and acknowledge through this runtime, never through a second PG
    /// writer path. Network delivery belongs between claim and acknowledgement;
    /// receivers must deduplicate the persisted effectID across writer restarts.
    public func claimOutbox(
        limit: Int = 32, visibilityTimeoutSeconds: Int = 30
    ) async throws -> [DurableOutboxClaim] {
        try await withOutboxAdmission { persistence, epoch in
            try await persistence.claimOutbox(
                expectedWriterEpoch: epoch, limit: limit,
                visibilityTimeoutSeconds: visibilityTimeoutSeconds
            )
        }
    }

    /// Each production consumer claims its own kinds atomically in PostgreSQL.
    /// Filtering a mixed claimed batch afterward would steal another worker's
    /// visibility window and consume its retry budget.
    public func claimOutbox(
        kinds: Set<DurableEffectKind>, limit: Int = 32, visibilityTimeoutSeconds: Int = 90
    ) async throws -> [DurableOutboxClaim] {
        try await withOutboxAdmission { persistence, epoch in
            try await persistence.claimOutbox(
                expectedWriterEpoch: epoch, kinds: kinds, limit: limit,
                visibilityTimeoutSeconds: visibilityTimeoutSeconds
            )
        }
    }

    /// Release a wait before dispatch begins. The worker must never call this
    /// after external I/O or an ambiguous send; those consume a dispatch attempt.
    public func deferOutbox(_ claim: DurableOutboxClaim, retryAfterSeconds: Int = 5) async throws {
        try await withOutboxAdmission { persistence, epoch in
            try await persistence.deferOutbox(
                claim, expectedWriterEpoch: epoch, retryAfterSeconds: retryAfterSeconds
            )
        }
    }

    public func markDelivered(_ claim: DurableOutboxClaim) async throws {
        try await withOutboxAdmission { persistence, epoch in
            try await persistence.markDelivered(claim, expectedWriterEpoch: epoch)
        }
    }

    public func recordFailure(_ claim: DurableOutboxClaim, code: OutboxFailureCode) async throws {
        try await withOutboxAdmission { persistence, epoch in
            try await persistence.recordFailure(claim, expectedWriterEpoch: epoch, code: code)
        }
    }

    public func outboxEffect(effectID: UUID) async throws -> DurableOutboxEntry? {
        try await withOutboxAdmission { persistence, _ in
            try await persistence.outboxEffect(effectID: effectID)
        }
    }

    /// Uses exactly the same Shared FIFO as business execute. Even though this
    /// scope has no State mutation, its permit spans the fenced outbox command.
    /// Nested calls reject before waiting instead of waiting on their own UoW.
    private func withOutboxAdmission<Output: Sendable>(
        _ operation: @escaping @Sendable (PostgresPersistence, Int64) async throws -> Output
    ) async throws -> Output {
        let context = TransactionContext(domain: domain)
        return try await withTransactionContext(context) {
            try await self.performOutbox(context: context, operation: operation)
        }
    }

    private func performOutbox<Output: Sendable>(
        context: TransactionContext,
        operation: @Sendable (PostgresPersistence, Int64) async throws -> Output
    ) async throws -> Output {
        try await requireAdmission()
        do {
            let result = try await operation(persistence, lease.epoch)
            context.discard()
            return result
        } catch {
            context.discard()
            // An expired dispatch claim or invalid request is a command refusal,
            // not loss of writer ownership. No command is blindly retried here.
            if let refusal = error as? PersistenceError,
               refusal == .outboxClaimLost || refusal == .invalidOutboxRequest {
                // Preserve the active writer for this known command refusal.
            } else {
                await failClosed()
            }
            throw error
        }
    }
}
