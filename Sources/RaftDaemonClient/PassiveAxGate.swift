import Foundation

/// RFC 072 §7 passive AX ("peripheral vision") rollout gate: server flag AND a
/// local kill switch. `RAFT_PASSIVE_AX=0` in either the agent's env_vars or the
/// daemon process env turns it off (an emergency stop, so neither side can
/// override the other's off), and no env value can turn it on without the
/// server flag. Ported from the upstream daemon gate.
public enum PassiveAxGate {
    public static let envKey = "RAFT_PASSIVE_AX"

    static func parseBooleanFlag(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "on": return true
        case "0", "false", "off", "": return false
        default: return nil
        }
    }

    public static func resolve(
        serverEnabled: Bool?,
        agentEnvVars: [String: String]?,
        processEnv: [String: String] = [:]
    ) -> Bool {
        let agentOff = parseBooleanFlag(agentEnvVars?[envKey]) == false
        let machineOff = parseBooleanFlag(processEnv[envKey]) == false
        return serverEnabled == true && !agentOff && !machineOff
    }
}
