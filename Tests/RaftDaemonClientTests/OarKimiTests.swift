import Foundation
import Testing
import RaftDaemonClient

private let base = (slot: "/fixture/kimi-home", version: "test", at: 1_785_662_400_000)  // 2026-08-01T20:00:00Z

private func project(_ snapshot: OarAccountUsageSnapshot) -> RuntimeAccountUsageAccount {
    OarAdapter.project(
        provider: .kimi, snapshot: snapshot, localAccountSlot: base.slot,
        collectorVersion: base.version, observedAtMs: base.at
    ).accounts[0]
}

private func serialized(_ account: RuntimeAccountUsageAccount) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [
        "accountKey": account.accountKey,
        "maskedLabel": account.maskedLabel as Any,
        "planLabel": account.planLabel as Any,
        "displayName": account.displayName as Any,
        "health": account.health.rawValue,
        "windows": account.windows.map { ["status": $0.status, "label": $0.label] },
    ]), as: UTF8.self)
}

@Test func kimiWindowsPreservePercentagesResetsAndMaskedIdentity() {
    let resetsAt = "2026-08-08T20:00:00.000Z"
    let account = project(.init(
        kind: .available, email: "alpha@example.com", plan: "Moderato",
        windows: [
            .init(label: "Weekly limit", usedRatio: 0.4, resetsAt: resetsAt),
            .init(label: "5h limit", usedRatio: 0.48, resetsAt: resetsAt),
        ]
    ))
    #expect(account.maskedLabel == "a****@example.com")
    #expect(account.planLabel == "Moderato")
    #expect(account.windows.map { [$0.label, String($0.usedRatio ?? -1), $0.resetsAt ?? ""] } == [
        ["Weekly limit", "0.4", resetsAt],
        ["5h limit", "0.48", resetsAt],
    ])
    #expect(!serialized(account).contains("alpha@example.com"))
}

@Test func phoneSignInsWithoutAnEmailUseTheProfileNickname() {
    let account = project(.init(
        kind: .available, plan: "Max", displayName: " 登月者8387 ",
        rateLimited: true, windows: [.init(label: "5h limit", usedRatio: 1)]
    ))
    #expect(account.maskedLabel == nil)
    #expect(account.displayName == "登月者8387")
    #expect(account.planLabel == "Max")
}

@Test func anAccountIdentifiedByMaskedEmailNeverCarriesDisplayName() {
    let account = project(.init(
        kind: .available, email: "alpha@example.com", displayName: "登月者8387",
        windows: [.init(label: "Weekly limit", usedRatio: 0.4)]
    ))
    #expect(account.maskedLabel == "a****@example.com")
    #expect(account.displayName == nil)
}

@Test func extraUsageHeadroomKeepsHealthEvenWhenASubscriptionWindowIsFull() {
    let account = project(.init(
        kind: .available,
        windows: [
            .init(label: "Weekly limit", usedRatio: 1),
            .init(label: "Extra Usage monthly limit", usedRatio: 0.25),
        ]
    ))
    #expect(account.health == .ok)
    #expect(account.windows[0].status == "limit_reached")
    #expect(account.windows[1].usedRatio == 0.25)
    #expect(account.windows[1].status == "ok")
    #expect(account.windows[1].resetsAt == nil)
}

@Test func theSameProviderSlotIdentityIsUsedForSuccessAndFailure() {
    let expected = OarAdapter.sha256Hex("kimi" + "\u{0000}" + base.slot)
    for kind in [OarSnapshotKind.available, .reauthRequired, .unsupported] {
        let snapshot = kind == .available
            ? OarAccountUsageSnapshot(kind: kind, rateLimited: true, windows: [.init(label: "Weekly limit", usedRatio: 1)])
            : OarAccountUsageSnapshot(kind: kind)
        let account = project(snapshot)
        #expect(account.accountKey == expected)
        if kind == .available {
            #expect(account.health == .rateLimited)
        } else {
            #expect(account.health == (kind == .reauthRequired ? .reauthRequired : .unsupported))
            #expect(account.windows == [])
        }
    }
}

@Test func percentageWithoutAResetIsUsable() {
    let account = project(.init(kind: .available, windows: [.init(label: "Weekly limit", usedRatio: 0.25)]))
    #expect(account.windows[0].status == "ok")
    #expect(account.windows[0].usedRatio == 0.25)
    #expect(account.windows[0].resetsAt == nil)
    #expect(account.parseErrorCode == nil)
}

private func collectorRuntime(
    installation: @escaping @Sendable () async throws -> OarInstallation,
    usage: @escaping @Sendable (OarInstallation) async throws -> OarAccountUsageSnapshot,
    seen: Seen
) -> OarRuntimeAdapter {
    OarRuntimeAdapter(
        installation: {
            seen.probeCalls += 1
            return try await installation()
        },
        accountUsage: { given, _ in
            seen.readerGot.append(given)
            return try await usage(given)
        }
    )
}

private final class Seen: @unchecked Sendable {
    var probeCalls = 0
    var readerGot: [OarInstallation] = []
}

private final class Queue: @unchecked Sendable {
    var results: [OarAccountUsageSnapshot]
    init(_ results: [OarAccountUsageSnapshot]) { self.results = results }
    func next() -> OarAccountUsageSnapshot { results.removeFirst() }
}

@Test func theCollectorUsesTheRuntimeBoundaryAndClassifiesTypedFailures() async {
    let installation = OarInstallation(kind: "available", command: "/fixture/kimi")
    let seen = Seen()
    let results = Queue([
        .init(kind: .available, windows: [.init(label: "Weekly limit", usedRatio: 0.4)]),
        .init(kind: .reauthRequired),
        .init(kind: .unsupported),
    ])
    let runtime = OarRuntimeAdapter(
        installation: { seen.probeCalls += 1; return installation },
        accountUsage: { given, _ in
            seen.readerGot.append(given)
            return results.next()
        }
    )
    let collector = RuntimeAccountUsageCollector.createCollector(
        localAccountSlot: base.slot, collectorVersion: base.version, now: { base.at }, oar: .init(runtime: runtime)
    )
    for expected in [RuntimeAccountUsageHealth.ok, .reauthRequired, .unsupported] {
        let result = await collector(.kimi)
        #expect(result.accounts.first?.health == expected)
    }
    #expect(seen.probeCalls == 3)
    #expect(seen.readerGot.first === installation)
}

@Test func kimiWithoutAnInstallationHasNoInventedUsageAndNeverReads() async {
    let seen = Seen()
    let runtime = collectorRuntime(
        installation: { OarInstallation(kind: "not_found") },
        usage: { _ in .init(kind: .unsupported) },
        seen: seen
    )
    let result = await RuntimeAccountUsageCollector.read(
        provider: .kimi, localAccountSlot: base.slot, collectorVersion: base.version,
        observedAtMs: base.at, deps: .init(runtime: runtime)
    )
    #expect(result.accounts.first?.health == .unsupported)
    #expect(result.accounts.first?.windows == [])
    #expect(seen.readerGot.isEmpty)
}

@Test func unrelatedFailuresRemainErrorsInsteadOfSendingUsersThroughLogin() async {
    let seen = Seen()
    let runtime = collectorRuntime(
        installation: { OarInstallation(kind: "available", command: "/fixture/kimi") },
        usage: { _ in throw NSError(domain: "secret-provider-message", code: 1) },
        seen: seen
    )
    let result = await RuntimeAccountUsageCollector.read(
        provider: .kimi, localAccountSlot: base.slot, collectorVersion: base.version,
        observedAtMs: base.at, deps: .init(runtime: runtime)
    )
    #expect(result.accounts.first?.health == .error)
    #expect(result.accounts.first?.windows == [])
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: result.jsonObject()), as: UTF8.self)
    #expect(!json.contains("secret-provider-message"))
}
