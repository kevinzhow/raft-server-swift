import RaftDaemonClient
import Testing

private let machineId = "4c4c4544004d3610804bb4c04f4e4d32"

@Test func hostIdHashIsStablePerMachineAndServerAndHidesTheHardwareId() {
    let hash = HostIdentity.hostIdHashForServer(hardwareId: machineId, serverId: "server-a")
    #expect(hash.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
    #expect(HostIdentity.hostIdHashForServer(hardwareId: machineId, serverId: "server-a") == hash)
    #expect(HostIdentity.hostIdHashForServer(hardwareId: machineId, serverId: "server-b") != hash)
    #expect(HostIdentity.hostIdHashForServer(hardwareId: "ffeeddccbbaa99887766554433221100", serverId: "server-a") != hash)
    #expect(!hash.contains(String(machineId.prefix(12))))
}

@Test func normalizeHardwareIdAcceptsRealFormsAndRejectsPlaceholders() {
    #expect(HostIdentity.normalizeHardwareId("\(machineId)\n") == machineId)
    #expect(HostIdentity.normalizeHardwareId("12345678-ABCD-4EF0-9123-456789ABCDEF") == "12345678abcd4ef09123456789abcdef")
    #expect(HostIdentity.normalizeHardwareId(nil) == nil)
    #expect(HostIdentity.normalizeHardwareId("") == nil)
    #expect(HostIdentity.normalizeHardwareId("abc123") == nil)
    #expect(HostIdentity.normalizeHardwareId("00000000-0000-0000-0000-000000000000") == nil)
    #expect(HostIdentity.normalizeHardwareId("uninitialized") == nil)
}

@Test func platformParsersReadTheirOutputs() {
    let ioreg = "+-o J314sAP  <class IOPlatformExpertDevice>\n    {\n      \"IOPlatformSerialNumber\" = \"SERIAL\"\n      \"IOPlatformUUID\" = \"12345678-ABCD-4EF0-9123-456789ABCDEF\"\n    }\n"
    #expect(HostIdentity.parseIoregPlatformUuid(ioreg) == "12345678-ABCD-4EF0-9123-456789ABCDEF")
    #expect(HostIdentity.parseIoregPlatformUuid("nothing here") == nil)
    let reg = "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\r\n"
    #expect(HostIdentity.parseRegMachineGuid(reg) == "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
}

@Test func linuxReadsMachineIdWithDbusFallback() async {
    let primary = await HostIdentity.readHardwareId(platform: "linux", io: .init(readFile: { file in
        file == "/etc/machine-id" ? "\(machineId)\n" : nil
    }))
    #expect(primary == machineId)
    let fallback = await HostIdentity.readHardwareId(platform: "linux", io: .init(readFile: { file in
        file == "/var/lib/dbus/machine-id" ? machineId : nil
    }))
    #expect(fallback == machineId)
    let missing = await HostIdentity.readHardwareId(platform: "linux", io: .init(readFile: { _ in nil }))
    #expect(missing == nil)
}

@Test func macOSAndWindowsReadTheirSystemIdsAndFailuresStayUnknown() async {
    let ioreg = "\"IOPlatformUUID\" = \"12345678-ABCD-4EF0-9123-456789ABCDEF\""
    let darwin = await HostIdentity.readHardwareId(platform: "darwin", io: .init(readFile: { _ in nil }, run: { file, _ in
        file == "/usr/sbin/ioreg" ? ioreg : nil
    }))
    #expect(darwin == "12345678abcd4ef09123456789abcdef")
    let windows = await HostIdentity.readHardwareId(platform: "win32", io: .init(readFile: { _ in nil }, run: { file, _ in
        file == "reg" ? "MachineGuid    REG_SZ    0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0" : nil
    }))
    #expect(windows == "0f1e2d3c4b5a69788796a5b4c3d2e1f0")
    let failed = await HostIdentity.readHardwareId(platform: "darwin", io: .init(readFile: { _ in nil }, run: { _, _ in nil }))
    #expect(failed == nil)
    let throwing = await HostIdentity.readHardwareId(platform: "darwin", io: .init(readFile: { _ in nil }, run: { _, _ in
        nil
    }))
    #expect(throwing == nil)
}
