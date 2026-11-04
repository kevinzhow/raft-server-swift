import Foundation
import Testing
import RaftRealtime

private final class Recorder: DesktopAttentionRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let logClear: Bool
    var log: [String] = []
    init(logClear: Bool = true) { self.logClear = logClear }
    func record(userId: String) { lock.withLock { log.append("record:\(userId)") } }
    func clear(userId: String) { if logClear { lock.withLock { log.append("clear:\(userId)") } } }
    var entries: [String] { lock.withLock { log } }
}

@Test func onlyARaftDesktopSocketCanReportAttention() {
    for kind in [SocketClientKind.web, .mobile, .cli] {
        let recorder = Recorder()
        let handler = DesktopAttentionHandler(userId: "u1", clientKind: kind, recorder: recorder)
        #expect(!handler.listens)
        handler.handle(["attended": true])
        #expect(recorder.entries.isEmpty, "\(kind) socket must not silence browser pushes")
    }
}

@Test func desktopAttentionRecordsItsOwnUserIgnoresOtherPayloadsAndThrottles() {
    let recorder = Recorder(logClear: false)
    final class Clock: @unchecked Sendable { var value = 0 }
    let clock = Clock()
    let handler = DesktopAttentionHandler(
        userId: "u1", clientKind: .desktop, recorder: recorder, now: { clock.value }
    )
    for bad: Any? in [nil, "attended", ["attended": false], ["attended": "true"], ["userId": "u2"]] {
        handler.handle(bad)
    }
    #expect(recorder.entries.isEmpty)

    handler.handle(["attended": true, "userId": "someone-else"])
    #expect(recorder.entries == ["record:u1"], "the payload cannot choose whose pushes are silenced")

    clock.value = DesktopAttentionEvents.minIntervalMs - 1
    handler.handle(["attended": true])
    #expect(recorder.entries == ["record:u1"], "a faster repeat is dropped")

    clock.value = DesktopAttentionEvents.minIntervalMs
    handler.handle(["attended": true])
    #expect(recorder.entries == ["record:u1", "record:u1"])
}

@Test func aFailedRecordNeverThrowsOutOfTheSocketHandler() {
    final class ThrowingRecorder: DesktopAttentionRecording, @unchecked Sendable {
        func record(userId: String) {}
        func clear(userId: String) {}
    }
    let handler = DesktopAttentionHandler(userId: "u1", clientKind: .desktop, recorder: ThrowingRecorder())
    handler.handle(["attended": true])
}

@Test func attendedFalseClearsItsOwnUserAndTheReturnRecordsImmediately() {
    let recorder = Recorder()
    final class Clock: @unchecked Sendable { var value = 0 }
    let clock = Clock()
    let handler = DesktopAttentionHandler(
        userId: "u1", clientKind: .desktop, recorder: recorder, now: { clock.value }
    )
    handler.handle(["attended": true])
    clock.value = 1_000
    handler.handle(["attended": false, "userId": "someone-else"])
    #expect(recorder.entries == ["record:u1", "clear:u1"], "an away report clears its own user")

    clock.value = 2_000
    handler.handle(["attended": true])
    #expect(recorder.entries == ["record:u1", "clear:u1", "record:u1"], "coming back is not held by the 30s throttle")

    clock.value = 3_000
    handler.handle(["attended": false])
    #expect(recorder.entries.count == 3, "a faster repeated clear is dropped")

    clock.value = 1_000 + DesktopAttentionEvents.minIntervalMs
    handler.handle(["attended": false])
    #expect(recorder.entries == ["record:u1", "clear:u1", "record:u1", "clear:u1"])
}

@Test func aBrowserSocketCannotClearAnyonesDesktopAttention() {
    let recorder = Recorder()
    let handler = DesktopAttentionHandler(userId: "u1", clientKind: .web, recorder: recorder)
    handler.handle(["attended": false])
    #expect(recorder.entries.isEmpty)
}

@Test func aFailedClearNeverThrowsOutOfTheSocketHandler() {
    final class Noop: DesktopAttentionRecording, @unchecked Sendable {
        func record(userId: String) {}
        func clear(userId: String) {}
    }
    let handler = DesktopAttentionHandler(userId: "u1", clientKind: .desktop, recorder: Noop())
    handler.handle(["attended": false])
}

@Test func theRegistryTracksTheObservableSuppressionState() {
    let registry = DesktopAttentionRegistry()
    #expect(!registry.isAttended(userId: "u1"))
    registry.record(userId: "u1")
    #expect(registry.isAttended(userId: "u1"))
    registry.clear(userId: "u1")
    #expect(!registry.isAttended(userId: "u1"))
}
