// Test seams for attachments and notifications: kill switch, account/identity pokes,
// the agent attachment presign handler and agent credential/grant revocation.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    /// Operator kill switch for `/internal/agent-api` and `/internal/computer`.
    /// `SLOCK_EXPERIMENTAL_SURFACES_DISABLED=true` disables them; tests may
    /// override without touching the process environment.
    public func setExperimentalSurfacesDisabledForTesting(_ value: Bool?) {
        lock.lock()
        experimentalSurfacesDisabledOverride = value
        lock.unlock()
    }

    public func setAccountProfileForTesting(id: String, name: String, displayName: String? = nil) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == id })?.key,
           var account = accounts[key] {
            account.name = name
            account.displayName = displayName ?? name
            accounts[key] = account
        }
        lock.unlock()
    }

    public func socialCompletionUserIdForTesting(provider: String, code: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        guard let completion = socialCompletions.first(where: { $0.provider == provider && $0.code == code }) else {
            return nil
        }
        return .some(completion.userId)
    }

    public func setAgentAttachmentPresignForTesting(_ handler: (@Sendable (String, Int, String, String) throws -> String)?) {
        lock.lock()
        agentAttachmentPresign = handler
        lock.unlock()
    }

    public func addAgentAttachmentForTesting(
        channelId: String,
        id: String,
        uploaderId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        storageKey: String? = nil,
        bytes: Data
    ) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: nil,
            messagePosition: nil,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            storageKey: storageKey
        )
        agentAttachmentBytes[id] = bytes
        lock.unlock()
    }

    public func setAgentAudienceStatusForTesting(agentId: String, status: String) {
        lock.lock()
        agentAudienceStatusOverrides[agentId] = status
        lock.unlock()
    }

    public func revokeAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        lock.lock()
        agentIntegrationGrants["\(agentId)\n\(clientKey)"] = true
        lock.unlock()
    }

    public func restoreAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        lock.lock()
        agentIntegrationGrants["\(agentId)\n\(clientKey)"] = false
        lock.unlock()
    }

    public func revokeAgentCredentialForTesting(apiKey: String) {
        lock.lock()
        agentCredentials[apiKey]?.revokedAt = Date()
        lock.unlock()
    }
}
