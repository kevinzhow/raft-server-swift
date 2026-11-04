import Foundation

/// Object-store migration bundle accounting: a strict 250,000-entry boundary
/// with a bounded recovery wire that reports only the largest workspace
/// top-level paths, redacting secret-shaped names. Ported from the upstream
/// daemon migration bundle helper.
public struct AgentMigrationBundleFileEntry: Sendable, Equatable {
    public var source: String
    public var workspaceRelativePath: String?
    public init(source: String, workspaceRelativePath: String?) {
        self.source = source
        self.workspaceRelativePath = workspaceRelativePath
    }
}

public struct AgentMigrationObjectStoreTopPathCount: Sendable, Equatable {
    public var path: String
    public var entryCount: Int
    public init(path: String, entryCount: Int) {
        self.path = path
        self.entryCount = entryCount
    }
}

public final class AgentMigrationObjectStoreEntryCountLimitError: Error, @unchecked Sendable {
    public let code = "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED"
    public let entryCount: Int
    public let maxEntries: Int
    public let topPathCounts: [AgentMigrationObjectStoreTopPathCount]
    public let message: String
    public init(entryCount: Int, maxEntries: Int, topPathCounts: [AgentMigrationObjectStoreTopPathCount] = []) {
        self.entryCount = entryCount
        self.maxEntries = maxEntries
        self.topPathCounts = topPathCounts
        self.message = AgentMigrationObjectStoreBundle.entryCountLimitWireMessage(
            entryCount: entryCount, maxEntries: maxEntries, topPathCounts: topPathCounts
        )
    }
}

public enum AgentMigrationObjectStoreBundle {
    public static let maxObjectStoreBundleEntries = 250_000
    public static let maxBundleTooLargeAccountingEntries = 3
    public static let maxEncodedAccountingPathLength = 96

    /// Strict workspace-relative normalization; host-independent unsafe paths
    /// (empty, dot, absolute, drive, UNC, escaping, NUL) are rejected.
    public static func normalizeWorkspaceRelativePath(_ raw: String) throws -> String {
        let error = NSError(domain: "MIGRATION_OBJECT_STORE_UNSAFE_PATH", code: 1)
        if raw.isEmpty || raw.contains("\0") { throw error }
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        if unified.hasPrefix("/") || unified.hasPrefix("//") { throw error }
        if unified.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil { throw error }
        var segments: [String] = []
        for segment in unified.split(separator: "/", omittingEmptySubsequences: false) {
            let value = String(segment)
            if value.isEmpty || value == "." { continue }
            // Any parent segment is host-independent unsafe, even when it
            // would only climb within the workspace.
            if value == ".." { throw error }
            segments.append(value)
        }
        guard !segments.isEmpty else { throw error }
        return segments.joined(separator: "/")
    }

    static func topLevelPath(_ path: String) -> String {
        guard let index = path.firstIndex(of: "/") else { return path + "/" }
        return String(path[...index])
    }

    static func isSensitiveAccountingPath(_ value: String) -> Bool {
        let basename = value.hasSuffix("/") ? String(value.dropLast()) : value
        if basename.range(of: #"^\.env(?:\.|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return basename.range(of: #"(?:secret|token|credential|api[-_]?key)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func encodeAccountingPath(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        var encoded = ""
        for character in value {
            let next = String(character).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            if encoded.count + next.count > maxEncodedAccountingPathLength { break }
            encoded += next
        }
        return encoded
    }

    static func entryCountLimitWireMessage(
        entryCount: Int, maxEntries: Int, topPathCounts: [AgentMigrationObjectStoreTopPathCount]
    ) -> String {
        let encoded = topPathCounts.prefix(maxBundleTooLargeAccountingEntries).compactMap { entry -> String? in
            let value = "\(encodeAccountingPath(entry.path)),\(entry.entryCount)"
            return value.isEmpty ? nil : value
        }
        return "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED:entryCount=\(entryCount)"
            + ":maxEntries=\(maxEntries):topPathCounts=\(encoded.joined(separator: ";"))"
    }

    /// Throws when the walk found more entries than the limit; `overflow` adds
    /// the entries the export walk only counted after passing the limit.
    public static func assertEntryLimit(
        entries: [AgentMigrationBundleFileEntry],
        maxEntries: Int = maxObjectStoreBundleEntries,
        overflowEntryCount: Int = 0,
        overflowCountByTopLevelPath: [String: Int]? = nil
    ) throws {
        guard maxEntries > 0 else {
            throw NSError(domain: "MIGRATION_OBJECT_STORE_MAX_ENTRIES_INVALID", code: 1)
        }
        let total = entries.count + overflowEntryCount
        if total <= maxEntries { return }
        throw AgentMigrationObjectStoreEntryCountLimitError(
            entryCount: total, maxEntries: maxEntries,
            topPathCounts: largestWorkspaceEntryCounts(
                files: entries, limit: maxBundleTooLargeAccountingEntries,
                extraCountByTopLevelPath: overflowCountByTopLevelPath
            )
        )
    }

    public static func largestWorkspaceEntryCounts(
        files: [AgentMigrationBundleFileEntry],
        limit: Int = maxBundleTooLargeAccountingEntries,
        extraCountByTopLevelPath: [String: Int]? = nil
    ) -> [AgentMigrationObjectStoreTopPathCount] {
        guard limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        func add(_ path: String, _ count: Int) {
            let accounting = isSensitiveAccountingPath(path) ? "other/" : path
            counts[accounting, default: 0] += count
        }
        for entry in files {
            guard entry.source == "workspace", let relative = entry.workspaceRelativePath,
                  let normalized = try? normalizeWorkspaceRelativePath(relative)
            else { continue }
            add(topLevelPath(normalized), 1)
        }
        for (path, count) in extraCountByTopLevelPath ?? [:] { add(path, count) }
        return counts.map { AgentMigrationObjectStoreTopPathCount(path: $0.key, entryCount: $0.value) }
            .sorted { left, right in
                left.entryCount != right.entryCount ? left.entryCount > right.entryCount : left.path < right.path
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Wire suffix for MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE: largest
    /// top-level workspace paths by bytes, redacting secret-shaped names.
    public static func bundleTooLargeTopEntries(bytesByTopLevelPath: [String: Int]) -> String {
        var bytes: [String: Int] = [:]
        for (path, value) in bytesByTopLevelPath {
            bytes[isSensitiveAccountingPath(path) ? "other/" : path, default: 0] += value
        }
        return bytes.sorted { left, right in
            left.value != right.value ? left.value > right.value : left.key < right.key
        }
        .prefix(maxBundleTooLargeAccountingEntries)
        .map { "\(encodeAccountingPath($0.key)),\($0.value)" }
        .joined(separator: ";")
    }
}
