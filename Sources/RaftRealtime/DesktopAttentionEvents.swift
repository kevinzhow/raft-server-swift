import Foundation

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
public final class DesktopAttentionRegistry: DesktopAttentionRecording, @unchecked Sendable {
    /// Fixed window (not user-configurable): a desktop that is merely open but
    /// unused stops suppressing after it lapses.
    public static let windowMs = 10 * 60 * 1000
    private let lock = NSLock()
    private var attendedUntil: [String: Int] = [:]

    public init() {}

    public func record(userId: String) {
        record(userId: userId, now: Int(Date().timeIntervalSince1970 * 1000))
    }

    public func record(userId: String, now: Int) {
        lock.withLock { attendedUntil[userId] = now + Self.windowMs }
    }

    public func clear(userId: String) {
        lock.withLock { attendedUntil.removeValue(forKey: userId) }
    }

    public func isAttended(userId: String, now: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Bool {
        lock.withLock {
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
        lock.withLock { attendedUntil.removeAll() }
    }
}

/// The socket-facing handler: attach it to one socket's event registry and
/// forward that socket's `desktop:attention` payloads to `handle`.
public final class DesktopAttentionHandler: @unchecked Sendable {
    public let userId: String
    public let clientKind: SocketClientKind
    private let recorder: any DesktopAttentionRecording
    private let now: @Sendable () -> Int
    private let onError: @Sendable (String) -> Void
    private var lastRecordedAt: Int?
    private var lastClearedAt: Int?

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
        if (attended as? Bool) == false {
            if let last = lastClearedAt, at - last < DesktopAttentionEvents.minIntervalMs { return }
            lastClearedAt = at
            // The user's return must be recorded at once, not up to 30 s later.
            lastRecordedAt = nil
            recorder.clear(userId: userId)
            return
        }
        guard (attended as? Bool) == true else { return }
        if let last = lastRecordedAt, at - last < DesktopAttentionEvents.minIntervalMs { return }
        lastRecordedAt = at
        recorder.record(userId: userId)
    }
}
