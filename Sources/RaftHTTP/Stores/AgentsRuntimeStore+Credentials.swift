import Foundation

extension AgentsRuntimeStore {
    // MARK: - Agent send delivery

    /// Reads one agent credential without changing it. The caller still checks
    /// `revokedAt` and the agent runtime row.
    func agentCredential(token: String) -> (agentId: String, scopes: [String], revokedAt: Date?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = storage.agentCredentials[token] else { return nil }
        return (credential.agentId, Array(credential.scopes), credential.revokedAt)
    }

    /// The shared agent-credential check: a present, unrevoked credential is
    /// marked used and its identity returned in one critical section.

    /// The `agentCredentialAgent` read, kept in one critical section: a revoked
    /// credential does not resolve and a live one records the use.
    func useAgentCredential(token: String, now: Date) -> (agentId: String, scopes: [String])? {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = storage.agentCredentials[token], credential.revokedAt == nil else {
            return nil
        }
        storage.agentCredentials[token]?.lastUsedAt = now
        return (credential.agentId, Array(credential.scopes))
    }

    /// The `agentCapabilityDenial` predicate: a live credential that does not
    /// carry the required scope is the only denial.
    func agentCredentialLacksScope(token: String, required: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = storage.agentCredentials[token], credential.revokedAt == nil else {
            return false
        }
        return !credential.scopes.contains(required)
    }

    /// Raw credential lookup used by the profile update. The upstream handler
    /// does not re-check revocation here, and the parity test set depends on
    /// that reading.
    func agentId(forCredentialToken token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentCredentials[token]?.agentId
    }
}
