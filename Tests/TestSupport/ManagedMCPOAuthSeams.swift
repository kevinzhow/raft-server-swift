@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func addAnnouncementForTesting(
        title: String,
        pages: [String],
        startsAt: Date = Date(),
        expiresAt: Date? = nil,
        status: String = "published",
        publishedAt: Date? = nil,
        imageId: String? = nil,
        audienceServerIds: [String] = []
    ) -> String {
        let id = UUID().uuidString.lowercased()
        notificationsStore.storage.withLock { owned in
            owned.announcements.append((
                id: id,
                title: title,
                pages: pages,
                startsAt: startsAt,
                expiresAt: expiresAt,
                status: status,
                publishedAt: publishedAt ?? (status == "draft" ? nil : Date()),
                imageId: imageId,
                audienceServerIds: audienceServerIds
            ))
        }
        return id
    }

    public func setAnnouncementStateForTesting(
        id: String,
        status: String,
        publishedAt: Date?,
        startsAt: Date
    ) {
        notificationsStore.storage.withLock { owned in
            if let index = owned.announcements.firstIndex(where: { $0.id == id }) {
                owned.announcements[index].status = status
                owned.announcements[index].publishedAt = publishedAt
                owned.announcements[index].startsAt = startsAt
            }
        }
    }

    public func addAnnouncementImageForTesting(id: String, announcementId: String, contentType: String, bytes: Data) {
        notificationsStore.storage.withLock { state in
            state.announcementImageAssets[id] = AnnouncementImageAsset(
                id: id,
                announcementId: announcementId,
                contentType: contentType,
                bytes: bytes
            )
        }
    }

    public func addExternalAvatarForTesting(
        id: String,
        contentType: String = "image/webp",
        bytes: Data,
        sourceDigest: String,
        active: Bool = true
    ) {
        messagesAndThreadsStore.withState { state in
            state.externalAvatarAssets[id] = ExternalAvatarAsset(
                id: id,
                contentType: contentType,
                bytes: bytes,
                sourceDigest: sourceDigest,
                active: active
            )
        }
    }

    public func setExternalAvatarStorageAvailableForTesting(_ available: Bool) {
        messagesAndThreadsStore.withState { state in
            state.externalAvatarStorageAvailable = available
        }
    }

    public func setAnnouncementImageStorageAvailableForTesting(_ available: Bool) {
        notificationsStore.storage.withLock { state in
            state.announcementImageStorageAvailable = available
        }
    }

    public func setUserChannelReadCursorForTesting(userId: String, channelId: String, seq: Int) {
        messagesAndThreadsStore.withState { state in
            state.userChannelReadCursors["\(userId)\n\(channelId)"] = seq
        }
    }

    public func softDeleteAgentReminderSurfaceForTesting(agentId: String) {
        guard let channelId = feedbackStore.agentReminderSurfaceChannelId(agentId: agentId) else { return }
        serversAndChannelsStore.mutex.withLock { state in
            state.postableChannels[channelId]?.deletedAt = Date()
        }
    }

    public func agentReminderSurfaceForTesting(agentId: String) -> String? {
        feedbackStore.agentReminderSurfaceChannelId(agentId: agentId)
    }
}
