import Foundation

/// Detects the legacy daemon supervisor (PM2, systemd, launchd) that is still
/// running this daemon and returns exact cleanup guidance, so migration off the
/// legacy install does not leave a supervisor restarting it. Ported from the
/// upstream daemon helper; probes are injectable for deterministic tests.
public struct LegacyDaemonSupervisorProbe: Sendable {
    public var pid: Int
    public var platform: String
    public var env: [String: String]
    public var execFile: @Sendable (String, [String]) -> String?
    public var readFile: @Sendable (String) -> String?
    public init(
        pid: Int, platform: String, env: [String: String],
        execFile: @escaping @Sendable (String, [String]) -> String?,
        readFile: @escaping @Sendable (String) -> String?
    ) {
        self.pid = pid
        self.platform = platform
        self.env = env
        self.execFile = execFile
        self.readFile = readFile
    }
}

public enum LegacySupervisor {
    public static let fallbackCommands = LegacyDaemonSupervisorFallbacks.commands

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func parentPid(_ probe: LegacyDaemonSupervisorProbe, _ pid: Int) -> Int? {
        guard let stdout = probe.execFile("ps", ["-o", "ppid=", "-p", String(pid)]),
              let parsed = Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0
        else { return nil }
        return parsed
    }

    static func processCommand(_ probe: LegacyDaemonSupervisorProbe, _ pid: Int) -> String {
        (probe.execFile("ps", ["-o", "command=", "-p", String(pid)]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func relatedProcessIds(_ probe: LegacyDaemonSupervisorProbe) -> [Int] {
        var ids = [probe.pid]
        var current = probe.pid
        for _ in 0..<12 {
            guard let parent = parentPid(probe, current), !ids.contains(parent) else { break }
            ids.append(parent)
            if parent == 1 { break }
            current = parent
        }
        return ids
    }

    static func detectPm2(
        _ probe: LegacyDaemonSupervisorProbe, _ relatedPids: [Int]
    ) -> LegacyDaemonSupervisorGuidance? {
        let hasPm2Ancestor = relatedPids.dropFirst().contains { processCommand(probe, $0).contains("pm2") }
        let hasPm2Environment = probe.env["PM2_HOME"] != nil || probe.env["pm_id"] != nil
        guard hasPm2Ancestor || hasPm2Environment else { return nil }
        if let pm2Json = probe.execFile("pm2", ["jlist"]),
           let data = pm2Json.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let entry = entries.first(where: { entry in
               guard let pid = entry["pid"] as? NSNumber else { return false }
               return relatedPids.contains(pid.intValue)
           }) {
            let rawName = entry["name"] as? String
            let name = (rawName?.isEmpty == false) ? rawName! : String((entry["pid"] as? NSNumber)?.intValue ?? 0)
            return LegacyDaemonSupervisorGuidance(
                kind: "pm2",
                cleanupCommands: ["pm2 delete \(shellQuote(name))", "pm2 save"],
                detail: "PM2 app \(encodeJSON(name)) is supervising this legacy daemon."
            )
        }
        return LegacyDaemonSupervisorGuidance(
            kind: "pm2",
            cleanupCommands: ["pm2 delete <legacy-daemon-app-name>", "pm2 save"],
            detail: "PM2 is supervising this legacy daemon, but its app name could not be resolved."
        )
    }

    static func encodeJSON(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[]".utf8)
        let serialized = String(decoding: data, as: UTF8.self)
        return String(serialized.dropFirst().dropLast())
    }

    static func systemdUnitFromCgroup(_ cgroup: String?) -> (unit: String, user: Bool)? {
        guard let cgroup else { return nil }
        for line in cgroup.components(separatedBy: "\n") {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let pathPart = String(line[line.index(after: colon)...])
            var unit: String?
            for segment in pathPart.components(separatedBy: "/") {
                if segment.hasSuffix(".service"), segment.count > ".service".count,
                   segment.range(of: #"^user@\d+\.service$"#, options: .regularExpression) == nil {
                    unit = segment
                }
            }
            if let unit { return (unit, pathPart.contains("/user.slice/")) }
        }
        return nil
    }

    static func detectSystemd(_ probe: LegacyDaemonSupervisorProbe) -> LegacyDaemonSupervisorGuidance? {
        guard probe.platform == "linux" else { return nil }
        let cgroupUnit = systemdUnitFromCgroup(probe.readFile("/proc/\(probe.pid)/cgroup"))
        guard cgroupUnit != nil || probe.env["INVOCATION_ID"] != nil else { return nil }
        if let cgroupUnit {
            let prefix = cgroupUnit.user ? "systemctl --user" : "sudo systemctl"
            return LegacyDaemonSupervisorGuidance(
                kind: "systemd",
                cleanupCommands: ["\(prefix) disable --now \(shellQuote(cgroupUnit.unit))"],
                detail: "systemd unit \(encodeJSON(cgroupUnit.unit)) is supervising this legacy daemon."
            )
        }
        return LegacyDaemonSupervisorGuidance(
            kind: "systemd",
            cleanupCommands: ["systemctl --user disable --now <legacy-daemon-unit>.service"],
            detail: "systemd is supervising this legacy daemon, but its unit name could not be resolved."
        )
    }

    static func detectLaunchd(_ probe: LegacyDaemonSupervisorProbe) -> LegacyDaemonSupervisorGuidance? {
        guard probe.platform == "darwin" else { return nil }
        let label = probe.env["LAUNCH_JOBKEY_LABEL"] ?? probe.env["XPC_SERVICE_NAME"]
        guard let label, !label.isEmpty, label != "0" else { return nil }
        return LegacyDaemonSupervisorGuidance(
            kind: "launchd",
            cleanupCommands: [
                "launchctl bootout gui/$(id -u)/\(shellQuote(label))",
                "rm -f ~/Library/LaunchAgents/\(shellQuote(label + ".plist"))",
            ],
            detail: "launchd job \(encodeJSON(label)) is supervising this legacy daemon."
        )
    }

    /// Injectable probe seam for deterministic tests; production callers pass a pid.
    public static func detect(_ probe: LegacyDaemonSupervisorProbe) -> LegacyDaemonSupervisorGuidance? {
        let relatedPids = relatedProcessIds(probe)
        return detectPm2(probe, relatedPids) ?? detectSystemd(probe) ?? detectLaunchd(probe)
    }
}
