import Foundation

/// Which runtime CLI version this Computer detected last, kept across restarts
/// so a restart that quietly picks a different CLI is visible. Every change is
/// a trace-worthy observation; a downgrade is also a notice that status shows
/// until a later detection is back at or above the version it fell from.
/// Ported from the upstream daemon tracker.
public struct RuntimeCliDowngrade: Sendable, Equatable {
    public var from: String
    public var to: String
    public var at: String
    public init(from: String, to: String, at: String) {
        self.from = from
        self.to = to
        self.at = at
    }
}

public struct RuntimeCliVersionState: Sendable, Equatable {
    public var schemaVersion = 1
    public var versions: [String: String] = [:]
    public var downgrades: [String: RuntimeCliDowngrade] = [:]
    public init() {}
}

public struct RuntimeCliVersionChange: Sendable, Equatable {
    public var runtime: String
    public var from: String
    public var to: String
    public var direction: String
    public init(runtime: String, from: String, to: String, direction: String) {
        self.runtime = runtime
        self.from = from
        self.to = to
        self.direction = direction
    }
}

public enum RuntimeCliVersionTracker {
    public static let fileName = "runtime-cli-versions.json"

    public static func path(slockHome: String) -> String {
        slockHome + "/computer/" + fileName
    }

    static func versionNumbers(_ version: String) -> [Int]? {
        guard let range = version.range(of: #"\d+(?:\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(version[range]).split(separator: ".").compactMap { Int($0) }
    }

    public static func compare(_ a: String, _ b: String) -> Int? {
        guard let left = versionNumbers(a), let right = versionNumbers(b) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let diff = (index < left.count ? left[index] : 0) - (index < right.count ? right[index] : 0)
            if diff != 0 { return diff }
        }
        return 0
    }

    /// Pure comparison of a detection with the recorded state. A runtime not
    /// detected this round keeps its record; a downgrade notice clears once the
    /// detected version is back at or above the version it fell from.
    public static func observe(
        state: RuntimeCliVersionState,
        detected: [String: String],
        now: Date
    ) -> (changes: [RuntimeCliVersionChange], next: RuntimeCliVersionState) {
        var changes: [RuntimeCliVersionChange] = []
        var next = state
        for runtime in detected.keys.sorted() {
            let to = detected[runtime] ?? ""
            if to.isEmpty { continue }
            let from = next.versions[runtime]
            next.versions[runtime] = to
            let notice = next.downgrades[runtime]
            if let notice, (compare(to, notice.from) ?? -1) >= 0 {
                next.downgrades[runtime] = nil
            }
            guard let from, from != to else { continue }
            let comparison = compare(to, from)
            let direction: String
            if let comparison {
                direction = comparison > 0 ? "upgrade" : comparison < 0 ? "downgrade" : "changed"
            } else {
                direction = "changed"
            }
            changes.append(RuntimeCliVersionChange(runtime: runtime, from: from, to: to, direction: direction))
            if direction == "downgrade" {
                // Keep the version it first fell from, so a second step down still points at the good one.
                next.downgrades[runtime] = RuntimeCliDowngrade(
                    from: notice?.from ?? from, to: to, at: isoString(now)
                )
            }
        }
        return (changes, next)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func readState(slockHome: String) -> RuntimeCliVersionState {
        guard let data = FileManager.default.contents(atPath: path(slockHome: slockHome)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["schemaVersion"] as? NSNumber)?.intValue == 1
        else { return RuntimeCliVersionState() }
        var state = RuntimeCliVersionState()
        if let versions = object["versions"] as? [String: String] {
            state.versions = versions
        }
        if let raw = object["downgrades"] as? [String: [String: Any]] {
            for (runtime, value) in raw {
                guard let from = value["from"] as? String,
                      let to = value["to"] as? String,
                      let at = value["at"] as? String
                else { continue }
                state.downgrades[runtime] = RuntimeCliDowngrade(from: from, to: to, at: at)
            }
        }
        return state
    }

    public static func writeState(slockHome: String, state: RuntimeCliVersionState) throws {
        let file = path(slockHome: slockHome)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var downgrades: [String: Any] = [:]
        for (runtime, value) in state.downgrades {
            downgrades[runtime] = ["from": value.from, "to": value.to, "at": value.at]
        }
        let object: [String: Any] = [
            "schemaVersion": 1,
            "versions": state.versions,
            "downgrades": downgrades,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
}
