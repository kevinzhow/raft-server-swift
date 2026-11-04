import Foundation
import Testing
import RaftDaemonClient

private final class FakeScheduler: RuntimeNotificationScheduler, @unchecked Sendable {
    var scheduled: [(body: @Sendable () -> Void, ms: Int)] = []
    var cancelled: [Int] = []
    var nextId = 1
    func schedule(_ body: @escaping @Sendable () -> Void, afterMs: Int) -> Int {
        let id = nextId
        nextId += 1
        scheduled.append((body, afterMs))
        return id
    }
    func cancel(_ timer: Int) {
        cancelled.append(timer)
    }
}

@Test func pendingDebtIsTrackedSeparatelyFromScheduling() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    #expect(state.add() == 1)
    #expect(state.add(2) == 3)
    #expect(state.pendingCount == 3)
    #expect(!state.hasTimer)
}

@Test func schedulesAtMostOneTimer() {
    let state = RuntimeNotificationState(scheduler: FakeScheduler())
    final class Calls: @unchecked Sendable { var value = 0 }
    let calls = Calls()
    #expect(state.schedule({ calls.value += 1 }, delayMs: 10_000) == true)
    #expect(state.schedule({ calls.value += 1 }, delayMs: 10_000) == false)
    #expect(state.hasTimer)
    state.clearTimer()
    #expect(!state.hasTimer)
    #expect(calls.value == 0)
}

@Test func defaultSchedulerFiresThroughTheRuntimeTimerPath() async {
    let state = RuntimeNotificationState()
    final class Calls: @unchecked Sendable { var value = 0 }
    let calls = Calls()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ok = state.schedule({
            calls.value += 1
            continuation.resume()
        }, delayMs: 1)
        #expect(ok == true)
    }
    #expect(calls.value == 1)
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
