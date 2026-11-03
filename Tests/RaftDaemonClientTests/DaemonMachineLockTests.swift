import Foundation
import RaftDaemonClient
import Testing

private func makeTempRoot(_ label: String) throws -> String {
    let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("slock-lock-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private func readOwnerJSON(_ handle: DaemonMachineLockHandle) -> [String: Any] {
    let path = (handle.lockDir as NSString).appendingPathComponent("owner.json")
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

@Test func machineLockSerializesOneDaemonPerMachineKey() throws {
    let root = try makeTempRoot("serialize")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com", rootDir: root)
    #expect(first.lockId == DaemonMachineLock.lockId(apiKey: "sk_machine_test"))
    #expect(first.machineDir.contains("machine-"))
    let owner = readOwnerJSON(first)
    #expect((owner["pid"] as? NSNumber)?.intValue == Int(ProcessInfo.processInfo.processIdentifier))
    #expect((owner["schemaVersion"] as? NSNumber)?.intValue == 2)
    #expect(owner["kind"] as? String == "legacy_raw_daemon")

    var conflict: Error?
    do {
        _ = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com", rootDir: root)
    } catch {
        conflict = error
    }
    #expect(conflict != nil)
    #expect(String(describing: conflict ?? NSError(domain: "test", code: 0)).contains("Another Slock daemon is already running"))

    first.release()
    let second = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com", rootDir: root)
    second.release()
}

@Test func machineLockPreservesIdentityAcrossCleanRelease() throws {
    let root = try makeTempRoot("identity")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let lock = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com", rootDir: root)
    let before = readOwnerJSON(lock)
    #expect(before["kind"] as? String == "legacy_raw_daemon")
    lock.release()
    let after = readOwnerJSON(lock)
    #expect(after["pid"] as? NSNumber == 0)
    #expect(after["apiKeyFingerprint"] as? String == before["apiKeyFingerprint"] as? String)
    #expect((after["schemaVersion"] as? NSNumber)?.intValue == 2)
    #expect(after["kind"] as? String == "legacy_raw_daemon")

    let next = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com", rootDir: root)
    #expect((readOwnerJSON(next)["pid"] as? NSNumber)?.intValue == Int(ProcessInfo.processInfo.processIdentifier))
    next.release()
}

@Test func machineLockWritesAndPreservesManagedProvenance() throws {
    let root = try makeTempRoot("managed")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let lock = try DaemonMachineLock.acquire(
        apiKey: "sk_computer_test", serverUrl: "https://daemon.example.com", rootDir: root,
        ownerProvenance: .managed(
            serverId: "11111111-1111-4111-8111-111111111111",
            serverMachineId: "22222222-2222-4222-8222-222222222222"
        )
    )
    var owner = readOwnerJSON(lock)
    #expect(owner["kind"] as? String == "managed_computer_runner")
    #expect(owner["serverId"] as? String == "11111111-1111-4111-8111-111111111111")
    #expect(owner["serverMachineId"] as? String == "22222222-2222-4222-8222-222222222222")
    lock.release()
    owner = readOwnerJSON(lock)
    #expect(owner["pid"] as? NSNumber == 0)
    #expect(owner["kind"] as? String == "managed_computer_runner")
    #expect(owner["serverMachineId"] as? String == "22222222-2222-4222-8222-222222222222")
}

@Test func machineLockDefaultsToSlockHomeMachines() throws {
    let root = try makeTempRoot("home")
    let previous = ProcessInfo.processInfo.environment["SLOCK_HOME"]
    setenv("SLOCK_HOME", root, 1)
    defer {
        if let previous { setenv("SLOCK_HOME", previous, 1) } else { unsetenv("SLOCK_HOME") }
        try? FileManager.default.removeItem(atPath: root)
    }
    let expectedRoot = (root as NSString).appendingPathComponent("machines")
    #expect(DaemonMachineLock.defaultMachineStateRoot() == expectedRoot)
    let lock = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com")
    #expect(lock.machineDir == (expectedRoot as NSString).appendingPathComponent(DaemonMachineLock.lockId(apiKey: "sk_machine_test")))
    lock.release()
}

@Test func machineLockRecoversStaleLockDirectories() throws {
    let root = try makeTempRoot("stale")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let lockDir = ((root as NSString).appendingPathComponent(DaemonMachineLock.lockId(apiKey: "sk_machine_test")) as NSString)
        .appendingPathComponent("daemon.lock")
    try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
    try Data("{\"pid\":0}".utf8).write(to: URL(fileURLWithPath: (lockDir as NSString).appendingPathComponent("owner.json")))
    let lock = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com", rootDir: root)
    #expect(lock.lockDir == lockDir)
    lock.release()
}

@Test func machineLockKeepsRecentIncompleteLockDirectories() throws {
    let root = try makeTempRoot("incomplete")
    defer { try? FileManager.default.removeItem(atPath: root) }
    let lockDir = ((root as NSString).appendingPathComponent(DaemonMachineLock.lockId(apiKey: "sk_machine_test")) as NSString)
        .appendingPathComponent("daemon.lock")
    try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
    var conflict: Error?
    do {
        _ = try DaemonMachineLock.acquire(apiKey: "sk_machine_test", serverUrl: "https://daemon.example.com", rootDir: root)
    } catch {
        conflict = error
    }
    #expect(conflict != nil)
    #expect(FileManager.default.fileExists(atPath: lockDir), "a recent incomplete lock directory stays for its owner")
}
