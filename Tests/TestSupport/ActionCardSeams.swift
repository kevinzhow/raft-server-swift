@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    @discardableResult
    public func addActionCardForTesting(
        serverId: String, agentId: String, carrierChannelId: String,
        actionType: String = "channel:create", state: String = "prepared"
    ) -> String {
        let id = UUID().uuidString.lowercased()
        managedMCPAndCardsStore.storage.withLock { owned in
            owned.actionCardRecords[id] = ActionCardRecord(
                messageId: id, serverId: serverId, requesterAgentId: agentId,
                storageChannelId: carrierChannelId, localCarrierChannelId: carrierChannelId,
                actionType: actionType, channelName: "test-card-channel", visibility: "public",
                state: state, executedByUserId: nil
            )
        }
        return id
    }

    public func actionCardStateForTesting(messageId: String) -> String? {
        return managedMCPAndCardsStore.storage.withLock { owned in
            return owned.actionCardRecords[messageId]?.state
        }
    }

    public func setAgentInboxAvailableForTesting(_ value: Bool?) {
        agentsRuntimeStore.withState { owned in
            owned.agentInboxAvailable = value
        }
    }

    public func setMarketplaceReviewerIdsForTesting(_ ids: Set<String>?) {
        feedbackStore.marketplaceReviewerOverride = ids
    }

    public func setSendFreshnessModeForTesting(_ mode: String?) {
        messagesAndThreadsStore.withState { $0.sendFreshnessModeOverride = mode }
    }

    public func addManagedMCPServerForTesting(
        serverId: String,
        name: String,
        provider: String? = nil,
        authMode: String? = nil,
        oauthStatus: String? = nil,
        endpointUrl: String = "https://example.com/mcp",
        tools: [(name: String, inputSchemaJSON: String)] = [],
        catalogVersion: Int = 1
    ) -> String {
        let id = UUID().uuidString.lowercased()
        let catalog = tools.map { tool in
            "{\"name\":\(jsonString(tool.name)),\"inputSchema\":\(tool.inputSchemaJSON)}"
        }.joined(separator: ",")
        managedMCPAndCardsStore.storage.withLock { owned in
            owned.managedMCPServers.append(ManagedMCPServerRecord(
                id: id,
                serverId: serverId,
                name: name,
                provider: provider,
                authMode: authMode,
                oauthStatus: oauthStatus,
                endpointUrl: endpointUrl,
                toolCatalogJSON: "[\(catalog)]",
                catalogVersion: catalogVersion
            ))
        }
        return id
    }
}
