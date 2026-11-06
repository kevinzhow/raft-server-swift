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
        agentsRuntimeStore.withState { owned in
            owned.wakeStreamHeartbeatOverrideMs = value
        }
    }

    public func setAgentCredentialUseThrottleMsForTesting(_ value: Int?) {
        agentsRuntimeStore.withState { owned in
            owned.agentCredentialUseThrottleOverrideMs = value
        }
    }

    /// Stamps every credential of the agent as just used.
    public func markAgentCredentialUsed(agentId: String) {
        agentsRuntimeStore.withState { owned in
            for key in owned.agentCredentials.keys where owned.agentCredentials[key]?.agentId == agentId {
                owned.agentCredentials[key]?.lastUsedAt = Date()
            }
        }
    }

    public func agentCredentialLastUsedAtForTesting(apiKey: String) -> Date? {
        return agentsRuntimeStore.withState { owned in owned.agentCredentials[apiKey]?.lastUsedAt }
    }

    /// Inventory size only — enough to prove a read-only surface minted nothing.
    public func agentCredentialInventoryCountForTesting() -> Int {
        return agentsRuntimeStore.withState { owned in owned.agentCredentials.count }
    }

    public func channelSystemMessagesForTesting(channelId: String) -> [(content: String, subtype: String?)] {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows
                .filter { $0.channelId == channelId && $0.messageType == "system" }
                .map { ($0.content, $0.actionKind) }
        }
    }

    public func directChannelIdForTesting(serverId: String, firstId: String, secondId: String) -> String? {
        serversAndChannelsStore.mutex.withLock { state in
            return state.postableChannels.first { _, channel in
                channel.serverId == serverId && channel.kind == "dm"
                    && channel.memberIds.contains(firstId) && channel.memberIds.contains(secondId)
            }?.key
        }
    }
}
