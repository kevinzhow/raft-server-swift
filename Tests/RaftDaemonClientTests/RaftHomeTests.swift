import Foundation
import Testing
import RaftDaemonClient

private func withTempHome(_ run: (String) throws -> Void) throws {
    let home = NSTemporaryDirectory() + "raft-home-default-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    try run(home)
}

private func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

@Test func defaultsToRaftOnAMachineWithoutSlock() throws {
    try withTempHome { home in
        #expect(RaftHome.resolveRoot(env: [:], homeDir: home) == home + "/.raft")
    }
}

@Test func keepsAnExistingSlockThatHoldsRaftStateEvenWhenRaftExists() throws {
    try withTempHome { home in
        try mkdir(home + "/.slock/agents")
        #expect(RaftHome.resolveRoot(env: [:], homeDir: home) == home + "/.slock")
        try mkdir(home + "/.raft/agents")
        #expect(RaftHome.resolveRoot(env: [:], homeDir: home) == home + "/.slock")
    }
}

@Test func notPulledToASlockThatOnlyHoldsANoticeFile() throws {
    try withTempHome { home in
        try mkdir(home + "/.raft/agents")
        try mkdir(home + "/.slock")
        try "".write(toFile: home + "/.slock/.cli-rename-notice", atomically: true, encoding: .utf8)
        #expect(RaftHome.resolveRoot(env: [:], homeDir: home) == home + "/.raft")
    }
}

@Test func defaultRootIsResolvedIndependentlyOfSlockHome() throws {
    try withTempHome { home in
        #expect(RaftHome.resolveDefaultRoot(homeDir: home) == home + "/.raft")
    }
}

@Test func normalizesSlockHomeToAnAbsolutePath() {
    #expect(RaftHome.resolveRoot(env: ["SLOCK_HOME": "relative-slock-root"], homeDir: "/Users/alice") == URL(fileURLWithPath: "relative-slock-root").standardizedFileURL.path)
}

@Test func acceptsRaftHomeAsAFallback() {
    #expect(RaftHome.resolveRoot(env: ["RAFT_HOME": "relative-raft-root"], homeDir: "/Users/alice") == URL(fileURLWithPath: "relative-raft-root").standardizedFileURL.path)
}

@Test func prefersRaftHomeOverSlockHome() {
    #expect(RaftHome.resolveRoot(env: ["SLOCK_HOME": "/tmp/slock-loses", "RAFT_HOME": "/tmp/raft-wins"], homeDir: "/Users/alice") == "/tmp/raft-wins")
}

@Test func derivesChildPathsFromTheResolvedRoot() {
    #expect(RaftHome.resolvePath("agents", raftHome: "/tmp/slock-a") == "/tmp/slock-a/agents")
}

@Test func reportsExistingDefaultRootStateWhenSlockHomeIsCustom() throws {
    let home = NSTemporaryDirectory() + "slock-home-test-\(UUID().uuidString)"
    let customRoot = home + "/custom"
    defer { try? FileManager.default.removeItem(atPath: home) }
    try mkdir(home + "/.slock/agents")
    try mkdir(home + "/.slock/machines")
    let paths = RaftHome.listLegacyStatePaths(raftHome: customRoot, homeDir: home)
    #expect(paths.map(\.path).sorted() == [home + "/.slock/agents", home + "/.slock/machines"].sorted())
    #expect(paths.map(\.destination).sorted() == [customRoot + "/agents", customRoot + "/machines"].sorted())
}

@Test func isEmptyForTheDefaultSlockHome() throws {
    let home = NSTemporaryDirectory() + "slock-home-default-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: home) }
    try mkdir(home + "/.slock/agents")
    #expect(RaftHome.listLegacyStatePaths(raftHome: home + "/.slock", homeDir: home).isEmpty)
}
