import Crypto
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// One running daemon per machine key. A lock directory holds an `owner.json`
/// that identifies the live process; a clean release neutralizes the pid claim
/// (pid 0) instead of deleting the file so migration discovery keeps the
/// machine identity. Ported from the upstream daemon helper.
public struct DaemonMachineOwnerProvenance: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case legacyRawDaemon = "legacy_raw_daemon"
        case managedComputerRunner = "managed_computer_runner"
    }

    public var kind: Kind
    public var serverId: String?
    public var serverMachineId: String?

    public init(kind: Kind, serverId: String? = nil, serverMachineId: String? = nil) {
        self.kind = kind
        self.serverId = serverId
        self.serverMachineId = serverMachineId
    }

    public static let legacy = DaemonMachineOwnerProvenance(kind: .legacyRawDaemon)

    public static func managed(serverId: String, serverMachineId: String) -> DaemonMachineOwnerProvenance {
        DaemonMachineOwnerProvenance(kind: .managedComputerRunner, serverId: serverId, serverMachineId: serverMachineId)
    }
}

public struct DaemonMachineLockConflictError: Error, CustomStringConvertible {
    public let code = "DAEMON_MACHINE_LOCK_HELD"
    public var lockDir: String
    public var ownerDescription: String

    public var description: String {
        "Another Slock daemon is already running for this machine key (\(ownerDescription)). "
            + "Lock: \(lockDir). Stop the existing daemon first, or use a different machine key/state directory."
    }
}

public final class DaemonMachineLockHandle {
    public let lockId: String
    public let machineDir: String
    public let lockDir: String
    private let token: String
    private let ownerPath: String
    private var released = false

    fileprivate init(lockId: String, machineDir: String, lockDir: String, token: String) {
        self.lockId = lockId
        self.machineDir = machineDir
        self.lockDir = lockDir
        self.token = token
        self.ownerPath = (lockDir as NSString).appendingPathComponent("owner.json")
    }

    /// Relinquishes the lock: the machine identity stays on disk with pid 0.
    public func release() {
        guard !released else { return }
        released = true
        guard let owner = DaemonMachineLock.readOwner(lockDir: lockDir),
              owner.pid == Int(ProcessInfo.processInfo.processIdentifier),
              owner.token == token
        else { return }
        var releasedOwner = owner
        releasedOwner.pid = 0
        do {
            try DaemonMachineLock.writeOwner(releasedOwner, to: ownerPath)
        } catch {
            try? FileManager.default.removeItem(atPath: lockDir)
        }
    }
}

public enum DaemonMachineLock {
    public struct Owner: Codable, Equatable {
        public var pid: Int
        public var token: String
        public var hostname: String
        public var startedAt: String
        public var serverUrl: String
        public var apiKeyFingerprint: String
        public var schemaVersion: Int
        public var kind: String
        public var serverId: String?
        public var serverMachineId: String?
    }

    static let incompleteLockStaleMs: Int = 30_000

    public static func fingerprint(_ apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func lockId(apiKey: String) -> String {
        "machine-" + String(fingerprint(apiKey).prefix(16))
    }

    public static func defaultMachineStateRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = environment["SLOCK_HOME"] ?? environment["RAFT_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".slock")
        return (home as NSString).appendingPathComponent("machines")
    }

    public static func acquire(
        apiKey: String,
        serverUrl: String,
        rootDir: String? = nil,
        ownerProvenance: DaemonMachineOwnerProvenance = .legacy,
        now: Date = Date()
    ) throws -> DaemonMachineLockHandle {
        let root = rootDir ?? defaultMachineStateRoot()
        let machineDir = (root as NSString).appendingPathComponent(lockId(apiKey: apiKey))
        let lockDir = (machineDir as NSString).appendingPathComponent("daemon.lock")
        let token = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(atPath: machineDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        var owner = Owner(
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            token: token,
            hostname: ProcessInfo.processInfo.hostName,
            startedAt: formatter.string(from: now),
            serverUrl: serverUrl,
            apiKeyFingerprint: String(fingerprint(apiKey).prefix(16)),
            schemaVersion: 2,
            kind: ownerProvenance.kind.rawValue,
            serverId: ownerProvenance.serverId,
            serverMachineId: ownerProvenance.serverMachineId
        )
        for _ in 0..<2 {
            do {
                try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: false)
            } catch {
                let existing = readOwner(lockDir: lockDir)
                if let existing, existing.pid > 0, isProcessAlive(existing.pid) {
                    throw DaemonMachineLockConflictError(
                        lockDir: lockDir,
                        ownerDescription: "pid=\(existing.pid), startedAt=\(existing.startedAt), host=\(existing.hostname)"
                    )
                }
                if existing == nil, let age = lockAgeMs(lockDir: lockDir), age < incompleteLockStaleMs {
                    throw DaemonMachineLockConflictError(lockDir: lockDir, ownerDescription: "unknown owner")
                }
                try? FileManager.default.removeItem(atPath: lockDir)
                continue
            }
            do {
                try writeOwner(owner, to: (lockDir as NSString).appendingPathComponent("owner.json"))
            } catch {
                try? FileManager.default.removeItem(atPath: lockDir)
                throw error
            }
            return DaemonMachineLockHandle(lockId: lockId(apiKey: apiKey), machineDir: machineDir, lockDir: lockDir, token: token)
        }
        _ = owner
        throw DaemonMachineLockConflictError(
            lockDir: lockDir,
            ownerDescription: readOwner(lockDir: lockDir).map { "pid=\($0.pid)" } ?? "unknown owner"
        )
    }

    static func readOwner(lockDir: String) -> Owner? {
        let path = (lockDir as NSString).appendingPathComponent("owner.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let owner = try? JSONDecoder().decode(Owner.self, from: data) { return owner }
        // Older or partially-written owners carry only some fields; a pid of 0
        // still marks the lock released and must be reclaimable.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.intValue
        else { return nil }
        return Owner(
            pid: pid,
            token: object["token"] as? String ?? "",
            hostname: object["hostname"] as? String ?? "",
            startedAt: object["startedAt"] as? String ?? "",
            serverUrl: object["serverUrl"] as? String ?? "",
            apiKeyFingerprint: object["apiKeyFingerprint"] as? String ?? "",
            schemaVersion: (object["schemaVersion"] as? NSNumber)?.intValue ?? 2,
            kind: object["kind"] as? String ?? "legacy_raw_daemon",
            serverId: object["serverId"] as? String,
            serverMachineId: object["serverMachineId"] as? String
        )
    }

    static func writeOwner(_ owner: Owner, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(owner).write(to: URL(fileURLWithPath: path))
    }

    static func lockAgeMs(lockDir: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: lockDir),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Int(Date().timeIntervalSince(modified) * 1000)
    }

    static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Glibc)
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno != ESRCH
        #else
        return false
        #endif
    }
}
