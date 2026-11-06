import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func createFeatureFlagForTesting(
        key: String,
        defaultEnabled: Bool = false,
        enabled: Bool = true,
        killSwitch: Bool = false
    ) {
        agentsRuntimeStore.withState { owned in
            owned.featureFlagRecords[key] = FeatureFlagRecord(
                key: key,
                enabled: enabled,
                killSwitch: killSwitch,
                defaultEnabled: defaultEnabled
            )
        }
    }

    public func addFeatureFlagRuleForTesting(
        key: String,
        stage: String,
        decision: String,
        values: [String],
        clientOs: [String]? = nil,
        minClientBuild: Int? = nil,
        clientBuildTypes: [String]? = nil,
        priority: Int = 0
    ) {
        agentsRuntimeStore.withState { owned in
            owned.featureFlagRuleRecords.append(FeatureFlagRuleRecord(
                key: key,
                stage: stage,
                decision: decision,
                values: values,
                clientOs: clientOs,
                minClientBuild: minClientBuild,
                clientBuildTypes: clientBuildTypes,
                priority: priority
            ))
        }
    }

    public func setFeatureFlagDefaultForTesting(key: String, defaultEnabled: Bool) {
        agentsRuntimeStore.withState { owned in
            owned.featureFlagRecords[key]?.defaultEnabled = defaultEnabled
        }
    }

    public func setFeatureFlagKillSwitchForTesting(key: String, killSwitch: Bool) {
        agentsRuntimeStore.withState { owned in
            owned.featureFlagRecords[key]?.killSwitch = killSwitch
        }
    }
}
