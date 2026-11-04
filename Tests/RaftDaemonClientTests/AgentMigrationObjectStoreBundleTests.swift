import Foundation
import Testing
import RaftDaemonClient

private func entry(_ path: String) -> AgentMigrationBundleFileEntry {
    .init(source: "workspace", workspaceRelativePath: path)
}

@Test func entryCountUsesAStrict250kBoundaryWithBoundedRecoveryWire() throws {
    let sample = entry("src/index.ts")
    try AgentMigrationObjectStoreBundle.assertEntryLimit(entries: Array(repeating: sample, count: 249_999))
    try AgentMigrationObjectStoreBundle.assertEntryLimit(entries: Array(repeating: sample, count: 250_000))
    do {
        try AgentMigrationObjectStoreBundle.assertEntryLimit(entries: Array(repeating: sample, count: 250_001))
        Issue.record("expected limit error")
    } catch let error as AgentMigrationObjectStoreEntryCountLimitError {
        #expect(error.entryCount == 250_001)
        #expect(error.maxEntries == 250_000)
        #expect(error.message == "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED:entryCount=250001:maxEntries=250000:topPathCounts=src%2F,250001")
        #expect(error.message.count < 500)
    }
}

@Test func entryCountAddsEntriesTheExportWalkOnlyCounted() throws {
    let sample = entry("src/index.ts")
    try AgentMigrationObjectStoreBundle.assertEntryLimit(
        entries: Array(repeating: sample, count: 3), maxEntries: 6,
        overflowEntryCount: 3, overflowCountByTopLevelPath: ["repos/": 2, ".env": 1]
    )
    do {
        try AgentMigrationObjectStoreBundle.assertEntryLimit(
            entries: Array(repeating: sample, count: 3), maxEntries: 5,
            overflowEntryCount: 3, overflowCountByTopLevelPath: ["repos/": 2, ".env": 1]
        )
        Issue.record("expected limit error")
    } catch let error as AgentMigrationObjectStoreEntryCountLimitError {
        #expect(error.message == "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED:entryCount=6:maxEntries=5:topPathCounts=src%2F,3;repos%2F,2;other%2F,1")
    }
}

@Test func recoveryWireRedactsSecretShapedPathsAndBoundsTheList() {
    var files: [AgentMigrationBundleFileEntry] = []
    files += Array(repeating: entry(".env.production"), count: 7)
    files += Array(repeating: entry("api-key-cache/value"), count: 6)
    files += Array(repeating: entry("src/index.ts"), count: 5)
    files += Array(repeating: entry(".git/config"), count: 4)
    files += Array(repeating: entry("docs/readme.md"), count: 3)
    let counts = AgentMigrationObjectStoreBundle.largestWorkspaceEntryCounts(files: files)
    let error = AgentMigrationObjectStoreEntryCountLimitError(
        entryCount: 250_001, maxEntries: 250_000, topPathCounts: counts
    )
    #expect(error.message.range(of: #":topPathCounts=other%2F,13;src%2F,5;.git%2F,4$"#, options: .regularExpression) != nil)
    #expect(error.message.range(of: #"\.env|api-key|secret|token|credential"#, options: [.regularExpression, .caseInsensitive]) == nil)
    #expect(error.message.range(of: #"/Users/|\\Users\\|agents/agent-"#, options: .regularExpression) == nil)
    #expect(error.message.split(separator: ";").count == 3)
    #expect(error.message.count < 500)
}

@Test func workspaceRelativePathNormalizationRejectsUnsafePaths() throws {
    let unsafePaths = [
        "", ".", "./", "/posix-absolute.txt", "C:\\windows-absolute.txt",
        "C:/windows-absolute.txt", "C:drive-relative.txt", "\\\\server\\share\\unc.txt",
        "../escape.txt", "nested/../escape.txt", "nested\\..\\escape.txt", "nul\0byte.txt",
    ]
    for path in unsafePaths {
        #expect(throws: (any Error).self, Comment(rawValue: path)) {
            try AgentMigrationObjectStoreBundle.normalizeWorkspaceRelativePath(path)
        }
    }
    let normalized = try AgentMigrationObjectStoreBundle.normalizeWorkspaceRelativePath("./nested\\safe//file.txt")
    #expect(normalized == "nested/safe/file.txt")
}
