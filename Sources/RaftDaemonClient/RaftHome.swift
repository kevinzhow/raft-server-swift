import Foundation

/// Where the Raft home lives: the one directory that holds a machine's Raft
/// state. ONE rule for every process: `$RAFT_HOME`, else `$SLOCK_HOME` when
/// set; otherwise `~/.slock` when it already holds Raft state (agent
/// workspaces, Computer state, daemon machine state, CLI profiles, agent
/// ledgers), otherwise `~/.raft`. A `~/.slock` holding only a notice file does
/// not count. Ported from the shared/daemon raft-home rule.
public enum RaftHome {
    public static let raftHomeEnv = "RAFT_HOME"
    public static let slockHomeEnv = "SLOCK_HOME"
    public static let raftHomeDirname = ".raft"
    public static let legacyRaftHomeDirname = ".slock"
    public static let legacyStateEntries = ["agents", "computer", "machines", "profiles", "agent-state"]

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func defaultDirname(exists: (String) -> Bool) -> String {
        let holdsState = legacyStateEntries.contains { exists(legacyRaftHomeDirname + "/" + $0) }
        return holdsState ? legacyRaftHomeDirname : raftHomeDirname
    }

    /// `~/.slock` when it already holds Raft state, else `~/.raft`.
    public static func resolveDefaultRoot(homeDir: String = NSHomeDirectory()) -> String {
        let dirname = defaultDirname { relative in
            FileManager.default.fileExists(atPath: homeDir + "/" + relative)
        }
        return resolve(homeDir + "/" + dirname)
    }

    public static func resolveRoot(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDir: String = NSHomeDirectory()
    ) -> String {
        // RAFT_HOME wins over legacy SLOCK_HOME.
        let raft = env[raftHomeEnv]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let slock = env[slockHomeEnv]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = !raft.isEmpty ? raft : slock
        let root = !raw.isEmpty ? raw : resolveDefaultRoot(homeDir: homeDir)
        return resolve(root)
    }

    public static func resolvePath(_ childPath: String, raftHome: String) -> String {
        raftHome + "/" + childPath
    }

    public struct LegacyStatePath: Sendable, Equatable {
        public var path: String
        public var destination: String
        public var description: String
        public init(path: String, destination: String, description: String) {
            self.path = path
            self.destination = destination
            self.description = description
        }
    }

    public static func listLegacyStatePaths(
        raftHome: String,
        homeDir: String = NSHomeDirectory()
    ) -> [LegacyStatePath] {
        let defaultHome = resolveDefaultRoot(homeDir: homeDir)
        guard resolve(raftHome) != defaultHome else { return [] }
        let candidates: [(String, String)] = [
            ("agents", "agent workspaces and per-agent runtime wrapper state"),
            ("machines", "daemon machine locks, local traces, and machine-scoped state"),
            ("attachments", "chat bridge attachment download cache"),
        ]
        return candidates.compactMap { child, description in
            let source = defaultHome + "/" + child
            guard FileManager.default.fileExists(atPath: source) else { return nil }
            return LegacyStatePath(
                path: source,
                destination: resolve(raftHome) + "/" + child,
                description: description
            )
        }
    }
}
