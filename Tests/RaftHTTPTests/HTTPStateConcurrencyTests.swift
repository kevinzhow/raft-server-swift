import Foundation
import Synchronization
import Testing
@testable import RaftHTTP

private func admittedConcurrently(
    count: Int,
    _ operation: @escaping @Sendable (Int) -> Bool
) async -> Int {
    await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for index in 0..<count { group.addTask { operation(index) } }
        var admitted = 0
        for await allowed in group where allowed { admitted += 1 }
        return admitted
    }
}

@Test func httpStateAttachmentBudgetAdmitsExactlyOneWindowAcrossConcurrentRequests() async {
    let budget = PublicAttachmentBudget()
    let now = Date(timeIntervalSince1970: 1_000)
    let admitted = await admittedConcurrently(count: 512) { _ in budget.allow(ip: "one", now: now) }
    #expect(admitted == 120)
    #expect(!budget.allow(ip: "one", now: now.addingTimeInterval(59.999)))
    #expect(budget.allow(ip: "two", now: now))
    #expect(budget.allow(ip: "one", now: now.addingTimeInterval(60)))
}

@Test func httpStateSearchBudgetAndInFlightSlotsRemainAtomic() async {
    let now = Date(timeIntervalSince1970: 2_000)
    let store = PublicSearchMemoryBucketStore(now: { now })
    let consumed = await admittedConcurrently(count: 512) { _ in store.consume(limit: 32) == .allowed }
    #expect(consumed == 32)
    #expect(store.consume(limit: 32) == .rateLimited(retryAfter: 60))
    let acquired = await admittedConcurrently(count: 128) { _ in store.acquire(max: 8) }
    #expect(acquired == 8)
    for _ in 0..<20 { store.release() }
    let reacquired = await admittedConcurrently(count: 128) { _ in store.acquire(max: 8) }
    #expect(reacquired == 8)
}

@Test func httpStateSearchWindowResetKeepsRetryAfterAndRateIndependentOfInFlight() {
    let clock = Mutex(Date(timeIntervalSince1970: 3_000))
    let store = PublicSearchMemoryBucketStore(now: { clock.withLock { $0 } })
    #expect(store.consume(limit: 1) == .allowed)
    #expect(store.consume(limit: 1) == .rateLimited(retryAfter: 60))
    clock.withLock { $0 = $0.addingTimeInterval(59.2) }
    #expect(store.consume(limit: 1) == .rateLimited(retryAfter: 1))
    clock.withLock { $0 = $0.addingTimeInterval(0.8) }
    #expect(store.consume(limit: 1) == .allowed)
    #expect(store.acquire(max: 1))
    #expect(!store.acquire(max: 1))
    clock.withLock { $0 = $0.addingTimeInterval(60) }
    #expect(store.consume(limit: 1) == .allowed)
    #expect(!store.acquire(max: 1))
}

@Test func httpStateDesktopFeedCacheKeepsEveryIndependentConcurrentEntry() async {
    let cache = DesktopFeedCache()
    let retained = await admittedConcurrently(count: 128) { index in
        let key = "feed-\(index)"
        let value = FeedRead.feed(version: "1.\(index).0", files: ["asset-\(index)"])
        cache.set(key, at: index, read: value)
        return cache.get(key)?.at == index && cache.get(key)?.read == value
    }
    #expect(retained == 128)
    for index in 0..<128 {
        #expect(cache.get("feed-\(index)")?.read == .feed(version: "1.\(index).0", files: ["asset-\(index)"]))
    }
}
