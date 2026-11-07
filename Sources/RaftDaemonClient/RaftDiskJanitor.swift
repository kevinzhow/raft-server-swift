import Foundation
import Synchronization

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

    public final class WalkBudget: Sendable {
        private struct State: Sendable {
            var entriesLeft: Int
            var deadlineMs: Int
            var outcome: MeasureOutcome = .complete
        }

        private let state: Mutex<State>
        private let now: @Sendable () -> Int

        // Public property assignments remain independent operations.
        public var entriesLeft: Int {
            get { state.withLock { $0.entriesLeft } }
            set { state.withLock { $0.entriesLeft = newValue } }
        }

        public var deadlineMs: Int {
            get { state.withLock { $0.deadlineMs } }
            set { state.withLock { $0.deadlineMs = newValue } }
        }

        public var outcome: MeasureOutcome {
            get { state.withLock { $0.outcome } }
            set { state.withLock { $0.outcome = newValue } }
        }

        public init(
            maxEntries: Int = RaftDisk.walkMaxEntries,
            deadlineMs: Int = RaftDisk.walkDeadlineMs,
            nowMs: Int? = nil,
            now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
        ) {
            self.now = now
            let absoluteDeadline = (nowMs ?? now()) + deadlineMs
            self.state = Mutex(State(entriesLeft: maxEntries, deadlineMs: absoluteDeadline))
        }

        public var isExhausted: Bool {
            let exhausted = state.withLock { state in
                if state.outcome != .complete { return true }
                if state.entriesLeft <= 0 { state.outcome = .truncated; return true }
                return false
            }
            if exhausted { return true }
            // The foreign clock can read or update the budget. Preserve the
            // original deadline read after it returns, without rechecking guards.
            let sampledNow = now()
            return state.withLock { state in
                if sampledNow >= state.deadlineMs { state.outcome = .timeout; return true }
                return false
            }
        }

        fileprivate func consumeEntries(_ count: Int) {
            state.withLock { $0.entriesLeft -= count }
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
                budget.consumeEntries(batch.count)
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

    public final class JanitorSchedule: Sendable {
        private struct Timer: Sendable {
            let generation: UUID
            var token: Int?
        }

        private enum Effect: Sendable {
            case schedule(generation: UUID, delayMs: Int)
            case cancel(Int)
        }

        private struct State: Sendable {
            var timer: Timer?
            var runningPass: UUID?
            var stopped = false
            var effects: [Effect] = []
            var draining = false

            mutating func reserveTimer(_ delayMs: Int) {
                guard !stopped, timer == nil, runningPass == nil else { return }
                let generation = UUID()
                timer = Timer(generation: generation)
                effects.append(.schedule(generation: generation, delayMs: delayMs))
            }

            mutating func stop() {
                stopped = true
                if let token = timer?.token { effects.append(.cancel(token)) }
                timer = nil
            }
        }

        private let state = Mutex(State())
        private let pass: @Sendable () async -> Void
        private let timers: Timers
        private let intervalMs: Int

        init(pass: @escaping @Sendable () async -> Void, timers: Timers, intervalMs: Int, initialDelayMs: Int) {
            self.pass = pass
            self.timers = timers
            self.intervalMs = intervalMs
            state.withLock { $0.reserveTimer(initialDelayMs) }
            drainEffects()
        }

        private func timerFired(_ generation: UUID) {
            let admitted = state.withLock { state in
                guard !state.stopped, state.timer?.generation == generation,
                      state.runningPass == nil else { return false }
                state.timer = nil
                state.runningPass = generation
                return true
            }
            guard admitted else { return }
            // Preserve the existing ownership of an admitted pass across await.
            // The timer body itself holds only a weak reference to this owner.
            Task { [self] in
                await pass()
                passFinished(generation)
            }
        }

        private func passFinished(_ generation: UUID) {
            state.withLock { state in
                guard state.runningPass == generation else { return }
                state.runningPass = nil
                state.reserveTimer(intervalMs)
            }
            drainEffects()
        }

        /// Invalidates future callback admissions and registrations. A pass
        /// already admitted before stop remains in flight and is not joined.
        /// An in-flight registration is cancelled when its token returns.
        public func stop() {
            state.withLock { $0.stop() }
            drainEffects()
        }

        // One drainer keeps injected timer operations outside the mutex. If a
        // synchronous callback finishes its pass before setTimeout returns, its
        // next registration stays queued until the current registration returns.
        // Reentrant stop invalidates queued schedules and unpublished tokens.
        private func drainEffects() {
            let start = state.withLock { state in
                guard !state.draining, !state.effects.isEmpty else { return false }
                state.draining = true
                return true
            }
            guard start else { return }
            while let effect = state.withLock({ state -> Effect? in
                guard !state.effects.isEmpty else {
                    state.draining = false
                    return nil
                }
                return state.effects.removeFirst()
            }) {
                switch effect {
                case .cancel(let token):
                    timers.clearTimeout(token)
                case .schedule(let generation, let delayMs):
                    let current = state.withLock {
                        !$0.stopped && $0.timer?.generation == generation
                    }
                    guard current else { continue }
                    let token = timers.setTimeout({ [weak self] in
                        self?.timerFired(generation)
                    }, delayMs)
                    state.withLock { state in
                        if !state.stopped, state.timer?.generation == generation {
                            state.timer?.token = token
                        } else {
                            // The reservation fired or stopped before its token
                            // returned. Cancel that token outside the mutex.
                            state.effects.append(.cancel(token))
                        }
                    }
                }
            }
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
