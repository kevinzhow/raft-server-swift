import Foundation
import Testing
import RaftDaemonClient

private final class FakeScheduler: OarDeadlineScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(id: Int, ms: Int, body: @Sendable () -> Void)] = []
    private var nextId = 1
    func schedule(afterMs: Int, _ body: @escaping @Sendable () -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        handlers.append((id, afterMs, body))
        return id
    }
    func cancel(_ timer: Int) {
        lock.withLock { handlers.removeAll { $0.id == timer } }
    }
    var count: Int { lock.withLock { handlers.count } }
    func fireAll() {
        let bodies = lock.withLock { handlers.map(\.body) }
        for body in bodies { body() }
    }
}

private final class Box: @unchecked Sendable {
    var continuation: CheckedContinuation<ListModelsResult, Never>?
}

private func baseInput(
    lister: ModelLister, deadlineMs: Int = 1_000, scheduler: OarDeadlineScheduler = FakeScheduler()
) -> OarModelSourceInput {
    OarModelSourceInput(
        lister: lister,
        installation: OarInstallation(kind: "available", command: "opencode"),
        deadlineMs: deadlineMs,
        keepReasoningEfforts: true,
        scheduler: scheduler,
        label: { $0.displayName ?? "label:\($0.id)" },
        onUnsupported: { _ in .unsupported }
    )
}

private func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@Test func okWithModelsMapsToLiveKeepingTiersAndEfforts() async {
    let lister = ModelLister { _, _ in
        .ok(models: [
            .init(id: "a/one", displayName: "One", effortLevels: ["low", "high"], defaultEffort: "high",
                  serviceTiers: ["fast"], defaultServiceTier: "fast"),
            .init(id: "a/two"),
        ])
    }
    let outcome = await OarListModels.detect(baseInput(lister: lister))
    #expect(outcome == .live(models: [
        .init(id: "a/one", label: "One", supportedReasoningEfforts: ["low", "high"],
              defaultReasoningEffort: "high", serviceTiers: ["fast"], defaultServiceTier: "fast",
              verified: "launchable"),
        .init(id: "a/two", label: "label:a/two", verified: "launchable"),
    ]))
}

@Test func okWithAnEmptyListMapsToNoModels() async {
    let lister = ModelLister { _, _ in .ok(models: []) }
    #expect(await OarListModels.detect(baseInput(lister: lister)) == .noModels)
}

@Test func okWithOnlyDisabledEntriesMapsToNoModels() async {
    let lister = ModelLister { _, _ in .ok(models: [.init(id: "a/x", disabled: true)]) }
    #expect(await OarListModels.detect(baseInput(lister: lister)) == .noModels)
}

@Test func unauthenticatedMapsToRetryableRuntimeNotAuthenticated() async {
    let lister = ModelLister { _, _ in .unauthenticated }
    #expect(await OarListModels.detect(baseInput(lister: lister)) == .error(retryable: true, code: "runtime_not_authenticated"))
}

@Test func unsupportedIsTheCallersDecisionWithOarsReason() async {
    final class Reasons: @unchecked Sendable { var values: [String] = [] }
    let reasons = Reasons()
    let lister = ModelLister { _, _ in .unsupported(reason: "why") }
    var input = baseInput(lister: lister)
    input.onUnsupported = { reason in
        reasons.values.append(reason)
        return .error(retryable: true, code: "detect_failed")
    }
    #expect(await OarListModels.detect(input) == .error(retryable: true, code: "detect_failed"))
    #expect(reasons.values == ["why"])
}

@Test func aThrownListingMapsToRetryableErrorWithNoCode() async {
    let lister = ModelLister { _, _ in throw NSError(domain: "Failed to list opencode models", code: 1) }
    #expect(await OarListModels.detect(baseInput(lister: lister)) == .error(retryable: true))
}

@Test func aListingStillRunningAtOurDeadlineReportsDetectTimeout() async {
    let scheduler = FakeScheduler()
    let box = Box()
    let lister = ModelLister { _, _ in
        await withCheckedContinuation { box.continuation = $0 }
    }
    async let pending = OarListModels.detect(baseInput(lister: lister, deadlineMs: 20, scheduler: scheduler))
    #expect(await eventually { scheduler.count == 1 })
    scheduler.fireAll()
    #expect(await pending == .error(retryable: true, code: "detect_timeout"))
    box.continuation?.resume(returning: .ok(models: []))
    _ = await eventually { true }
}

@Test func theListerGetsATimeoutAboveOurDeadline() async {
    final class Seen: @unchecked Sendable { var values: [Int?] = [] }
    let seen = Seen()
    let lister = ModelLister { _, timeout in
        seen.values.append(timeout)
        return .ok(models: [])
    }
    _ = await OarListModels.detect(baseInput(lister: lister, deadlineMs: 1_000))
    #expect(seen.values.count == 1)
    let firstTimeout = seen.values.first.flatMap { $0 } ?? 0
    #expect(firstTimeout > 1_000, "lister timeout must exceed our deadline")
}

@Test func projectionDropsEffortsWhenTheRuntimeCannotApplyThemAndDeduplicates() {
    let models = OarListModels.project(
        [.init(id: "a/one", effortLevels: ["low"], defaultEffort: "low"), .init(id: "a/one", displayName: "dup")],
        options: (label: { $0.id }, keepReasoningEfforts: false)
    )
    #expect(models == [.init(id: "a/one", label: "a/one", verified: "launchable")])
}

@Test func aRequestAfterOurDeadlineJoinsTheRunningListingInsteadOfStartingASecond() async {
    final class Started: @unchecked Sendable { var count = 0 }
    final class Finish: @unchecked Sendable { var continuation: CheckedContinuation<ListModelsResult, Never>? }
    let started = Started()
    let finish = Finish()
    let lister = ModelLister { _, _ in
        started.count += 1
        return await withCheckedContinuation { finish.continuation = $0 }
    }
    let scheduler = FakeScheduler()
    async let first = OarListModels.detect(baseInput(lister: lister, deadlineMs: 10, scheduler: scheduler))
    #expect(await eventually { scheduler.count == 1 })
    scheduler.fireAll()
    #expect(await first == .error(retryable: true, code: "detect_timeout"))
    let secondScheduler = FakeScheduler()
    let secondTask = Task { await OarListModels.detect(baseInput(lister: lister, deadlineMs: 1_000, scheduler: secondScheduler)) }
    #expect(await eventually { secondScheduler.count == 1 })
    finish.continuation?.resume(returning: .ok(models: [.init(id: "a/late")]))
    #expect(await secondTask.value == .live(models: [.init(id: "a/late", label: "label:a/late", verified: "launchable")]))
    #expect(started.count == 1, "one listing ran for both requests")
    // Once it settled, the next request starts a new listing.
    let thirdScheduler = FakeScheduler()
    async let third = OarListModels.detect(baseInput(lister: lister, deadlineMs: 10, scheduler: thirdScheduler))
    #expect(await eventually { thirdScheduler.count == 1 })
    thirdScheduler.fireAll()
    #expect(await third == .error(retryable: true, code: "detect_timeout"))
    finish.continuation?.resume(returning: .ok(models: []))
    _ = await eventually { true }
}
