// Test seams for server profile and ordering: gates, timezone, translation provider.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func setLegacyTimezoneObservationForTesting(userId: String, timezone: String, at: Date) {
        lock.lock()
        timezoneObservations[userId] = TimezoneObservation(
            firstTimezone: timezone,
            firstAt: at,
            lastTimezone: timezone,
            lastAt: at
        )
        lock.unlock()
    }

    public func assignAgentMachineForTesting(agentId: String, machineId: String) {
        lock.lock()
        agentMachineIds[agentId] = machineId
        lock.unlock()
    }

    public func setRemoteUpgradeGateForTesting(serverId: String, enabled: Bool) {
        lock.lock()
        if enabled { remoteUpgradeDisabledServers.remove(serverId) } else { remoteUpgradeDisabledServers.insert(serverId) }
        lock.unlock()
    }

    public func enableGrokRuntimeForTesting(serverId: String, enabled: Bool = true) {
        lock.lock()
        if enabled { grokRuntimeServers.insert(serverId) } else { grokRuntimeServers.remove(serverId) }
        lock.unlock()
    }

    public func setTranslationProviderForTesting(_ provider: String?) {
        messagesAndThreadsStore.translationProviderOverride = provider
    }

    public func messageTranslationForTesting(messageId: String) -> (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)? {
        messagesAndThreadsStore.messageTranslationLedger[messageId]
    }

    /// Enables or disables the composer resource references (and so the apps
    /// list) for one server.
    public func enableComposerResourceReferences(serverId: String, enabled: Bool = true) {
        if enabled {
            serversAndChannelsStore.composerResourceServers.insert(serverId)
        } else {
            serversAndChannelsStore.composerResourceServers.remove(serverId)
        }
    }

    /// Stores a switcher order and version for one user.
    public func seedServerSwitcherOrder(userId: String, ids: [String], version: Int) {
        serversAndChannelsStore.serverSwitcherOrders[userId] = (ids, version)
    }
}
