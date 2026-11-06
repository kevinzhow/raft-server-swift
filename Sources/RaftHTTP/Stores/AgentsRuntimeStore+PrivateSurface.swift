import Foundation

/// A stored archive row of one agent, as the archived-agents list publishes it.
struct ArchivedAgentFact: Sendable, Equatable {
    var agentId: String
    var machineName: String
    var workspaceState: String
}

/// Credential, presence, webhook and assistant-link rows behind the agent
/// private surface. Each read-modify-write is one critical section.
extension AgentsRuntimeStore {
    /// Records one use of a live credential: stamps the credential and the
    /// agent's last-seen time unless the previous use is inside the throttle.
    /// Returns the agent id when a use was recorded, `nil` when the credential
    /// is unknown, revoked or throttled.
    func recordCredentialUse(token: String, now: Date, defaultThrottleMs: Int) -> String? {
        withState { state in
            guard var credential = state.agentCredentials[token], credential.revokedAt == nil else {
                return nil
            }
            let throttle = state.agentCredentialUseThrottleOverrideMs ?? defaultThrottleMs
            if let last = credential.lastUsedAt, now.timeIntervalSince(last) * 1000 < Double(throttle) {
                return nil
            }
            credential.lastUsedAt = now
            state.agentCredentials[token] = credential
            state.agentLastSeenAt[credential.agentId] = now
            return credential.agentId
        }
    }

    /// Whether any credential was minted for the agent and when one was last used.
    func credentialUsage(agentId: String) -> (minted: Bool, lastUsedAt: Date?) {
        withState { state in
            let credentials = state.agentCredentials.values.filter { $0.agentId == agentId }
            return (!credentials.isEmpty, credentials.compactMap { $0.lastUsedAt }.max())
        }
    }

    func archivedAgents(serverId: String) -> [ArchivedAgentFact] {
        withState { state in
            state.agentArchiveRecords
                .filter { $0.value.serverId == serverId }
                .map { ArchivedAgentFact(
                    agentId: $0.key,
                    machineName: $0.value.machineName,
                    workspaceState: $0.value.workspaceState
                ) }
        }
    }

    func hostedRuntimeEnabled(serverId: String) -> Bool {
        withState { $0.hostedRuntimeServers.contains(serverId) }
    }

    func bindMachine(agentId: String, machineId: String) {
        withState { $0.agentMachineIds[agentId] = machineId }
    }

    /// A new hosted agent starts in `provisioning`.
    func beginHostedProvisioning(agentId: String, provider: String, now: Date) {
        withState { $0.hostedRuntimes[agentId] = (provider, nil, "provisioning", false, now) }
    }

    func setPushWebhook(agentId: String, url: String, secret: String) {
        withState { $0.externalPushWebhooks[agentId] = (url: url, secret: secret) }
    }

    func lastSeenSnapshot() -> [String: Date] {
        withState { $0.agentLastSeenAt }
    }

    // MARK: - Assistant link

    func assistantOwner(agentId: String) -> String? {
        withState { $0.assistantOwners[agentId] }
    }

    func clearAssistantOwner(agentId: String) {
        withState { _ = $0.assistantOwners.removeValue(forKey: agentId) }
    }

    /// Whether `userId` already lends another live assistant. `isLive` answers
    /// for a candidate agent id.
    func hasAssistantConflict(userId: String, agentId: String, isLive: (String) -> Bool) -> Bool {
        withState { state in
            state.assistantOwners.contains { candidate, owner in
                owner == userId && candidate != agentId && isLive(candidate)
            }
        }
    }

    /// Links the assistant unless the owner already lends another live
    /// assistant; the check and the write are one critical section, so two
    /// concurrent claims cannot both link.
    func claimAssistantOwner(agentId: String, userId: String, isLive: (String) -> Bool) -> Bool {
        withState { state in
            let conflict = state.assistantOwners.contains { candidate, owner in
                owner == userId && candidate != agentId && isLive(candidate)
            }
            guard !conflict else { return false }
            state.assistantOwners[agentId] = userId
            return true
        }
    }
}
