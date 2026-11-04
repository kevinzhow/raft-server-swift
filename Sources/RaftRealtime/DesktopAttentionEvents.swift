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

/// In-memory record of users whose desktop window is attended. The upstream
/// service is Redis-backed; this port keeps the observable suppression state.
public final class DesktopAttentionRegistry: DesktopAttentionRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var attended: Set<String> = []

    public init() {}

    public func record(userId: String) {
        lock.withLock { _ = attended.insert(userId) }
    }

    public func clear(userId: String) {
        lock.withLock { attended.remove(userId) }
    }

    public func isAttended(userId: String) -> Bool {
        lock.withLock { attended.contains(userId) }
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
