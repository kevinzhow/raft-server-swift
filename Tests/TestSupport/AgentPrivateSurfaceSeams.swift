// Test seams for the agent private surface: heartbeat/throttle config and read-backs.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    /// Write-only provider secrets never leave the server: HTTP projections
    /// blank the provider apiKey while the stored config keeps it.
    public func agentRuntimeConfigForTesting(agentId: String) -> String? {
        oauth.agentRuntimeInfo(id: agentId)?.runtimeConfigJSON
    }

    public func setWakeStreamHeartbeatMsForTesting(_ value: Int?) {
        lock.lock()
        wakeStreamHeartbeatOverrideMs = value
        lock.unlock()
    }

    public func setAgentCredentialUseThrottleMsForTesting(_ value: Int?) {
        lock.lock()
        agentCredentialUseThrottleOverrideMs = value
        lock.unlock()
    }

    public func agentCredentialLastUsedAtForTesting(apiKey: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return agentCredentials[apiKey]?.lastUsedAt
    }

    /// Inventory size only — enough to prove a read-only surface minted nothing.
    public func agentCredentialInventoryCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return agentCredentials.count
    }

    public func channelSystemMessagesForTesting(channelId: String) -> [(content: String, subtype: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows
            .filter { $0.channelId == channelId && $0.messageType == "system" }
            .map { ($0.content, $0.actionKind) }
    }

    public func directChannelIdForTesting(serverId: String, firstId: String, secondId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return postableChannels.first { _, channel in
            channel.serverId == serverId && channel.kind == "dm"
                && channel.memberIds.contains(firstId) && channel.memberIds.contains(secondId)
        }?.key
    }
}
