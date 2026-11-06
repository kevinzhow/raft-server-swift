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
        lock.lock(); translationProviderOverride = provider; lock.unlock()
    }

    public func messageTranslationForTesting(messageId: String) -> (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)? {
        lock.lock(); defer { lock.unlock() }
        return messageTranslationLedger[messageId]
    }
}
