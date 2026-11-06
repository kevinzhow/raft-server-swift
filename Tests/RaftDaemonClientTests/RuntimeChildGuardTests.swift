import Foundation
import Synchronization
import Testing
import RaftDaemonClient
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private final class FakeClock: Sendable {
    private struct State {
        var pending: [(due: Int, id: UUID, action: @Sendable () -> Void)] = []
        var now = 0
    }
    private let state = Mutex(State())

    func schedule(afterMs: Int, action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.pending.append(($0.now + afterMs, id, action)) }
        return id
    }

    func cancel(_ id: UUID) {
        state.withLock { $0.pending.removeAll { $0.id == id } }
    }

    func advance(_ ms: Int) {
        let due = state.withLock { state in
            state.now += ms
            let due = state.pending.filter { $0.due <= state.now }.sorted { $0.due < $1.due }
            state.pending.removeAll { $0.due <= state.now }
            return due
        }
        for item in due { item.action() }
    }
}

private final class Recorder: Sendable {
    private struct State {
        var logs: [String] = []
        var kills: [String] = []
    }
    private let state = Mutex(State())
    var logs: [String] { state.withLock { $0.logs } }
    var kills: [String] { state.withLock { $0.kills } }
    func log(_ message: String) { state.withLock { $0.logs.append(message) } }
    func kill(_ signal: String) -> Bool {
        state.withLock { $0.kills.append(signal) }
        return true
    }
}

private func makeGuard(_ clock: FakeClock, _ recorder: Recorder, pid: Int = 4242) -> RuntimeChildGuard {
    RuntimeChildGuard(
        pid: pid,
        log: { recorder.log($0) },
        kill: { recorder.kill($0) },
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

@Suite(.serialized)
struct RuntimeChildGuardTests {
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

    @Test func cancelledEscalationCannotSignalAfterHandover() throws {
        let clock = FakeClock()
        let recorder = Recorder()
        let guardChild = RuntimeChildGuard(
            pid: 4242, log: { recorder.log($0) }, kill: { recorder.kill($0) },
            schedule: { clock.schedule(afterMs: $0, action: $1) }
            // Deliberately retain callbacks, as the default canceller does.
        )
        guardChild.feedStdout(Data(repeating: 120, count: RuntimeChildGuard.maxEarlyOutputBytes + 1))
        #expect(recorder.kills == ["SIGTERM"])
        let early = try #require(guardChild.takeEarlyEvents())
        #expect(early.abandoned == "held output exceeded 4194304 bytes")
        clock.advance(20_000)
        #expect(recorder.kills == ["SIGTERM"], "both stale timers are harmless even if cancellation cannot remove them")
        #expect(recorder.logs.count == 1)
    }

    @Test func loggingAndCancellationCanReenterTheGuard() throws {
        let clock = FakeClock()
        let recorder = Recorder()
        let owner = Mutex<RuntimeChildGuard?>(nil)
        let handedOver = Mutex<RuntimeChildHandover?>(nil)
        let guardChild = RuntimeChildGuard(
            pid: 4242,
            log: { message in
                recorder.log(message)
                let guardChild = owner.withLock { $0 }
                guardChild?.noteExit(code: 0, signal: nil)
                let early = guardChild?.takeEarlyEvents()
                handedOver.withLock { $0 = early }
            },
            kill: { recorder.kill($0) },
            schedule: { clock.schedule(afterMs: $0, action: $1) },
            cancel: { token in
                clock.cancel(token)
                let guardChild = owner.withLock { $0 }
                guardChild?.noteClose(code: 0, signal: nil)
            }
        )
        owner.withLock { $0 = guardChild }
        guardChild.noteError(code: "EACCES")
        guardChild.feedStdout(Data(repeating: 120, count: RuntimeChildGuard.maxEarlyOutputBytes + 1))
        let early = try #require(handedOver.withLock { $0 })
        #expect(kinds(early.events) == ["error", "close", "exit"])
        #expect(recorder.logs == ["[RuntimeChild pid=4242] abandoning a runtime child no session took over: held output exceeded 4194304 bytes (errors=EACCES, exited=false)"])
        #expect(recorder.kills.isEmpty, "the reentrant exit and handover retire queued process effects")
        owner.withLock { $0 = nil }
    }

    @Test func aKillerCanReportExitBeforeEscalationIsRegistered() {
        let clock = FakeClock()
        let recorder = Recorder()
        let owner = Mutex<RuntimeChildGuard?>(nil)
        let guardChild = RuntimeChildGuard(
            pid: 4242, log: { recorder.log($0) },
            kill: { signal in
                _ = recorder.kill(signal)
                let guardChild = owner.withLock { $0 }
                guardChild?.noteExit(code: nil, signal: signal)
                return true
            },
            schedule: { clock.schedule(afterMs: $0, action: $1) },
            cancel: { clock.cancel($0) }
        )
        owner.withLock { $0 = guardChild }
        guardChild.feedStderr(Data(repeating: 120, count: RuntimeChildGuard.maxEarlyOutputBytes + 1))
        clock.advance(20_000)
        #expect(recorder.kills == ["SIGTERM"])
        #expect(guardChild.takeEarlyEvents()?.events == [.exit(code: nil, signal: "SIGTERM")])
        owner.withLock { $0 = nil }
    }

    @Test func timersMayFireSynchronouslyBeforeTheirTokensArePublished() {
        let recorder = Recorder()
        let registered = Mutex<[UUID]>([])
        let cancelled = Mutex<[UUID]>([])
        let guardChild = RuntimeChildGuard(
            pid: nil, log: { recorder.log($0) }, kill: { recorder.kill($0) },
            schedule: { _, action in
                let token = UUID()
                registered.withLock { $0.append(token) }
                action()
                action()
                return token
            },
            cancel: { token in cancelled.withLock { $0.append(token) } }
        )
        #expect(recorder.kills == ["SIGTERM", "SIGKILL"])
        #expect(recorder.logs == ["[RuntimeChild pid=none] abandoning a runtime child no session took over: not taken over within 10000ms (errors=none, exited=false)"])
        #expect(Set(cancelled.withLock { $0 }) == Set(registered.withLock { $0 }))
        #expect(guardChild.takeEarlyEvents()?.abandoned == "not taken over within 10000ms")
    }

    @Test(.timeLimit(.minutes(1))) func handoverRetiresATimerWhoseRegistrationIsStillInFlight() async throws {
        let clock = FakeClock()
        let recorder = Recorder()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lateToken = UUID()
        let lateAction = Mutex<(@Sendable () -> Void)?>(nil)
        let cancelled = Mutex<[UUID]>([])
        let guardChild = RuntimeChildGuard(
            pid: 4242, log: { recorder.log($0) }, kill: { recorder.kill($0) },
            schedule: { delay, action in
                if delay == RuntimeChildGuard.abandonKillAfterMs {
                    lateAction.withLock { $0 = action }
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                    return lateToken
                }
                return clock.schedule(afterMs: delay, action: action)
            },
            cancel: { token in
                cancelled.withLock { $0.append(token) }
                clock.cancel(token)
            }
        )
        let overflow = Task {
            guardChild.feedStdout(Data(repeating: 120, count: RuntimeChildGuard.maxEarlyOutputBytes + 1))
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let early = guardChild.takeEarlyEvents()
        release.signal()
        await overflow.value
        #expect(early?.abandoned == "held output exceeded 4194304 bytes")
        #expect(cancelled.withLock { $0.contains(lateToken) })
        let action = try #require(lateAction.withLock { $0 })
        action()
        #expect(recorder.kills == ["SIGTERM"])
    }

    @Test func concurrentChildEventsReplayInProducerOrderAndOnlyOnce() async throws {
        let recorder = Recorder()
        let guardChild = RuntimeChildGuard(pid: 4242, log: { recorder.log($0) }, kill: { recorder.kill($0) })
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<8 {
                group.addTask {
                    for index in 0..<64 {
                        guardChild.feedStdout(Data("out/\(producer)/\(index)".utf8))
                        guardChild.feedStderr(Data("err/\(producer)/\(index)".utf8))
                        guardChild.noteError(code: "\(producer)/\(index)")
                        guardChild.noteStdinError("stdin/\(producer)/\(index)")
                    }
                }
            }
        }
        guardChild.noteExit(code: 0, signal: nil)
        guardChild.noteClose(code: 0, signal: nil)
        let replays = await withTaskGroup(of: RuntimeChildHandover?.self, returning: [RuntimeChildHandover].self) { group in
            for _ in 0..<16 { group.addTask { guardChild.takeEarlyEvents() } }
            var results: [RuntimeChildHandover] = []
            for await replay in group { if let replay { results.append(replay) } }
            return results
        }
        #expect(replays.count == 1)
        let early = try #require(replays.first)
        #expect(early.abandoned == nil)
        #expect(early.events.count == 8 * 64 * 3 + 2)
        #expect(early.stdinErrors.count == 8 * 64)
        #expect(Array(early.events.suffix(2)) == [.exit(code: 0, signal: nil), .close(code: 0, signal: nil)])
        for producer in 0..<8 {
            let codes = early.events.compactMap { event -> String? in
                if case .error(let code) = event, code.hasPrefix("\(producer)/") { return code }
                return nil
            }
            #expect(codes == (0..<64).map { "\(producer)/\($0)" })
        }
        #expect(recorder.logs.isEmpty)
        #expect(recorder.kills.isEmpty)
    }

    @Test func anExitedChildKeepsErrorAndCloseOrderWithoutSignals() throws {
        let clock = FakeClock()
        let recorder = Recorder()
        let guardChild = makeGuard(clock, recorder)
        guardChild.feedStdout(Data("discarded stdout".utf8))
        guardChild.noteError(code: "EACCES")
        guardChild.feedStderr(Data("discarded stderr".utf8))
        guardChild.noteStdinError("before abandonment")
        guardChild.noteExit(code: 0, signal: nil)
        guardChild.noteClose(code: 0, signal: nil)
        clock.advance(10_000)
        guardChild.noteError(code: nil)
        guardChild.noteStdinError("after abandonment")
        let early = try #require(guardChild.takeEarlyEvents())
        #expect(early.events == [.error(code: "EACCES"), .exit(code: 0, signal: nil), .close(code: 0, signal: nil), .error(code: "Error")])
        #expect(early.stdinErrors == ["before abandonment"])
        #expect(recorder.kills.isEmpty)
        #expect(recorder.logs == [
            "[RuntimeChild pid=4242] abandoning a runtime child no session took over: not taken over within 10000ms (errors=EACCES, exited=true)",
            "[RuntimeChild pid=4242] error on an abandoned runtime child: Error",
        ])
    }

    @Test func concurrentFeedAndHandoverReplayAConsistentPrefix() async throws {
        for _ in 0..<16 {
            let guardChild = RuntimeChildGuard(pid: 4242)
            guardChild.noteError(code: "seed")
            let replays = Mutex<[RuntimeChildHandover]>([])
            await withTaskGroup(of: Void.self) { group in
                for producer in 0..<8 {
                    group.addTask {
                        for index in 0..<128 {
                            guardChild.feedStdout(Data("\(producer)/\(index)".utf8))
                            guardChild.noteError(code: "\(producer)/\(index)")
                        }
                    }
                }
                for _ in 0..<8 {
                    group.addTask {
                        if let replay = guardChild.takeEarlyEvents() {
                            replays.withLock { $0.append(replay) }
                        }
                    }
                }
            }
            let results = replays.withLock { $0 }
            #expect(results.count == 1)
            let early = try #require(results.first)
            #expect(early.events.first == .error(code: "seed"))
            #expect(early.abandoned == nil)
            for producer in 0..<8 {
                let prefix = "\(producer)/"
                let outputs = early.events.compactMap { event -> String? in
                    if case .stdout(let data) = event {
                        let text = String(decoding: data, as: UTF8.self)
                        if text.hasPrefix(prefix) { return text }
                    }
                    return nil
                }
                let errors = early.events.compactMap { event -> String? in
                    if case .error(let code) = event, code.hasPrefix(prefix) { return code }
                    return nil
                }
                #expect(outputs == (0..<outputs.count).map { "\(prefix)\($0)" })
                #expect(errors == (0..<errors.count).map { "\(prefix)\($0)" })
                #expect(outputs.count == errors.count || outputs.count == errors.count + 1)
            }
            #expect(guardChild.takeEarlyEvents() == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func outputCapEscalatesForARealChildIgnoringTermination() throws {
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 30"]
        child.standardOutput = output
        try child.run()
        let childPID = child.processIdentifier
        defer {
            if child.isRunning { _ = kill(childPID, SIGKILL) }
            child.waitUntilExit()
        }
        #expect(output.fileHandleForReading.readData(ofLength: 5) == Data("ready".utf8))
        let recorder = Recorder()
        let guardChild = RuntimeChildGuard(
            pid: Int(childPID), log: { recorder.log($0) },
            kill: { signal in
                _ = recorder.kill(signal)
                return kill(childPID, signal == "SIGKILL" ? SIGKILL : SIGTERM) == 0
            }
        )
        guardChild.noteError(code: nil)
        guardChild.feedStdout(Data("discarded".utf8))
        guardChild.feedStderr(Data(repeating: 120, count: RuntimeChildGuard.maxEarlyOutputBytes + 1))
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGKILL)
        guardChild.noteExit(code: nil, signal: "SIGKILL")
        guardChild.noteClose(code: nil, signal: "SIGKILL")
        let early = try #require(guardChild.takeEarlyEvents())
        #expect(early.events == [.error(code: "Error"), .exit(code: nil, signal: "SIGKILL"), .close(code: nil, signal: "SIGKILL")])
        #expect(early.abandoned == "held output exceeded 4194304 bytes")
        #expect(recorder.kills == ["SIGTERM", "SIGKILL"])
        #expect(recorder.logs == ["[RuntimeChild pid=\(childPID)] abandoning a runtime child no session took over: held output exceeded 4194304 bytes (errors=Error, exited=false)"])
    }

    @Test(.timeLimit(.minutes(1))) func defaultTimerDoesNotTerminateAHandedOverRealChild() async throws {
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 11; printf 'child survived handover\\n'"]
        child.standardOutput = output
        try child.run()
        let childPID = child.processIdentifier
        defer {
            if child.isRunning { _ = kill(childPID, SIGKILL) }
            child.waitUntilExit()
        }
        let recorder = Recorder()
        let guardChild = RuntimeChildGuard(
            pid: Int(childPID),
            log: { recorder.log($0) },
            kill: { signal in
                _ = recorder.kill(signal)
                return kill(childPID, signal == "SIGKILL" ? SIGKILL : SIGTERM) == 0
            }
        )
        guardChild.feedStdout(Data("before handover".utf8))
        let early = try #require(guardChild.takeEarlyEvents())
        #expect(early.events == [.stdout(Data("before handover".utf8))])
        #expect(early.abandoned == nil)
        // Use the real default 10-second global timer and observe the child past it.
        try await Task.sleep(for: .seconds(12))
        child.waitUntilExit()
        #expect(child.terminationReason == .exit)
        #expect(child.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "child survived handover\n")
        #expect(recorder.kills.isEmpty)
        #expect(recorder.logs.isEmpty)
        withExtendedLifetime(guardChild) {}
    }
}
