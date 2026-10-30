import Foundation

/// `GET /api/public/feature-flags` from `routes/publicFeatureFlags.ts`.
///
/// There is no user and no server. Only flags marked pre-auth evaluable answer,
/// and only from the kill switch, the enabled bit, platform rules, and the
/// default. Every other key is false. Credentials are ignored, so one URL has
/// one cacheable answer.

public struct PublicFeatureFlagRule: Equatable, Sendable {
    public var stage: String
    public var decision: String
    public var values: [String]
    public var priority: Int
    public var createdAtMs: Int

    public init(stage: String, decision: String, values: [String], priority: Int = 0, createdAtMs: Int = 0) {
        self.stage = stage
        self.decision = decision
        self.values = values
        self.priority = priority
        self.createdAtMs = createdAtMs
    }
}

public struct PublicFeatureFlag: Equatable, Sendable {
    public var key: String
    public var enabled: Bool
    public var killSwitch: Bool
    public var defaultEnabled: Bool
    public var preAuthEvaluable: Bool
    public var rules: [PublicFeatureFlagRule]

    public init(
        key: String,
        enabled: Bool = true,
        killSwitch: Bool = false,
        defaultEnabled: Bool = false,
        preAuthEvaluable: Bool = false,
        rules: [PublicFeatureFlagRule] = []
    ) {
        self.key = key
        self.enabled = enabled
        self.killSwitch = killSwitch
        self.defaultEnabled = defaultEnabled
        self.preAuthEvaluable = preAuthEvaluable
        self.rules = rules
    }
}

public enum PublicFeatureFlags {
    public static let maxKeys = 50

    public static func reply(keysQuery: String?, platformQuery: String?, flags: [PublicFeatureFlag]) -> HTTPReply {
        let keys: [String]
        if let keysQuery {
            keys = keysQuery.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            keys = []
        }
        if keys.isEmpty || keys.count > maxKeys || keys.contains(where: { !isValidKey($0) }) {
            return error("keys must contain 1-\(maxKeys) valid feature flag keys")
        }
        if let platformQuery, platformQuery != "web", platformQuery != "mobile" {
            return error("platform must be web or mobile")
        }
        let evaluated = evaluate(keys: keys, platform: platformQuery, flags: flags)
        let pairs = evaluated.map { "\(jsonString($0.key)):\($0.enabled ? "true" : "false")" }
        let body = "{\"flags\":{\(pairs.joined(separator: ","))}}"
        return HTTPReply(
            status: 200,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "public, max-age=60",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    /// Before-login evaluation. Platform rules are the only rules that can flip
    /// a marked flag; a missing platform uses the default.
    public static func evaluate(keys: [String], platform: String?, flags: [PublicFeatureFlag]) -> [(key: String, enabled: Bool)] {
        var unique: [String] = []
        var seen = Set<String>()
        for key in keys where seen.insert(key).inserted {
            unique.append(key)
        }
        let byKey = Dictionary(flags.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        return unique.map { key in
            guard let flag = byKey[key], flag.preAuthEvaluable, !flag.killSwitch, flag.enabled else {
                return (key, false)
            }
            if let platform, let rule = platformRule(flag, matching: platform) {
                return (key, rule.decision == "allow")
            }
            return (key, flag.defaultEnabled)
        }
    }

    private static func platformRule(_ flag: PublicFeatureFlag, matching platform: String) -> PublicFeatureFlagRule? {
        flag.rules
            .filter { $0.stage == "platform" }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.createdAtMs < rhs.createdAtMs
            }
            .first { $0.values.contains(platform) }
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_.-]{0,127}$") else { return false }
        let range = NSRange(key.startIndex..., in: key)
        guard let match = expression.firstMatch(in: key, range: range) else { return false }
        return match.range.location == 0 && match.range.length == range.length
    }

    private static func error(_ message: String) -> HTTPReply {
        let body = "{\"error\":\(jsonString(message))}"
        return HTTPReply(
            status: 400,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }
}
