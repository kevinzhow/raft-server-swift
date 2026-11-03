import Foundation
import Testing
import RaftDaemonClient

private func macJson(_ name: String, model: String = "Mac14,3") -> String {
    #"{"SPHardwareDataType":[{"machine_name":"\#(name)","machine_model":"\#(model)","serial_number":"SERIAL123"}]}"#
}

@Test func classifiesMacModelNames() {
    let cases: [(String, DeviceClass)] = [
        ("MacBook Pro", .laptop), ("MacBook Air", .laptop), ("Mac mini", .mini),
        ("Mac Studio", .studio), ("iMac", .imac), ("Mac Pro", .desktop),
    ]
    for (name, expected) in cases {
        #expect(DeviceClassDetector.classifyMacHardware(macJson(name)) == expected, "\(name)")
    }
    #expect(DeviceClassDetector.classifyMacHardware(macJson("Apple Virtual Machine 1", model: "VirtualMac2,1")) == .vm)
    #expect(DeviceClassDetector.classifyMacHardware(macJson("Mac Something New")) == nil)
    #expect(DeviceClassDetector.classifyMacHardware(#"{"SPHardwareDataType":[{}]}"#) == nil)
    #expect(DeviceClassDetector.classifyMacHardware("not json") == nil)
}

@Test func classifiesLinuxChassisAndHypervisors() {
    let cases: [(String, DeviceClass)] = [
        ("9\n", .laptop), ("10\n", .laptop), ("31\n", .laptop),
        ("3\n", .desktop), ("35\n", .desktop), ("23\n", .server), ("17\n", .server),
    ]
    for (chassis, expected) in cases {
        #expect(DeviceClassDetector.classifyLinuxDmi(.init(chassisType: chassis, sysVendor: "LENOVO\n", productName: "21CB\n")) == expected, "\(chassis)")
    }
    #expect(DeviceClassDetector.classifyLinuxDmi(.init(chassisType: "1\n", sysVendor: "QEMU\n", productName: "Standard PC (Q35 + ICH9, 2009)\n")) == .vm)
    #expect(DeviceClassDetector.classifyLinuxDmi(.init(chassisType: "1\n", sysVendor: "Amazon EC2\n", productName: "m6i.large\n")) == .vm)
    #expect(DeviceClassDetector.classifyLinuxDmi(.init(chassisType: "3\n", sysVendor: "Microsoft Corporation\n", productName: "Virtual Machine\n")) == .vm)
    #expect(DeviceClassDetector.classifyLinuxDmi(.init(chassisType: "23\n", hypervisorType: "xen\n")) == .vm)
    #expect(DeviceClassDetector.classifyLinuxDmi(.init(chassisType: "1\n")) == nil)
    #expect(DeviceClassDetector.classifyLinuxDmi(.init(chassisType: "2\n")) == nil)
    #expect(DeviceClassDetector.classifyLinuxDmi(.init()) == nil)
}

@Test func detectsMacAndLinuxAndTreatsFailuresAsUnknown() async {
    let mini = await DeviceClassDetector.detect(platform: "darwin", io: .init(macHardware: { macJson("Mac mini") }, readFile: { _ in nil }))
    #expect(mini == .mini)
    let failed = await DeviceClassDetector.detect(platform: "darwin", io: .init(macHardware: { nil }, readFile: { _ in nil }))
    #expect(failed == nil)

    var files: [String: String] = [
        "/proc/sys/kernel/osrelease": "6.1.0-arm64\n",
        "/sys/class/dmi/id/chassis_type": "10\n",
        "/sys/class/dmi/id/sys_vendor": "Dell Inc.\n",
    ]
    final class Box: @unchecked Sendable { var files: [String: String] = [:] }
    let box = Box(); box.files = files
    let laptop = await DeviceClassDetector.detect(platform: "linux", io: .init(macHardware: { nil }, readFile: { box.files[$0] }))
    #expect(laptop == .laptop)
    box.files["/proc/sys/kernel/osrelease"] = "5.15.153.1-microsoft-standard-WSL2\n"
    let wsl = await DeviceClassDetector.detect(platform: "linux", io: .init(macHardware: { nil }, readFile: { box.files[$0] }))
    #expect(wsl == nil)
    let pi = await DeviceClassDetector.detect(platform: "linux", io: .init(macHardware: { nil }, readFile: { _ in nil }))
    #expect(pi == nil)
    let windows = await DeviceClassDetector.detect(platform: "win32")
    #expect(windows == nil)
    _ = files
}
