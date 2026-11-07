import Dispatch
import Foundation
import Synchronization
import Testing
import RaftDaemonClient

private final class WeakDeadlineScheduler: Sendable {
    private struct State: Sendable {
        weak var scheduler: DispatchDeadlineScheduler?
    }
    private let state = Mutex(State())

    init(_ scheduler: DispatchDeadlineScheduler) {
        state.withLock { $0.scheduler = scheduler }
    }

    func get() -> DispatchDeadlineScheduler? {
        state.withLock { $0.scheduler }
    }

    var isReleased: Bool {
        state.withLock { $0.scheduler == nil }
    }
}

private func deadlineEvent(_ event: DispatchSemaphore) -> Bool {
    event.wait(timeout: .now() + .seconds(2)) == .success
}

@Test func nativeDeadlineTimersFireAndReenterWithoutRunningCancelledWork() {
    let scheduler = DispatchDeadlineScheduler()
    let owner = WeakDeadlineScheduler(scheduler)
    let output = Mutex<[String]>([])
    let registered = Mutex<[Int]>([])
    let rootsFinished = DispatchSemaphore(value: 0)
    let nestedFinished = DispatchSemaphore(value: 0)
    let sentinelFinished = DispatchSemaphore(value: 0)
    let cancelledRan = DispatchSemaphore(value: 0)
    defer {
        let timers = registered.withLock { $0 }
        for timer in timers { scheduler.cancel(timer) }
    }

    let pending = scheduler.schedule(afterMs: 100) {
        output.withLock { $0.append("cancelled") }
        cancelledRan.signal()
    }
    registered.withLock { $0.append(pending) }
    scheduler.cancel(pending)

    let zero = scheduler.schedule(afterMs: 0) {
        if let scheduler = owner.get() {
            let nested = scheduler.schedule(afterMs: 0) {
                output.withLock { $0.append("nested") }
                nestedFinished.signal()
            }
            registered.withLock { $0.append(nested) }
            scheduler.cancel(pending)
        }
        output.withLock { $0.append("zero") }
        rootsFinished.signal()
    }
    registered.withLock { $0.append(zero) }
    let negative = scheduler.schedule(afterMs: -1) {
        output.withLock { $0.append("negative") }
        rootsFinished.signal()
    }
    registered.withLock { $0.append(negative) }
    let sentinel = scheduler.schedule(afterMs: 150) {
        output.withLock { $0.append("sentinel") }
        sentinelFinished.signal()
    }
    registered.withLock { $0.append(sentinel) }

    let firstRoot = deadlineEvent(rootsFinished)
    let secondRoot = deadlineEvent(rootsFinished)
    let nested = deadlineEvent(nestedFinished)
    let sentinelPassed = deadlineEvent(sentinelFinished)
    let cancelledFired = cancelledRan.wait(timeout: .now() + .milliseconds(50)) == .success
    let actual = output.withLock { $0 }
    #expect(firstRoot && secondRoot && nested && sentinelPassed)
    #expect(!cancelledFired)
    #expect(actual.count == 4)
    #expect(Set(actual) == Set(["zero", "negative", "nested", "sentinel"]))
}

@Test func cancellingAnAdmittedNativeDeadlineDoesNotJoinItsCallback() {
    let scheduler = DispatchDeadlineScheduler()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let callbackFinished = DispatchSemaphore(value: 0)
    let cancelReturned = DispatchSemaphore(value: 0)
    let output = Mutex<[Bool]>([])
    defer { release.signal() }

    let timer = scheduler.schedule(afterMs: 0) {
        entered.signal()
        let released = release.wait(timeout: .now() + .seconds(2)) == .success
        output.withLock { $0.append(released) }
        callbackFinished.signal()
    }
    let admitted = deadlineEvent(entered)
    Thread.detachNewThread {
        scheduler.cancel(timer)
        cancelReturned.signal()
    }
    // The return marker must arrive while the actual callback is still held.
    let returnedBeforeRelease = cancelReturned.wait(timeout: .now() + .milliseconds(500)) == .success
    release.signal()
    let callbackDrained = deadlineEvent(callbackFinished)
    let cancelDrained = returnedBeforeRelease || deadlineEvent(cancelReturned)
    let actual = output.withLock { $0 }
    #expect(admitted)
    #expect(returnedBeforeRelease)
    #expect(callbackDrained && cancelDrained)
    #expect(actual == [true], "the admitted callback completes after the caller releases its bounded work")
}

@Test func pendingNativeDeadlineOutlivesItsSchedulerWithoutRetainingIt() {
    var scheduler: DispatchDeadlineScheduler? = DispatchDeadlineScheduler()
    let owner = WeakDeadlineScheduler(scheduler!)
    let observeAfterRelease = DispatchSemaphore(value: 0)
    let callbackFinished = DispatchSemaphore(value: 0)
    let output = Mutex<[Bool]>([])
    defer { observeAfterRelease.signal() }

    let timer = scheduler!.schedule(afterMs: 50) {
        let ready = observeAfterRelease.wait(timeout: .now() + .seconds(2)) == .success
        let released = owner.isReleased
        output.withLock { $0.append(ready && released) }
        callbackFinished.signal()
    }
    // The weak bridge does not keep the scheduler alive. Even if the native
    // callback starts early, it observes ownership only after this release.
    scheduler = nil
    observeAfterRelease.signal()
    let callbackDrained = deadlineEvent(callbackFinished)
    // Break an accidental self-retention cycle on a failing implementation.
    owner.get()?.cancel(timer)
    let actual = output.withLock { $0 }
    #expect(callbackDrained)
    #expect(actual == [true], "the native queue keeps the callback alive while its scheduler can deinitialize")
}
