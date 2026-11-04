import Foundation
import Testing
import RaftDaemonClient

private func live(_ models: [String]) -> RuntimeModelSourceOutcome {
    .live(.init(models: models.map { RuntimeModelEntry(id: $0, label: $0) }))
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool, timeoutMs: Int = 1_000) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private final class ClockBox: @unchecked Sendable {
    var now = 0
}

private final class Counter: @unchecked Sendable {
    var foreground = 0
    var background = 0
    var outcomes: [RuntimeModelSourceOutcome] = []
}

private func cache(now: @escaping @Sendable () -> Int = { 0 }, freshMs: Int = runtimeModelCacheFreshMs) -> RuntimeModelSourceCache {
    RuntimeModelSourceCache(now: now, freshMs: freshMs)
}

@Test func firstReadWaitsAndAReadInsideTheFreshWindowRunsNone() async {
    let counter = Counter()
    let cache = cache()
    let detect: RuntimeModelSourceCache.Detect = { _ in counter.foreground += 1; return live(["a"]) }
    let first = await cache.read(runtime: "codex", detect: detect)
    #expect(first.cache == .miss)
    #expect(counter.foreground == 1)
    let second = await cache.read(runtime: "codex", detect: detect)
    #expect(second.cache == .fresh)
    #expect(counter.foreground == 1)
}

@Test func staleReadAnswersAtOnceAndRefreshesInBackground() async {
    let clock = ClockBox()
    let counter = Counter()
    let cache = cache(now: { clock.now })
    let detect: RuntimeModelSourceCache.Detect = { mode in
        if mode == "background" { counter.background += 1 } else { counter.foreground += 1 }
        return live(["a"])
    }
    _ = await cache.read(runtime: "codex", detect: detect)
    clock.now = runtimeModelCacheFreshMs
    let stale = await cache.read(runtime: "codex", detect: detect)
    #expect(stale.cache == .stale)
    await waitUntil { counter.background == 1 }
    #expect(counter.background == 1)
    #expect(counter.foreground == 1)
}

@Test func concurrentStaleReadsStartOneBackgroundRefresh() async {
    let clock = ClockBox()
    let cache = cache(now: { clock.now })
    let counter = Counter()
    let detect: RuntimeModelSourceCache.Detect = { mode in
        if mode == "background" {
            counter.background += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        } else {
            counter.foreground += 1
        }
        return live(["a"])
    }
    await cache.store(runtime: "codex", outcome: live(["old"]))
    clock.now = runtimeModelCacheFreshMs
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<5 { group.addTask { _ = await cache.read(runtime: "codex", detect: detect) } }
    }
    await waitUntil { counter.background == 1 }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(counter.background == 1)
}

@Test func forceBypassesAFreshEntryAndWaits() async {
    let counter = Counter()
    let cache = cache()
    let detect: RuntimeModelSourceCache.Detect = { _ in counter.foreground += 1; return live(["a"]) }
    _ = await cache.read(runtime: "codex", detect: detect)
    let forced = await cache.read(runtime: "codex", detect: detect, force: true)
    #expect(forced.cache == .forced)
    #expect(counter.foreground == 2)
}

@Test func definitiveNonLiveAnswerDropsTheCachedList() async {
    let cache = cache()
    await cache.store(runtime: "codex", outcome: live(["a"]))
    await cache.store(runtime: "codex", outcome: .missingConfig(recovery: "login"))
    #expect(cache.cachedOutcome(runtime: "codex") == nil)
}

@Test func nonLiveAnswersAreNeverCached() async {
    let cache = cache()
    await cache.store(runtime: "a", outcome: .noModels)
    await cache.store(runtime: "b", outcome: .unsupported)
    await cache.store(runtime: "c", outcome: .error(retryable: false, code: "boom", reason: nil))
    #expect(cache.cachedOutcome(runtime: "a") == nil)
    #expect(cache.cachedOutcome(runtime: "b") == nil)
    #expect(cache.cachedOutcome(runtime: "c") == nil)
}

@Test func transientRefreshFailureKeepsThePreviousList() async {
    let cache = cache(now: { 0 })
    await cache.store(runtime: "codex", outcome: live(["old"]))
    for outcome in [
        RuntimeModelSourceOutcome.error(retryable: true, code: "detect_timeout", reason: nil),
        .error(retryable: true, code: "detect_failed", reason: nil),
        .error(retryable: true, code: nil, reason: nil),
        .error(retryable: true, code: "runtime_not_found", reason: "probe_timeout"),
    ] {
        await cache.store(runtime: "codex", outcome: outcome)
        #expect(cache.cachedOutcome(runtime: "codex") != nil)
    }
}

@Test func storeFromTheConnectTimePushWarmsTheCache() async {
    let counter = Counter()
    let cache = cache()
    await cache.store(runtime: "codex", outcome: live(["pushed"]))
    let read = await cache.read(runtime: "codex", detect: { _ in counter.foreground += 1; return live([]) })
    #expect(read.cache == .fresh)
    #expect(counter.foreground == 0)
    #expect(read.outcome == live(["pushed"]))
}

@Test func runtimesAreCachedIndependently() async {
    let cache = cache()
    await cache.store(runtime: "codex", outcome: live(["c"]))
    await cache.store(runtime: "claude", outcome: live(["a"]))
    #expect(cache.cachedOutcome(runtime: "codex") == live(["c"]))
    #expect(cache.cachedOutcome(runtime: "claude") == live(["a"]))
}

@Test func confirmedAbsenceDropsTheList() async {
    let cache = cache()
    await cache.store(runtime: "codex", outcome: live(["old"]))
    await cache.store(runtime: "codex", outcome: .error(retryable: true, code: "runtime_not_found", reason: "not_installed"))
    #expect(cache.cachedOutcome(runtime: "codex") == nil)
    await cache.store(runtime: "codex", outcome: live(["old"]))
    await cache.store(runtime: "codex", outcome: .error(retryable: true, code: "runtime_not_found", reason: nil))
    #expect(cache.cachedOutcome(runtime: "codex") == nil)
}
