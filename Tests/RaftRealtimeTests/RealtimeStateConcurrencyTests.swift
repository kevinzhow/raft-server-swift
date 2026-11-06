import Foundation
import Synchronization
import Testing
import RaftRealtime

private final class AttentionRecorder: DesktopAttentionRecording {
    private let entries = Mutex<[String]>([])
    private let afterRecord = Mutex<(@Sendable () -> Void)?>(nil)

    var events: [String] { entries.withLock { $0 } }

    func onNextRecord(_ callback: @escaping @Sendable () -> Void) {
        afterRecord.withLock { $0 = callback }
    }

    func record(userId: String) {
        entries.withLock { $0.append("record:\(userId)") }
        let callback = afterRecord.withLock { callback in
            let next = callback
            callback = nil
            return next
        }
        callback?()
    }

    func clear(userId: String) {
        entries.withLock { $0.append("clear:\(userId)") }
    }
}

private func reportConcurrently(_ report: @escaping @Sendable () -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<128 { group.addTask { report() } }
    }
}

@Test func realtimeStateAttentionThrottleAdmitsOneConcurrentReportAndClear() async {
    let recorder = AttentionRecorder()
    let handler = DesktopAttentionHandler(userId: "owner", clientKind: .desktop, recorder: recorder, now: { 1_000 })
    await reportConcurrently { handler.handle(["attended": true]) }
    #expect(recorder.events == ["record:owner"])
    await reportConcurrently { handler.handle(["attended": false]) }
    #expect(recorder.events == ["record:owner", "clear:owner"])
    await reportConcurrently { handler.handle(["attended": true]) }
    #expect(recorder.events == ["record:owner", "clear:owner", "record:owner"])
}

@Test func realtimeStateAttentionRecorderCanReenterWithoutHoldingTheThrottleLock() {
    let recorder = AttentionRecorder()
    let handler = DesktopAttentionHandler(userId: "owner", clientKind: .desktop, recorder: recorder, now: { 1_000 })
    recorder.onNextRecord { handler.handle(["attended": false]) }
    handler.handle(["attended": true])
    #expect(recorder.events == ["record:owner", "clear:owner"])
    handler.handle(["attended": true])
    #expect(recorder.events == ["record:owner", "clear:owner", "record:owner"])
}

@Test func realtimeStateAttentionKeepsFoundationBooleanNumberCompatibility() throws {
    let recorder = AttentionRecorder()
    let handler = DesktopAttentionHandler(userId: "owner", clientKind: .desktop, recorder: recorder, now: { 1_000 })
    handler.handle(try JSONSerialization.jsonObject(with: Data(#"{"attended":1}"#.utf8)))
    handler.handle(try JSONSerialization.jsonObject(with: Data(#"{"attended":0}"#.utf8)))
    handler.handle(try JSONSerialization.jsonObject(with: Data(#"{"attended":true}"#.utf8)))
    handler.handle(["attended": "false"])
    #expect(recorder.events == ["record:owner", "clear:owner", "record:owner"])
}

@Test func realtimeStateRegistryRetainsConcurrentUsersUntilTheExactExpiryBoundary() async {
    let registry = DesktopAttentionRegistry()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<128 {
            group.addTask { registry.record(userId: "user-\(index)", now: 1_000) }
        }
    }
    let users = (0..<128).map { "user-\($0)" }
    #expect(registry.usersWithRecentDesktopAttention(users, now: 1_000 + DesktopAttentionRegistry.windowMs - 1) == Set(users))
    #expect(registry.usersWithRecentDesktopAttention(users, now: 1_000 + DesktopAttentionRegistry.windowMs).isEmpty)
}
