import Foundation

/// Workspace walk + transfer summary for agent migration export: unknown files
/// move by default, only unambiguously tool-generated directories are
/// regenerable, and `.raftmigrateignore` can drop re-downloadable paths while
/// never dropping MEMORY.md, the ignore file, or `.raft/activity`. Ported from
/// the upstream daemon export.
public enum AgentMigrationExport {
    public static let ignoreFileName = ".raftmigrateignore"
    public static let thirdPartyRegenerableNames: Set<String> = [
        ".nox", ".pnpm-store", ".terraform", ".tox", ".venv", "bower_components", "node_modules", "vendor",
    ]
    public static let cacheRegenerableNames: Set<String> = [
        ".cache", ".dart_tool", ".gradle", ".mypy_cache", ".parcel-cache", ".pytest_cache", ".ruff_cache", ".turbo", "__pycache__",
    ]
    public static let buildRegenerableNames: Set<String> = [".next", ".nuxt", ".svelte-kit", "dist", "target"]
    public static let regenerableDirectoryNames: [String] = (
        Array(thirdPartyRegenerableNames) + Array(cacheRegenerableNames) + Array(buildRegenerableNames)
    ).sorted()
    static let alwaysMovedRootPaths: Set<String> = ["MEMORY.md", ignoreFileName]
    static let alwaysMovedDirectories = [".raft/activity"]
    static let patternChars = CharacterSet(charactersIn: "*?[]!")

    public struct ExcludedRegenerable: Sendable, Equatable {
        public var path: String
        public var reason = "regenerable_default"
        public var regenerableHint: String?
        public init(path: String, reason: String = "regenerable_default", regenerableHint: String? = nil) {
            self.path = path
            self.reason = reason
            self.regenerableHint = regenerableHint
        }
    }

    public struct ExcludedIgnored: Sendable, Equatable {
        public var path: String
        public var reason = "raftmigrateignore"
        public var fileCount: Int
        public var sizeBytes: Int
        public init(path: String, reason: String = "raftmigrateignore", fileCount: Int, sizeBytes: Int) {
            self.path = path
            self.reason = reason
            self.fileCount = fileCount
            self.sizeBytes = sizeBytes
        }
    }

    public struct Unreachable: Sendable, Equatable {
        public var path: String
        public var reason = "read_error"
        public init(path: String, reason: String = "read_error") {
            self.path = path
            self.reason = reason
        }
    }

    public struct WorkspaceListing: Sendable, Equatable {
        public var excludedRegenerable: [ExcludedRegenerable] = []
        public var excludedIgnored: [ExcludedIgnored] = []
        public var unreachable: [Unreachable] = []
    }

    public struct RegenerableCategories: Sendable, Equatable {
        public var thirdPartyDependencies = 0
        public var caches = 0
        public var buildArtifacts = 0
        public var otherRegenerable = 0
        public init() {}
    }

    public struct IgnoredSummary: Sendable, Equatable {
        public var count: Int
        public var fileCount: Int
        public var bytes: Int
        public var largest: [(path: String, bytes: Int)]
        public init(count: Int, fileCount: Int, bytes: Int, largest: [(path: String, bytes: Int)]) {
            self.count = count
            self.fileCount = fileCount
            self.bytes = bytes
            self.largest = largest
        }
        public static func == (lhs: IgnoredSummary, rhs: IgnoredSummary) -> Bool {
            lhs.count == rhs.count && lhs.fileCount == rhs.fileCount && lhs.bytes == rhs.bytes
                && lhs.largest.count == rhs.largest.count
                && zip(lhs.largest, rhs.largest).allSatisfy { $0.path == $1.path && $0.bytes == $1.bytes }
        }
    }

    public struct TransferSummary: Sendable, Equatable {
        public var includedFileCount: Int
        public var includedBytes: Int
        public var excludedRegenerableCount: Int
        public var excludedRegenerableByCategory: RegenerableCategories
        public var memoryMdPresent: Bool
        public var notesPresent: Bool
        public var excludedIgnored: IgnoredSummary?
    }

    /// The agent's `notes/` directory or anything under it.
    /// Collation key matching the Node `localeCompare` order the upstream walk
    /// sorts by (punctuation `_` before `.`, letters case-insensitive).
    public static func orderingKey(_ value: String) -> String {
        var key = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "_": key.unicodeScalars.append("\u{0001}")
            case ".": key.unicodeScalars.append("\u{0002}")
            default:
                if scalar.value >= 65, scalar.value <= 90, let lowered = UnicodeScalar(scalar.value + 32) {
                    key.unicodeScalars.append(lowered)
                } else {
                    key.unicodeScalars.append(scalar)
                }
            }
        }
        return key
    }

    public static func localeLess(_ left: String, _ right: String) -> Bool {
        let leftKey = orderingKey(left)
        let rightKey = orderingKey(right)
        if leftKey != rightKey { return leftKey < rightKey }
        return left < right
    }

    public static func isNotesPath(_ workspaceRelativePath: String) -> Bool {
        workspaceRelativePath == "notes" || workspaceRelativePath.hasPrefix("notes/")
    }

    public static func isRegenerablePath(_ relativePath: String) -> Bool {
        normalizedRelative(relativePath).split(separator: "/").contains { regenerableDirectoryNames.contains(String($0)) }
    }

    public struct UnsafeLinkError: Error, CustomStringConvertible {
        public let linkPath: String
        public let target: String
        public var description: String { "MIGRATION_OBJECT_STORE_UNSAFE_LINK: \(linkPath) -> \(target)" }
    }

    /// Normalize a symlink target to a portable path. The target is resolved
    /// against the link's directory and must stay inside the workspace; the
    /// returned value is the normalized target itself, not the resolved path.
    public static func normalizeSymlinkTarget(_ linkPath: String, _ target: String) throws -> String {
        if target.contains("\0") || target.hasPrefix("/") || target.hasPrefix("\\")
            || target.hasPrefix("\\") || isWindowsDrive(target) {
            throw UnsafeLinkError(linkPath: linkPath, target: target)
        }
        let portable = target.replacingOccurrences(of: "\\", with: "/")
        let normalized = normalizedPosix(portable)
        let linkDirectory = normalizedPosix((linkPath as NSString).deletingLastPathComponent)
        let resolved = linkDirectory == "." ? normalized : normalizedPosix(linkDirectory + "/" + normalized)
        if resolved == ".." || resolved.hasPrefix("../") || resolved.hasPrefix("/") {
            throw UnsafeLinkError(linkPath: linkPath, target: target)
        }
        return normalized
    }

    static func isWindowsDrive(_ value: String) -> Bool {
        let chars = Array(value)
        return chars.count >= 2 && chars[0].isLetter && chars[1] == ":"
    }

    static func normalizedPosix(_ value: String) -> String {
        var parts: [String] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if parts.last == ".." || parts.isEmpty { parts.append("..") } else { parts.removeLast() }
            } else {
                parts.append(String(component))
            }
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    static func normalizedRelative(_ value: String) -> String {
        let portable = value.replacingOccurrences(of: "\\", with: "/")
        if value.contains("\0") || isWindowsDrive(value) || value.hasPrefix("/") || value.hasPrefix("\\") {
            return portable
        }
        let normalized = normalizedPosix(portable)
        return normalized
    }

    static func isAlwaysMovedPath(_ relativePath: String) -> Bool {
        if alwaysMovedRootPaths.contains(relativePath) { return true }
        return alwaysMovedDirectories.contains { directory in
            directory == relativePath || directory.hasPrefix(relativePath + "/") || relativePath.hasPrefix(directory + "/")
        }
    }

    static func readIgnorePaths(_ workspace: String) -> Set<String> {
        guard let text = try? String(contentsOfFile: workspace + "/" + ignoreFileName, encoding: .utf8) else { return [] }
        var candidates: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.rangeOfCharacter(from: patternChars) != nil { continue }
            var value = line
            if value.hasPrefix("./") { value.removeFirst(2) }
            while value.hasSuffix("/") { value.removeLast() }
            if value.isEmpty { continue }
            candidates.append(value)
        }
        return Set(candidates.map { normalizedPosix($0) }.filter { !isAlwaysMovedPath($0) && $0 != "." && !$0.hasPrefix("../") })
    }

    /// Walk the workspace (deterministic name order) and hand each included file
    /// or symlink path to `onEntry`, without reading file contents.
    public static func listWorkspace(
        workspacePath: String, measureIgnored: Bool = true,
        onEntry: @Sendable (String) -> Void
    ) -> WorkspaceListing {
        let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        var listing = WorkspaceListing()
        let ignorePaths = readIgnorePaths(workspace)
        walk(root: workspace, relativeDir: "", ignorePaths: ignorePaths, measureIgnored: measureIgnored,
             listing: &listing, onEntry: onEntry)
        listing.excludedRegenerable.sort { localeLess($0.path, $1.path) }
        listing.excludedIgnored.sort { localeLess($0.path, $1.path) }
        listing.unreachable.sort { localeLess($0.path, $1.path) }
        return listing
    }

    static func walk(
        root: String, relativeDir: String, ignorePaths: Set<String>, measureIgnored: Bool,
        listing: inout WorkspaceListing, onEntry: (String) -> Void
    ) {
        let absoluteDir = relativeDir.isEmpty ? root : root + "/" + relativeDir
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: absoluteDir) else {
            listing.unreachable.append(.init(path: relativeDir.isEmpty ? "." : relativeDir))
            return
        }
        for name in names.sorted() {
            let relativePath = relativeDir.isEmpty ? name : relativeDir + "/" + name
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: absoluteDir + "/" + name, isDirectory: &isDirectory) else { continue }
            if ignorePaths.contains(relativePath) {
                if measureIgnored {
                    let totals = measureIgnoredPath(root: root, relativePath: relativePath, isDirectory: isDirectory.boolValue, listing: &listing)
                    listing.excludedIgnored.append(.init(path: relativePath, fileCount: totals.files, sizeBytes: totals.bytes))
                }
                continue
            }
            if isDirectory.boolValue {
                if isRegenerablePath(relativePath) {
                    listing.excludedRegenerable.append(.init(
                        path: relativePath,
                        regenerableHint: "\(name) is treated as rebuildable/installable state and is not bundled by default"
                    ))
                    continue
                }
                walk(root: root, relativeDir: relativePath, ignorePaths: ignorePaths, measureIgnored: measureIgnored,
                     listing: &listing, onEntry: onEntry)
                continue
            }
            onEntry(relativePath)
        }
    }

    static func measureIgnoredPath(root: String, relativePath: String, isDirectory: Bool, listing: inout WorkspaceListing) -> (files: Int, bytes: Int) {
        var files = 0
        var bytes = 0
        func visit(_ path: String, directory: Bool) {
            let absolute = root + "/" + path
            if !directory {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: absolute) {
                    files += 1
                    if (attributes[.type] as? FileAttributeType) == .typeRegular {
                        bytes += (attributes[.size] as? NSNumber)?.intValue ?? 0
                    }
                }
                return
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: absolute) else {
                listing.unreachable.append(.init(path: path))
                return
            }
            for name in names.sorted() {
                var childDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: absolute + "/" + name, isDirectory: &childDirectory)
                visit(path + "/" + name, directory: childDirectory.boolValue)
            }
        }
        visit(relativePath, directory: isDirectory)
        return (files, bytes)
    }

    public static func summarize(
        includedFileCount: Int, includedBytes: Int, memoryMdPresent: Bool, notesPresent: Bool,
        excludedRegenerable: [ExcludedRegenerable], excludedIgnored: [ExcludedIgnored] = []
    ) -> TransferSummary {
        var categories = RegenerableCategories()
        for entry in excludedRegenerable {
            let names = entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            if names.contains(where: thirdPartyRegenerableNames.contains) {
                categories.thirdPartyDependencies += 1
            } else if names.contains(where: cacheRegenerableNames.contains) {
                categories.caches += 1
            } else if names.contains(where: buildRegenerableNames.contains) {
                categories.buildArtifacts += 1
            } else {
                categories.otherRegenerable += 1
            }
        }
        var ignored: IgnoredSummary?
        if !excludedIgnored.isEmpty {
            let sorted = excludedIgnored.sorted { $0.sizeBytes != $1.sizeBytes ? $0.sizeBytes > $1.sizeBytes : localeLess($0.path, $1.path) }
            ignored = IgnoredSummary(
                count: excludedIgnored.count,
                fileCount: excludedIgnored.reduce(0) { $0 + $1.fileCount },
                bytes: excludedIgnored.reduce(0) { $0 + $1.sizeBytes },
                largest: sorted.prefix(5).map { (path: $0.path, bytes: $0.sizeBytes) }
            )
        }
        return TransferSummary(
            includedFileCount: includedFileCount, includedBytes: includedBytes,
            excludedRegenerableCount: excludedRegenerable.count,
            excludedRegenerableByCategory: categories,
            memoryMdPresent: memoryMdPresent, notesPresent: notesPresent,
            excludedIgnored: ignored
        )
    }
}
