import Foundation
import Testing
import RaftDaemonClient

private func tempRoot() -> String {
    let root = NSTemporaryDirectory() + "agent-migration-export-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private func write(_ path: String, _ contents: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? contents.write(toFile: path, atomically: false, encoding: .utf8)
}

private final class Listed: @unchecked Sendable { var paths: [String] = [] }

private func listWorkspace(_ workspace: String) -> (listed: [String], listing: AgentMigrationExport.WorkspaceListing) {
    let listed = Listed()
    let listing = AgentMigrationExport.listWorkspace(workspacePath: workspace) { listed.paths.append($0) }
    return (listed.paths, listing)
}

private func summarize(_ listing: AgentMigrationExport.WorkspaceListing, includedFiles: Int? = nil) -> AgentMigrationExport.TransferSummary {
    AgentMigrationExport.summarize(
        includedFileCount: includedFiles ?? listing.excludedRegenerable.count + 4,
        includedBytes: 0, memoryMdPresent: false, notesPresent: false,
        excludedRegenerable: listing.excludedRegenerable, excludedIgnored: listing.excludedIgnored
    )
}

@Test func exportIncludesUnknownFilesByDefaultAndOnlyRegenerableDirsAreExcluded() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let workspace = root + "/.slock/agents/agent-1"
    for dir in ["node_modules/leftpad", "target", ".venv", "dist", "__pycache__", "build"] {
        try? FileManager.default.createDirectory(atPath: workspace + "/" + dir, withIntermediateDirectories: true)
    }
    write(workspace + "/README.md", "important notes\n")
    write(workspace + "/.gitignore", ".env\nbuild\n")
    write(workspace + "/.env", "OPENAI_API_KEY=sk-test-secret\nNORMAL=value\n")
    write(workspace + "/node_modules/leftpad/index.js", "regenerated\n")
    write(workspace + "/target/artifact", "regenerated\n")
    write(workspace + "/.venv/pyvenv.cfg", "regenerated\n")
    write(workspace + "/dist/bundle.js", "regenerated\n")
    write(workspace + "/__pycache__/module.pyc", "regenerated\n")
    write(workspace + "/build/artifact.txt", "not on daemon whitelist\n")

    let (listed, listing) = listWorkspace(workspace)
    let actualListed = listed.sorted(by: AgentMigrationExport.localeLess)
    let actualExcluded = listing.excludedRegenerable.map(\.path)
    #expect(actualListed == [".env", ".gitignore", "build/artifact.txt", "README.md"])
    #expect(actualExcluded == ["__pycache__", ".venv", "dist", "node_modules", "target"])
    let summary = summarize(listing)
    #expect(summary.excludedRegenerableByCategory.thirdPartyDependencies == 2)
    #expect(summary.excludedRegenerableByCategory.caches == 1)
    #expect(summary.excludedRegenerableByCategory.buildArtifacts == 2)
    #expect(summary.excludedRegenerableByCategory.otherRegenerable == 0)
}

@Test func unreadableDirectoriesAreRecordedAsUnreachable() throws {
    let root = tempRoot()
    let workspace = root + "/.slock/agents/agent-unreachable"
    let unreadable = workspace + "/private-dir"
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable)
        try? FileManager.default.removeItem(atPath: root)
    }
    try FileManager.default.createDirectory(atPath: unreadable, withIntermediateDirectories: true)
    write(workspace + "/notes.md", "ok\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable)

    let (listed, listing) = listWorkspace(workspace)
    #expect(listed == ["notes.md"])
    #expect(listing.unreachable.map(\.path) == ["private-dir"])
    #expect(listing.unreachable.first?.reason == "read_error")
}

@Test func symlinkTargetNormalizationRejectsForeignRootsNulAndWorkspaceEscape() {
    for target in [
        "/Users/alice/source-local-secret",
        "C:\\Users\\alice\\source-local-secret",
        "C:source-local-secret",
        "\\\\server\\share\\source-local-secret",
        "target\0secret",
        "../../source-local-secret",
    ] {
        #expect(throws: AgentMigrationExport.UnsafeLinkError.self) {
            try AgentMigrationExport.normalizeSymlinkTarget("nested/link", target)
        }
    }
    #expect(try! AgentMigrationExport.normalizeSymlinkTarget("nested/link", "peer\\target-file") == "peer/target-file")
    #expect(try! AgentMigrationExport.normalizeSymlinkTarget("nested/link", "../target-file") == "../target-file")
}

@Test func commonFrameworkOutputsAndCachesSummarizeByCategory() {
    let summary = AgentMigrationExport.summarize(
        includedFileCount: 0, includedBytes: 0, memoryMdPresent: false, notesPresent: false,
        excludedRegenerable: [
            .init(path: "web/.next"), .init(path: "py/.mypy_cache"), .init(path: "py/.pytest_cache"),
            .init(path: "infra/.terraform"), .init(path: "app/.turbo"),
        ]
    )
    #expect(summary.excludedRegenerableByCategory.thirdPartyDependencies == 1)
    #expect(summary.excludedRegenerableByCategory.caches == 3)
    #expect(summary.excludedRegenerableByCategory.buildArtifacts == 1)
    #expect(summary.excludedRegenerableByCategory.otherRegenerable == 0)
}

@Test func raftMigrateIgnoreExcludesListedPathsButNeverMemoryOrTheIgnoreFile() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let workspace = root + "/.slock/agents/agent-ignore"
    try? FileManager.default.createDirectory(atPath: workspace + "/datasets/raw", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: workspace + "/notes", withIntermediateDirectories: true)
    write(workspace + "/MEMORY.md", "memory\n")
    write(workspace + "/notes/domain.md", "domain\n")
    write(workspace + "/datasets/a.csv", String(repeating: "x", count: 300))
    write(workspace + "/datasets/raw/b.csv", String(repeating: "y", count: 700))
    write(workspace + "/cache.sqlite", String(repeating: "z", count: 50))
    write(workspace + "/keep.txt", "keep\n")
    write(workspace + "/.raftmigrateignore", [
        "# re-downloadable", "./datasets/", "cache.sqlite", "MEMORY.md", ".raftmigrateignore", "*.log", "../outside", "",
    ].joined(separator: "\n"))

    let (listed, listing) = listWorkspace(workspace)
    #expect(listed.sorted() == [".raftmigrateignore", "MEMORY.md", "keep.txt", "notes/domain.md"])
    #expect(listing.excludedIgnored == [
        .init(path: "cache.sqlite", fileCount: 1, sizeBytes: 50),
        .init(path: "datasets", fileCount: 2, sizeBytes: 1000),
    ])
    let summary = summarize(listing)
    #expect(summary.excludedIgnored == .init(
        count: 2, fileCount: 3, bytes: 1050,
        largest: [(path: "datasets", bytes: 1000), (path: "cache.sqlite", bytes: 50)]
    ))
}

@Test func raftMigrateIgnoreNeverExcludesActivityItsParentsOrContents() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let workspace = root + "/.slock/agents/agent-ignore-activity"
    try? FileManager.default.createDirectory(atPath: workspace + "/.raft/activity", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: workspace + "/.raft/scratch", withIntermediateDirectories: true)
    write(workspace + "/.raft/activity/1-1-s.jsonl", "{}\n")
    write(workspace + "/.raft/scratch/tmp.bin", String(repeating: "x", count: 10))
    write(workspace + "/.raftmigrateignore", [
        ".raft", "./.raft/activity/", ".raft/activity/1-1-s.jsonl", ".raft/scratch", ".raft/activity-old", "",
    ].joined(separator: "\n"))

    let (listed, listing) = listWorkspace(workspace)
    #expect(listed.sorted() == [".raft/activity/1-1-s.jsonl", ".raftmigrateignore"])
    #expect(listing.excludedIgnored == [.init(path: ".raft/scratch", fileCount: 1, sizeBytes: 10)])
}

@Test func aSummaryWithoutIgnoredPathsOmitsExcludedIgnored() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let workspace = root + "/.slock/agents/agent-no-ignore"
    try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    write(workspace + "/MEMORY.md", "memory\n")
    let (_, listing) = listWorkspace(workspace)
    #expect(listing.excludedIgnored == [])
    #expect(summarize(listing).excludedIgnored == nil)
}
