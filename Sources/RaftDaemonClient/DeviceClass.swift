import Foundation

/// A coarse machine category for the Computer icon. Only the category leaves
/// the machine; model names, model ids and DMI strings are read and dropped.
/// Unknown or unreadable stays nil. Ported from the upstream daemon helper.
public enum DeviceClass: String, Sendable, Equatable, CaseIterable {
    case laptop, mini, studio, imac, desktop, server, vm
}

public enum DeviceClassDetector {
    static let macModelNames: [(String, DeviceClass)] = [
        ("macbook", .laptop), ("mac mini", .mini), ("mac studio", .studio),
        ("imac", .imac), ("mac pro", .desktop),
    ]
    static let laptopChassis: Set<Int> = [8, 9, 10, 14, 31, 32]
    static let desktopChassis: Set<Int> = [3, 4, 5, 6, 7, 13, 15, 16, 35, 36]
    static let serverChassis: Set<Int> = [17, 23, 28, 29]
    static let vmVendor = try! NSRegularExpression(
        pattern: #"qemu|kvm|vmware|virtualbox|innotek|xen|bochs|parallels|amazon ec2|google compute engine|microsoft corporation virtual|hyper-v|openstack|digitalocean|hetzner vserver"#,
        options: [.caseInsensitive]
    )

    /// `system_profiler SPHardwareDataType -json` output -> category.
    public static func classifyMacHardware(_ json: String) -> DeviceClass? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["SPHardwareDataType"] as? [[String: Any]],
              let item = items.first
        else { return nil }
        if let model = item["machine_model"] as? String, model.range(of: "^VirtualMac", options: .regularExpression) != nil {
            return .vm
        }
        let name = (item["machine_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for (prefix, kind) in macModelNames where name.hasPrefix(prefix) { return kind }
        return nil
    }

    public struct LinuxDmi: Sendable {
        public var chassisType: String?
        public var sysVendor: String?
        public var productName: String?
        public var hypervisorType: String?
        public init(chassisType: String? = nil, sysVendor: String? = nil, productName: String? = nil, hypervisorType: String? = nil) {
            self.chassisType = chassisType
            self.sysVendor = sysVendor
            self.productName = productName
            self.hypervisorType = hypervisorType
        }
    }

    /// Linux DMI fields (sysfs, world-readable) -> category.
    public static func classifyLinuxDmi(_ dmi: LinuxDmi) -> DeviceClass? {
        let vendor = "\((dmi.sysVendor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) \((dmi.productName ?? "").trimmingCharacters(in: .whitespacesAndNewlines))"
        let hasHypervisor = !(dmi.hypervisorType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let vendorMatches = vmVendor.firstMatch(in: vendor, range: NSRange(location: 0, length: (vendor as NSString).length)) != nil
        if vendorMatches || hasHypervisor { return .vm }
        let chassis = Int((dmi.chassisType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int.min
        if laptopChassis.contains(chassis) { return .laptop }
        if desktopChassis.contains(chassis) { return .desktop }
        if serverChassis.contains(chassis) { return .server }
        return nil
    }

    public struct IO: Sendable {
        public var macHardware: @Sendable () async -> String?
        public var readFile: @Sendable (String) -> String?
        public init(
            macHardware: @escaping @Sendable () async -> String? = { nil },
            readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
        ) {
            self.macHardware = macHardware
            self.readFile = readFile
        }
    }

    public static func detect(platform: String = "linux", io: IO = IO()) async -> DeviceClass? {
        if platform == "darwin" {
            guard let json = await io.macHardware() else { return nil }
            return classifyMacHardware(json)
        }
        if platform == "linux" {
            // WSL sees no host DMI; the Server already has os_variant for it.
            if (io.readFile("/proc/sys/kernel/osrelease") ?? "").lowercased().contains("microsoft") { return nil }
            return classifyLinuxDmi(LinuxDmi(
                chassisType: io.readFile("/sys/class/dmi/id/chassis_type"),
                sysVendor: io.readFile("/sys/class/dmi/id/sys_vendor"),
                productName: io.readFile("/sys/class/dmi/id/product_name"),
                hypervisorType: io.readFile("/sys/hypervisor/type")
            ))
        }
        return nil
    }
}
