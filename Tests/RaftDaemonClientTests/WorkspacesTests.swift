import Foundation
import Testing
import RaftDaemonClient

private func tempRoot() throws -> String {
    let root = NSTemporaryDirectory() + "daemon-workspaces-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

@Test func scanSummarizesWorkspaceDirectoriesRecursively() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = root + "/agent-one"
    let second = root + "/agent-two"
    try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
    try "hello".write(toFile: first + "/notes.md", atomically: true, encoding: .utf8)
    try #"{"ok":true}"#.write(toFile: first + "/config.json", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: first + "/nested", withIntermediateDirectories: true)
    try "nested".write(toFile: first + "/nested/child.txt", atomically: true, encoding: .utf8)
    try "x".write(toFile: second + "/README.txt", atomically: true, encoding: .utf8)

    let directories = Workspaces.scanDirectories(dataDir: root)
    let firstInfo = try #require(directories.first { $0.directoryName == "agent-one" })
    let secondInfo = try #require(directories.first { $0.directoryName == "agent-two" })
    #expect(firstInfo.fileCount == 3)
    #expect(firstInfo.totalSizeBytes == "hello".utf8.count + #"{"ok":true}"#.utf8.count + "nested".utf8.count)
    #expect(firstInfo.lastModified != "1970-01-01T00:00:00.000Z")
    #expect(secondInfo.fileCount == 1)
    #expect(secondInfo.totalSizeBytes == 1)
    #expect(secondInfo.displayPath == Workspaces.displayPath(second))
}

@Test func resolveRejectsTraversal() {
    #expect(Workspaces.resolveDirectoryPath(dataDir: "/tmp/daemon", directoryName: "agent-1") == "/tmp/daemon/agent-1")
    #expect(Workspaces.resolveDirectoryPath(dataDir: "/tmp/daemon", directoryName: "../agent-1") == nil)
    #expect(Workspaces.resolveDirectoryPath(dataDir: "/tmp/daemon", directoryName: "nested/agent-1") == nil)
}

@Test func deleteRemovesOnlyValidWorkspaceDirectories() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let target = root + "/agent-delete"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    try "delete-me".write(toFile: target + "/notes.md", atomically: true, encoding: .utf8)

    #expect(Workspaces.deleteDirectory(dataDir: root, directoryName: "agent-delete"))
    #expect(Workspaces.scanDirectories(dataDir: root).isEmpty)
    #expect(!Workspaces.deleteDirectory(dataDir: root, directoryName: "../outside"))
}

@Test func resolveRejectsNamesThatResolveToTheRootItself() {
    for name in [".", "", "./", "agent-1/.."] {
        #expect(Workspaces.resolveDirectoryPath(dataDir: "/tmp/daemon", directoryName: name) == nil, Comment(rawValue: name))
    }
    #expect(Workspaces.resolveDirectoryPath(dataDir: "/tmp/daemon", directoryName: "agent-1") == "/tmp/daemon/agent-1")
    #expect(Workspaces.resolveDirectoryPath(dataDir: "/tmp/daemon", directoryName: ".hidden-agent") == "/tmp/daemon/.hidden-agent")
    #expect(Workspaces.resolveDirectoryPath(dataDir: "/tmp/daemon", directoryName: "agent-1/") == "/tmp/daemon/agent-1")
}

@Test func deletingTheRootLeavesItIntact() throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let target = root + "/agent-keep"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    try "must survive".write(toFile: target + "/notes.md", atomically: true, encoding: .utf8)

    #expect(!Workspaces.deleteDirectory(dataDir: root, directoryName: "."))
    #expect(!Workspaces.deleteDirectory(dataDir: root, directoryName: ""))
    #expect(Workspaces.scanDirectories(dataDir: root).map(\.directoryName) == ["agent-keep"],
            "deleting '.' must not remove every workspace on the machine")
}

@Test func displayPathsAreHomeRelativeUnderTheHomeAndAbsoluteElsewhere() {
    #expect(Workspaces.displayPath("/home/alice/.raft/agents/a1", homeDir: "/home/alice") == "~/.raft/agents/a1/")
    #expect(Workspaces.displayPath("/home/alice/.slock/agents/a1", homeDir: "/home/alice") == "~/.slock/agents/a1/")
    #expect(Workspaces.displayPath("/srv/raft/agents/a1", homeDir: "/home/alice") == "/srv/raft/agents/a1/")
    #expect(Workspaces.displayPath("/home/alice2/agents/a1", homeDir: "/home/alice") == "/home/alice2/agents/a1/")
}
