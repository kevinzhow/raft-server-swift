import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func createFeatureFlagForTesting(
        key: String,
        defaultEnabled: Bool = false,
        enabled: Bool = true,
        killSwitch: Bool = false
    ) {
        lock.lock()
        featureFlagRecords[key] = FeatureFlagRecord(
            key: key,
            enabled: enabled,
            killSwitch: killSwitch,
            defaultEnabled: defaultEnabled
        )
        lock.unlock()
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
        lock.lock()
        featureFlagRuleRecords.append(FeatureFlagRuleRecord(
            key: key,
            stage: stage,
            decision: decision,
            values: values,
            clientOs: clientOs,
            minClientBuild: minClientBuild,
            clientBuildTypes: clientBuildTypes,
            priority: priority
        ))
        lock.unlock()
    }

    public func setFeatureFlagDefaultForTesting(key: String, defaultEnabled: Bool) {
        lock.lock()
        featureFlagRecords[key]?.defaultEnabled = defaultEnabled
        lock.unlock()
    }

    public func setFeatureFlagKillSwitchForTesting(key: String, killSwitch: Bool) {
        lock.lock()
        featureFlagRecords[key]?.killSwitch = killSwitch
        lock.unlock()
    }
}
