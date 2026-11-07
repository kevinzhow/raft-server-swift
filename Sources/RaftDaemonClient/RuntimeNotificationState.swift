import Foundation
import Synchronization

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

public final class DispatchNotificationScheduler: RuntimeNotificationScheduler {
    private struct State: Sendable {
        var callbacks: [Int: @Sendable () -> Void] = [:]
        var nextId = 1
    }

    private let state = Mutex(State())

    public init() {}

    public func schedule(_ body: @escaping @Sendable () -> Void, afterMs: Int) -> Int {
        let id = state.withLock { state in
            let id = state.nextId
            state.nextId += 1
            state.callbacks[id] = body
            return id
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(0, afterMs))) { [self] in
            // Claim once, then call and release captured values outside the
            // mutex. Cancellation cannot join a callback already claimed here.
            let callback = state.withLock { $0.callbacks.removeValue(forKey: id) }
            callback?()
            withExtendedLifetime(callback) {}
        }
        return id
    }

    public func cancel(_ timer: Int) {
        let retired = state.withLock { $0.callbacks.removeValue(forKey: timer) }
        // Releasing an external closure can run a captured object's deinit,
        // which may reenter this scheduler.
        withExtendedLifetime(retired) {}
    }
}

/// Owns pending busy-delivery notification state: the count of messages queued
/// since the last attempt (separate from inbox length), at most one timer, the
/// last successfully written notice fingerprint (session-scoped dedup memo) and
/// the failed-encode memo. Ported from the upstream daemon state.
public final class RuntimeNotificationState: Sendable {
    private struct Timer: Sendable {
        let generation: UUID
        var token: Int?
        var callbackAdmitted = false
    }

    private struct State: Sendable {
        var timer: Timer?
        var pendingCount = 0
        var lastNoticeFingerprint: String?
        var lastNoticeSessionId: String?
        var lastEncodeFailedFingerprint: String?
        var lastEncodeFailedSessionId: String?
        var contributedSessionId: String?
        var contributedIdentities: Set<String> = []

        mutating func invalidateTimer() -> Int? {
            let token = timer?.token
            timer = nil
            return token
        }

        mutating func clearNoticeFingerprint() {
            lastNoticeFingerprint = nil
            lastNoticeSessionId = nil
            lastEncodeFailedFingerprint = nil
            lastEncodeFailedSessionId = nil
            contributedSessionId = nil
            contributedIdentities.removeAll()
        }

        mutating func ensureContributionSession(_ sessionId: String?) {
            if contributedSessionId == sessionId { return }
            contributedSessionId = sessionId
            contributedIdentities.removeAll()
        }
    }

    private let state = Mutex(State())
    private let scheduler: RuntimeNotificationScheduler

    public init(scheduler: RuntimeNotificationScheduler = DispatchNotificationScheduler()) {
        self.scheduler = scheduler
    }

    public var pendingCount: Int { state.withLock { $0.pendingCount } }
    /// The scheduler token is available only after registration returns.
    public var timer: Int? { state.withLock { $0.timer?.token } }
    /// A registration in progress already occupies the one timer slot.
    public var hasTimer: Bool { state.withLock { $0.timer != nil } }

    @discardableResult
    public func add(_ count: Int = 1) -> Int {
        state.withLock { state in
            state.pendingCount += count
            return state.pendingCount
        }
    }

    public func clearPending() {
        state.withLock { $0.pendingCount = 0 }
    }

    @discardableResult
    public func remove(_ count: Int) -> Int {
        state.withLock { state in
            guard count > 0 else { return state.pendingCount }
            state.pendingCount = max(0, state.pendingCount - count)
            return state.pendingCount
        }
    }

    public func clearTimer() {
        let token = state.withLock { $0.invalidateTimer() }
        if let token { scheduler.cancel(token) }
    }

    public func clear() {
        let token = state.withLock { state in
            state.pendingCount = 0
            let token = state.invalidateTimer()
            state.clearNoticeFingerprint()
            return token
        }
        if let token { scheduler.cancel(token) }
    }

    /// True iff this exact unread-set was already written in THIS session; an
    /// empty fingerprint is never a duplicate.
    public func isDuplicateNotice(_ fingerprint: String, sessionId: String?) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return state.withLock {
            $0.lastNoticeFingerprint == fingerprint && $0.lastNoticeSessionId == sessionId
        }
    }

    /// Register a fingerprint as written — call only after a successful write.
    public func recordNoticeWritten(
        _ fingerprint: String, sessionId: String?, messages: [InboxNoticeIdentityMessage] = []
    ) {
        state.withLock { state in
            state.lastNoticeFingerprint = fingerprint
            state.lastNoticeSessionId = sessionId
            state.lastEncodeFailedFingerprint = nil
            state.lastEncodeFailedSessionId = nil
            state.ensureContributionSession(sessionId)
            for message in messages {
                let identity = inboxNoticeMessageIdentity(message)
                if !identity.isEmpty { state.contributedIdentities.insert(identity) }
            }
        }
    }

    public func hasContributedMessage(_ message: InboxNoticeIdentityMessage, sessionId: String?) -> Bool {
        state.withLock { state in
            guard state.contributedSessionId == sessionId else { return false }
            let identity = inboxNoticeMessageIdentity(message)
            return !identity.isEmpty && state.contributedIdentities.contains(identity)
        }
    }

    public func filterUncontributedMessages(
        _ messages: [InboxNoticeIdentityMessage], sessionId: String?
    ) -> [InboxNoticeIdentityMessage] {
        state.withLock { state in
            guard state.contributedSessionId == sessionId, !state.contributedIdentities.isEmpty else { return messages }
            return messages.filter { message in
                let identity = inboxNoticeMessageIdentity(message)
                return identity.isEmpty || !state.contributedIdentities.contains(identity)
            }
        }
    }

    public func pruneContributedToPending(_ messages: [InboxNoticeIdentityMessage], sessionId: String?) {
        state.withLock { state in
            state.ensureContributionSession(sessionId)
            guard !state.contributedIdentities.isEmpty else { return }
            var pending: Set<String> = []
            for message in messages {
                let identity = inboxNoticeMessageIdentity(message)
                if !identity.isEmpty { pending.insert(identity) }
            }
            state.contributedIdentities = state.contributedIdentities.filter { pending.contains($0) }
        }
    }

    public func isDuplicateEncodeFailedNotice(_ fingerprint: String, sessionId: String?) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return state.withLock {
            $0.lastEncodeFailedFingerprint == fingerprint && $0.lastEncodeFailedSessionId == sessionId
        }
    }

    public func recordNoticeEncodeFailed(_ fingerprint: String, sessionId: String?) {
        guard !fingerprint.isEmpty else { return }
        state.withLock {
            $0.lastEncodeFailedFingerprint = fingerprint
            $0.lastEncodeFailedSessionId = sessionId
        }
    }

    public func clearNoticeFingerprint() {
        state.withLock { $0.clearNoticeFingerprint() }
    }

    @discardableResult
    public func schedule(_ callback: @escaping @Sendable () -> Void, delayMs: Int) -> Bool {
        let generation = UUID()
        let reserved = state.withLock { state in
            guard state.timer == nil else { return false }
            state.timer = Timer(generation: generation)
            return true
        }
        guard reserved else { return false }

        let token = scheduler.schedule({ [self] in
            guard admitCallback(generation) else { return }
            callback()
        }, afterMs: delayMs)
        let published = state.withLock { state in
            guard state.timer?.generation == generation else { return false }
            state.timer?.token = token
            return true
        }
        // clear, takePending, or a synchronous callback may retire the
        // reservation before its scheduler token becomes available.
        if !published { scheduler.cancel(token) }
        return true
    }

    public func takePendingAndClearTimer() -> Int {
        let (count, token) = state.withLock { state in
            let count = state.pendingCount
            state.pendingCount = 0
            return (count, state.invalidateTimer())
        }
        if let token { scheduler.cancel(token) }
        return count
    }

    private func admitCallback(_ generation: UUID) -> Bool {
        state.withLock { state in
            guard state.timer?.generation == generation,
                  state.timer?.callbackAdmitted == false else { return false }
            // Keep the timer occupied until explicitly cleared, as in the
            // serialized path. Clear invalidates future admissions; it does not
            // join a callback already admitted before the reset.
            state.timer?.callbackAdmitted = true
            return true
        }
    }
}
