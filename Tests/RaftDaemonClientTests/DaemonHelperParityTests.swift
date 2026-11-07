import Foundation
import RaftDaemonClient
import Testing

@Test func historyMessageLineIncludesThreadMetadataAndAttachments() {
    let threaded = DaemonTextFormatting.formatHistoryMessageLine(.init(
        seq: 42,
        id: "msg-1",
        createdAt: "2026-04-15T00:00:00.000Z",
        senderType: "agent",
        senderName: "alice",
        content: "hello",
        threadId: "thread-123",
        replyCount: 3
    ))
    #expect(threaded == "[seq=42 msg=msg-1 time=2026-04-15 00:00:00Z type=agent threadId=thread-123 replyCount=3] @alice: hello")

    let plain = DaemonTextFormatting.formatHistoryMessageLine(.init(
        seq: 7, id: "msg-2", createdAt: "2026-04-15T00:00:00.000Z", senderName: "bob", content: "plain"
    ))
    #expect(plain == "[seq=7 msg=msg-2 time=2026-04-15 00:00:00Z] @bob: plain")

    let attached = DaemonTextFormatting.formatHistoryMessageLine(.init(
        seq: 9, id: "msg-3", createdAt: "2026-04-15T00:00:00.000Z", senderName: "carol", content: "see attached",
        attachments: [.init(id: "att-1", filename: "trace.log")]
    ))
    #expect(attached.contains("trace.log (id:att-1)"))
    #expect(attached.contains("`raft attachment view --id <attachmentId> --output <path>`"))
    #expect(!attached.contains("view_file"))
}

@Test func recentDeliveryIdsExpireByAgeAndDropTheOldest() {
    let ids = RecentDeliveryIds(maxEntries: 4096, maxAgeMs: 10 * 60_000)
    ids.remember("a", now: 0)
    #expect(ids.has("a", now: 10 * 60_000 - 1))
    #expect(!ids.has("a", now: 10 * 60_000))
    #expect(ids.size == 0)

    let capped = RecentDeliveryIds(maxEntries: 3, maxAgeMs: 10 * 60_000)
    for (index, id) in ["a", "b", "c", "d"].enumerated() { capped.remember(id, now: index) }
    #expect(capped.size == 3)
    #expect(!capped.has("a", now: 4))
    #expect(capped.has("b", now: 4))
    #expect(capped.has("d", now: 4))

    let reordered = RecentDeliveryIds(maxEntries: 2, maxAgeMs: 10 * 60_000)
    reordered.remember("a", now: 0)
    reordered.remember("b", now: 1)
    reordered.remember("a", now: 2)
    reordered.remember("c", now: 3)
    #expect(reordered.has("a", now: 3))
    #expect(!reordered.has("b", now: 3))
}

@Test func recentDeliveryIdsKeepLazyExpiryBoundsAndConcurrentCapacity() async {
    for cap in [0, -1] {
        let ids = RecentDeliveryIds(maxEntries: cap, maxAgeMs: 10)
        ids.remember("a", now: 10)
        #expect(ids.size == 0)
        #expect(!ids.has("a", now: 10))
    }
    for age in [0, -1] {
        let ids = RecentDeliveryIds(maxEntries: 2, maxAgeMs: age)
        ids.remember("a", now: 10)
        #expect(!ids.has("a", now: 10))
        #expect(ids.size == 0)
    }
    let lazy = RecentDeliveryIds(maxEntries: 4, maxAgeMs: 10)
    lazy.remember("a", now: 0)
    lazy.remember("b", now: 5)
    #expect(lazy.has("b", now: 11))
    #expect(lazy.size == 2, "has only expires the queried identity")
    #expect(!lazy.has("a", now: 11))
    #expect(lazy.size == 1)
    lazy.remember("b", now: 0)
    #expect(lazy.has("b", now: -1), "a backwards clock is not clamped")
    #expect(lazy.has("b", now: 9))
    #expect(!lazy.has("b", now: 10))

    let shared = RecentDeliveryIds(maxEntries: 4, maxAgeMs: 1_000)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<64 { group.addTask { shared.remember("same", now: 0) } }
    }
    #expect(shared.size == 1)
    #expect(shared.has("same", now: 1))
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<64 { group.addTask { shared.remember("id-\(index)", now: 0) } }
    }
    #expect(shared.size == 4)
    #expect((0..<64).filter { shared.has("id-\($0)", now: 1) }.count == 4)
    for index in 0..<4 { shared.remember("new-\(index)", now: 1) }
    #expect(shared.size == 4)
    #expect((0..<4).allSatisfy { shared.has("new-\($0)", now: 1) })
    #expect((0..<64).allSatisfy { !shared.has("id-\($0)", now: 1) })
}

@Test func daemonLogSubscribersReceiveStructuredEventsAndCanUnsubscribe() {
    let log = DaemonLog()
    final class Sink: @unchecked Sendable {
        var events: [DaemonLog.Event] = []
    }
    let sink = Sink()
    let token = log.subscribe { event in sink.events.append(event) }
    log.info("hello")
    log.warn("careful")
    log.unsubscribe(token)
    log.error("boom")
    #expect(sink.events.count == 2)
    #expect(sink.events.map(\.level) == ["INFO", "WARN"])
    #expect(sink.events[0].line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z \[INFO\] hello$"#, options: .regularExpression) != nil)
    #expect(sink.events[1].message == "careful")
}
