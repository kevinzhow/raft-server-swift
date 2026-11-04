import Foundation

/// Derived dedup-key for a busy stdin inbox notice: the sorted set of
/// seq-preferred identities of the messages projected into the notice — NOT a
/// count or a (count, first, latest) summary, which collide when one message is
/// read and another arrives. An empty key means "nothing identified, do not
/// dedup" (fail toward sending). Ported from the upstream daemon state.
public struct InboxNoticeIdentityMessage: Sendable, Equatable {
    public var seq: Int?
    public var messageId: String?
    public var id: String?
    public init(seq: Int? = nil, messageId: String? = nil, id: String? = nil) {
        self.seq = seq
        self.messageId = messageId
        self.id = id
    }
}

public func inboxNoticeMessageIdentity(_ message: InboxNoticeIdentityMessage) -> String {
    if let seq = message.seq, seq > 0, seq <= Int.max {
        return "s:\(seq)"
    }
    let id = (message.messageId?.isEmpty == false ? message.messageId! : nil)
        ?? (message.id?.isEmpty == false ? message.id! : nil)
        ?? ""
    return id.isEmpty ? "" : "m:\(id)"
}

public func computeInboxNoticeFingerprint(_ messages: [InboxNoticeIdentityMessage]) -> String {
    let keys = messages.map(inboxNoticeMessageIdentity).filter { !$0.isEmpty }.sorted()
    return keys.isEmpty ? "" : keys.joined(separator: ",")
}

public protocol RuntimeNotificationScheduler: Sendable {
    func schedule(_ body: @escaping @Sendable () -> Void, afterMs: Int) -> Int
    func cancel(_ timer: Int)
}

public final class DispatchNotificationScheduler: RuntimeNotificationScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: DispatchWorkItem] = [:]
    private var nextId = 1
    public init() {}
    public func schedule(_ body: @escaping @Sendable () -> Void, afterMs: Int) -> Int {
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        let item = DispatchWorkItem(block: body)
        lock.withLock { items[id] = item }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(0, afterMs)), execute: item)
        return id
    }
    public func cancel(_ timer: Int) {
        let item = lock.withLock { items.removeValue(forKey: timer) }
        item?.cancel()
    }
}

/// Owns pending busy-delivery notification state: the count of messages queued
/// since the last attempt (separate from inbox length), at most one timer, the
/// last successfully written notice fingerprint (session-scoped dedup memo) and
/// the failed-encode memo. Ported from the upstream daemon state.
public final class RuntimeNotificationState: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduler: RuntimeNotificationScheduler
    private var timerValue: Int?
    private var pendingCountValue = 0
    private var lastNoticeFingerprint: String?
    private var lastNoticeSessionId: String?
    private var lastEncodeFailedFingerprint: String?
    private var lastEncodeFailedSessionId: String?
    private var contributedSessionId: String?
    private var contributedIdentities: Set<String> = []

    public init(scheduler: RuntimeNotificationScheduler = DispatchNotificationScheduler()) {
        self.scheduler = scheduler
    }

    public var pendingCount: Int { lock.withLock { pendingCountValue } }
    public var timer: Int? { lock.withLock { timerValue } }
    public var hasTimer: Bool { lock.withLock { timerValue != nil } }

    @discardableResult
    public func add(_ count: Int = 1) -> Int {
        lock.withLock {
            pendingCountValue += count
            return pendingCountValue
        }
    }

    public func clearPending() {
        lock.withLock { pendingCountValue = 0 }
    }

    @discardableResult
    public func remove(_ count: Int) -> Int {
        lock.withLock {
            guard count > 0 else { return pendingCountValue }
            pendingCountValue = max(0, pendingCountValue - count)
            return pendingCountValue
        }
    }

    public func clearTimer() {
        let timer = lock.withLock { () -> Int? in
            let value = timerValue
            timerValue = nil
            return value
        }
        if let timer { scheduler.cancel(timer) }
    }

    public func clear() {
        clearPending()
        clearTimer()
        clearNoticeFingerprint()
    }

    /// True iff this exact unread-set was already written in THIS session; an
    /// empty fingerprint is never a duplicate.
    public func isDuplicateNotice(_ fingerprint: String, sessionId: String?) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return lock.withLock {
            lastNoticeFingerprint == fingerprint && lastNoticeSessionId == sessionId
        }
    }

    /// Register a fingerprint as written — call only after a successful write.
    public func recordNoticeWritten(
        _ fingerprint: String, sessionId: String?, messages: [InboxNoticeIdentityMessage] = []
    ) {
        lock.withLock {
            lastNoticeFingerprint = fingerprint
            lastNoticeSessionId = sessionId
            lastEncodeFailedFingerprint = nil
            lastEncodeFailedSessionId = nil
            ensureContributionSessionLocked(sessionId)
            for message in messages {
                let identity = inboxNoticeMessageIdentity(message)
                if !identity.isEmpty { contributedIdentities.insert(identity) }
            }
        }
    }

    public func hasContributedMessage(_ message: InboxNoticeIdentityMessage, sessionId: String?) -> Bool {
        lock.withLock {
            guard contributedSessionId == sessionId else { return false }
            let identity = inboxNoticeMessageIdentity(message)
            return !identity.isEmpty && contributedIdentities.contains(identity)
        }
    }

    public func filterUncontributedMessages(
        _ messages: [InboxNoticeIdentityMessage], sessionId: String?
    ) -> [InboxNoticeIdentityMessage] {
        lock.withLock {
            guard contributedSessionId == sessionId, !contributedIdentities.isEmpty else { return messages }
            return messages.filter { message in
                let identity = inboxNoticeMessageIdentity(message)
                return identity.isEmpty || !contributedIdentities.contains(identity)
            }
        }
    }

    public func pruneContributedToPending(_ messages: [InboxNoticeIdentityMessage], sessionId: String?) {
        lock.withLock {
            ensureContributionSessionLocked(sessionId)
            guard !contributedIdentities.isEmpty else { return }
            var pending: Set<String> = []
            for message in messages {
                let identity = inboxNoticeMessageIdentity(message)
                if !identity.isEmpty { pending.insert(identity) }
            }
            contributedIdentities = contributedIdentities.filter { pending.contains($0) }
        }
    }

    public func isDuplicateEncodeFailedNotice(_ fingerprint: String, sessionId: String?) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return lock.withLock {
            lastEncodeFailedFingerprint == fingerprint && lastEncodeFailedSessionId == sessionId
        }
    }

    public func recordNoticeEncodeFailed(_ fingerprint: String, sessionId: String?) {
        guard !fingerprint.isEmpty else { return }
        lock.withLock {
            lastEncodeFailedFingerprint = fingerprint
            lastEncodeFailedSessionId = sessionId
        }
    }

    public func clearNoticeFingerprint() {
        lock.withLock {
            lastNoticeFingerprint = nil
            lastNoticeSessionId = nil
            lastEncodeFailedFingerprint = nil
            lastEncodeFailedSessionId = nil
            contributedSessionId = nil
            contributedIdentities.removeAll()
        }
    }

    @discardableResult
    public func schedule(_ callback: @escaping @Sendable () -> Void, delayMs: Int) -> Bool {
        lock.lock()
        if timerValue != nil { lock.unlock(); return false }
        let scheduler = self.scheduler
        lock.unlock()
        let token = scheduler.schedule(callback, afterMs: delayMs)
        lock.withLock { timerValue = token }
        return true
    }

    public func takePendingAndClearTimer() -> Int {
        lock.lock()
        let count = pendingCountValue
        pendingCountValue = 0
        let timer = timerValue
        timerValue = nil
        lock.unlock()
        if let timer { scheduler.cancel(timer) }
        return count
    }

    private func ensureContributionSessionLocked(_ sessionId: String?) {
        if contributedSessionId == sessionId { return }
        contributedSessionId = sessionId
        contributedIdentities.removeAll()
    }
}
