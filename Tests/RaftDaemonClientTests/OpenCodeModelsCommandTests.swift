import Foundation
import Synchronization
import Testing
import RaftDaemonClient

private let resolvedExe = #"C:\Users\tester\AppData\Local\opencode\bin\opencode.exe"#

private final class Calls: @unchecked Sendable {
    var items: [(command: String, args: [String], shell: Bool)] = []
}

private enum ScriptOutcome: Sendable {
    case stdout(String)
    case status(Int)
    case code(String)
}

private func syncDeps(
    _ script: @escaping @Sendable (String, [String]) -> ScriptOutcome,
    calls: Calls? = nil
) -> OpenCodeModelsDeps {
    OpenCodeModelsDeps(platform: "win32", existsSyncFn: { _ in false }, execFileSyncFn: { command, args in
        switch script(command, args) {
        case .stdout(let value): return value
        case .status(let status): throw ProbeChildError("\(command) exited", status: status)
        case .code(let code): throw ProbeChildError("\(command) failed", code: code)
        }
    })
}

private func asyncRunner(
    _ script: @escaping @Sendable (String, [String]) -> ScriptOutcome,
    calls: Calls? = nil,
    beforeListing: (@Sendable () throws -> Void)? = nil
) -> RunProbeChild {
    { command, args, options in
        if args.first == "models" {
            calls?.items.append((command, args, options.shell))
            try beforeListing?()
        }
        switch script(command, args) {
        case .stdout(let value): return ProbeChildOutput(stdout: value, stderr: "")
        case .status(let status): throw ProbeChildError("\(command) exited", status: status)
        case .code(let code): throw ProbeChildError("\(command) failed", code: code)
        }
    }
}

private func windowsScript(version: String, listing: @escaping @Sendable (String, [String]) -> ScriptOutcome = { _, _ in .stdout("opencode/gpt-5-nano\n") })
    -> @Sendable (String, [String]) -> ScriptOutcome
{
    { command, args in
        if command == "powershell.exe" { return .stdout(resolvedExe + "\r\n") }
        if args.contains("--version") { return .stdout(version + "\n") }
        if args.first == "models" { return listing(command, args) }
        return .code("UNEXPECTED")
    }
}

@Test func asyncWindowsListingMatchesTheSyncTwin() async throws {
    for (version, expectedArgs) in [("1.18.35", ["models"]), ("2.0.27", ["models", "--standalone"]), ("2.0.26", ["models"])] {
        let syncCalls = Calls()
        let asyncCalls = Calls()
        let script = windowsScript(version: version)
        let viaSync = OpenCodeModelsCommand.runSync(home: "/tmp/opencode-home", deps: syncDeps(script, calls: syncCalls))
        let viaAsync = try await OpenCodeModelsCommand.runAsync(
            home: "/tmp/opencode-home", deps: syncDeps(script),
            runProbeChild: asyncRunner(script, calls: asyncCalls)
        )
        #expect(viaAsync == viaSync, "\(version)")
        let items = asyncCalls.items
        #expect(items.count == 1, "\(version)")
        #expect(items.first?.command == resolvedExe)
        #expect(items.first?.args == expectedArgs)
        #expect(items.first?.shell == false)
    }
}

@Test func listingFailuresMapAlike() async throws {
    for (label, failure) in [("exit 1", ScriptOutcome.status(1)), ("timeout", .code("ETIMEDOUT")), ("spawn failure", .code("ENOENT"))] {
        let script = windowsScript(version: "1.18.35", listing: { _, _ in failure })
        let viaSync = OpenCodeModelsCommand.runSync(home: "/tmp/h", deps: syncDeps(script))
        let viaAsync = try await OpenCodeModelsCommand.runAsync(
            home: "/tmp/h", deps: syncDeps(script), runProbeChild: asyncRunner(script)
        )
        #expect(viaAsync.status == viaSync.status, "\(label)")
        #expect((viaAsync.errorMessage != nil) == (viaSync.errorMessage != nil), "\(label)")
        let asyncDetect = try await OpenCodeModelsCommand.detectAsync(
            home: "/tmp/h", deps: syncDeps(script), runProbeChild: asyncRunner(script)
        )
        #expect(asyncDetect == OpenCodeModelsCommand.detectSync(home: "/tmp/h", deps: syncDeps(script)), "\(label)")
    }
}

@Test func detectionKeepsFailureEmptyAndLiveDistinct() async throws {
    let failing = try await OpenCodeModelsCommand.detectAsync(home: "/tmp/h", deps: syncDeps { _, _ in .code("X") }) { _, _, _ in
        throw ProbeChildError("failed", status: 1)
    }
    #expect(failing == .error(retryable: true))
    let empty = OpenCodeModelsCommand.detect(source: .init(status: 0, stdout: "", errorMessage: nil))
    #expect(empty == .noModels)
    let live = OpenCodeModelsCommand.detect(source: .init(status: 0, stdout: "opencode/gpt-5-nano\n", errorMessage: nil))
    #expect(live.kind == "live")
    #expect(live == OpenCodeModelsCommand.detectSync(home: "/tmp/h", deps: syncDeps { _, _ in .stdout("opencode/gpt-5-nano\n") }))
}

@Test func windowsResolutionFailureIsAResultNeverThrown() async throws {
    let script: @Sendable (String, [String]) -> ScriptOutcome = { command, _ in
        if command == "powershell.exe" { return .status(3) }
        return .code("UNEXPECTED")
    }
    let deps = OpenCodeModelsDeps(platform: "win32", existsSyncFn: { _ in false }, execFileSyncFn: { command, args in
        switch script(command, args) {
        case .stdout(let value): return value
        case .status(let status): throw ProbeChildError("\(command) exited", status: status)
        case .code(let code): throw ProbeChildError("\(command) failed", code: code)
        }
    })
    let viaSync = OpenCodeModelsCommand.runSync(home: "/tmp/opencode-home", deps: deps)
    let viaAsync = try await OpenCodeModelsCommand.runAsync(home: "/tmp/opencode-home", deps: deps, runProbeChild: asyncRunner(script))
    #expect(viaSync.status == nil)
    #expect(viaAsync.status == nil)
    #expect(viaSync.errorMessage?.contains("Cannot resolve OpenCode CLI entry point on Windows") == true)
    #expect(viaAsync.errorMessage == viaSync.errorMessage)
}

@Test func preAbortedSignalRejects() async {
    do {
        _ = try await OpenCodeModelsCommand.runAsync(
            home: "/tmp/h", deps: syncDeps { _, _ in .stdout("") },
            runProbeChild: { _, _, _ in throw ProbeChildError("aborted", code: "ABORT_ERR") },
            preAborted: true
        )
        Issue.record("expected abort")
    } catch let error as ProbeChildError {
        #expect(error.code == "ABORT_ERR")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func abortDuringTheListingChildPropagatesWithCleanup() async {
    let script = windowsScript(version: "1.18.35")
    let runChild: RunProbeChild = { command, args, options in
        if args.first == "models" {
            throw ProbeChildError("listing aborted", code: "ABORT_ERR", cleanup: ProbeCleanup(childExited: true, waitedMs: 3))
        }
        return try await asyncRunner(script)(command, args, options)
    }
    do {
        _ = try await OpenCodeModelsCommand.runAsync(home: "/tmp/h", deps: syncDeps(script), runProbeChild: runChild)
        Issue.record("expected abort")
    } catch let error as ProbeChildError {
        #expect(error.code == "ABORT_ERR")
        #expect(error.cleanup?.childExited == true)
    } catch {
        Issue.record("unexpected error \(error)")
    }
    do {
        _ = try await OpenCodeModelsCommand.detectAsync(home: "/tmp/h", deps: syncDeps(script), runProbeChild: runChild)
        Issue.record("expected abort")
    } catch let error as ProbeChildError {
        #expect(error.code == "ABORT_ERR")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func listingPassesTheBudgetAndEnvironmentWithoutAShell() async throws {
    final class Observed: @unchecked Sendable {
        var items: [(timeoutMs: Int, shell: Bool, home: String?, noColor: String?)] = []
    }
    let seen = Calls()
    let observed = Observed()
    let script = windowsScript(version: "1.18.35")
    let runChild: RunProbeChild = { command, args, options in
        if args.first == "models" {
            observed.items.append((options.timeoutMs, options.shell, options.env["HOME"], options.env["NO_COLOR"]))
        }
        return try await asyncRunner(script)(command, args, options)
    }
    _ = try await OpenCodeModelsCommand.runAsync(home: "/tmp/opencode-home", deps: syncDeps(script), runProbeChild: runChild)
    #expect(observed.items.count == 1)
    #expect(observed.items.first?.timeoutMs == 5_000)
    #expect(observed.items.first?.shell == false)
    #expect(observed.items.first?.home == "/tmp/opencode-home")
    #expect(observed.items.first?.noColor == "1")
    _ = seen
}

@Test func concurrentProbeStatusUpdatesCannotProduceAnImpossibleSyncResult() {
    let error = ProbeChildError("shared probe failure", status: 9)
    let readers = Mutex(3)
    let impossible = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 4) { worker in
        if worker == 0 {
            while readers.withLock({ $0 > 0 }) {
                error.status = nil
                error.status = 9
            }
        } else {
            defer { readers.withLock { $0 -= 1 } }
            let deps = OpenCodeModelsDeps(platform: "linux", execFileSyncFn: { _, _ in throw error })
            for _ in 0..<3_000 {
                let result = OpenCodeModelsCommand.runSync(home: "/tmp/h", deps: deps)
                let valid = (result.status == 9 && result.errorMessage == nil)
                    || (result.status == nil && result.errorMessage == "shared probe failure")
                if !valid { impossible.withLock { $0 += 1 } }
            }
        }
    }
    #expect(impossible.withLock { $0 } == 0, "status and its error-message decision must use one captured error state")
}

@Test func mutableProbeAbortKeepsTheSameErrorAndUpdatedCleanup() async {
    let shared = ProbeChildError("listing aborted", code: "ENOENT", status: 9)
    let script = windowsScript(version: "1.18.35")
    let run: RunProbeChild = { command, args, options in
        if args.first == "models" {
            shared.code = "ABORT_ERR"
            shared.status = nil
            shared.cleanup = .init(childExited: true, waitedMs: 3)
            throw shared
        }
        return try await asyncRunner(script)(command, args, options)
    }
    do {
        _ = try await OpenCodeModelsCommand.runAsync(home: "/tmp/h", deps: syncDeps(script), runProbeChild: run)
        Issue.record("an abort must propagate rather than becoming a result")
    } catch let error as ProbeChildError {
        #expect(error === shared)
        #expect(error.code == "ABORT_ERR")
        #expect(error.status == nil)
        #expect(error.cleanup == .init(childExited: true, waitedMs: 3))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}
