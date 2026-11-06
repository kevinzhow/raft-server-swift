import Foundation
import Synchronization
import Testing
import RaftDaemonClient

private let base = (slot: "/home/agent/.slock", version: "test", at: 1_787_936_400_000)

private final class Seen: @unchecked Sendable {
    var probeCalls = 0
    var readerGot: [OarInstallation] = []
}

private func recordingRuntime(_ installation: OarInstallation) -> (OarRuntimeAdapter, Seen) {
    let seen = Seen()
    let runtime = OarRuntimeAdapter(
        installation: {
            seen.probeCalls += 1
            return installation
        },
        accountUsage: { given, _ in
            seen.readerGot.append(given)
            return .init(kind: .unsupported)
        }
    )
    return (runtime, seen)
}

private func read(_ runtime: OarRuntimeAdapter?, provider: RuntimeAccountUsageProvider = .codex, kimi: KimiUsageDeps? = nil) async -> RuntimeAccountUsageSnapshot {
    await RuntimeAccountUsageCollector.read(
        provider: provider, localAccountSlot: base.slot, collectorVersion: base.version,
        observedAtMs: base.at, deps: .init(runtime: runtime, kimi: kimi)
    )
}

@Test func installationIsProbedExactlyOncePerRead() async {
    let available = OarInstallation(kind: "available")
    let (runtime, seen) = recordingRuntime(available)
    _ = await read(runtime)
    #expect(seen.probeCalls == 1, "the installation probe must be the sole probe, called once")
}

@Test func theExactInstallationObjectIsHandedToTheReader() async {
    let available = OarInstallation(kind: "available", command: "/usr/local/bin/codex")
    let (runtime, seen) = recordingRuntime(available)
    _ = await read(runtime)
    #expect(seen.readerGot.count == 1)
    #expect(seen.readerGot[0] === available, "the reader must receive the SAME object, not a copy or a re-probe")
}

@Test func unavailableInstallationShortCircuitsWithoutReading() async {
    for installation in [OarInstallation(kind: "not_found"), OarInstallation(kind: "unsupported")] {
        let (runtime, seen) = recordingRuntime(installation)
        let result = await read(runtime)
        #expect(seen.probeCalls == 1)
        #expect(seen.readerGot.isEmpty, "a non-available installation must not be read from")
        #expect(result.accounts.first?.health == .unsupported)
        #expect(result.accounts.first?.windows == [])
    }
}

@Test func runtimeWithoutProbeOrReaderIsUnsupportedNotError() async {
    let bare = OarRuntimeAdapter()
    let result = await read(bare)
    #expect(result.accounts.first?.health == .unsupported)
    #expect(result.accounts.first?.windows == [])
}

@Test func thrownReadBecomesAnExplicitErrorAccount() async {
    let throwing = OarRuntimeAdapter(
        installation: { OarInstallation(kind: "available") },
        accountUsage: { _, _ in throw NSError(domain: "app-server unreachable", code: 1) }
    )
    let result = await read(throwing)
    #expect(result.accounts.first?.health == .error)
    #expect(result.accounts.first?.windows == [])
    let data = try! JSONSerialization.data(withJSONObject: result.jsonObject())
    #expect(!String(decoding: data, as: UTF8.self).contains("usedRatio"))
}

@Test func gateOnShortCircuitsOnlyThePreStepsOwnVerdicts() async {
    let runtime = OarRuntimeAdapter(
        installation: { OarInstallation(kind: "available", command: "/fixture/kimi") },
        accountUsage: { _, _ in
            Issue.record("a short-circuiting verdict must not read usage")
            return .init(kind: .unsupported)
        }
    )
    let auth = KimiCodeAuth(
        baseUrl: "https://api.kimi.test/coding/v1", oauthHost: "https://auth.kimi.test",
        storage: "file", storageName: "kimi-code", home: "/tmp/kimi",
        credentialPath: "/tmp/kimi/credentials/kimi-code.json", lockTarget: "/tmp/kimi/oauth/kimi-code"
    )
    func deps(_ freshness: KimiFreshness) -> KimiUsageDeps {
        .init(resolveAuth: { _ in auth }, ensureFresh: { _ in freshness }, enabled: true)
    }
    let rejected = await read(runtime, provider: .kimi, kimi: deps(.rejected(reason: "refresh_rejected")))
    #expect(rejected.accounts.first?.health == .reauthRequired)
    let revoked = await read(runtime, provider: .kimi, kimi: deps(.revoked))
    #expect(revoked.accounts.first?.health == .reauthRequired)
    let expiredTransient = await read(runtime, provider: .kimi, kimi: deps(.transient(reason: "network", expired: true)))
    #expect(expiredTransient.accounts.first?.health == .error)
}

@Test func gateOnLetsEveryOtherFreshnessReachTheProbe() async {
    var captured: [Double] = []
    let runtime = OarRuntimeAdapter(
        installation: { OarInstallation(kind: "available", command: "/fixture/kimi") },
        accountUsage: { _, _ in
            .init(kind: .available, windows: [.init(label: "7 days", usedRatio: 0.4)])
        }
    )
    _ = captured
    let auth = KimiCodeAuth(
        baseUrl: "https://api.kimi.test/coding/v1", oauthHost: "https://auth.kimi.test",
        storage: "file", storageName: "kimi-code", home: "/tmp/kimi",
        credentialPath: "/tmp/kimi/credentials/kimi-code.json", lockTarget: "/tmp/kimi/oauth/kimi-code"
    )
    for freshness in [
        KimiFreshness.fresh(expiresAt: 1), .refreshed(expiresAt: 1), .adopted(expiresAt: 1),
        .missing(reason: "no_file"), .transient(reason: "network", expired: false),
        .platformUnsupported(reason: "win32"),
    ] {
        let result = await read(runtime, provider: .kimi, kimi: .init(
            resolveAuth: { _ in auth }, ensureFresh: { _ in freshness }, enabled: true
        ))
        #expect(result.accounts.first?.health == .ok, "\(freshness)")
        captured.append(result.accounts.first?.windows.first?.usedRatio ?? -1)
    }
    #expect(captured == Array(repeating: 0.4, count: 6))
}

@Test func gateOffNeverRunsThePreStepAndProjectsOarUnchanged() async {
    final class Flag: @unchecked Sendable { var called = false }
    let flag = Flag()
    let runtime = OarRuntimeAdapter(
        installation: { OarInstallation(kind: "available") },
        accountUsage: { _, _ in .init(kind: .available, windows: [.init(label: "7 days", usedRatio: 0.4)]) }
    )
    let result = await read(runtime, provider: .kimi, kimi: .init(
        resolveAuth: { _ in flag.called = true; return nil },
        ensureFresh: { _ in .rejected(reason: "refresh_rejected") }, enabled: false
    ))
    #expect(!flag.called)
    #expect(result.accounts.first?.health == .ok)
    #expect(result.accounts.first?.windows.first?.usedRatio == 0.4)
}

@Test func collectorFactoryReadsEveryProviderThroughItsRuntime() async {
    let counter = Seen()
    let runtime = OarRuntimeAdapter(
        installation: { counter.probeCalls += 1; return OarInstallation(kind: "available") },
        accountUsage: { _, _ in .init(kind: .unsupported) }
    )
    let collector = RuntimeAccountUsageCollector.createCollector(
        localAccountSlot: base.slot, collectorVersion: base.version,
        now: { base.at }, oar: .init(runtime: runtime)
    )
    for provider in [RuntimeAccountUsageProvider.claude, .codex, .kimi] {
        let snapshot = await collector(provider)
        #expect(snapshot.provider == provider)
        #expect(snapshot.accounts.first?.health == .unsupported)
    }
    #expect(counter.probeCalls == 3)
}

@Test func concurrentInstallationUpdatesPreserveTheObjectPassedToEveryReader() async {
    let installation = OarInstallation(kind: "available", command: "/fixture/first")
    let readers = Mutex(4)
    let probes = Mutex(0)
    let reads = Mutex(0)
    let runtime = OarRuntimeAdapter(
        installation: {
            probes.withLock { $0 += 1 }
            return installation
        },
        accountUsage: { given, _ in
            #expect(given === installation)
            let command = given.command
            #expect(command == "/fixture/first" || command == "/fixture/second")
            reads.withLock { $0 += 1 }
            await Task.yield()
            return .init(kind: .available, windows: [.init(label: "7 days", usedRatio: 0.4)])
        }
    )
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            while readers.withLock({ $0 > 0 }) {
                installation.command = "/fixture/first"
                installation.command = "/fixture/second"
                await Task.yield()
            }
        }
        for _ in 0..<4 {
            group.addTask {
                defer { readers.withLock { $0 -= 1 } }
                for _ in 0..<100 {
                    let result = await read(runtime)
                    #expect(result.accounts.first?.health == .ok)
                }
            }
        }
    }
    #expect(probes.withLock { $0 } == 400)
    #expect(reads.withLock { $0 } == 400)
}

@Test func installationCallbacksCanMutateTheSameObjectAfterTheCollectorSnapshot() async {
    let installation = OarInstallation(kind: "available", command: "/fixture/before")
    let commands = Mutex<[String]>([])
    let reads = Mutex(0)
    let runtime = OarRuntimeAdapter(
        installation: { installation },
        accountUsage: { given, _ in
            #expect(given === installation)
            #expect(given.kind == "unsupported")
            #expect(given.command == "/fixture/after")
            reads.withLock { $0 += 1 }
            return .init(kind: .available, windows: [.init(label: "7 days", usedRatio: 0.4)])
        }
    )
    let result = await read(runtime, provider: .kimi, kimi: .init(resolveAuth: { command in
        commands.withLock { $0.append(command) }
        installation.kind = "unsupported"
        installation.command = "/fixture/after"
        await Task.yield()
        return nil
    }, enabled: true))
    #expect(commands.withLock { $0 } == ["/fixture/before"])
    #expect(reads.withLock { $0 } == 1)
    #expect(result.accounts.first?.health == .ok)
}
