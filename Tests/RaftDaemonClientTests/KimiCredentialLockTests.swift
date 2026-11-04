import Foundation
import Testing
import RaftDaemonClient

private func temporaryRoot() -> String {
    let root = NSTemporaryDirectory() + "kimi-lock-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private final class ShellOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

@discardableResult
private func runShell(_ script: String) async -> String {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        let output = ShellOutput()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            output.append(chunk)
        }
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            output.append(pipe.fileHandleForReading.availableData)
            continuation.resume(returning: output.text())
        }
        try? process.run()
    }
}

private let fast = KimiRefreshLock.Options(retries: 2, minTimeoutMs: 50, maxTimeoutMs: 100)

@Test func anotherProcessHoldingTheLockKeepsTheDaemonOutUntilReleased() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let target = root + "/oauth/kimi-code"
    let holder = Task {
        await runShell("mkdir -p '\(root)/oauth'; mkdir '\(target).lock'; sleep 0.7; rmdir '\(target).lock'")
    }
    var waited = 0
    while !KimiRefreshLock.isHeld(target: target) && waited < 2_000 {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waited += 20
    }
    #expect(KimiRefreshLock.isHeld(target: target))

    final class Ran: @unchecked Sendable { var count = 0 }
    let ran = Ran()
    let startedAt = Date()
    let blocked = await KimiRefreshLock.withLock(target: target, options: fast) { _ in
        ran.count += 1
        return "x"
    }
    guard case .unavailable = blocked else {
        Issue.record("expected unavailable while another process holds the lock")
        return
    }
    #expect(ran.count == 0, "fn never runs without the lock")
    #expect(Date().timeIntervalSince(startedAt) < 2.0, "the wait is bounded")

    await holder.value
    let held = await KimiRefreshLock.withLock(target: target, options: fast) { handle in
        #expect(!handle.isCompromised)
        return "y"
    }
    guard case .held(let value) = held else {
        Issue.record("expected the lock after release")
        return
    }
    #expect(value == "y")
    #expect(!FileManager.default.fileExists(atPath: target + ".lock"), "released after fn settled")
}

@Test func whileTheDaemonHoldsTheLockTheClientAttemptIsKeptOut() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let target = root + "/oauth/kimi-code"
    let result = await KimiRefreshLock.withLock(target: target, options: fast) { _ in
        let output = await runShell("mkdir '\(target).lock' 2>/dev/null && echo acquired || echo blocked")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard case .held(let value) = result else {
        Issue.record("expected the lock to be held")
        return
    }
    #expect(value == "blocked")
}

@Test func aLockReclaimedUnderTheDaemonIsReportedAsCompromisedNotThrown() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let target = root + "/oauth/kimi-code"
    let options = KimiRefreshLock.Options(retries: 2, minTimeoutMs: 50, maxTimeoutMs: 100, staleMs: 2_000)
    let result = await KimiRefreshLock.withLock(target: target, options: options) { handle in
        #expect(!handle.isCompromised)
        let manager = FileManager.default
        try? manager.removeItem(atPath: target + ".lock")
        try? manager.createDirectory(atPath: target + ".lock", withIntermediateDirectories: false)
        let foreign = Date().addingTimeInterval(-60)
        try? manager.setAttributes([.modificationDate: foreign], ofItemAtPath: target + ".lock")
        let deadline = Date().addingTimeInterval(4)
        while !handle.isCompromised && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return handle.isCompromised
    }
    guard case .held(let compromised) = result else {
        Issue.record("expected held result")
        return
    }
    #expect(compromised, "a reclaimed lock is reported on the handle")
}
