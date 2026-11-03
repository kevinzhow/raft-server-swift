import Foundation

/// Launch-time runtime CLI version policy: block only versions proven bad,
/// warn but allow unproven-but-older ones, and never invent a hard floor below
/// the tested-good version. Ported from the upstream daemon helper.
public struct RuntimeLaunchVersionPolicy: Sendable {
    public var displayName: String
    public var knownBadVersions: [String]
    public var testedGoodVersion: String
    public var probe: @Sendable () -> (available: Bool, version: String?)
    public init(
        displayName: String, knownBadVersions: [String], testedGoodVersion: String,
        probe: @escaping @Sendable () -> (available: Bool, version: String?)
    ) {
        self.displayName = displayName
        self.knownBadVersions = knownBadVersions
        self.testedGoodVersion = testedGoodVersion
        self.probe = probe
    }
}

public struct RuntimeLaunchVersionDriver: Sendable {
    public var id: String
    public var launchVersionPolicy: RuntimeLaunchVersionPolicy?
    public init(id: String, launchVersionPolicy: RuntimeLaunchVersionPolicy? = nil) {
        self.id = id
        self.launchVersionPolicy = launchVersionPolicy
    }
}

public enum RuntimeLaunchVersionDecision: Equatable, Sendable {
    case notConfigured
    case compatible(actualVersion: String, testedGoodVersion: String)
    case warn(reason: String, warning: String)
    case block(message: String)
}

public enum RuntimeLaunchVersion {
    static let versionTriple = try! NSRegularExpression(
        pattern: #"(?:^|[^0-9A-Za-z+.-])(\d+)\.(\d+)\.(\d+)(?=$|[^0-9A-Za-z+.-])"#
    )

    struct ComparableVersion: Equatable, Comparable, Sendable {
        var normalized: String
        var parts: [Int]
        static func < (lhs: ComparableVersion, rhs: ComparableVersion) -> Bool {
            for index in 0..<3 {
                if lhs.parts[index] != rhs.parts[index] { return lhs.parts[index] < rhs.parts[index] }
            }
            return false
        }
    }

    static func parse(_ value: String) -> ComparableVersion? {
        let range = NSRange(location: 0, length: (value as NSString).length)
        guard let match = versionTriple.firstMatch(in: value, range: range), match.numberOfRanges == 4 else { return nil }
        let parts = (1...3).map { Int((value as NSString).substring(with: match.range(at: $0))) ?? 0 }
        return ComparableVersion(normalized: parts.map(String.init).joined(separator: "."), parts: parts)
    }

    public static func evaluate(driver: RuntimeLaunchVersionDriver) -> RuntimeLaunchVersionDecision {
        guard let policy = driver.launchVersionPolicy else { return .notConfigured }
        guard let testedGood = parse(policy.testedGoodVersion) else {
            return .warn(reason: "invalid_policy", warning: "Invalid tested-good runtime version policy for \(driver.id)")
        }
        let probe = policy.probe()
        guard probe.available, let version = probe.version else {
            return .warn(
                reason: "version_unavailable",
                warning: "Raft could not verify the \(policy.displayName) CLI version. "
                    + "Update \(policy.displayName) to the latest version if startup fails; \(policy.displayName) \(testedGood.normalized) is known to work. Starting anyway."
            )
        }
        guard let actual = parse(version) else {
            return .warn(
                reason: "version_unparseable",
                warning: "Raft could not compare the \(policy.displayName) CLI version. "
                    + "Update \(policy.displayName) to the latest version if startup fails; \(policy.displayName) \(testedGood.normalized) is known to work. Starting anyway."
            )
        }
        let knownBad = Set(policy.knownBadVersions.compactMap { parse($0)?.normalized })
        if knownBad.contains(actual.normalized) {
            let message = "\(policy.displayName) CLI \(actual.normalized) is known incompatible with this Raft runtime. "
                + "Update \(policy.displayName) to the latest version before starting the agent; \(policy.displayName) \(testedGood.normalized) is known to work."
            return .block(message: message)
        }
        if actual < testedGood {
            return .warn(
                reason: "below_tested_good",
                warning: "\(policy.displayName) CLI \(actual.normalized) is older than a field-tested working version, \(testedGood.normalized). "
                    + "Update \(policy.displayName) to the latest version if messages fail; starting anyway because this version is not known incompatible."
            )
        }
        return .compatible(actualVersion: actual.normalized, testedGoodVersion: testedGood.normalized)
    }

    public static func enforce(
        driver: RuntimeLaunchVersionDriver,
        onWarning: (String) -> Void
    ) throws -> RuntimeLaunchVersionDecision {
        let decision = evaluate(driver: driver)
        if case .block(let message) = decision { throw RuntimeLaunchVersionBlocked(message: message) }
        if case .warn(_, let warning) = decision { onWarning(warning) }
        return decision
    }
}

public struct RuntimeLaunchVersionBlocked: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}
