// Test seams for the agent lifecycle service: channel flags, attachments, attestation config.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func removeChannelMemberForTesting(channelId: String, userId: String) {
        oauth.removeChannelHuman(channelId: channelId, userId: userId)
        serversAndChannelsStore.mutex.withLock { owned in
            _ = owned.postableChannels[channelId]?.memberIds.remove(userId)
        }
    }

    public func setChannelGuestVisibleForTesting(channelId: String, visible: Bool) {
        serversAndChannelsStore.mutex.withLock { owned in
            owned.guestVisibleChannels[channelId] = visible
        }
    }

    public func setChannelGuestJoinableForTesting(channelId: String, joinable: Bool) {
        serversAndChannelsStore.mutex.withLock { owned in
            owned.guestJoinableChannels[channelId] = joinable
        }
    }

    public func setChannelPostablePrivateForTesting(channelId: String) {
        serversAndChannelsStore.mutex.withLock { owned in
            owned.postableChannels[channelId]?.kind = "private"
        }
    }

    public func addChannelAttachmentForTesting(channelId: String, id: String, uploaderId: String, filename: String) {
        messagesAndThreadsStore.withState { state in
            state.channelAttachments[id] = ChannelAttachment(id: id, channelId: channelId, uploaderId: uploaderId, filename: filename, messageId: nil, messagePosition: nil)
        }
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
        messagesAndThreadsStore.withState { state in
            state.channelAttachments[id] = ChannelAttachment(
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
        }
    }

    public func setScopeAttestationSecretForTesting(_ secret: String?) {
        authProfileStore.scopeAttestationSecretOverride = .some(secret)
    }

    public func setDeploymentEnvironmentForTesting(_ environment: String?) {
        authProfileStore.deploymentEnvironmentOverride = .some(environment)
    }

    public func setComputerAttachEnabledForTesting(_ enabled: Bool?) {
        machinesAndComputersStore.storage.withLock { owned in
            owned.computerAttachEnabledOverride = enabled
        }
    }

    public func setShareUsageData(userId: String, value: Bool?) {
        authProfileStore.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
                owned.accountSurface.accounts[key]?.shareUsageData = value
            }
        }
    }

    public func recordedProductEvents(subjectId: String) -> [RecordedProductEvent] {
        productEventStore.productEvents(subjectId: subjectId)
    }

    public func recordedClientEvents(serverId: String) -> [ClientEventRecord] {
        productEventStore.clientEvents(serverId: serverId)
    }
}
