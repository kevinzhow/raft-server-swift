import Crypto
import Foundation

/// "Several Computers on one physical machine", per server: the hardware ID
/// never leaves the machine; the server only sees
/// HMAC(key: hardwareId, "raft-host-id-v1:" + serverId). Ported from the
/// upstream daemon host identity module.
public enum HostIdentity {
    static let hostIdDomain = "raft-host-id-v1:"
    static let hostIdHashChars = 32

    public static func hostIdHashForServer(hardwareId: String, serverId: String) -> String {
        let key = SymmetricKey(data: Data(hardwareId.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(hostIdDomain)\(serverId)".utf8),
            using: key
        )
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(hostIdHashChars))
    }

    /// Accept only something that looks like a real machine ID (>= 16 hex
    /// digits once dashes are dropped); all-zero values are placeholders.
    public static func normalizeHardwareId(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        guard value.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil else { return nil }
        guard value.range(of: "^0+$", options: .regularExpression) == nil else { return nil }
        return value
    }

    /// `ioreg -rd1 -c IOPlatformExpertDevice` -> IOPlatformUUID.
    public static func parseIoregPlatformUuid(_ output: String) -> String? {
        firstMatch(#""IOPlatformUUID"\s*=\s*"([^"]+)""#, in: output)
    }

    /// `reg query HKLM\SOFTWARE\Microsoft\Cryptography /v MachineGuid` -> GUID.
    public static func parseRegMachineGuid(_ output: String) -> String? {
        firstMatch(#"MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]+)"#, in: output)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    /// Injectable IO so platform discovery stays testable without spawning.
    public struct HardwareIdIo: Sendable {
        public var readFile: @Sendable (String) -> String?
        public var run: @Sendable (String, [String]) async -> String?

        public init(
            readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
            run: @escaping @Sendable (String, [String]) async -> String? = { _, _ in nil }
        ) {
            self.readFile = readFile
            self.run = run
        }
    }

    public static func readHardwareId(platform: String = "linux", io: HardwareIdIo = HardwareIdIo()) async -> String? {
        if platform == "linux" {
            return normalizeHardwareId(io.readFile("/etc/machine-id"))
                ?? normalizeHardwareId(io.readFile("/var/lib/dbus/machine-id"))
        }
        if platform == "darwin" {
            let output = await io.run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"])
            return normalizeHardwareId(output.flatMap(parseIoregPlatformUuid))
        }
        if platform == "win32" {
            let output = await io.run("reg", ["query", "HKLM\\SOFTWARE\\Microsoft\\Cryptography", "/v", "MachineGuid"])
            return normalizeHardwareId(output.flatMap(parseRegMachineGuid))
        }
        return nil
    }

    private actor Cache {
        var cached: Task<String?, Never>?
        func value(_ build: @escaping @Sendable () async -> String?) async -> String? {
            if let cached { return await cached.value }
            let task = Task { await build() }
            cached = task
            return await task.value
        }
    }

    private static let cache = Cache()

    /// This machine's hash for one server; nil when the hardware ID can't be read.
    public static func hostIdHash(serverId: String) async -> String? {
        let hardwareId = await cache.value { await readHardwareId() }
        guard let hardwareId else { return nil }
        return hostIdHashForServer(hardwareId: hardwareId, serverId: serverId)
    }
}
