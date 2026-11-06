// Test seams for server profile and ordering: gates, timezone, translation provider.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func setLegacyTimezoneObservationForTesting(userId: String, timezone: String, at: Date) {
        authProfileStore.state.withLock { state in
            state.profile.timezoneObservations[userId] = TimezoneObservation(
                firstTimezone: timezone,
                firstAt: at,
                lastTimezone: timezone,
                lastAt: at
            )
        }
    }

    public func assignAgentMachineForTesting(agentId: String, machineId: String) {
        agentsRuntimeStore.withState { state in
            state.agentMachineIds[agentId] = machineId
        }
    }

    public func setRemoteUpgradeGateForTesting(serverId: String, enabled: Bool) {
        agentsRuntimeStore.withState { state -> Void in
            if enabled { state.remoteUpgradeDisabledServers.remove(serverId) } else { state.remoteUpgradeDisabledServers.insert(serverId) }
        }
    }

    public func enableGrokRuntimeForTesting(serverId: String, enabled: Bool = true) {
        agentsRuntimeStore.withState { state -> Void in
            if enabled { state.grokRuntimeServers.insert(serverId) } else { state.grokRuntimeServers.remove(serverId) }
        }
    }

    public func setTranslationProviderForTesting(_ provider: String?) {
        messagesAndThreadsStore.withState { state in
            state.translationProviderOverride = provider
        }
    }

    public func messageTranslationForTesting(messageId: String) -> (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)? {
        messagesAndThreadsStore.withState { state in
            state.messageTranslationLedger[messageId]
        }
    }

    /// Enables or disables the composer resource references (and so the apps
    /// list) for one server.
    public func enableComposerResourceReferences(serverId: String, enabled: Bool = true) {
        serversAndChannelsStore.mutex.withLock { state -> Void in
            if enabled {
                state.composerResourceServers.insert(serverId)
            } else {
                state.composerResourceServers.remove(serverId)
            }
        }
    }

    /// Stores a switcher order and version for one user.
    public func seedServerSwitcherOrder(userId: String, ids: [String], version: Int) {
        serversAndChannelsStore.mutex.withLock { state in
            state.serverSwitcherOrders[userId] = (ids, version)
        }
    }
}
