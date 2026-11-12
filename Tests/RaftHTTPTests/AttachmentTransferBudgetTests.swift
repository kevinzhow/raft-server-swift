import Synchronization
import TestSupport
import Testing
@testable import RaftHTTP

@Suite(.serialized) struct AttachmentTransferBudgetTests {
    private struct PreparationError: Error {}

    private struct Record: Sendable {
        var entered: [Int] = []
        var active = 0
        var maxActive = 0
        var completed = 0
    }

    /// Test-local observation of actual operation entry. The budget is never
    /// asked for its queue depth or any other internal counter.
    private final class Recorder: Sendable {
        private struct State: Sendable {
            var record = Record()
            var enteredTarget = 0
            var enteredObserver: CheckedContinuation<Void, Never>?
        }

        private let state = Mutex(State())

        func enter(_ id: Int) {
            let observer: CheckedContinuation<Void, Never>? = state.withLock { stored in
                stored.record.entered.append(id)
                stored.record.active += 1
                stored.record.maxActive = max(stored.record.maxActive, stored.record.active)
                guard let observer = stored.enteredObserver,
                      stored.record.entered.count >= stored.enteredTarget else {
                    return nil
                }
                stored.enteredObserver = nil
                return observer
            }
            observer?.resume()
        }

        func leave() {
            state.withLock { stored in
                stored.record.active -= 1
                stored.record.completed += 1
            }
        }

        var record: Record { state.withLock { $0.record } }

        func awaitEntered(_ count: Int) async {
            await withCheckedContinuation { continuation in
                let reached: Bool = state.withLock { stored in
                    stored.enteredTarget = max(stored.enteredTarget, count)
                    if stored.record.entered.count >= count { return true }
                    precondition(stored.enteredObserver == nil, "One recorder observer at a time")
                    stored.enteredObserver = continuation
                    return false
                }
                if reached { continuation.resume() }
            }
        }
    }

    /// A one-shot release gate held open by the test.
    private final class Gate: Sendable {
        private struct State: Sendable {
            var isOpen = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func wait() async {
            await withCheckedContinuation { continuation in
                let open: Bool = state.withLock { stored in
                    if stored.isOpen { return true }
                    stored.waiters.append(continuation)
                    return false
                }
                if open { continuation.resume() }
            }
        }

        func open() {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock { stored in
                stored.isOpen = true
                let pending = stored.waiters
                stored.waiters.removeAll()
                return pending
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    /// A one-shot signal from a started task to the test.
    private final class Signal: Sendable {
        private struct State: Sendable {
            var isSignaled = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func signal() {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock { stored in
                stored.isSignaled = true
                let pending = stored.waiters
                stored.waiters.removeAll()
                return pending
            }
            for waiter in waiters { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let signaled: Bool = state.withLock { stored in
                    if stored.isSignaled { return true }
                    stored.waiters.append(continuation)
                    return false
                }
                if signaled { continuation.resume() }
            }
        }
    }

    /// Lets tasks that signalled and then called `withPermit` reach their
    /// suspension point before the test asserts that queued work has not run.
    private func settleScheduler() async {
        for _ in 0..<16 { await Task.yield() }
    }

    @Test func boundsConcurrentPreparationAndDrainsQueuedWork() async throws {
        let budget = AttachmentTransferBudget(limit: 2)
        let recorder = Recorder()
        let gate = Gate()

        try await withTestDeadline("bounded preparation", seconds: 20) {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for id in 0..<6 {
                    group.addTask {
                        try await budget.withPermit {
                            recorder.enter(id)
                            defer { recorder.leave() }
                            await gate.wait()
                            return id
                        }
                    }
                }
                await recorder.awaitEntered(2)
                #expect(recorder.record.active == 2)
                #expect(recorder.record.maxActive == 2)
                gate.open()
                for try await id in group {
                    #expect((0..<6).contains(id))
                }
            }
        }

        let record = recorder.record
        #expect(record.entered.count == 6)
        #expect(record.completed == 6)
        #expect(record.active == 0)
        #expect(record.maxActive == 2)
    }

    @Test func queuedPreparationWaitsForHolderReleaseAndGrantsFIFO() async throws {
        let budget = AttachmentTransferBudget(limit: 1)
        let recorder = Recorder()
        let holderGate = Gate()
        let holderEntered = Signal()

        let holder = Task {
            try await budget.withPermit {
                recorder.enter(0)
                holderEntered.signal()
                await holderGate.wait()
                recorder.leave()
            }
        }
        try await withTestDeadline("holder entry", seconds: 10) {
            await holderEntered.wait()
        }

        let firstStarted = Signal()
        let first = Task {
            firstStarted.signal()
            try await budget.withPermit {
                recorder.enter(1)
                recorder.leave()
            }
        }
        try await withTestDeadline("first waiter start", seconds: 10) {
            await firstStarted.wait()
        }
        await settleScheduler()
        #expect(recorder.record.entered == [0])
        #expect(recorder.record.active == 1)

        let secondStarted = Signal()
        let second = Task {
            secondStarted.signal()
            try await budget.withPermit {
                recorder.enter(2)
                recorder.leave()
            }
        }
        try await withTestDeadline("second waiter start", seconds: 10) {
            await secondStarted.wait()
        }
        await settleScheduler()
        #expect(recorder.record.entered == [0])

        holderGate.open()
        try await withTestDeadline("holder completion", seconds: 10) {
            try await holder.value
        }
        try await withTestDeadline("first waiter completion", seconds: 10) {
            try await first.value
        }
        try await withTestDeadline("second waiter completion", seconds: 10) {
            try await second.value
        }

        #expect(recorder.record.entered == [0, 1, 2])
        #expect(recorder.record.active == 0)
    }

    @Test func cancelledQueuedWaiterDoesNotRunOrBlockTheNextWaiter() async throws {
        let budget = AttachmentTransferBudget(limit: 1)
        let recorder = Recorder()
        let holderGate = Gate()
        let holderEntered = Signal()

        let holder = Task {
            try await budget.withPermit {
                recorder.enter(0)
                holderEntered.signal()
                await holderGate.wait()
                recorder.leave()
            }
        }
        try await withTestDeadline("holder entry", seconds: 10) {
            await holderEntered.wait()
        }

        let cancelledStarted = Signal()
        let cancelled = Task {
            cancelledStarted.signal()
            try await budget.withPermit {
                recorder.enter(1)
                recorder.leave()
            }
        }
        try await withTestDeadline("cancelled waiter start", seconds: 10) {
            await cancelledStarted.wait()
        }
        await settleScheduler()
        #expect(recorder.record.active == 1)

        cancelled.cancel()
        try await withTestDeadline("cancelled waiter unwind", seconds: 10) {
            do {
                try await cancelled.value
                Issue.record("A canceled queued waiter returned successfully")
            } catch is CancellationError {
            }
        }
        #expect(recorder.record.entered == [0])

        let nextStarted = Signal()
        let next = Task {
            nextStarted.signal()
            try await budget.withPermit {
                recorder.enter(2)
                recorder.leave()
            }
        }
        try await withTestDeadline("next waiter start", seconds: 10) {
            await nextStarted.wait()
        }
        await settleScheduler()
        #expect(recorder.record.entered == [0])

        holderGate.open()
        try await withTestDeadline("holder completion", seconds: 10) {
            try await holder.value
        }
        try await withTestDeadline("next waiter completion", seconds: 10) {
            try await next.value
        }

        #expect(recorder.record.entered == [0, 2])
        #expect(recorder.record.active == 0)

        let afterCancellation = try await withTestDeadline("budget after cancellation", seconds: 10) {
            try await budget.withPermit { 7 }
        }
        #expect(afterCancellation == 7)
    }

    @Test func operationFailureReturnsThePermit() async throws {
        let budget = AttachmentTransferBudget(limit: 1)
        let recorder = Recorder()

        var threw = false
        do {
            try await budget.withPermit {
                recorder.enter(0)
                defer { recorder.leave() }
                throw PreparationError()
            }
        } catch is PreparationError {
            threw = true
        }
        #expect(threw)
        #expect(recorder.record.active == 0)

        let result = try await withTestDeadline("permit after operation throw", seconds: 10) {
            try await budget.withPermit { 42 }
        }
        #expect(result == 42)
    }

    @Test func preCancelledTaskDoesNotRunTheOperation() async throws {
        let budget = AttachmentTransferBudget(limit: 1)
        let recorder = Recorder()
        let started = Signal()
        let release = Gate()

        let task = Task {
            started.signal()
            await release.wait()
            try await budget.withPermit {
                recorder.enter(0)
                recorder.leave()
            }
        }
        try await withTestDeadline("pre-cancelled task start", seconds: 10) {
            await started.wait()
        }
        task.cancel()
        release.open()

        try await withTestDeadline("pre-cancelled task unwind", seconds: 10) {
            do {
                try await task.value
                Issue.record("A pre-cancelled preparation ran")
            } catch is CancellationError {
            }
        }
        #expect(recorder.record.entered.isEmpty)

        let ran = try await withTestDeadline("permit after pre-cancellation", seconds: 10) {
            try await budget.withPermit { true }
        }
        #expect(ran)
    }

    @Test func cancellationAndGrantStressNeitherDeadlocksNorLeaks() async throws {
        let budget = AttachmentTransferBudget(limit: 3)
        let recorder = Recorder()

        var tasks: [Task<Void, Never>] = []
        for id in 0..<80 {
            let task = Task {
                do {
                    try await budget.withPermit {
                        recorder.enter(id)
                        defer { recorder.leave() }
                        for _ in 0..<(id % 4) { await Task.yield() }
                    }
                } catch is CancellationError {
                } catch {
                    Issue.record("Unexpected preparation error: \(error)")
                }
            }
            if id % 4 == 0 { task.cancel() }
            tasks.append(task)
            if id % 9 == 0 { await Task.yield() }
        }

        let pending = tasks
        try await withTestDeadline("cancellation stress completion", seconds: 30) {
            for task in pending { await task.value }
        }

        let record = recorder.record
        #expect(record.maxActive <= 3)
        #expect(record.active == 0)
        #expect(Set(record.entered).count == record.entered.count)

        let afterStress = try await withTestDeadline("permit after stress", seconds: 10) {
            try await budget.withPermit { 9 }
        }
        #expect(afterStress == 9)
    }
}
