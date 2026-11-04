import Foundation

/// Records a runtime child's early lifecycle until a session takes it over.
/// A child nobody takes over in time, or one that prints past the cap first, is
/// abandoned (output dropped, process terminated, recorded error/exit kept);
/// a hand-off replays the recorded events exactly once. Ported from the
/// upstream daemon runtime child guard.
public enum RuntimeChildEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case error(code: String)
    case exit(code: Int?, signal: String?)
    case close(code: Int?, signal: String?)
}

public struct RuntimeChildHandover: Sendable, Equatable {
    public var events: [RuntimeChildEvent]
    public var abandoned: String?
    public var stdinErrors: [String]
    public init(events: [RuntimeChildEvent], abandoned: String?, stdinErrors: [String] = []) {
        self.events = events
        self.abandoned = abandoned
        self.stdinErrors = stdinErrors
    }
}

public final class RuntimeChildGuard: @unchecked Sendable {
    public static let orphanAfterMs = 10_000
    public static let maxEarlyOutputBytes = 4 * 1024 * 1024
    public static let abandonKillAfterMs = 5_000

    public typealias Logger = @Sendable (String) -> Void
    public typealias Killer = @Sendable (String) -> Bool
    public typealias Scheduler = @Sendable (Int, @escaping @Sendable () -> Void) -> UUID
    public typealias Canceller = @Sendable (UUID) -> Void

    private let pid: Int?
    private let log: Logger
    private let kill: Killer
    private let schedule: Scheduler
    private let cancel: Canceller

    private var events: [RuntimeChildEvent] = []
    private var stdinErrors: [String] = []
    private var abandonedReason: String?
    private var heldOutputBytes = 0
    private var handedOver = false
    private var orphanTimer: UUID?
    private var killTimer: UUID?

    public init(
        pid: Int?,
        log: @escaping Logger = { _ in },
        kill: @escaping Killer = { _ in true },
        schedule: @escaping Scheduler = { afterMs, action in
            let id = UUID()
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(afterMs) / 1000, execute: action)
            return id
        },
        cancel: @escaping Canceller = { _ in }
    ) {
        self.pid = pid
        self.log = log
        self.kill = kill
        self.schedule = schedule
        self.cancel = cancel
        self.orphanTimer = schedule(Self.orphanAfterMs) { [weak self] in
            self?.abandon("not taken over within \(Self.orphanAfterMs)ms")
        }
    }

    public func feedStdout(_ data: Data) { holdOutput(isStdout: true, data) }
    public func feedStderr(_ data: Data) { holdOutput(isStdout: false, data) }

    public func noteError(code: String?) {
        let resolved = code ?? "Error"
        events.append(.error(code: resolved))
        if abandonedReason != nil {
            log("[RuntimeChild pid=\(pid.map(String.init) ?? "none")] error on an abandoned runtime child: \(resolved)")
        }
    }

    public func noteExit(code: Int?, signal: String?) { events.append(.exit(code: code, signal: signal)) }
    public func noteClose(code: Int?, signal: String?) { events.append(.close(code: code, signal: signal)) }

    public func noteStdinError(_ error: String) {
        if abandonedReason == nil { stdinErrors.append(error) }
    }

    private func holdOutput(isStdout: Bool, _ data: Data) {
        guard abandonedReason == nil else { return }
        heldOutputBytes += data.count
        if heldOutputBytes > Self.maxEarlyOutputBytes {
            abandon("held output exceeded \(Self.maxEarlyOutputBytes) bytes")
            return
        }
        events.append(isStdout ? .stdout(data) : .stderr(data))
    }

    private func abandon(_ reason: String) {
        guard abandonedReason == nil else { return }
        abandonedReason = reason
        if let orphanTimer { cancel(orphanTimer) }
        orphanTimer = nil
        let kept = events.filter { event in
            switch event {
            case .stdout, .stderr: false
            default: true
            }
        }
        events = kept
        heldOutputBytes = 0
        let errorCodes = kept.compactMap { event -> String? in
            if case .error(let code) = event { return code }
            return nil
        }
        let exited = kept.contains { event in
            if case .exit = event { return true }
            return false
        }
        log(
            "[RuntimeChild pid=\(pid.map(String.init) ?? "none")] abandoning a runtime child no session took over: \(reason)"
                + " (errors=\(errorCodes.isEmpty ? "none" : errorCodes.joined(separator: ",")), exited=\(exited))"
        )
        guard !exited else { return }
        _ = kill("SIGTERM")
        killTimer = schedule(Self.abandonKillAfterMs) { [weak self] in
            guard let self, self.abandonedReason != nil else { return }
            let exitedNow = self.events.contains { event in
                if case .exit = event { return true }
                return false
            }
            if !exitedNow { _ = self.kill("SIGKILL") }
        }
    }

    /// Replays the recorded early events once. A later hand-off sees the child
    /// was abandoned instead of a partial replay.
    public func takeEarlyEvents() -> RuntimeChildHandover? {
        guard !handedOver else { return nil }
        handedOver = true
        if let orphanTimer { cancel(orphanTimer) }
        if let killTimer { cancel(killTimer) }
        return RuntimeChildHandover(events: events, abandoned: abandonedReason, stdinErrors: stdinErrors)
    }
}
