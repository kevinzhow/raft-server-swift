import Foundation

/// Raft Computer's own disk use under the Raft home: migration transfer copies,
/// archived workspaces and per-launch CLI transport. Agent workspaces are never
/// walked or touched here. Every walk and sweep is bounded by an entry budget
/// and a deadline so one pass cannot saturate disk IO; a bounded result says so
/// explicitly instead of reporting a misleadingly small number. Ported from the
/// upstream daemon janitor.
public enum RaftDisk {
    public static let migrationsDirectory = "migrations"
    public static let backupDirectory = "migration-workspace-backups"
    public static let cliTransportDirectory = "cli-transport"
    public static let agentProxyTokensDirectory = "agent-proxy-tokens"

    public static let migrationGenerationIdleMs = 7 * 24 * 60 * 60 * 1000
    public static let walkMaxEntries = 200_000
    public static let walkDeadlineMs = 30_000
    public static let backupMaxPerAgent = 3
    public static let backupMaxAgeMs = 30 * 24 * 60 * 60 * 1000
    static let walkBatchSize = 64
    static let bulkEntryPrefixes = ["chunks", "source-spool"]

    public enum MeasureOutcome: String, Sendable, Equatable {
        case complete, truncated, timeout
    }

    public final class WalkBudget: @unchecked Sendable {
        public var entriesLeft: Int
        public var deadlineMs: Int
        public var outcome: MeasureOutcome = .complete
        private let now: @Sendable () -> Int
        public init(
            maxEntries: Int = RaftDisk.walkMaxEntries,
            deadlineMs: Int = RaftDisk.walkDeadlineMs,
            nowMs: Int? = nil,
            now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
        ) {
            self.entriesLeft = maxEntries
            self.now = now
            self.deadlineMs = (nowMs ?? now()) + deadlineMs
        }

        public var isExhausted: Bool {
            if outcome != .complete { return true }
            if entriesLeft <= 0 { outcome = .truncated; return true }
            if now() >= deadlineMs { outcome = .timeout; return true }
            return false
        }
    }

    static func bulkEntry(_ name: String) -> Bool {
        if bulkEntryPrefixes.contains(name) { return true }
        return name.hasPrefix("extracting-")
    }

    /// Apparent bytes of regular files under `root`; symlinks are not followed.
    public static func measureDirectoryBytes(_ root: String, budget: WalkBudget) -> Int {
        var bytes = 0
        var pending = [root]
        while let dir = pending.popLast() {
            if budget.isExhausted { return bytes }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            var index = 0
            while index < names.count {
                if budget.isExhausted { return bytes }
                let batch = Array(names[index..<min(index + walkBatchSize, names.count)])
                budget.entriesLeft -= batch.count
                for name in batch {
                    let entryPath = dir + "/" + name
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: entryPath) else { continue }
                    let kind = attributes[.type] as? FileAttributeType
                    if kind == .typeDirectory {
                        pending.append(entryPath)
                    } else if kind == .typeRegular {
                        bytes += (attributes[.size] as? NSNumber)?.intValue ?? 0
                    }
                }
                index += walkBatchSize
            }
        }
        return bytes
    }

    /// Apparent size of one tree, ignoring symlinks.
    public static func treeSize(_ root: String) -> Int {
        measureDirectoryBytes(root, budget: WalkBudget())
    }

    /// Removes the bulk transfer data of one migration generation and keeps its
    /// JSON reports. Returns the bytes freed (bounded measurement).
    @discardableResult
    public static func removeMigrationGenerationBulk(_ generationRoot: String, budget: WalkBudget) -> Int {
        var freed = 0
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: generationRoot) else { return 0 }
        for name in names where bulkEntry(name) {
            let target = generationRoot + "/" + name
            freed += measureDirectoryBytes(target, budget: budget)
            try? FileManager.default.removeItem(atPath: target)
        }
        return freed
    }

    static func lastActivityMs(_ generationRoot: String) -> Int? {
        let manager = FileManager.default
        guard let rootAttributes = try? manager.attributesOfItem(atPath: generationRoot) else { return nil }
        var newest = (rootAttributes[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        for name in (try? manager.contentsOfDirectory(atPath: generationRoot)) ?? [] {
            guard let attributes = try? manager.attributesOfItem(atPath: generationRoot + "/" + name),
                  let date = attributes[.modificationDate] as? Date
            else { continue }
            newest = max(newest, Int(date.timeIntervalSince1970 * 1000))
        }
        return newest
    }

    public struct BackupRemoval: Sendable, Equatable {
        public var ownerAgentId: String
        public var backupKind: String
        public var ageDays: Int
        public var freedBytes: Int
        public init(ownerAgentId: String, backupKind: String, ageDays: Int, freedBytes: Int) {
            self.ownerAgentId = ownerAgentId
            self.backupKind = backupKind
            self.ageDays = ageDays
            self.freedBytes = freedBytes
        }
    }

    public struct JanitorResult: Sendable, Equatable {
        public var migrationGenerationsCleaned = 0
        public var migrationFreedBytes = 0
        public var backupsRemoved: [BackupRemoval] = []
        public var backupsFreedBytes = 0
        public var sweepOutcome: MeasureOutcome = .complete
    }

    static func listDirectories(_ dir: String) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: dir + "/" + name, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func pruneBackups(_ agentBackupRoot: String, nowMs: Int, budget: WalkBudget, owner: String, result: inout JanitorResult) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: agentBackupRoot) else { return }
        var directories: [(name: String, modifiedAtMs: Int)] = []
        for name in names {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: agentBackupRoot + "/" + name, isDirectory: &isDirectory), isDirectory.boolValue,
                  let attributes = try? manager.attributesOfItem(atPath: agentBackupRoot + "/" + name)
            else { continue }
            let modified = (attributes[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
            directories.append((name, modified))
        }
        directories.sort { left, right in
            left.modifiedAtMs != right.modifiedAtMs ? left.modifiedAtMs > right.modifiedAtMs : left.name > right.name
        }
        let cutoff = nowMs - backupMaxAgeMs
        for (index, entry) in directories.enumerated() {
            if index < backupMaxPerAgent && entry.modifiedAtMs >= cutoff { continue }
            let freed = measureDirectoryBytes(agentBackupRoot + "/" + entry.name, budget: budget)
            result.backupsFreedBytes += freed
            result.backupsRemoved.append(BackupRemoval(
                ownerAgentId: owner,
                backupKind: entry.name.hasPrefix("preexisting-") ? "preexisting" : "migration",
                ageDays: (nowMs - entry.modifiedAtMs) / (24 * 60 * 60 * 1000),
                freedBytes: freed
            ))
            try? manager.removeItem(atPath: agentBackupRoot + "/" + entry.name)
        }
    }

    /// One bounded janitor pass.
    public static func runJanitor(slockHome: String, nowMs: Int, budget: WalkBudget = WalkBudget()) -> JanitorResult {
        var result = JanitorResult()
        let migrationsRoot = slockHome + "/" + migrationsDirectory
        let idleBefore = nowMs - migrationGenerationIdleMs
        for migration in listDirectories(migrationsRoot) {
            for generation in listDirectories(migrationsRoot + "/" + migration) {
                if budget.isExhausted { break }
                let generationRoot = migrationsRoot + "/" + migration + "/" + generation
                let names = (try? FileManager.default.contentsOfDirectory(atPath: generationRoot)) ?? []
                guard names.contains(where: bulkEntry) else { continue }
                guard let lastActivity = lastActivityMs(generationRoot), lastActivity < idleBefore else { continue }
                result.migrationFreedBytes += removeMigrationGenerationBulk(generationRoot, budget: budget)
                result.migrationGenerationsCleaned += 1
            }
        }
        let backupRoot = slockHome + "/" + backupDirectory
        for owner in listDirectories(backupRoot) {
            if budget.isExhausted { break }
            pruneBackups(backupRoot + "/" + owner, nowMs: nowMs, budget: budget, owner: owner, result: &result)
        }
        result.sweepOutcome = budget.outcome
        return result
    }

    public struct Footprint: Sendable, Equatable {
        public var raftMigrationChunksBytes: Int
        public var raftWorkspaceBackupsBytes: Int
        public var raftLaunchDirsBytes: Int
        public var measureOutcome: MeasureOutcome
        public init(raftMigrationChunksBytes: Int, raftWorkspaceBackupsBytes: Int, raftLaunchDirsBytes: Int, measureOutcome: MeasureOutcome) {
            self.raftMigrationChunksBytes = raftMigrationChunksBytes
            self.raftWorkspaceBackupsBytes = raftWorkspaceBackupsBytes
            self.raftLaunchDirsBytes = raftLaunchDirsBytes
            self.measureOutcome = measureOutcome
        }
    }

    public static func measureFootprint(slockHome: String, budget: WalkBudget = WalkBudget()) -> Footprint {
        let migrations = measureDirectoryBytes(slockHome + "/" + migrationsDirectory, budget: budget)
        let backups = measureDirectoryBytes(slockHome + "/" + backupDirectory, budget: budget)
        let launches = measureDirectoryBytes(slockHome + "/" + cliTransportDirectory, budget: budget)
            + measureDirectoryBytes(slockHome + "/" + agentProxyTokensDirectory, budget: budget)
        return Footprint(
            raftMigrationChunksBytes: migrations, raftWorkspaceBackupsBytes: backups,
            raftLaunchDirsBytes: launches, measureOutcome: budget.outcome
        )
    }

    public static let janitorInitialDelayMs = 10 * 60 * 1000
    public static let janitorIntervalMs = 24 * 60 * 60 * 1000

    public struct Timers: Sendable {
        public var setTimeout: @Sendable (@escaping @Sendable () -> Void, Int) -> Int
        public var clearTimeout: @Sendable (Int) -> Void
        public init(
            setTimeout: @escaping @Sendable (@escaping @Sendable () -> Void, Int) -> Int,
            clearTimeout: @escaping @Sendable (Int) -> Void
        ) {
            self.setTimeout = setTimeout
            self.clearTimeout = clearTimeout
        }
    }

    public final class JanitorSchedule: @unchecked Sendable {
        private let lock = NSLock()
        private var timer: Int?
        private var stopped = false
        private let pass: @Sendable () async -> Void
        private let timers: Timers
        private let intervalMs: Int

        init(pass: @escaping @Sendable () async -> Void, timers: Timers, intervalMs: Int, initialDelayMs: Int) {
            self.pass = pass
            self.timers = timers
            self.intervalMs = intervalMs
            arm(initialDelayMs)
        }

        private func arm(_ delayMs: Int) {
            let timers = self.timers
            let token = timers.setTimeout({ [weak self] in
                guard let self else { return }
                self.lock.withLock { self.timer = nil }
                Task {
                    await self.pass()
                    let shouldArm = self.lock.withLock { !self.stopped }
                    // Re-arm outside the lock: arm() takes it again.
                    if shouldArm { self.arm(self.intervalMs) }
                }
            }, delayMs)
            lock.withLock { timer = token }
        }

        public func stop() {
            lock.lock()
            stopped = true
            let timer = self.timer
            self.timer = nil
            lock.unlock()
            if let timer { timers.clearTimeout(timer) }
        }
    }

    /// Runs `pass` after the initial delay and then every interval; never overlapping.
    public static func scheduleJanitor(
        pass: @escaping @Sendable () async -> Void,
        timers: Timers,
        initialDelayMs: Int = janitorInitialDelayMs,
        intervalMs: Int = janitorIntervalMs
    ) -> JanitorSchedule {
        JanitorSchedule(pass: pass, timers: timers, intervalMs: intervalMs, initialDelayMs: initialDelayMs)
    }
}
