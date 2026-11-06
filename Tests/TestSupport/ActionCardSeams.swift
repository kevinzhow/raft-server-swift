@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    @discardableResult
    public func addActionCardForTesting(
        serverId: String, agentId: String, carrierChannelId: String,
        actionType: String = "channel:create", state: String = "prepared"
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        actionCardRecords[id] = ActionCardRecord(
            messageId: id, serverId: serverId, requesterAgentId: agentId,
            storageChannelId: carrierChannelId, localCarrierChannelId: carrierChannelId,
            actionType: actionType, channelName: "test-card-channel", visibility: "public",
            state: state, executedByUserId: nil
        )
        lock.unlock()
        return id
    }

    public func actionCardStateForTesting(messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return actionCardRecords[messageId]?.state
    }

    public func setAgentInboxAvailableForTesting(_ value: Bool?) {
        lock.lock()
        agentInboxAvailable = value
        lock.unlock()
    }

    public func setMarketplaceReviewerIdsForTesting(_ ids: Set<String>?) {
        lock.lock()
        marketplaceReviewerOverride = ids
        lock.unlock()
    }

    public func setSendFreshnessModeForTesting(_ mode: String?) {
        lock.lock()
        sendFreshnessModeOverride = mode
        lock.unlock()
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
        lock.lock()
        managedMCPServers.append(ManagedMCPServerRecord(
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
        lock.unlock()
        return id
    }
}
