import Foundation

public enum MachineCredentialMaterial {
    static func machineAPIKeyMaterial() -> String {
        machineAPIKeyPrefix + MachineCredentialMaterial.credentialHex64()
    }

    static func computerAPIKeyMaterial() -> String {
        computerAPIKeyPrefix + MachineCredentialMaterial.credentialHex64()
    }

    static func credentialHex64() -> String {
        (UUID().uuidString + UUID().uuidString)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
    }

    static let machineAPIKeyPrefix = "sk_machine_"

    static let computerAPIKeyPrefix = "sk_computer_"

    static let computerAPIKeyPrefixLength = 16
}
