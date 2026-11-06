import Foundation
import Synchronization

/// `desktop:attention { attended: true|false }` from Raft Desktop sockets.
/// Only a desktop socket may silence its own browser notifications; a blur
/// needs no message because the record lapses on its own, while
/// `{ attended: false }` (idle/screen locked) clears it at once. Reports from
/// one socket are throttled to one per 30s so a misbehaving client cannot turn
/// the event into a store write loop. Ported from the upstream socket handler.
public enum DesktopAttentionEvents {
    public static let eventName = "desktop:attention"
    public static let minIntervalMs = 30 * 1000
}

public protocol DesktopAttentionRecording: Sendable {
    func record(userId: String)
    func clear(userId: String)
}

/// In-memory record of users whose desktop window was attended within the
/// fixed window. The upstream service is Redis-backed with a TTL; this port
/// keeps the same observable suppression state.
public final class DesktopAttentionRegistry: DesktopAttentionRecording {
    /// Fixed window (not user-configurable): a desktop that is merely open but
    /// unused stops suppressing after it lapses.
    public static let windowMs = 10 * 60 * 1000
    private let attendedUntil = Mutex<[String: Int]>([:])

    public init() {}

    public func record(userId: String) {
        record(userId: userId, now: Int(Date().timeIntervalSince1970 * 1000))
    }

    public func record(userId: String, now: Int) {
        attendedUntil.withLock { $0[userId] = now + Self.windowMs }
    }

    public func clear(userId: String) {
        _ = attendedUntil.withLock { $0.removeValue(forKey: userId) }
    }

    public func isAttended(userId: String, now: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Bool {
        attendedUntil.withLock { attendedUntil in
            guard let until = attendedUntil[userId] else { return false }
            if until > now { return true }
            attendedUntil.removeValue(forKey: userId)
            return false
        }
    }

    /// The subset of `userIds` whose desktop window was attended within the
    /// window. Fails open: an unreadable store suppresses nobody.
    public func usersWithRecentDesktopAttention(
        _ userIds: [String], now: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) -> Set<String> {
        var attended: Set<String> = []
        for userId in userIds {
            if isAttended(userId: userId, now: now) { attended.insert(userId) }
        }
        return attended
    }

    public func resetForTests() {
        attendedUntil.withLock { $0.removeAll() }
    }
}

/// The socket-facing handler: attach it to one socket's event registry and
/// forward that socket's `desktop:attention` payloads to `handle`.
public final class DesktopAttentionHandler: Sendable {
    public let userId: String
    public let clientKind: SocketClientKind
    private let recorder: any DesktopAttentionRecording
    private let now: @Sendable () -> Int
    private let onError: @Sendable (String) -> Void

    private enum Action: Sendable {
        case record
        case clear
    }

    private struct State: Sendable {
        var lastRecordedAt: Int?
        var lastClearedAt: Int?
        var pending: [Action] = []
        var delivering = false
    }

    private let state = Mutex(State())

    public init(
        userId: String,
        clientKind: SocketClientKind,
        recorder: any DesktopAttentionRecording = DesktopAttentionRegistry(),
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        onError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.userId = userId
        self.clientKind = clientKind
        self.recorder = recorder
        self.now = now
        self.onError = onError
    }

    /// Whether this socket kind receives the event at all.
    public var listens: Bool { clientKind == .desktop }

    public func handle(_ payload: Any?) {
        guard listens else { return }
        guard let object = payload as? [String: Any] else { return }
        let attended = object["attended"]
        let at = now()
        let action: Action
        if (attended as? Bool) == false {
            action = .clear
        } else {
            guard (attended as? Bool) == true else { return }
            action = .record
        }
        let shouldDeliver = state.withLock { state in
            switch action {
            case .clear:
                if let last = state.lastClearedAt, at - last < DesktopAttentionEvents.minIntervalMs { return false }
                state.lastClearedAt = at
                // The user's return must be recorded at once, not up to 30 s later.
                state.lastRecordedAt = nil
            case .record:
                if let last = state.lastRecordedAt, at - last < DesktopAttentionEvents.minIntervalMs { return false }
                state.lastRecordedAt = at
            }
            state.pending.append(action)
            guard !state.delivering else { return false }
            state.delivering = true
            return true
        }
        if shouldDeliver { deliverPending() }
    }

    private func deliverPending() {
        // Recorder callbacks can reenter handle. Claim each action under the
        // mutex, then call out after releasing it; one drainer preserves order.
        while let action = state.withLock({ state -> Action? in
            guard !state.pending.isEmpty else {
                state.delivering = false
                return nil
            }
            return state.pending.removeFirst()
        }) {
            switch action {
            case .record: recorder.record(userId: userId)
            case .clear: recorder.clear(userId: userId)
            }
        }
    }
}
