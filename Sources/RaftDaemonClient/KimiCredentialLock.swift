import Foundation
import Synchronization

/// The Kimi Code client's own refresh lock: a directory sentinel
/// `<target>.lock`, stale after 5 s, taken with a bounded retry schedule. A
/// lock this daemon cannot take is a bounded failure, never a reason to touch
/// credentials without it; a lock reclaimed or removed underneath us is
/// reported as compromised on the handle, never thrown. Ported from the
/// upstream daemon helper (the real client uses proper-lockfile).
public enum KimiRefreshLockResult<T: Sendable>: Sendable {
    case held(T)
    case unavailable(reason: String)
}

public final class KimiRefreshLockHandle: Sendable {
    private let compromisedError = Mutex<String?>(nil)

    public var isCompromised: Bool {
        compromisedError.withLock { $0 != nil }
    }

    public var compromisedBy: String? {
        compromisedError.withLock { $0 }
    }

    func markCompromised(_ reason: String) {
        compromisedError.withLock { stored in
            if stored == nil { stored = reason }
        }
    }
}

public enum KimiRefreshLock {
    public static let staleMs = 5_000
    public struct Options: Sendable {
        public var retries: Int
        public var minTimeoutMs: Int
        public var maxTimeoutMs: Int
        public var staleMs: Int
        public init(retries: Int = 12, minTimeoutMs: Int = 500, maxTimeoutMs: Int = 1_000, staleMs: Int = KimiRefreshLock.staleMs) {
            self.retries = retries
            self.minTimeoutMs = minTimeoutMs
            self.maxTimeoutMs = maxTimeoutMs
            self.staleMs = staleMs
        }
    }

    static func lockDirectory(_ target: String) -> String { target + ".lock" }

    static func mtimeMs(_ path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    static func setMtimeNow(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    /// True when the sentinel exists and its lock directory is fresh.
    public static func isHeld(target: String, staleMs: Int = staleMs) -> Bool {
        let dir = lockDirectory(target)
        guard let modified = mtimeMs(dir) else { return false }
        return Int(Date().timeIntervalSince1970 * 1000) - modified <= staleMs
    }

    /// Runs `fn` while holding the client's refresh lock. The lock is prepared
    /// (sentinel file) and retried with bounded backoff; `fn` never runs without
    /// it. The monitor renews the mtime and marks foreign/stale takeovers.
    public static func withLock<T: Sendable>(
        target: String,
        options: Options = Options(),
        fn: @escaping @Sendable (KimiRefreshLockHandle) async throws -> T
    ) async -> KimiRefreshLockResult<T> {
        let manager = FileManager.default
        let sentinel = target
        do {
            try manager.createDirectory(atPath: (sentinel as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: sentinel) {
                manager.createFile(atPath: sentinel, contents: Data())
            }
        } catch {
            return .unavailable(reason: "cannot prepare lock sentinel: \(error.localizedDescription)")
        }
        let lockDir = lockDirectory(target)
        var acquired = false
        var attempt = 0
        var timeout = options.minTimeoutMs
        while attempt <= options.retries {
            do {
                try manager.createDirectory(atPath: lockDir, withIntermediateDirectories: false)
                acquired = true
                break
            } catch {
                if let modified = mtimeMs(lockDir),
                   Int(Date().timeIntervalSince1970 * 1000) - modified > options.staleMs {
                    try? manager.removeItem(atPath: lockDir)
                }
                attempt += 1
                if attempt > options.retries { break }
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                timeout = min(timeout * 2, options.maxTimeoutMs)
            }
        }
        guard acquired else {
            return .unavailable(reason: "cannot acquire refresh lock: lock is held")
        }
        let handle = KimiRefreshLockHandle()
        let renewIntervalMs = max(options.staleMs / 2, 1_000)
        let monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(renewIntervalMs) * 1_000_000)
                if Task.isCancelled { return }
                guard let modified = mtimeMs(lockDir) else {
                    handle.markCompromised("refresh lock directory vanished")
                    return
                }
                let now = Int(Date().timeIntervalSince1970 * 1000)
                if now - modified > options.staleMs {
                    handle.markCompromised("refresh lock mtime is no longer ours")
                    return
                }
                setMtimeNow(lockDir)
            }
        }
        defer {
            monitor.cancel()
            if !handle.isCompromised {
                try? manager.removeItem(atPath: lockDir)
            }
        }
        do {
            let value = try await fn(handle)
            return .held(value)
        } catch {
            return .unavailable(reason: "refresh lock callback failed: \(error.localizedDescription)")
        }
    }
}
