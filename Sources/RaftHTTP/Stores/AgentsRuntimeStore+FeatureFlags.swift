import Foundation

extension AgentsRuntimeStore {
    /// The rollout decision of every requested flag as one snapshot.
    ///
    /// The retired handler evaluated the whole list while holding the directory
    /// lock, so a concurrent flag edit could not produce a torn answer; the
    /// list is one store critical section here.
    func evaluateFeatureFlags(
        keys: [String],
        userId: String,
        serverId: String?,
        platform: String?,
        client: FeatureFlagClientFacts
    ) -> [(key: String, enabled: Bool, reason: String)] {
        withState { state in
            keys.map { key in
                let result = Self.evaluate(
                    state: state, key: key, userId: userId,
                    serverId: serverId, platform: platform, client: client
                )
                return (key, result.enabled, result.reason)
            }
        }
    }

    /// One flag's decision: the kill switch, the enabled flag, then the user,
    /// platform, client and server rules in that order, then the default.
    func evaluateFeatureFlag(
        key: String,
        userId: String,
        serverId: String?,
        platform: String?,
        client: FeatureFlagClientFacts
    ) -> (enabled: Bool, reason: String) {
        withState { state in
            Self.evaluate(
                state: state, key: key, userId: userId,
                serverId: serverId, platform: platform, client: client
            )
        }
    }

    private static func rules(_ state: State, key: String, stage: String) -> [FeatureFlagRuleRecord] {
        state.featureFlagRuleRecords
            .filter { $0.key == key && $0.stage == stage }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private static func evaluate(
        state: State,
        key: String,
        userId: String,
        serverId: String?,
        platform: String?,
        client: FeatureFlagClientFacts
    ) -> (enabled: Bool, reason: String) {
        guard let flag = state.featureFlagRecords[key] else {
            return (false, "missing_flag")
        }
        if flag.killSwitch { return (false, "kill_switch") }
        if !flag.enabled { return (false, "flag_disabled") }
        if let rule = rules(state, key: key, stage: "user").first(where: { $0.values.contains(userId) }) {
            return (rule.decision == "allow", "user_rule")
        }
        if let platform,
           let rule = rules(state, key: key, stage: "platform").first(where: { $0.values.contains(platform) }) {
            return (rule.decision == "allow", "platform_rule")
        }
        if let serverId {
            for rule in rules(state, key: key, stage: "client") where rule.values.contains(serverId) {
                let hasConstraint = rule.clientOs != nil || rule.minClientBuild != nil || rule.clientBuildTypes != nil
                guard hasConstraint else { continue }
                if let clientOs = rule.clientOs {
                    guard let os = client.os, clientOs.contains(os) else { continue }
                }
                if let buildTypes = rule.clientBuildTypes {
                    guard let buildType = client.buildType, buildTypes.contains(buildType) else { continue }
                }
                if let minimum = rule.minClientBuild {
                    guard let buildNumber = client.buildNumber, buildNumber >= minimum else { continue }
                }
                return (rule.decision == "allow", "client_rule")
            }
        }
        if let serverId,
           let rule = rules(state, key: key, stage: "server").first(where: { $0.values.contains(serverId) }) {
            return (rule.decision == "allow", "server_rule")
        }
        return (flag.defaultEnabled, "default")
    }
}
