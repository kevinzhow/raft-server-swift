import Foundation

/// Context generation signal (RFC 072 §7.2): which model context an agent's CLI
/// is running in. The daemon writes `<transportDir>/context-generation` before
/// each spawn and at every compaction_started; a resume reuses the id that
/// session last had, everything else gets a fresh id. A failed write leaves no
/// file at all ("signal unknown") rather than a stale id the CLI could match.
/// Ported from the upstream daemon signal.
public enum ContextGeneration {
    public static let filename = "context-generation"
    public static let maxBytes = 4096
    public static let sessionsFilename = "sessions.json"
    public static let maxRememberedSessions = 32
    public static let reasons = ["spawn", "resume", "compaction"]

    /// Whether each runtime reports context compaction. Runtimes that do not
    /// report it cannot prove an unchanged id means "context kept".
    public static let runtimeReportsCompaction: [String: Bool] = [
        "claude": true, "codex": true, "cursor": true, "kimi": true, "kimi-sdk": true,
        "pi": true, "builtin": true,
        "grok": false, "copilot": false, "gemini": false, "opencode": false, "antigravity": false,
    ]

    public static let registeredRuntimeIds = ["claude", "codex", "cursor", "kimi", "kimi-sdk", "pi", "builtin", "grok", "copilot", "gemini", "opencode", "antigravity"]

    public static func reportsCompaction(_ runtime: String) -> Bool {
        runtimeReportsCompaction[runtime] == true
    }

    /// The composed passive AX gate: only an explicit `true` turns it on.
    public static func configPassiveAx(_ config: [String: Any]) -> Bool {
        (config["passiveAx"] as? Bool) == true
    }

    public struct Record: Sendable, Equatable {
        public var contextId: String
        public var reason: String
        public var compactionReported: Bool
        public var runtime: String
        public var writtenAt: String
        public var passiveAx: Bool
        public init(contextId: String, reason: String, compactionReported: Bool, runtime: String, writtenAt: String, passiveAx: Bool) {
            self.contextId = contextId
            self.reason = reason
            self.compactionReported = compactionReported
            self.runtime = runtime
            self.writtenAt = writtenAt
            self.passiveAx = passiveAx
        }
    }

    public struct SessionBinding: Sendable, Equatable {
        public var contextId: String
        public var updatedAt: String
    }

    public struct FileSystem: Sendable {
        public var read: @Sendable (String) throws -> String
        public var write: @Sendable (String, String) throws -> Void
        public var rename: @Sendable (String, String) throws -> Void
        public var unlink: @Sendable (String) throws -> Void
        public init(
            read: @escaping @Sendable (String) throws -> String,
            write: @escaping @Sendable (String, String) throws -> Void,
            rename: @escaping @Sendable (String, String) throws -> Void,
            unlink: @escaping @Sendable (String) throws -> Void
        ) {
            self.read = read
            self.write = write
            self.rename = rename
            self.unlink = unlink
        }

        public static let `default` = FileSystem(
            read: { path in try String(contentsOfFile: path, encoding: .utf8) },
            write: { path, contents in
                try contents.write(toFile: path, atomically: false, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            },
            rename: { from, to in
                if FileManager.default.fileExists(atPath: to) { try FileManager.default.removeItem(atPath: to) }
                try FileManager.default.moveItem(atPath: from, toPath: to)
            },
            unlink: { path in
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
        )
    }

    public struct Deps: Sendable {
        public var fs: FileSystem = .default
        public var now: @Sendable () -> Date = { Date() }
        public var newId: @Sendable () -> String = { UUID().uuidString }
        public init(fs: FileSystem = .default, now: @escaping @Sendable () -> Date = { Date() }, newId: @escaping @Sendable () -> String = { UUID().uuidString }) {
            self.fs = fs
            self.now = now
            self.newId = newId
        }
    }

    static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    static func generationFile(_ transportDir: String) -> String {
        transportDir + "/" + filename
    }

    /// Publish a fresh context id. Never throws; a failure leaves no file.
    @discardableResult
    public static func write(
        transportDir: String, reason: String, runtime: String, passiveAx: Bool,
        contextId: String? = nil, deps: Deps = Deps()
    ) -> String? {
        let fs = deps.fs
        let file = generationFile(transportDir)
        let record = Record(
            contextId: contextId ?? deps.newId(), reason: reason,
            compactionReported: reportsCompaction(runtime), runtime: runtime,
            writtenAt: isoString(deps.now()), passiveAx: passiveAx
        )
        let tmp = file + ".\(UUID().uuidString).tmp"
        do {
            try unlinkIfPresent(fs, file)
            let payload: [String: Any] = [
                "contextId": record.contextId, "reason": record.reason,
                "compactionReported": record.compactionReported, "runtime": record.runtime,
                "writtenAt": record.writtenAt, "passiveAx": record.passiveAx,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try fs.write(tmp, String(decoding: data, as: UTF8.self) + "\n")
            try fs.rename(tmp, file)
            return record.contextId
        } catch {
            try? unlinkIfPresent(fs, tmp)
            try? unlinkIfPresent(fs, file)
            return nil
        }
    }

    static func unlinkIfPresent(_ fs: FileSystem, _ file: String) throws {
        do {
            try fs.unlink(file)
        } catch {
            // Missing files are the normal case.
            let nsError = error as NSError
            if nsError.code != NSFileNoSuchFileError && nsError.code != 2 { throw error }
        }
    }

    public static func read(transportDir: String, deps: Deps = Deps()) -> Record? {
        let fs = deps.fs
        guard let raw = try? fs.read(generationFile(transportDir)), raw.utf8.count <= maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let contextId = object["contextId"] as? String, !contextId.isEmpty
        else { return nil }
        return Record(
            contextId: contextId,
            reason: object["reason"] as? String ?? "",
            compactionReported: (object["compactionReported"] as? Bool) ?? false,
            runtime: object["runtime"] as? String ?? "",
            writtenAt: object["writtenAt"] as? String ?? "",
            passiveAx: (object["passiveAx"] as? Bool) ?? false
        )
    }

    public struct SpawnPlan: Sendable, Equatable {
        public var contextId: String
        public var reason: String
        public init(contextId: String, reason: String) {
            self.contextId = contextId
            self.reason = reason
        }
    }

    /// The id a spawn publishes, decided before the process exists.
    public static func planSpawn(transportDir: String, runtime: String, resumeSessionId: String? = nil, deps: Deps = Deps()) -> SpawnPlan {
        if let resumeSessionId, reportsCompaction(runtime),
           let reused = readSessions(transportDir, deps: deps)?[resumeSessionId] {
            return SpawnPlan(contextId: reused.contextId, reason: "resume")
        }
        return SpawnPlan(contextId: deps.newId(), reason: "spawn")
    }

    @discardableResult
    public static func publishSpawn(
        transportDir: String, runtime: String, resumeSessionId: String? = nil,
        passiveAx: Bool, plan: SpawnPlan? = nil, deps: Deps = Deps()
    ) -> String? {
        let plan = plan ?? planSpawn(transportDir: transportDir, runtime: runtime, resumeSessionId: resumeSessionId, deps: deps)
        return write(
            transportDir: transportDir, reason: plan.reason, runtime: runtime,
            passiveAx: passiveAx, contextId: plan.contextId, deps: deps
        )
    }

    /// The runtime reported `sessionId`; bind the published id to it, or publish
    /// a new id first when it reports a different session than the resumed one.
    @discardableResult
    public static func bindToSession(
        transportDir: String, runtime: String, sessionId: String,
        expectedSessionId: String?, deps: Deps = Deps()
    ) -> String? {
        let current = read(transportDir: transportDir, deps: deps)
        var contextId = current?.contextId
        if let current, contextId != nil, let expectedSessionId, expectedSessionId != sessionId {
            // Same process, same gate: carry the published value to the new id.
            contextId = write(
                transportDir: transportDir, reason: "spawn", runtime: runtime,
                passiveAx: current.passiveAx == true, deps: deps
            )
        }
        rememberSession(transportDir: transportDir, sessionId: sessionId, contextId: contextId, deps: deps)
        return contextId
    }

    static func sessionsFile(_ transportDir: String) -> String {
        // transportDir is <home>/cli-transport/<agentId>/<launch part>.
        let parent = (transportDir as NSString).deletingLastPathComponent
        return parent + "/" + sessionsFilename
    }

    static func readSessions(_ transportDir: String, deps: Deps) -> [String: SessionBinding]? {
        guard let raw = try? deps.fs.read(sessionsFile(transportDir)),
              let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == 1,
              let sessions = object["sessions"] as? [String: [String: Any]]
        else { return nil }
        var result: [String: SessionBinding] = [:]
        for (sessionId, entry) in sessions {
            guard let contextId = entry["contextId"] as? String, !contextId.isEmpty else { continue }
            result[sessionId] = SessionBinding(
                contextId: contextId, updatedAt: entry["updatedAt"] as? String ?? ""
            )
        }
        return result
    }

    /// Record (or, with nil contextId, forget) the id a session last had. On a
    /// failed write the whole table is removed: a stale entry is worse than none.
    public static func rememberSession(
        transportDir: String, sessionId: String, contextId: String?, deps: Deps = Deps()
    ) {
        let fs = deps.fs
        let file = sessionsFile(transportDir)
        var table = readSessions(transportDir, deps: deps) ?? [:]
        if contextId == nil && table[sessionId] == nil { return }
        table[sessionId] = nil
        if let contextId {
            table[sessionId] = SessionBinding(contextId: contextId, updatedAt: isoString(deps.now()))
            if table.count > maxRememberedSessions {
                // Recency order: sort by updatedAt, keep the newest entries.
                let sorted = table.sorted { $0.value.updatedAt < $1.value.updatedAt }
                for (key, _) in sorted.prefix(table.count - maxRememberedSessions) {
                    table[key] = nil
                }
            }
        }
        let tmp = file + ".\(UUID().uuidString).tmp"
        do {
            var serialized: [String: Any] = ["version": 1]
            var sessions: [String: Any] = [:]
            for (key, value) in table {
                sessions[key] = ["contextId": value.contextId, "updatedAt": value.updatedAt]
            }
            serialized["sessions"] = sessions
            let data = try JSONSerialization.data(withJSONObject: serialized, options: [.sortedKeys])
            try fs.write(tmp, String(decoding: data, as: UTF8.self) + "\n")
            try fs.rename(tmp, file)
        } catch {
            try? unlinkIfPresent(fs, tmp)
            try? unlinkIfPresent(fs, file)
        }
    }
}
