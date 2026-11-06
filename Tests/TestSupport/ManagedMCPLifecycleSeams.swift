@testable import RaftHTTP
import Foundation

// Test-only seams for the provider-connection, push and agent-cursor state the
// managed MCP lifecycle service owns. They keep the names the tests already
// call; the production types no longer carry them.

extension EmailLoginDirectory {
    public func setProviderConnectionsEnabled(serverId: String, enabled: Bool) {
        if enabled {
            managedMCPAndCardsStore.providerConnectionsEnabledServers.insert(serverId)
        } else {
            managedMCPAndCardsStore.providerConnectionsEnabledServers.remove(serverId)
        }
    }

    public func assignAgentToProviderConnection(
        connectionId: String,
        serverId: String,
        agentId: String,
        computerName: String?
    ) {
        managedMCPAndCardsStore.providerAssignments.append(ProviderAssignment(
            connectionId: connectionId,
            serverId: serverId,
            agentId: agentId,
            computerName: computerName
        ))
    }

    public func pushRegistration(installationId: String, provider: String) -> PushRegistration? {
        notificationsStore.pushRegistrations.first {
            $0.installationId == installationId && $0.provider == provider
        }
    }

    public func webPushEndpoints(userId: String) -> [String] {
        notificationsStore.webPushSubscriptions.filter { $0.userId == userId }.map { $0.endpoint }
    }

    public func pushFamilyStatus(capability: String) -> (revoked: Bool, reason: String?, retainUntil: Date?)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        guard let family = authProfileStore.sessionFamilies.values.first(where: {
            $0.revokeCapabilityNonce == parts[1]
        }) else { return nil }
        return (family.revokedAt != nil, family.revokedReason, family.capabilityRetainUntil)
    }

    public func expirePushFamilyCapability(capability: String) {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return }
        var families = authProfileStore.sessionFamilies
        if let familyId = families.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key {
            families[familyId]?.capabilityRetainUntil = Date().addingTimeInterval(-1)
            authProfileStore.sessionFamilies = families
        }
    }

    public func setAgentActivity(agentId: String, activity: String, detail: String) {
        agentsRuntimeStore.agentActivities[agentId] = (activity, detail)
    }

    public func agentReadCursor(agentId: String, channelId: String) -> (seq: Int, version: Int) {
        messagesAndThreadsStore.agentChannelReadCursors["\(channelId)\n\(agentId)"] ?? (0, 0)
    }
}
