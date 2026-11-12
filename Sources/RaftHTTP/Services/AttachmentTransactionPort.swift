import Foundation
import Synchronization

/// One short business-persistence phase for the selected attachment body plane.
///
/// The port exists because the HTTP owner must not hold the global business
/// writer across object I/O or multipart collection. A classified request runs
/// without the outer `runtime.execute`; instead it commits admission and row
/// mutations through this port in short phases and performs storage I/O in
/// between. Direct/unbounded callers keep the legacy in-transaction path.
///
/// `read` is a committed-read projection only. It discards `inout` mutations
/// (`withCommittedReadView` semantics), so it must never wrap authentication or
/// admission that may write. `commit` runs one `runtime.execute`, captures the
/// operation outcome inside the transaction, and reports whether that commit
/// was confirmed, refused, failed, or is unknown.
public protocol AttachmentTransactionPort: Sendable {
    /// A pure committed projection. Never use for a mutating admission.
    func read<Value: Sendable>(
        _ body: @Sendable () throws -> Value
    ) async throws -> Value

    /// One short writer phase. The body reports its own outcome so a committed
    /// operation failure is distinguishable from a persistence/fencing failure.
    /// The body must not perform storage I/O, network I/O or body collection.
    func commit<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> AttachmentCommitAttempt<Value>
    ) async -> AttachmentCommitOutcome<Value>
}

/// Captured inside `runtime.execute` so the transaction can commit any
/// admission/auth side effects before the caller projects the outcome.
public enum AttachmentCommitAttempt<Value: Sendable>: Sendable {
    /// The operation completed and its result is committed.
    case ready(Value)
    /// The operation refused with a typed domain error before writing an
    /// attachment row. Any admission side effects still commit.
    case refused(any DomainError)
    /// The operation threw an unexpected non-domain error. Side effects still
    /// commit; the caller rethrows to the existing error boundary (500).
    case failed(any Error)
}

public enum AttachmentCommitNotCommitted: Sendable {
    case refused(any DomainError)
    case failed(any Error)
    /// `requireAdmission` or the gate refused before the operation started.
    case unavailable
    /// Cancellation arrived before the operation callback started.
    case cancelledBeforeStart
}

public enum AttachmentCommitOutcome<Value: Sendable>: Sendable {
    case committed(Value)
    case notCommitted(AttachmentCommitNotCommitted)
    /// The operation started and may have mutated, but COMMIT is unconfirmed.
    /// Never delete an object after this outcome.
    case outcomeUnknown
}

public extension AttachmentCommitOutcome {
    /// Projects a committed value or the operation's original refusal/failure.
    /// Only pre-callback admission loss and an unconfirmed commit become the
    /// exact 503 business-persistence refusal; unexpected operation failures
    /// keep their original error (the existing 500 mapping).
    func value() throws -> Value {
        switch self {
        case .committed(let value): return value
        case .notCommitted(.refused(let error)): throw error
        case .notCommitted(.failed(let error)): throw error
        case .notCommitted(.unavailable), .notCommitted(.cancelledBeforeStart), .outcomeUnknown:
            throw AttachmentPersistenceUnavailable()
        }
    }
}

/// The exact existing business-persistence 503 bytes. Admission middlewares
/// return this directly (not through the JSON boundary) so HEAD keeps its
/// declared length and the body/header set is unchanged.
public struct AttachmentPersistenceUnavailable: DomainError {
    public init() {}

    public var status: UInt { 503 }
    public var errorMessage: String { "Business persistence unavailable" }
    public var errorHeaders: ResponseHeaders {
        .exact(["Content-Type": "application/json", "Cache-Control": "no-store"])
    }
}

/// Production adapter over the existing runtime API. It changes no commit,
/// readiness or publication semantics: `read` uses the live committed view,
/// `commit` is exactly one `runtime.execute`.
public struct RuntimeAttachmentTransactionPort: AttachmentTransactionPort {
    private let runtime: BusinessPersistenceRuntime

    public init(runtime: BusinessPersistenceRuntime) {
        self.runtime = runtime
    }

    public func read<Value: Sendable>(_ body: @Sendable () throws -> Value) async throws -> Value {
        _ = await runtime.readiness()
        do {
            return try runtime.withCommittedReadView(body)
        } catch let error as BusinessPersistenceError {
            _ = error
            throw AttachmentPersistenceUnavailable()
        }
    }

    public func commit<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> AttachmentCommitAttempt<Value>
    ) async -> AttachmentCommitOutcome<Value> {
        // Set before any operation work. A throw after this point may follow a
        // mutation or a completed CAS, so the object must be retained.
        let callbackStarted = Mutex(false)
        do {
            let attempt = try await runtime.execute {
                callbackStarted.withLock { $0 = true }
                do {
                    return try await body()
                } catch {
                    return .failed(error)
                }
            }
            switch attempt {
            case .ready(let value): return .committed(value)
            case .refused(let error): return .notCommitted(.refused(error))
            case .failed(let error): return .notCommitted(.failed(error))
            }
        } catch {
            if callbackStarted.withLock({ $0 }) { return .outcomeUnknown }
            if error is CancellationError { return .notCommitted(.cancelledBeforeStart) }
            return .notCommitted(.unavailable)
        }
    }
}

/// Explicit mode at every service callsite. `.legacy` runs the pre-existing
/// code inline, so excluded internal agent/machine callers still execute inside
/// the outer `runtime.execute` even though `domain.isReadOnlyUnscoped` is true
/// in production. `.bounded` is only supplied for classified HTTP requests.
public enum AttachmentTransactionMode: Sendable {
    case legacy
    case bounded(any AttachmentTransactionPort)

    /// Runs a synchronous unit of work through one bounded commit phase, or
    /// inline for legacy callers. Never nests a transaction: `.legacy` relies on
    /// the caller's existing context and `.bounded` starts outside one.
    public func committedValue<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        switch self {
        case .legacy:
            return try body()
        case .bounded(let port):
            let outcome = await port.commit {
                do {
                    return .ready(try body())
                } catch let error as any DomainError {
                    return .refused(error)
                } catch {
                    return .failed(error)
                }
            }
            return try outcome.value()
        }
    }

    /// Async variant for local preview-token verification. No storage, network
    /// or body collection belongs inside the caller's closure.
    public func committedAsyncValue<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        switch self {
        case .legacy:
            return try await body()
        case .bounded(let port):
            let outcome = await port.commit {
                do {
                    return .ready(try await body())
                } catch let error as any DomainError {
                    return .refused(error)
                } catch {
                    return .failed(error)
                }
            }
            return try outcome.value()
        }
    }
}
