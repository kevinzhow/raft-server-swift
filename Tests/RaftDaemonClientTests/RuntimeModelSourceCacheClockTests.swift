import Synchronization
import Testing
import RaftDaemonClient

private final class WeakClockModelCache: Sendable {
    private struct State: Sendable {
        weak var cache: RuntimeModelSourceCache?
    }
    private let state = Mutex(State())

    func install(_ cache: RuntimeModelSourceCache) {
        state.withLock { $0.cache = cache }
    }

    func get() -> RuntimeModelSourceCache? {
        state.withLock { $0.cache }
    }
}

@Test func clockCanReenterPublicStoreBeforeALiveEntryIsPublished() async {
    let reference = WeakClockModelCache()
    let cache = RuntimeModelSourceCache(now: {
        reference.get()?.store(runtime: "codex", outcome: .noModels)
        return 0
    })
    reference.install(cache)
    let outer = RuntimeModelSourceOutcome.live(.init(models: [
        RuntimeModelEntry(id: "outer", label: "outer"),
    ]))
    let detect: RuntimeModelSourceCache.Detect = { _ in .unsupported }

    cache.store(runtime: "codex", outcome: outer)
    let first = await cache.read(runtime: "codex", detect: detect)
    #expect((first.outcome, first.cache) == (outer, RuntimeModelCacheRead.fresh))
    let second = await cache.read(runtime: "codex", detect: detect)
    #expect((second.outcome, second.cache) == (RuntimeModelSourceOutcome.unsupported, RuntimeModelCacheRead.miss))
}
