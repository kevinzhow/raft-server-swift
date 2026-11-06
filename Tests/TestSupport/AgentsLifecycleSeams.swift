// Test seams for the agent lifecycle service: channel flags, attachments, attestation config.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func removeChannelMemberForTesting(channelId: String, userId: String) {
        oauth.removeChannelHuman(channelId: channelId, userId: userId)
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(userId)
        lock.unlock()
    }

    public func setChannelGuestVisibleForTesting(channelId: String, visible: Bool) {
        lock.lock()
        guestVisibleChannels[channelId] = visible
        lock.unlock()
    }

    public func setChannelGuestJoinableForTesting(channelId: String, joinable: Bool) {
        lock.lock()
        guestJoinableChannels[channelId] = joinable
        lock.unlock()
    }

    public func setChannelPostablePrivateForTesting(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.kind = "private"
        lock.unlock()
    }

    public func addChannelAttachmentForTesting(channelId: String, id: String, uploaderId: String, filename: String) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(id: id, channelId: channelId, uploaderId: uploaderId, filename: filename, messageId: nil, messagePosition: nil)
        lock.unlock()
    }

    public func addChannelFileForTesting(
        channelId: String,
        id: String,
        uploaderId: String,
        uploaderType: String = "user",
        messageId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        createdAt: Date,
        thumbnailKey: String? = nil
    ) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: messageId,
            messagePosition: 0,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            uploaderType: uploaderType,
            createdAt: createdAt,
            thumbnailKey: thumbnailKey
        )
        lock.unlock()
    }

    public func setScopeAttestationSecretForTesting(_ secret: String?) {
        lock.lock()
        authProfileStore.scopeAttestationSecretOverride = .some(secret)
        lock.unlock()
    }

    public func setDeploymentEnvironmentForTesting(_ environment: String?) {
        lock.lock()
        authProfileStore.deploymentEnvironmentOverride = .some(environment)
        lock.unlock()
    }

    public func setComputerAttachEnabledForTesting(_ enabled: Bool?) {
        lock.lock()
        computerAttachEnabledOverride = enabled
        lock.unlock()
    }

    public func setShareUsageData(userId: String, value: Bool?) {
        var state = authProfileStore.accountState
        if let key = state.accounts.first(where: { $0.value.id == userId })?.key {
            state.accounts[key]?.shareUsageData = value
            authProfileStore.accountState = state
        }
    }

    public func recordedProductEvents(subjectId: String) -> [RecordedProductEvent] {
        productEventStore.productEvents(subjectId: subjectId)
    }

    public func recordedClientEvents(serverId: String) -> [ClientEventRecord] {
        productEventStore.clientEvents(serverId: serverId)
    }
}
