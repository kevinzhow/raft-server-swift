import Foundation
import RaftDaemonClient
import Testing

@Test func processEnvPatchUndoesReplacedAndAddedKeys() async throws {
    setenv("TASK28_REPLACED", "daemon", 1)
    unsetenv("TASK28_ADDED")
    defer {
        unsetenv("TASK28_REPLACED")
        unsetenv("TASK28_ADDED")
    }
    let inside = try await DaemonProcessEnv.withProcessEnvPatch(["TASK28_REPLACED": "agent", "TASK28_ADDED": "agent"]) {
        try await Task.sleep(nanoseconds: 1_000_000)
        #expect(ProcessInfo.processInfo.environment["TASK28_REPLACED"] == "agent")
        let ambient = DaemonProcessEnv.ambient()
        #expect(ambient["TASK28_REPLACED"] == "daemon")
        #expect(ambient["TASK28_ADDED"] == nil)
        return ambient["TASK28_REPLACED"]
    }
    #expect(inside == "daemon")
    #expect(ProcessInfo.processInfo.environment["TASK28_REPLACED"] == "daemon")
    #expect(DaemonProcessEnv.ambient()["TASK28_REPLACED"] == "daemon")
}

@Test func processEnvPatchRemoveFirstHidesKeysButKeepsThemAmbient() async throws {
    setenv("TASK28_REMOVED", "daemon", 1)
    defer { unsetenv("TASK28_REMOVED") }
    try await DaemonProcessEnv.withProcessEnvPatch(nil, removeFirst: ["TASK28_REMOVED"]) {
        #expect(ProcessInfo.processInfo.environment["TASK28_REMOVED"] == nil)
        #expect(DaemonProcessEnv.ambient()["TASK28_REMOVED"] == "daemon")
    }
    #expect(ProcessInfo.processInfo.environment["TASK28_REMOVED"] == "daemon")
}

@Test func osVariantClassifiesWslKernelsOnly() {
    #expect(DaemonOsVariant.classify(kernelRelease: "5.15.153.1-microsoft-standard-WSL2") == "wsl2")
    #expect(DaemonOsVariant.classify(kernelRelease: "4.4.0-19041-Microsoft") == "wsl1")
    #expect(DaemonOsVariant.classify(kernelRelease: "6.8.0-45-generic") == nil)
    #expect(DaemonOsVariant.detect(platform: "darwin", kernelRelease: { "5.15.0-microsoft-standard-WSL2" }) == nil)
    #expect(DaemonOsVariant.detect(platform: "linux", kernelRelease: { nil }) == nil)
    #expect(DaemonOsVariant.detect(platform: "linux", kernelRelease: { "5.15.0-microsoft-standard-WSL2" }) == "wsl2")
}
