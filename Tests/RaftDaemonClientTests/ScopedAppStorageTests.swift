import Foundation
import Testing
import RaftDaemonClient

private func tempHome() -> String {
    let home = NSTemporaryDirectory() + "scoped-app-storage-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    return home
}

private func allFiles(_ root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    var files: [String] = []
    for case let relative as String in enumerator {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root + "/" + relative, isDirectory: &isDirectory), !isDirectory.boolValue {
            files.append(root + "/" + relative)
        }
    }
    return files
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScopedAppStorage.FailureEvent] = []
    func append(_ event: ScopedAppStorage.FailureEvent) { lock.withLock { values.append(event) } }
    var all: [ScopedAppStorage.FailureEvent] { lock.withLock { values } }
    func json() -> String {
        let mapped: [[String: Any]] = all.map { event in
            var object: [String: Any] = [
                "operation": event.operation, "store": event.store, "appId": event.appId,
                "serverId": event.serverId, "writerEpoch": event.writerEpoch,
                "outcome": event.outcome, "reason": event.reason,
            ]
            if let failureInstanceId = event.failureInstanceId { object["failureInstanceId"] = failureInstanceId }
            if let observation = event.observation { object["observation"] = observation }
            return object
        }
        let data = (try? JSONSerialization.data(withJSONObject: mapped)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@Test func everyRetryableLockCodeClassifiesAsLockContention() {
    for code in ["EAGAIN", "EBUSY", "EEXIST"] {
        #expect(ScopedAppStorage.classifyFailureReason(code: code) == "lock_contention")
    }
    #expect(ScopedAppStorage.classifyFailureReason(code: "EIO") == "storage_io")
}

@Test func theSameAppAndAgentIsIsolatedAcrossServers() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let serverA = try ScopedAppStorage.Factory(slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"))
        .open(.init(appId: "system.agent-inbox", agentId: "agent-1"))
    let serverB = try ScopedAppStorage.Factory(slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-b"))
        .open(.init(appId: "system.agent-inbox", agentId: "agent-1"))
    try serverA.writeTextAtomic("server-a\n")
    #expect(try serverA.readText() == "server-a\n")
    #expect(try serverB.readText() == nil)
    try serverB.writeTextAtomic("server-b\n")
    #expect(try serverA.readText() == "server-a\n")
    #expect(try serverB.readText() == "server-b\n")
    #expect(allFiles(home + "/app-storage").filter { $0.hasSuffix("state.json") }.count == 2)
    #expect(!allFiles(home + "/app-storage").contains { $0.hasSuffix(".tmp") })
}

@Test func twoAgentOwnersInsideOneServerAndAppAreIsolated() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let factory = try ScopedAppStorage.Factory(slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"))
    let agentA = try factory.open(.init(appId: "system.agent-inbox", agentId: "agent-a"))
    let agentB = try factory.open(.init(appId: "system.agent-inbox", agentId: "agent-b"))
    try agentA.writeTextAtomic("agent-a\n")
    #expect(try agentA.readText() == "agent-a\n")
    #expect(try agentB.readText() == nil)
}

@Test func unknownLegacyAppBytesAreQuarantinedOutsideEveryServerScope() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let legacyPath = home + "/agent-inbox/agent-1.json"
    try FileManager.default.createDirectory(atPath: home + "/agent-inbox", withIntermediateDirectories: true)
    try "legacy-owner-unknown\n".write(toFile: legacyPath, atomically: false, encoding: .utf8)
    let factory = try ScopedAppStorage.Factory(slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"))
    #expect(try factory.quarantineLegacyFile(relativePath: "agent-inbox/agent-1.json", appId: "system.agent-inbox") == .quarantined)
    #expect(try factory.quarantineLegacyFile(relativePath: "agent-inbox/agent-1.json", appId: "system.agent-inbox") == .absent)
    #expect(!FileManager.default.fileExists(atPath: legacyPath))
    #expect(try factory.open(.init(appId: "system.agent-inbox", agentId: "agent-1")).readText() == nil)
    let quarantined = allFiles(home + "/app-storage-quarantine")
    #expect(quarantined.count == 1)
    #expect(try String(contentsOfFile: quarantined[0], encoding: .utf8) == "legacy-owner-unknown\n")
}

@Test func legacyQuarantineDirectoryFailuresEmitOnePrivacySafeTypedEvent() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let legacyPath = home + "/agent-inbox/agent-1.json"
    try FileManager.default.createDirectory(atPath: home + "/agent-inbox", withIntermediateDirectories: true)
    try "legacy bytes must not enter telemetry\n".write(toFile: legacyPath, atomically: false, encoding: .utf8)
    try "blocks mkdir".write(toFile: home + "/app-storage-quarantine", atomically: false, encoding: .utf8)
    let failures = Failures()
    let factory = try ScopedAppStorage.Factory(
        slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"),
        writerEpoch: "writer-1", onFailure: { failures.append($0) }
    )
    #expect(throws: (any Error).self) {
        try factory.quarantineLegacyFile(relativePath: "agent-inbox/agent-1.json", appId: "system.agent-inbox")
    }
    #expect(failures.all == [.init(
        operation: "legacy_quarantine", store: "legacy_unscoped", appId: "system.agent-inbox",
        serverId: "server-a", writerEpoch: "writer-1", outcome: "failed", reason: "storage_io"
    )])
    #expect(!failures.json().contains("legacy bytes"))
    #expect(!failures.json().contains(legacyPath))
}

@Test func scopeIdentitiesAndLegacyPathsFailClosedBeforePathConstruction() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    #expect(throws: (any Error).self) {
        try ScopedAppStorage.Factory(slockHome: home, owner: .init(machineId: "../machine", serverId: "server-a"))
    }
    let factory = try ScopedAppStorage.Factory(slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"))
    #expect(throws: (any Error).self) {
        try factory.open(.init(appId: "system.agent-inbox", agentId: "../agent"))
    }
    #expect(throws: (any Error).self) {
        try factory.quarantineLegacyFile(relativePath: "../other-server.json", appId: "system.agent-inbox")
    }
}

@Test func revocationClosesCapabilitiesAlreadyHandedToAnApp() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let failures = Failures()
    let factory = try ScopedAppStorage.Factory(
        slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"),
        writerEpoch: "writer-1", onFailure: { failures.append($0) }
    )
    let storage = try factory.open(.init(appId: "system.agent-inbox", agentId: "agent-1"))
    try storage.writeTextAtomic("before revoke\n")
    factory.revoke()
    #expect(throws: (any Error).self) { try storage.assertActive() }
    #expect(throws: (any Error).self) { _ = try storage.readText() }
    #expect(throws: (any Error).self) { try storage.writeTextAtomic("after revoke\n") }
    #expect(throws: (any Error).self) {
        _ = try factory.open(.init(appId: "system.agent-inbox", agentId: "agent-2"))
    }
    let expected = Array(repeating: ScopedAppStorage.FailureEvent(
        operation: "access", store: "app_state", appId: "system.agent-inbox",
        serverId: "server-a", writerEpoch: "writer-1", outcome: "denied", reason: "capability_revoked"
    ), count: 4)
    #expect(failures.all == expected)
}

@Test func writeFailuresEmitOnePrivacySafeTypedEventBeforeRethrow() throws {
    let root = NSTemporaryDirectory() + "scoped-app-storage-failure-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let slockHome = root + "/not-a-directory"
    try "blocks mkdir".write(toFile: slockHome, atomically: false, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let failures = Failures()
    let storage = try ScopedAppStorage.Factory(
        slockHome: slockHome, owner: .init(machineId: "machine-1", serverId: "server-a"),
        writerEpoch: "writer-1", onFailure: { failures.append($0) }
    ).open(.init(appId: "system.agent-inbox", agentId: "agent-1"))
    #expect(throws: (any Error).self) { try storage.writeTextAtomic("payload must not enter telemetry") }
    #expect(failures.all == [.init(
        operation: "write", store: "app_state", appId: "system.agent-inbox",
        serverId: "server-a", writerEpoch: "writer-1", outcome: "failed", reason: "storage_io"
    )])
    #expect(!failures.json().contains("payload"))
    #expect(!failures.json().contains(slockHome))
}

@Test func appDecodeFailuresReuseTheScopedOwnerEnvelopeWithoutLeakingBytes() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let failures = Failures()
    let storage = try ScopedAppStorage.Factory(
        slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"),
        writerEpoch: "writer-1", onFailure: { failures.append($0) }
    ).open(.init(appId: "system.agent-inbox", agentId: "agent-secret"))
    try storage.writeTextAtomic("secret malformed bytes")
    #expect(try storage.readText() == "secret malformed bytes")
    try storage.reportDataFailure("invalid_payload")
    try storage.reportDataFailure("invalid_payload")
    #expect(failures.all.count == 2)
    let stripped = failures.all.map { event in
        ScopedAppStorage.FailureEvent(
            operation: event.operation, store: event.store, appId: event.appId,
            serverId: event.serverId, writerEpoch: event.writerEpoch, outcome: event.outcome,
            reason: event.reason, observation: event.observation
        )
    }
    #expect(stripped == [
        .init(operation: "decode", store: "app_state", appId: "system.agent-inbox",
              serverId: "server-a", writerEpoch: "writer-1", outcome: "failed",
              reason: "invalid_payload", observation: "edge"),
        .init(operation: "decode", store: "app_state", appId: "system.agent-inbox",
              serverId: "server-a", writerEpoch: "writer-1", outcome: "failed",
              reason: "invalid_payload", observation: "level"),
    ])
    #expect(failures.all[0].failureInstanceId != nil)
    #expect(failures.all[0].failureInstanceId == failures.all[1].failureInstanceId)
    #expect(!failures.json().contains("secret malformed bytes"))
    #expect(!failures.json().contains("agent-secret"))
}

@Test func anAtomicRewriteCreatesANewCorruptionEdgeInsteadOfExtendingThePriorLevel() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let failures = Failures()
    let storage = try ScopedAppStorage.Factory(
        slockHome: home, owner: .init(machineId: "machine-1", serverId: "server-a"),
        writerEpoch: "writer-1", onFailure: { failures.append($0) }
    ).open(.init(appId: "system.reminder", agentId: "agent-secret"))
    try storage.writeTextAtomic("first malformed generation")
    #expect(try storage.readText() == "first malformed generation")
    try storage.reportDataFailure("invalid_payload")
    try storage.reportDataFailure("invalid_payload")
    try storage.writeTextAtomic("second malformed generation")
    #expect(try storage.readText() == "second malformed generation")
    try storage.reportDataFailure("invalid_payload")
    #expect(failures.all.map(\.observation) == ["edge", "level", "edge"])
    #expect(failures.all[0].failureInstanceId == failures.all[1].failureInstanceId)
    #expect(failures.all[1].failureInstanceId != failures.all[2].failureInstanceId)
    #expect(!failures.json().contains("first malformed generation"))
    #expect(!failures.json().contains("second malformed generation"))
    #expect(!failures.json().contains("agent-secret"))
}
