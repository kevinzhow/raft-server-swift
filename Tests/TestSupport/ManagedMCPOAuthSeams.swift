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
        lock.lock()
        announcements.append((
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
        lock.unlock()
        return id
    }

    public func setAnnouncementStateForTesting(
        id: String,
        status: String,
        publishedAt: Date?,
        startsAt: Date
    ) {
        lock.lock()
        if let index = announcements.firstIndex(where: { $0.id == id }) {
            announcements[index].status = status
            announcements[index].publishedAt = publishedAt
            announcements[index].startsAt = startsAt
        }
        lock.unlock()
    }

    public func addAnnouncementImageForTesting(id: String, announcementId: String, contentType: String, bytes: Data) {
        lock.lock()
        notificationsStore.announcementImageAssets[id] = AnnouncementImageAsset(
            id: id,
            announcementId: announcementId,
            contentType: contentType,
            bytes: bytes
        )
        lock.unlock()
    }

    public func addExternalAvatarForTesting(
        id: String,
        contentType: String = "image/webp",
        bytes: Data,
        sourceDigest: String,
        active: Bool = true
    ) {
        lock.lock()
        messagesAndThreadsStore.externalAvatarAssets[id] = ExternalAvatarAsset(
            id: id,
            contentType: contentType,
            bytes: bytes,
            sourceDigest: sourceDigest,
            active: active
        )
        lock.unlock()
    }

    public func setExternalAvatarStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        messagesAndThreadsStore.externalAvatarStorageAvailable = available
        lock.unlock()
    }

    public func setAnnouncementImageStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        notificationsStore.announcementImageStorageAvailable = available
        lock.unlock()
    }

    public func setUserChannelReadCursorForTesting(userId: String, channelId: String, seq: Int) {
        lock.lock()
        userChannelReadCursors["\(userId)\n\(channelId)"] = seq
        lock.unlock()
    }

    public func softDeleteAgentReminderSurfaceForTesting(agentId: String) {
        lock.lock()
        if let channelId = agentReminderSurfaceChannels[agentId] {
            postableChannels[channelId]?.deletedAt = Date()
        }
        lock.unlock()
    }

    public func agentReminderSurfaceForTesting(agentId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return agentReminderSurfaceChannels[agentId]
    }
}
