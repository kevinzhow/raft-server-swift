import Foundation
import Synchronization

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

public final class RuntimeChildGuard: Sendable {
    public static let orphanAfterMs = 10_000
    public static let maxEarlyOutputBytes = 4 * 1024 * 1024
    public static let abandonKillAfterMs = 5_000

    public typealias Logger = @Sendable (String) -> Void
    public typealias Killer = @Sendable (String) -> Bool
    public typealias Scheduler = @Sendable (Int, @escaping @Sendable () -> Void) -> UUID
    public typealias Canceller = @Sendable (UUID) -> Void

    private enum Phase: Sendable {
        case recording
        case abandoned(reason: String, generation: UUID)
        case handedOver
    }

    private enum TimerKind: Sendable {
        case orphan, kill
        var delayMs: Int { self == .orphan ? orphanAfterMs : abandonKillAfterMs }
    }

    private struct Timer: Sendable {
        let generation: UUID
        var token: UUID?
    }

    private enum Effect: Sendable {
        case log(String)
        case cancel(UUID)
        case schedule(TimerKind, UUID)
        case signal(String, abandonment: UUID)
    }

    private struct State: Sendable {
        var phase: Phase = .recording
        var events: [RuntimeChildEvent] = []
        var stdinErrors: [String] = []
        var heldOutputBytes = 0
        var orphanTimer: Timer?
        var killTimer: Timer?
        var effects: [Effect] = []
        var draining = false

        var hasExited: Bool {
            events.contains { if case .exit = $0 { true } else { false } }
        }

        func timer(_ kind: TimerKind) -> Timer? {
            switch kind {
            case .orphan: orphanTimer
            case .kill: killTimer
            }
        }

        mutating func setTimer(_ kind: TimerKind, _ timer: Timer?) {
            switch kind {
            case .orphan: orphanTimer = timer
            case .kill: killTimer = timer
            }
        }

        mutating func reserveTimer(_ kind: TimerKind) {
            let generation = UUID()
            setTimer(kind, Timer(generation: generation))
            effects.append(.schedule(kind, generation))
        }

        mutating func invalidateTimer(_ kind: TimerKind) {
            if let token = timer(kind)?.token { effects.append(.cancel(token)) }
            setTimer(kind, nil)
        }

        func canSignal(_ generation: UUID) -> Bool {
            guard case .abandoned(_, let current) = phase else { return false }
            return current == generation && !hasExited
        }

        mutating func abandon(_ reason: String, prefix: String) {
            guard case .recording = phase else { return }
            let generation = UUID()
            phase = .abandoned(reason: reason, generation: generation)
            invalidateTimer(.orphan)
            events.removeAll { event in
                switch event {
                case .stdout, .stderr: true
                default: false
                }
            }
            heldOutputBytes = 0
            let errorCodes = events.compactMap { event -> String? in
                if case .error(let code) = event { return code }
                return nil
            }
            let exited = hasExited
            effects.append(.log(
                "\(prefix) abandoning a runtime child no session took over: \(reason)"
                    + " (errors=\(errorCodes.isEmpty ? "none" : errorCodes.joined(separator: ",")), exited=\(exited))"
            ))
            if !exited {
                effects.append(.signal("SIGTERM", abandonment: generation))
                reserveTimer(.kill)
            }
        }
    }

    private let prefix: String
    private let log: Logger
    private let kill: Killer
    private let schedule: Scheduler
    private let cancel: Canceller
    private let state = Mutex(State())

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
        self.prefix = "[RuntimeChild pid=\(pid.map(String.init) ?? "none")]"
        self.log = log
        self.kill = kill
        self.schedule = schedule
        self.cancel = cancel
        state.withLock { $0.reserveTimer(.orphan) }
        drainEffects()
    }

    public func feedStdout(_ data: Data) { holdOutput(isStdout: true, data) }
    public func feedStderr(_ data: Data) { holdOutput(isStdout: false, data) }

    public func noteError(code: String?) {
        let resolved = code ?? "Error"
        state.withLock { state in
            if case .handedOver = state.phase { return }
            state.events.append(.error(code: resolved))
            if case .abandoned = state.phase {
                state.effects.append(.log("\(prefix) error on an abandoned runtime child: \(resolved)"))
            }
        }
        drainEffects()
    }

    public func noteExit(code: Int?, signal: String?) {
        state.withLock { state in
            if case .handedOver = state.phase { return }
            state.events.append(.exit(code: code, signal: signal))
            state.invalidateTimer(.kill)
        }
        drainEffects()
    }

    public func noteClose(code: Int?, signal: String?) {
        state.withLock { state in
            if case .handedOver = state.phase { return }
            state.events.append(.close(code: code, signal: signal))
        }
    }

    public func noteStdinError(_ error: String) {
        state.withLock { state in
            if case .recording = state.phase { state.stdinErrors.append(error) }
        }
    }

    private func holdOutput(isStdout: Bool, _ data: Data) {
        state.withLock { state in
            guard case .recording = state.phase else { return }
            if data.count > Self.maxEarlyOutputBytes - state.heldOutputBytes {
                state.abandon("held output exceeded \(Self.maxEarlyOutputBytes) bytes", prefix: prefix)
            } else {
                state.heldOutputBytes += data.count
                state.events.append(isStdout ? .stdout(data) : .stderr(data))
            }
        }
        drainEffects()
    }

    /// Replays the recorded early events once, then retires this guard's owner.
    /// Pending timer callbacks cannot abandon or signal a handed-over child.
    public func takeEarlyEvents() -> RuntimeChildHandover? {
        let result = state.withLock { state -> RuntimeChildHandover? in
            let reason: String?
            switch state.phase {
            case .handedOver: return nil
            case .recording: reason = nil
            case .abandoned(let abandoned, _): reason = abandoned
            }
            state.phase = .handedOver
            state.invalidateTimer(.orphan)
            state.invalidateTimer(.kill)
            let result = RuntimeChildHandover(events: state.events, abandoned: reason, stdinErrors: state.stdinErrors)
            state.events.removeAll()
            state.stdinErrors.removeAll()
            state.heldOutputBytes = 0
            return result
        }
        drainEffects()
        return result
    }

    private func timerFired(_ kind: TimerKind, generation: UUID) {
        state.withLock { state in
            guard state.timer(kind)?.generation == generation else { return }
            state.invalidateTimer(kind)
            switch kind {
            case .orphan:
                state.abandon("not taken over within \(Self.orphanAfterMs)ms", prefix: prefix)
            case .kill:
                if case .abandoned(_, let abandonment) = state.phase, !state.hasExited {
                    state.effects.append(.signal("SIGKILL", abandonment: abandonment))
                }
            }
        }
        drainEffects()
    }

    // One drainer preserves effect order without calling injected code under the
    // mutex. Reentrant callbacks can submit transitions; the active drainer then
    // observes them before claiming the next effect. A signal already claimed
    // before a concurrent handover is in flight; handover invalidates later work.
    private func drainEffects() {
        let start = state.withLock { state in
            guard !state.draining, !state.effects.isEmpty else { return false }
            state.draining = true
            return true
        }
        guard start else { return }
        while let effect = state.withLock({ state -> Effect? in
            guard !state.effects.isEmpty else {
                state.draining = false
                return nil
            }
            return state.effects.removeFirst()
        }) {
            switch effect {
            case .log(let message): log(message)
            case .cancel(let token): cancel(token)
            case .signal(let signal, let generation):
                if state.withLock({ $0.canSignal(generation) }) { _ = kill(signal) }
            case .schedule(let kind, let generation):
                guard state.withLock({ $0.timer(kind)?.generation == generation }) else { continue }
                let token = schedule(kind.delayMs) { [weak self] in
                    self?.timerFired(kind, generation: generation)
                }
                state.withLock { state in
                    if state.timer(kind)?.generation == generation {
                        state.setTimer(kind, Timer(generation: generation, token: token))
                    } else {
                        // A synchronous callback or handover retired this timer
                        // while schedule was outside the mutex.
                        state.effects.append(.cancel(token))
                    }
                }
            }
        }
    }
}
