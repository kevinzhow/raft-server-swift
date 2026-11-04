import Foundation
import Testing
import RaftDaemonClient

private let observedAtMs = 1_787_936_400_000  // 2026-08-26T09:00:00Z
private let base = (slot: "/home/agent/.slock", version: "1.0.19")

private func project(_ snapshot: OarAccountUsageSnapshot) -> RuntimeAccountUsageSnapshot {
    OarAdapter.project(
        provider: .codex, snapshot: snapshot, localAccountSlot: base.slot,
        collectorVersion: base.version, observedAtMs: observedAtMs
    )
}

private func serialized(_ snapshot: RuntimeAccountUsageSnapshot) -> String {
    let data = try! JSONSerialization.data(withJSONObject: snapshot.jsonObject(), options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

@Test func rawEmailNeverReachesTheSnapshot() {
    let snapshot = project(.init(
        kind: .available, email: "someone@example.com",
        windows: [.init(label: "7 days", usedRatio: 0.5)]
    ))
    #expect(!serialized(snapshot).contains("someone@example.com"))
    let label = try? #require(snapshot.accounts.first?.maskedLabel)
    #expect(label?.contains("*") == true, "masked label must carry an explicit mask marker")
}

@Test func unmaskableEmailIsDroppedRatherThanPassedThrough() {
    let snapshot = project(.init(
        kind: .available, email: "not-an-email",
        windows: [.init(label: "7 days", usedRatio: 0.1)]
    ))
    #expect(snapshot.accounts.first?.maskedLabel == nil)
    #expect(!serialized(snapshot).contains("not-an-email"))
}

@Test func failedReadIsAnErrorAccountWithNoWindows() {
    let snapshot = OarAdapter.failure(
        provider: .codex, localAccountSlot: base.slot,
        collectorVersion: base.version, observedAtMs: observedAtMs
    )
    #expect(snapshot.accounts.first?.health == .error)
    #expect(snapshot.accounts.first?.windows == [])
    #expect(!serialized(snapshot).contains("usedRatio"), "a failure must not carry a usedRatio in any form")
}

@Test func unsupportedAndReauthCarryNoWindows() {
    for kind in [OarSnapshotKind.unsupported, .reauthRequired] {
        let snapshot = project(.init(kind: kind))
        #expect(snapshot.accounts.first?.health == (kind == .unsupported ? .unsupported : .reauthRequired))
        #expect(snapshot.accounts.first?.windows == [])
        #expect(!serialized(snapshot).contains("usedRatio"))
    }
}

@Test func outOfRangeRatioBecomesParseUnavailableAndIsNeverClamped() {
    let snapshot = project(.init(
        kind: .available,
        windows: [.init(label: "bad", usedRatio: 42), .init(label: "also bad", usedRatio: .nan)]
    ))
    let windows = snapshot.accounts.first?.windows ?? []
    #expect(windows.count == 2)
    for window in windows {
        #expect(window.status == "parse_unavailable")
        #expect(window.usedRatio == nil, "an unreadable ratio must not be reported as a number")
    }
    #expect(snapshot.accounts.first?.parseErrorCode == "oar_window_ratio_unreadable")
}

@Test func rateLimitedMapsToHealthAndFullWindowToLimitReached() {
    let snapshot = project(.init(
        kind: .available, rateLimited: true,
        windows: [.init(label: "7 days", usedRatio: 1, resetsAt: "2026-08-27T00:00:00.000Z")]
    ))
    #expect(snapshot.accounts.first?.health == .rateLimited)
    #expect(snapshot.accounts.first?.windows.first?.status == "limit_reached")
    #expect(snapshot.accounts.first?.windows.first?.resetsAt == "2026-08-27T00:00:00.000Z")
}

@Test func accountKeyIsProviderScopedAndDoesNotRevealTheLocalSlot() {
    for provider in [RuntimeAccountUsageProvider.codex, .claude, .kimi] {
        let expected = OarAdapter.sha256Hex(provider.rawValue + "\u{0000}" + base.slot)
        let snapshot = OarAdapter.project(
            provider: provider, snapshot: .init(kind: .unsupported), localAccountSlot: base.slot,
            collectorVersion: base.version, observedAtMs: observedAtMs
        )
        #expect(snapshot.accounts.first?.accountKey == expected)
        #expect(!(snapshot.accounts.first?.accountKey.contains(base.slot) ?? false))
    }
}

@Test func snapshotAtTheWindowCeilingIsValid() {
    let snapshot = project(.init(
        kind: .available, windows: (0..<12).map { OarWindow(label: "Window \($0)", usedRatio: 0.1) }
    ))
    #expect(snapshot.accounts.first?.windows.count == 12)
    #expect(snapshot.accounts.first?.health == .ok)
}

@Test func snapshotAboveTheWindowCeilingIsAnExplicitError() {
    let snapshot = project(.init(
        kind: .available, windows: (0..<13).map { OarWindow(label: "Window \($0)", usedRatio: 0.1) }
    ))
    #expect(snapshot.accounts.first?.health == .error)
    #expect(snapshot.accounts.first?.windows == [], "no window may survive an overflow")
    #expect(!serialized(snapshot).contains("usedRatio"), "an overflowed reading must not carry any usedRatio")
}
