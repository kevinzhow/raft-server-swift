import Foundation
import Synchronization
import Testing
import RaftDaemonClient

private final class FakeScheduler: RuntimeNotificationScheduler {
    struct Entry: Sendable {
        let id: Int
        let body: @Sendable () -> Void
        let ms: Int
    }

    private struct State: Sendable {
        var scheduled: [Entry] = []
        var cancelled: [Int] = []
        var nextId = 1
        var beforeReturn: (@Sendable () -> Void)?
        var onCancel: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    private let firesSynchronously: Bool

    init(firesSynchronously: Bool = false) {
        self.firesSynchronously = firesSynchronously
    }

    var scheduled: [Entry] { state.withLock { $0.scheduled } }
    var cancelled: [Int] { state.withLock { $0.cancelled } }

    func beforeNextReturn(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.beforeReturn = action }
    }

    func onNextCancel(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.onCancel = action }
    }

    func schedule(_ body: @escaping @Sendable () -> Void, afterMs: Int) -> Int {
        let (id, beforeReturn) = state.withLock { state in
            let id = state.nextId
            state.nextId += 1
            state.scheduled.append(Entry(id: id, body: body, ms: afterMs))
            let beforeReturn = state.beforeReturn
            state.beforeReturn = nil
            return (id, beforeReturn)
        }
        beforeReturn?()
        if firesSynchronously { body() }
        return id
    }

    func cancel(_ timer: Int) {
        let onCancel = state.withLock { state in
            state.cancelled.append(timer)
            let onCancel = state.onCancel
            state.onCancel = nil
            return onCancel
        }
        onCancel?()
    }

    // Keep cancelled callbacks available to exercise callbacks already queued by
    // a scheduler that cannot retract them. Cancellation itself is not a join.
    func fire(_ timer: Int) {
        let body = state.withLock { state in
            state.scheduled.first { $0.id == timer }?.body
        }
        body?()
    }
}

@Suite
struct RuntimeNotificationStateTests {
@Test func pendingDebtIsTrackedSeparatelyFromScheduling() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    #expect(state.add() == 1)
    #expect(state.add(2) == 3)
    #expect(state.pendingCount == 3)
    #expect(!state.hasTimer)
}

@Test func schedulesAtMostOneTimer() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    let calls = Mutex(0)
    let firstAccepted = state.schedule({ calls.withLock { $0 += 1 } }, delayMs: 10_000)
    let secondAccepted = state.schedule({ calls.withLock { $0 += 1 } }, delayMs: 10_000)
    #expect(firstAccepted)
    #expect(!secondAccepted)
    #expect(state.hasTimer)
    state.clearTimer()
    #expect(!state.hasTimer)
    #expect(calls.withLock { $0 } == 0)
}

@Test func defaultSchedulerFiresThroughTheRuntimeTimerPath() async {
    let state = RuntimeNotificationState()
    let calls = Mutex(0)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ok = state.schedule({
            calls.withLock { $0 += 1 }
            continuation.resume()
        }, delayMs: 1)
        #expect(ok == true)
    }
    #expect(calls.withLock { $0 } == 1)
    #expect(state.hasTimer)
    state.clearTimer()
    #expect(!state.hasTimer)
}

@Test func takePendingClearsTimerForSendAttempt() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    state.add(4)
    _ = state.schedule({}, delayMs: 10_000)
    #expect(state.takePendingAndClearTimer() == 4)
    #expect(state.pendingCount == 0)
    #expect(!state.hasTimer)
}

@Test func clearResetsPendingAndTimerTogether() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    state.add(2)
    _ = state.schedule({}, delayMs: 10_000)
    state.clear()
    #expect(state.pendingCount == 0)
    #expect(!state.hasTimer)
}

@Test func synchronousCallbackCanClearTimerBeforeTokenReturns() {
    let scheduler = FakeScheduler(firesSynchronously: true)
    let state = RuntimeNotificationState(scheduler: scheduler)
    let calls = Mutex(0)
    state.add(3)

    let accepted = state.schedule({
        calls.withLock { $0 += 1 }
        state.clearTimer()
    }, delayMs: 27)
    #expect(accepted)

    #expect(calls.withLock { $0 } == 1)
    #expect(state.pendingCount == 3)
    #expect(!state.hasTimer)
    #expect(state.timer == nil)
    #expect(scheduler.cancelled == [1], "the token returned after clear still needs cancellation")
}

@Test func schedulingReservesTimerBeforeCallingScheduler() {
    let scheduler = FakeScheduler()
    let state = RuntimeNotificationState(scheduler: scheduler)
    let nestedResult = Mutex<Bool?>(nil)
    scheduler.beforeNextReturn {
        #expect(state.hasTimer, "an unpublished registration already occupies the timer slot")
        #expect(state.timer == nil, "a reservation has no scheduler token yet")
        let accepted = state.schedule({}, delayMs: 99)
        nestedResult.withLock { $0 = accepted }
    }

    let accepted = state.schedule({}, delayMs: 27)
    #expect(accepted)
    #expect(nestedResult.withLock { $0 } == false)
    #expect(scheduler.scheduled.map(\.ms) == [27])
    #expect(state.timer == 1)
    state.clearTimer()
    #expect(scheduler.cancelled == [1])
}

@Test func takePendingDuringRegistrationCancelsTheReturnedToken() {
    let scheduler = FakeScheduler()
    let state = RuntimeNotificationState(scheduler: scheduler)
    let taken = Mutex<Int?>(nil)
    state.add(4)
    scheduler.beforeNextReturn {
        let count = state.takePendingAndClearTimer()
        taken.withLock { $0 = count }
        state.add(2)
    }

    let accepted = state.schedule({}, delayMs: 27)
    #expect(accepted)
    #expect(taken.withLock { $0 } == 4)
    #expect(state.pendingCount == 2)
    #expect(!state.hasTimer)
    #expect(scheduler.cancelled == [1])
}

@Test func anOldRegistrationCannotReplaceATimerScheduledAfterClear() {
    let scheduler = FakeScheduler()
    let state = RuntimeNotificationState(scheduler: scheduler)
    scheduler.beforeNextReturn {
        state.clearTimer()
        let accepted = state.schedule({}, delayMs: 99)
        #expect(accepted)
    }

    let accepted = state.schedule({}, delayMs: 27)
    #expect(accepted)
    #expect(scheduler.scheduled.map(\.id) == [1, 2])
    #expect(state.timer == 2)
    #expect(scheduler.cancelled == [1])
    state.clearTimer()
    #expect(scheduler.cancelled == [1, 2])
}

@Test func clearPublishesTheWholeResetBeforeCancellationReenters() {
    let scheduler = FakeScheduler()
    let state = RuntimeNotificationState(scheduler: scheduler)
    let oldMessage = InboxNoticeIdentityMessage(seq: 7)
    let newMessage = InboxNoticeIdentityMessage(seq: 8)
    state.add(2)
    state.recordNoticeWritten("old", sessionId: "session", messages: [oldMessage])
    state.recordNoticeEncodeFailed("old-failure", sessionId: "session")
    let accepted = state.schedule({}, delayMs: 27)
    #expect(accepted)
    scheduler.onNextCancel {
        #expect(state.pendingCount == 0)
        #expect(!state.hasTimer)
        #expect(!state.isDuplicateNotice("old", sessionId: "session"))
        #expect(!state.isDuplicateEncodeFailedNotice("old-failure", sessionId: "session"))
        #expect(!state.hasContributedMessage(oldMessage, sessionId: "session"))
        state.add(3)
        state.recordNoticeWritten("new", sessionId: "session", messages: [newMessage])
        state.recordNoticeEncodeFailed("new-failure", sessionId: "session")
        let accepted = state.schedule({}, delayMs: 99)
        #expect(accepted)
    }

    state.clear()

    #expect(state.pendingCount == 3)
    #expect(state.timer == 2)
    #expect(state.isDuplicateNotice("new", sessionId: "session"))
    #expect(state.isDuplicateEncodeFailedNotice("new-failure", sessionId: "session"))
    #expect(state.hasContributedMessage(newMessage, sessionId: "session"))
    state.clearTimer()
}

@Test func callbacksRetiredByClearCannotWriteOrNotifyANewerGeneration() {
    let scheduler = FakeScheduler()
    let state = RuntimeNotificationState(scheduler: scheduler)
    let notices = Mutex<[String]>([])
    let oldMessage = InboxNoticeIdentityMessage(seq: 7)
    let accepted = state.schedule({
        state.add(10)
        state.recordNoticeWritten("old", sessionId: "session", messages: [oldMessage])
        state.recordNoticeEncodeFailed("old-failure", sessionId: "session")
        notices.withLock { $0.append("old") }
    }, delayMs: 27)
    #expect(accepted)
    state.clear()
    state.add(2)
    let newerAccepted = state.schedule({ notices.withLock { $0.append("new") } }, delayMs: 99)
    #expect(newerAccepted)

    scheduler.fire(1)
    scheduler.fire(1)

    #expect(notices.withLock { $0 }.isEmpty)
    #expect(state.pendingCount == 2)
    #expect(state.timer == 2)
    #expect(!state.isDuplicateNotice("old", sessionId: "session"))
    #expect(!state.isDuplicateEncodeFailedNotice("old-failure", sessionId: "session"))
    #expect(!state.hasContributedMessage(oldMessage, sessionId: "session"))
    scheduler.fire(2)
    #expect(notices.withLock { $0 } == ["new"])
    #expect(state.timer == 2, "firing preserves the explicit-clear timer lifetime")
    state.clearTimer()
}

@Test func takePendingRetiresQueuedCallbacksWithoutClearingNoticeMemos() {
    let scheduler = FakeScheduler()
    let state = RuntimeNotificationState(scheduler: scheduler)
    let calls = Mutex(0)
    let message = InboxNoticeIdentityMessage(seq: 7)
    state.add(4)
    state.recordNoticeWritten("written", sessionId: "session", messages: [message])
    state.recordNoticeEncodeFailed("failed", sessionId: "session")
    let accepted = state.schedule({ calls.withLock { $0 += 1 } }, delayMs: 27)
    #expect(accepted)

    #expect(state.takePendingAndClearTimer() == 4)
    scheduler.fire(1)

    #expect(calls.withLock { $0 } == 0)
    #expect(state.pendingCount == 0)
    #expect(!state.hasTimer)
    #expect(scheduler.cancelled == [1])
    #expect(state.isDuplicateNotice("written", sessionId: "session"))
    #expect(state.isDuplicateEncodeFailedNotice("failed", sessionId: "session"))
    #expect(state.hasContributedMessage(message, sessionId: "session"))
}

@Test func anAdmittedCallbackMayFinishAfterReentrantClear() {
    let scheduler = FakeScheduler()
    let state = RuntimeNotificationState(scheduler: scheduler)
    let events = Mutex<[String]>([])
    let accepted = state.schedule({
        events.withLock { $0.append("entered") }
        state.clearTimer()
        events.withLock { $0.append("finished") }
    }, delayMs: 27)
    #expect(accepted)

    scheduler.fire(1)
    scheduler.fire(1)

    #expect(events.withLock { $0 } == ["entered", "finished"], "clear invalidates later admissions and does not join an admitted callback")
    #expect(!state.hasTimer)
    #expect(scheduler.cancelled == [1])
}

@Test func fingerprintIsSetBasedAndOrderIndependent() {
    let a = computeInboxNoticeFingerprint([.init(seq: 11), .init(seq: 9)])
    let b = computeInboxNoticeFingerprint([.init(seq: 9), .init(seq: 11)])
    #expect(a == b)
    #expect(a == "s:11,s:9")
}

@Test func fingerprintFallsBackToMessageIdAndId() {
    #expect(computeInboxNoticeFingerprint([.init(messageId: "m2"), .init(messageId: "m1")]) == "m:m1,m:m2")
    #expect(computeInboxNoticeFingerprint([.init(id: "x")]) == "m:x")
    #expect(computeInboxNoticeFingerprint([.init(seq: 5, messageId: "m9")]) == "s:5")
}

@Test func fingerprintIsEmptyWithoutIdentity() {
    #expect(computeInboxNoticeFingerprint([.init(), .init(seq: 0), .init(messageId: "")]) == "")
}

@Test func fingerprintDistinguishesAChangedSetWithUnchangedCount() {
    let before = computeInboxNoticeFingerprint([.init(seq: 100), .init(seq: 101)])
    let after = computeInboxNoticeFingerprint([.init(seq: 101), .init(seq: 102)])
    #expect(before != after, "read-one + new-one keeps count=2 but the set changed")
}

@Test func noticeDedupSuppressesOnlyAnIdenticalSetInTheSameSession() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    let fp = computeInboxNoticeFingerprint([.init(seq: 1), .init(seq: 2)])
    #expect(!state.isDuplicateNotice(fp, sessionId: "sess-1"))
    state.recordNoticeWritten(fp, sessionId: "sess-1")
    #expect(state.isDuplicateNotice(fp, sessionId: "sess-1"))
    let fp2 = computeInboxNoticeFingerprint([.init(seq: 2), .init(seq: 3)])
    #expect(!state.isDuplicateNotice(fp2, sessionId: "sess-1"))
    #expect(!state.isDuplicateNotice(fp, sessionId: "sess-2"), "different session must never suppress")
}

@Test func contributionFiltersAlreadyWrittenPendingMessages() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    let first = InboxNoticeIdentityMessage(seq: 31, messageId: "first")
    let second = InboxNoticeIdentityMessage(seq: 32, messageId: "second")
    let anonymous = InboxNoticeIdentityMessage()
    let fp = computeInboxNoticeFingerprint([first])
    state.recordNoticeWritten(fp, sessionId: "sess-1", messages: [first])
    #expect(state.hasContributedMessage(first, sessionId: "sess-1"))
    #expect(!state.hasContributedMessage(second, sessionId: "sess-1"))
    #expect(state.filterUncontributedMessages([first, second, anonymous], sessionId: "sess-1") == [second, anonymous])
    #expect(state.filterUncontributedMessages([first, second], sessionId: "sess-2") == [first, second])
}

@Test func contributionPruningLetsAConsumedRowReappear() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    let message = InboxNoticeIdentityMessage(seq: 41, messageId: "reappears")
    let fp = computeInboxNoticeFingerprint([message])
    state.recordNoticeWritten(fp, sessionId: "sess-1", messages: [message])
    #expect(state.filterUncontributedMessages([message], sessionId: "sess-1").isEmpty)
    state.pruneContributedToPending([], sessionId: "sess-1")
    #expect(state.filterUncontributedMessages([message], sessionId: "sess-1") == [message])
}

@Test func dedupNeverSuppressesAnEmptyFingerprint() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    state.recordNoticeWritten("", sessionId: "sess-1")
    #expect(!state.isDuplicateNotice("", sessionId: "sess-1"))
}

@Test func clearResetsTheNoticeFingerprint() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    let fp = computeInboxNoticeFingerprint([.init(seq: 7)])
    state.recordNoticeWritten(fp, sessionId: "sess-1")
    #expect(state.isDuplicateNotice(fp, sessionId: "sess-1"))
    state.clear()
    #expect(!state.isDuplicateNotice(fp, sessionId: "sess-1"))
}

@Test func failedEncodeMemoSuppressesOnlyIdenticalFailedAttempts() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    let fp = computeInboxNoticeFingerprint([.init(seq: 21)])
    #expect(!state.isDuplicateEncodeFailedNotice(fp, sessionId: "sess-1"))
    state.recordNoticeEncodeFailed(fp, sessionId: "sess-1")
    #expect(state.isDuplicateEncodeFailedNotice(fp, sessionId: "sess-1"))
    #expect(!state.isDuplicateEncodeFailedNotice(fp, sessionId: "sess-2"))
    #expect(!state.isDuplicateEncodeFailedNotice(computeInboxNoticeFingerprint([.init(seq: 22)]), sessionId: "sess-1"))
    state.recordNoticeWritten(fp, sessionId: "sess-1")
    #expect(!state.isDuplicateEncodeFailedNotice(fp, sessionId: "sess-1"), "successful write clears failed-attempt memo")
    state.recordNoticeEncodeFailed(fp, sessionId: "sess-1")
    state.clear()
    #expect(!state.isDuplicateEncodeFailedNotice(fp, sessionId: "sess-1"))
}
}
