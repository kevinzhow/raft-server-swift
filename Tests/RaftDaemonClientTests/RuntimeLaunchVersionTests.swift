import Testing
import RaftDaemonClient

private func driver(_ probe: @escaping @Sendable () -> (available: Bool, version: String?)) -> RuntimeLaunchVersionDriver {
    RuntimeLaunchVersionDriver(
        id: "claude",
        launchVersionPolicy: .init(
            displayName: "Claude Code", knownBadVersions: ["2.1.59"], testedGoodVersion: "2.1.220", probe: probe
        )
    )
}

@Test func blocksOnlyTheExactProvenBadVersion() {
    let decision = RuntimeLaunchVersion.evaluate(driver: driver { (true, "2.1.59 (Claude Code)") })
    guard case .block(let message) = decision else { Issue.record("expected block"); return }
    #expect(message.contains("2.1.59"))
    #expect(message.contains("2.1.220 is known to work"))
}

@Test func warnsButAllowsUnprovenOlderVersions() {
    #expect(RuntimeLaunchVersion.evaluate(driver: driver { (true, "Claude Code 2.1.60") }) == .warn(
        reason: "below_tested_good",
        warning: "Claude Code CLI 2.1.60 is older than a field-tested working version, 2.1.220. Update Claude Code to the latest version if messages fail; starting anyway because this version is not known incompatible."
    ))
    if case .warn(let reason, _) = RuntimeLaunchVersion.evaluate(driver: driver { (true, "2.1.58 (Claude Code)") }) {
        #expect(reason == "below_tested_good")
    } else {
        Issue.record("expected warn")
    }
}

@Test func warnsButAllowsMissingAndUnparseableVersions() {
    for probe in [
        { (false, nil) }, {(true, nil)}, {(true, "Claude Code development build")}, {(true, "2.1.220-beta.1")},
    ] as [@Sendable () -> (available: Bool, version: String?)] {
        guard case .warn = RuntimeLaunchVersion.evaluate(driver: driver(probe)) else {
            Issue.record("expected warn")
            continue
        }
    }
}

@Test func allowsTheTestedRecommendationAndNewerVersions() {
    for version in ["2.1.220 (Claude Code)", "2.2.0", "3.0.0"] {
        guard case .compatible(let actual, let testedGood) = RuntimeLaunchVersion.evaluate(driver: driver { (true, version) }) else {
            Issue.record("expected compatible for \(version)")
            continue
        }
        #expect(actual == "2.1.220" || actual == "2.2.0" || actual == "3.0.0")
        #expect(testedGood == "2.1.220")
    }
}

@Test func isANoOpForRuntimesWithoutAPolicy() {
    #expect(RuntimeLaunchVersion.evaluate(driver: RuntimeLaunchVersionDriver(id: "builtin")) == .notConfigured)
}

@Test func reprobesEveryCreationSoAnInPlaceUpgradeUnlocks() {
    final class Counter: @unchecked Sendable { var count = 0 }
    let counter = Counter()
    let probe: @Sendable () -> (available: Bool, version: String?) = {
        counter.count += 1
        return counter.count == 1 ? (true, "2.1.59") : (true, "2.1.220")
    }
    let target = driver(probe)
    guard case .block = RuntimeLaunchVersion.evaluate(driver: target) else { Issue.record("expected block"); return }
    guard case .compatible = RuntimeLaunchVersion.evaluate(driver: target) else { Issue.record("expected compatible"); return }
    #expect(counter.count == 2)
}

@Test func enforceThrowsOnBlockAndReportsWarnings() {
    var warnings: [String] = []
    let blocked = RuntimeLaunchVersionDriver(
        id: "claude",
        launchVersionPolicy: .init(displayName: "Claude Code", knownBadVersions: ["2.1.59"], testedGoodVersion: "2.1.220", probe: { (true, "2.1.59") })
    )
    var threw = false
    do { _ = try RuntimeLaunchVersion.enforce(driver: blocked) { warnings.append($0) } } catch { threw = true }
    #expect(threw)
    let warned = RuntimeLaunchVersionDriver(
        id: "claude",
        launchVersionPolicy: .init(displayName: "Claude Code", knownBadVersions: ["2.1.59"], testedGoodVersion: "2.1.220", probe: { (true, "2.1.60") })
    )
    _ = try? RuntimeLaunchVersion.enforce(driver: warned) { warnings.append($0) }
    #expect(warnings.count == 1)
}
