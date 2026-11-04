import Foundation
import Testing
import RaftDaemonClient

private final class FakeClock: @unchecked Sendable {
    private var pending: [(due: Int, id: UUID, action: @Sendable () -> Void)] = []
    private var now = 0

    func schedule(afterMs: Int, action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        pending.append((now + afterMs, id, action))
        return id
    }

    func cancel(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    func advance(_ ms: Int) {
        now += ms
        let due = pending.filter { $0.due <= now }.sorted { $0.due < $1.due }
        pending.removeAll { $0.due <= now }
        for item in due { item.action() }
    }
}

private final class Recorder: @unchecked Sendable {
    var logs: [String] = []
    var kills: [String] = []
}

private func makeGuard(_ clock: FakeClock, _ recorder: Recorder, pid: Int = 4242) -> RuntimeChildGuard {
    RuntimeChildGuard(
        pid: pid,
        log: { recorder.logs.append($0) },
        kill: { signal in recorder.kills.append(signal); return true },
        schedule: { afterMs, action in clock.schedule(afterMs: afterMs, action: action) },
        cancel: { clock.cancel($0) }
    )
}

private func kinds(_ events: [RuntimeChildEvent]) -> [String] {
    events.map { event in
        switch event {
        case .stdout: "stdout"
        case .stderr: "stderr"
        case .error: "error"
        case .exit: "exit"
        case .close: "close"
        }
    }
}

@Test func anUnclaimedChildIsAbandonedLoggedDroppedAndTerminated() {
    let clock = FakeClock()
    let recorder = Recorder()
    let guardChild = makeGuard(clock, recorder)
    guardChild.feedStdout(Data("partial".utf8))
    guardChild.noteError(code: "EACCES")
    #expect(recorder.logs.isEmpty, "recorded quietly while a hand-off may still come")

    clock.advance(10_000)
    #expect(recorder.logs.count == 1)
    #expect(recorder.logs[0].contains("abandoning"))
    #expect(recorder.logs[0].contains("not taken over within 10000ms"))
    #expect(recorder.logs[0].contains("errors=EACCES"))
    #expect(recorder.kills == ["SIGTERM"])
    clock.advance(5_000)
    #expect(recorder.kills == ["SIGTERM", "SIGKILL"], "still alive after SIGTERM: SIGKILL")

    guardChild.feedStdout(Data("more".utf8))
    guardChild.noteExit(code: nil, signal: "SIGKILL")
    let early = guardChild.takeEarlyEvents()
    #expect(early?.abandoned?.contains("not taken over") == true)
    #expect(kinds(early?.events ?? []) == ["error", "exit"], "no output is held or replayed after abandonment")
}

@Test func outputPastTheCapAbandonsTheChild() {
    let clock = FakeClock()
    let recorder = Recorder()
    let guardChild = makeGuard(clock, recorder)
    let chunk = Data(repeating: 120, count: 1024 * 1024)
    for _ in 0..<10 { guardChild.feedStdout(chunk) }
    let early = guardChild.takeEarlyEvents()
    #expect(early?.abandoned?.contains("exceeded") == true)
    let stdoutKinds = kinds(early?.events ?? []).filter { $0 == "stdout" }
    #expect(stdoutKinds.isEmpty, "nothing partial is offered for replay")
    #expect(recorder.kills == ["SIGTERM"])
}

@Test func aChildHandedOverInTimeIsNeverAbandoned() {
    let clock = FakeClock()
    let recorder = Recorder()
    let guardChild = makeGuard(clock, recorder)
    guardChild.feedStdout(Data("a".utf8))
    guardChild.noteExit(code: 0, signal: nil)

    let early = guardChild.takeEarlyEvents()
    #expect(early?.abandoned == nil)
    #expect(kinds(early?.events ?? []) == ["stdout", "exit"])
    #expect(guardChild.takeEarlyEvents() == nil, "the hand-off returns the recorded events once")
    clock.advance(20_000)
    #expect(recorder.logs.isEmpty)
    #expect(recorder.kills.isEmpty)
}
