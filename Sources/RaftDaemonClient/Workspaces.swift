import Foundation

/// Agent workspace directory operations: containment-checked resolution,
/// recursive summaries for the workspace list, deletion that can never remove
/// the root, and display paths that are `~/`-relative under the user's home.
/// Ported from the upstream daemon workspaces helper.
public struct WorkspaceDirectoryInfo: Sendable, Equatable {
    public var directoryName: String
    public var totalSizeBytes: Int
    public var lastModified: String
    public var fileCount: Int
    public var displayPath: String
    public init(directoryName: String, totalSizeBytes: Int, lastModified: String, fileCount: Int, displayPath: String) {
        self.directoryName = directoryName
        self.totalSizeBytes = totalSizeBytes
        self.lastModified = lastModified
        self.fileCount = fileCount
        self.displayPath = displayPath
    }
}

public struct AgentWorkspaceSeedFile: Sendable {
    public var relativePath: String
    public var content: String
    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

public enum Workspaces {
    public static let runtimeOutcomeOutboxDirName = ".runtime-outcome-outbox"

    /// Containment, not a blocklist: the resolved target must be exactly one
    /// level below `dataDir`. Rejects the root itself (`.`, ``, `./`, `x/..`),
    /// anything above it and nested paths.
    public static func resolveDirectoryPath(dataDir: String, directoryName: String) -> String? {
        let root = URL(fileURLWithPath: dataDir).standardizedFileURL.path
        let target = URL(fileURLWithPath: root).appendingPathComponent(directoryName).standardizedFileURL.path
        guard (target as NSString).deletingLastPathComponent == root else { return nil }
        return target
    }

    public static func initializeWorkspace(
        workspacePath: String, initialMemoryMarkdown: String, seedFiles: [AgentWorkspaceSeedFile]
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)
        let memoryPath = workspacePath + "/MEMORY.md"
        if !manager.fileExists(atPath: memoryPath) {
            try initialMemoryMarkdown.write(toFile: memoryPath, atomically: true, encoding: .utf8)
        }
        try manager.createDirectory(atPath: workspacePath + "/notes", withIntermediateDirectories: true)
        for seed in seedFiles {
            let fullPath = workspacePath + "/" + seed.relativePath
            if manager.fileExists(atPath: fullPath) { continue }
            try manager.createDirectory(
                atPath: (fullPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try seed.content.write(toFile: fullPath, atomically: true, encoding: .utf8)
        }
    }

    struct Summary {
        var totalSizeBytes = 0
        var fileCount = 0
        var latestMtime = Date(timeIntervalSince1970: 0)
    }

    static func merge(_ base: Summary, _ next: Summary) -> Summary {
        Summary(
            totalSizeBytes: base.totalSizeBytes + next.totalSizeBytes,
            fileCount: base.fileCount + next.fileCount,
            latestMtime: next.latestMtime > base.latestMtime ? next.latestMtime : base.latestMtime
        )
    }

    static func summarizeDirectory(_ dirPath: String) -> Summary {
        let manager = FileManager.default
        var summary = Summary()
        if let attributes = try? manager.attributesOfItem(atPath: dirPath),
           let modified = attributes[.modificationDate] as? Date {
            summary.latestMtime = modified
        }
        guard let names = try? manager.contentsOfDirectory(atPath: dirPath) else { return summary }
        for name in names {
            let entryPath = dirPath + "/" + name
            guard let attributes = try? manager.attributesOfItem(atPath: entryPath) else { continue }
            let kind = attributes[.type] as? FileAttributeType
            if kind == .typeDirectory {
                summary = merge(summary, summarizeDirectory(entryPath))
            } else if kind == .typeRegular {
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                summary = merge(summary, Summary(totalSizeBytes: size, fileCount: 1, latestMtime: modified))
            } else {
                let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                summary = merge(summary, Summary(totalSizeBytes: 0, fileCount: 0, latestMtime: modified))
            }
        }
        return summary
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `~/…` for a path under the user's home, else the absolute path; the
    /// trailing separator marks a directory.
    public static func displayPath(_ dirPath: String, homeDir: String = NSHomeDirectory()) -> String {
        let resolved = URL(fileURLWithPath: dirPath).standardizedFileURL.path
        let home = URL(fileURLWithPath: homeDir).standardizedFileURL.path
        let prefix = home + "/"
        if resolved.hasPrefix(prefix) {
            let relative = String(resolved.dropFirst(prefix.count)).replacingOccurrences(of: "/", with: "/")
            return "~/" + relative + "/"
        }
        return resolved + "/"
    }

    public static func scanDirectories(dataDir: String) -> [WorkspaceDirectoryInfo] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: dataDir) else { return [] }
        var results: [WorkspaceDirectoryInfo] = []
        for name in names.sorted() {
            if name == runtimeOutcomeOutboxDirName { continue }
            let path = dataDir + "/" + name
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let summary = summarizeDirectory(path)
            results.append(.init(
                directoryName: name,
                totalSizeBytes: summary.totalSizeBytes,
                lastModified: isoString(summary.latestMtime),
                fileCount: summary.fileCount,
                displayPath: displayPath(path)
            ))
        }
        return results
    }

    public static func deleteDirectory(dataDir: String, directoryName: String) -> Bool {
        guard let target = resolveDirectoryPath(dataDir: dataDir, directoryName: directoryName) else { return false }
        do {
            try FileManager.default.removeItem(atPath: target)
            return true
        } catch {
            return false
        }
    }
}
