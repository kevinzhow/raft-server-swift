import Foundation
import Synchronization

/// Reads one provider's account usage through an OAR runtime and projects it
/// onto the Raft wire shape. The two failure vocabularies stay apart:
/// `unsupported` means no reading is structurally obtainable (no probe/reader,
/// or the runtime is not installed); `error` means a read was attempted and
/// failed. Ported from the upstream daemon collector.
public final class OarInstallation: Sendable {
    struct Snapshot: Sendable {
        var kind: String
        var command: String?
    }
    private let state: Mutex<Snapshot>

    // Each setter is synchronized independently. A snapshot captures a read,
    // not an ownership claim over the installation while a callback awaits.
    public var kind: String {
        get { state.withLock { $0.kind } }
        set { state.withLock { $0.kind = newValue } }
    }
    public var command: String? {
        get { state.withLock { $0.command } }
        set { state.withLock { $0.command = newValue } }
    }

    func snapshot() -> Snapshot { state.withLock { $0 } }

    public init(kind: String, command: String? = nil) {
        self.state = Mutex(Snapshot(kind: kind, command: command))
    }
}

public struct OarRuntimeAdapter: Sendable {
    public var installation: (@Sendable () async throws -> OarInstallation)?
    public var accountUsage: (@Sendable (OarInstallation, Int) async throws -> OarAccountUsageSnapshot)?
    public init(
        installation: (@Sendable () async throws -> OarInstallation)? = nil,
        accountUsage: (@Sendable (OarInstallation, Int) async throws -> OarAccountUsageSnapshot)? = nil
    ) {
        self.installation = installation
        self.accountUsage = accountUsage
    }
}

public struct OarUsageReadDeps: Sendable {
    public var runtime: OarRuntimeAdapter?
    public var timeoutMs: Int?
    public var kimi: KimiUsageDeps?
    public init(runtime: OarRuntimeAdapter? = nil, timeoutMs: Int? = nil, kimi: KimiUsageDeps? = nil) {
        self.runtime = runtime
        self.timeoutMs = timeoutMs
        self.kimi = kimi
    }
}

public struct KimiUsageDeps: Sendable {
    public var resolveAuth: (@Sendable (String) async -> KimiCodeAuth?)?
    public var ensureFresh: (@Sendable (KimiCodeAuth) async -> KimiFreshness)?
    public var enabled: Bool
    public init(
        resolveAuth: (@Sendable (String) async -> KimiCodeAuth?)? = nil,
        ensureFresh: (@Sendable (KimiCodeAuth) async -> KimiFreshness)? = nil,
        enabled: Bool = false
    ) {
        self.resolveAuth = resolveAuth
        self.ensureFresh = ensureFresh
        self.enabled = enabled
    }
}

public enum KimiProbeDecision: Sendable, Equatable {
    case probe
    case reauthRequired
    case error
}

public enum RuntimeAccountUsageCollector {
    public static let defaultTimeoutMs = 20_000

    /// Only this pre-step's own verdicts short-circuit: an explicit rejection
    /// or revocation is re-login; a transient failure on an expired token is an
    /// error; every other freshness lets the probe run and speak for itself.
    public static func kimiProbeDecision(_ freshness: KimiFreshness) -> KimiProbeDecision {
        switch freshness {
        case .rejected, .revoked:
            return .reauthRequired
        case .transient(_, let expired):
            return expired ? .error : .probe
        case .missing:
            return .probe
        default:
            return .probe
        }
    }

    public static func read(
        provider: RuntimeAccountUsageProvider,
        localAccountSlot: String,
        collectorVersion: String,
        observedAtMs: Int,
        deps: OarUsageReadDeps = .init()
    ) async -> RuntimeAccountUsageSnapshot {
        func failure() -> RuntimeAccountUsageSnapshot {
            OarAdapter.failure(
                provider: provider, localAccountSlot: localAccountSlot,
                collectorVersion: collectorVersion, observedAtMs: observedAtMs
            )
        }
        func project(_ snapshot: OarAccountUsageSnapshot) -> RuntimeAccountUsageSnapshot {
            OarAdapter.project(
                provider: provider, snapshot: snapshot, localAccountSlot: localAccountSlot,
                collectorVersion: collectorVersion, observedAtMs: observedAtMs
            )
        }

        guard let runtime = deps.runtime else { return failure() }
        guard let probe = runtime.installation, let readUsage = runtime.accountUsage else {
            // Structural absence, not a failed attempt.
            return project(.init(kind: .unsupported))
        }
        do {
            let installation = try await probe()
            let installationSnapshot = installation.snapshot()
            guard installationSnapshot.kind == "available" else {
                // `not_found` and `unsupported` are both "no reading is obtainable here".
                return project(.init(kind: .unsupported))
            }
            if provider == .kimi, deps.kimi?.enabled == true, let kimi = deps.kimi {
                let command = installationSnapshot.command ?? "kimi"
                let resolveAuth = kimi.resolveAuth
                let auth = await resolveAuth?(command)
                if let auth {
                    let ensureFresh = kimi.ensureFresh
                    let freshness = await ensureFresh?(auth) ?? .platformUnsupported(reason: "missing")
                    switch kimiProbeDecision(freshness) {
                    case .reauthRequired:
                        return project(.init(kind: .reauthRequired))
                    case .error:
                        return failure()
                    case .probe:
                        break
                    }
                }
            }
            let snapshot = try await readUsage(installation, deps.timeoutMs ?? defaultTimeoutMs)
            return project(snapshot)
        } catch {
            // A thrown read is an explicit error account with no windows; it
            // must never be rendered as zero usage.
            return failure()
        }
    }

    public typealias Collector = @Sendable (RuntimeAccountUsageProvider) async -> RuntimeAccountUsageSnapshot

    /// Read every provider through the runtime and project its published
    /// usage contract.
    public static func createCollector(
        localAccountSlot: String,
        collectorVersion: String,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        oar: OarUsageReadDeps? = nil
    ) -> Collector {
        { provider in
            await read(
                provider: provider, localAccountSlot: localAccountSlot,
                collectorVersion: collectorVersion, observedAtMs: now(),
                deps: oar ?? .init()
            )
        }
    }
}
