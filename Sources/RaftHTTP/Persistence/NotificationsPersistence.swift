import Foundation

/// Every business field of NotificationsStore.State. NativeNotificationStore is
/// the separate fourteenth payload, exported from that same retained instance.
/// Excluded runtime fields: fcmPushAvailable, webPushEnabled,
/// announcementImageStorageAvailable, mobileEmailDeployment, nativeDeployment,
/// cancelMobileAppEmail, onAgentReadUpdated, nativeNotificationLiveWriteHook and
/// nativeNotificationAttestationVerifier. Restore leaves all nine unchanged.
private struct NotificationsBusinessSnapshot: Codable, Sendable {
    let pushRegistrations: [NotificationsPushRegistrationRow]
    let webPushSubscriptions: [NotificationsWebPushRow]
    /// Absent in snapshots written before prompt telemetry was retained.
    let pushPromptEvents: [NotificationsPushPromptEventRow]?
    let announcements: [NotificationsAnnouncementRow]
    let announcementImageAssets: [String: NotificationsAnnouncementAssetRow]
    let announcementDismissals: [String]
    let serverNotificationPrefs: [String: NotificationsServerPrefRow]

    init(_ state: NotificationsStore.State) {
        pushRegistrations = state.pushRegistrations.map(NotificationsPushRegistrationRow.init)
        webPushSubscriptions = state.webPushSubscriptions.map(NotificationsWebPushRow.init)
        pushPromptEvents = state.pushPromptEvents.map(NotificationsPushPromptEventRow.init)
        announcements = state.announcements.map(NotificationsAnnouncementRow.init)
        announcementImageAssets = state.announcementImageAssets.mapValues(NotificationsAnnouncementAssetRow.init)
        announcementDismissals = state.announcementDismissals.sorted()
        serverNotificationPrefs = state.serverNotificationPrefs.mapValues(NotificationsServerPrefRow.init)
    }
}

private struct NotificationsPushRegistrationRow: Codable, Sendable {
    let installationId: String
    let provider: String
    let env: String
    let topic: String
    let deviceToken: String
    let appVersion: NotificationsPersistenceCoding.RequiredOptional<String>
    let userId: NotificationsPersistenceCoding.RequiredOptional<String>
    let serverId: NotificationsPersistenceCoding.RequiredOptional<String>
    let sessionFamilyId: NotificationsPersistenceCoding.RequiredOptional<String>
    let revokeCapability: String

    init(_ row: PushRegistration) {
        installationId = row.installationId
        provider = row.provider
        env = row.env
        topic = row.topic
        deviceToken = row.deviceToken
        appVersion = .init(row.appVersion)
        userId = .init(row.userId)
        serverId = .init(row.serverId)
        sessionFamilyId = .init(row.sessionFamilyId)
        revokeCapability = row.revokeCapability
    }

    var record: PushRegistration {
        PushRegistration(
            installationId: installationId, provider: provider, env: env, topic: topic,
            deviceToken: deviceToken, appVersion: appVersion.value, userId: userId.value,
            serverId: serverId.value, sessionFamilyId: sessionFamilyId.value, revokeCapability: revokeCapability
        )
    }
}

private struct NotificationsWebPushRow: Codable, Sendable {
    let userId: String
    let endpoint: String

    init(_ row: WebPushSubscription) {
        userId = row.userId
        endpoint = row.endpoint
    }

    var record: WebPushSubscription { WebPushSubscription(userId: userId, endpoint: endpoint) }
}

private struct NotificationsPushPromptEventRow: Codable, Sendable {
    let userId: String
    let serverId: NotificationsPersistenceCoding.RequiredOptional<String>
    let event: String
    let trigger: String
    let result: NotificationsPersistenceCoding.RequiredOptional<String>
    let permissionBefore: NotificationsPersistenceCoding.RequiredOptional<String>
    let permissionAfter: NotificationsPersistenceCoding.RequiredOptional<String>
    let detail: NotificationsPersistenceCoding.RequiredOptional<String>
    let createdAt: Date

    init(_ row: PushPromptEvent) {
        userId = row.userId
        serverId = .init(row.serverId)
        event = row.event
        trigger = row.trigger
        result = .init(row.result)
        permissionBefore = .init(row.permissionBefore)
        permissionAfter = .init(row.permissionAfter)
        detail = .init(row.detail)
        createdAt = row.createdAt
    }

    var record: PushPromptEvent {
        PushPromptEvent(
            userId: userId, serverId: serverId.value, event: event, trigger: trigger,
            result: result.value, permissionBefore: permissionBefore.value,
            permissionAfter: permissionAfter.value, detail: detail.value, createdAt: createdAt
        )
    }
}

private struct NotificationsAnnouncementRow: Codable, Sendable {
    let id: String
    let title: String
    let pages: [String]
    let startsAt: Date
    let expiresAt: NotificationsPersistenceCoding.RequiredOptional<Date>
    let status: String
    let publishedAt: NotificationsPersistenceCoding.RequiredOptional<Date>
    let imageId: NotificationsPersistenceCoding.RequiredOptional<String>
    let audienceServerIds: [String]

    init(_ row: NotificationsStore.AnnouncementRow) {
        id = row.id
        title = row.title
        pages = row.pages
        startsAt = row.startsAt
        expiresAt = .init(row.expiresAt)
        status = row.status
        publishedAt = .init(row.publishedAt)
        imageId = .init(row.imageId)
        audienceServerIds = row.audienceServerIds
    }

    var record: NotificationsStore.AnnouncementRow {
        (id: id, title: title, pages: pages, startsAt: startsAt, expiresAt: expiresAt.value,
         status: status, publishedAt: publishedAt.value, imageId: imageId.value,
         audienceServerIds: audienceServerIds)
    }
}

private struct NotificationsAnnouncementAssetRow: Codable, Sendable {
    let id: String
    let announcementId: String
    let contentType: String
    let bytes: Data

    init(_ row: AnnouncementImageAsset) {
        id = row.id
        announcementId = row.announcementId
        contentType = row.contentType
        bytes = row.bytes
    }

    var record: AnnouncementImageAsset {
        AnnouncementImageAsset(id: id, announcementId: announcementId, contentType: contentType, bytes: bytes)
    }
}

private struct NotificationsServerPrefRow: Codable, Sendable {
    let muted: Bool
    let mentionsOnly: Bool
    let mode: String
    let version: Int

    init(_ row: NotificationsStore.ServerNotificationPref) {
        muted = row.muted
        mentionsOnly = row.mentionsOnly
        mode = row.mode
        version = row.version
    }

    var record: NotificationsStore.ServerNotificationPref {
        (muted: muted, mentionsOnly: mentionsOnly, mode: mode, version: version)
    }
}

extension NotificationsStore {
    /// Sensitive opaque business data; no live provider configuration or callbacks.
    /// Encoding follows the coherent locked copy, outside the owner lock.
    func exportOpaqueData() throws -> Data {
        let snapshot = storage.withLock { NotificationsBusinessSnapshot($0) }
        return try NotificationsPersistenceCoding.encode(snapshot, owner: "raft.notifications")
    }

    /// All decoding, nullable-key checks, Date validation and row reconstruction
    /// finish before the single critical section. The native owner is not replaced
    /// or touched here: its independent payload must participate in the caller's
    /// full fourteen-payload transaction.
    func restoreOpaqueData(_ data: Data) throws {
        let snapshot = try NotificationsPersistenceCoding.decode(
            NotificationsBusinessSnapshot.self, from: data, owner: "raft.notifications"
        )
        let pushRegistrations = snapshot.pushRegistrations.map(\.record)
        let webPushSubscriptions = snapshot.webPushSubscriptions.map(\.record)
        let pushPromptEvents = (snapshot.pushPromptEvents ?? []).map(\.record)
        let announcements = snapshot.announcements.map(\.record)
        let announcementImageAssets = snapshot.announcementImageAssets.mapValues(\.record)
        let announcementDismissals = Set(snapshot.announcementDismissals)
        guard announcementDismissals.count == snapshot.announcementDismissals.count else {
            throw NotificationsPersistenceCoding.Failure.invalidSnapshot
        }
        let serverNotificationPrefs = snapshot.serverNotificationPrefs.mapValues(\.record)
        storage.withLock { state in
            state.pushRegistrations = pushRegistrations
            state.webPushSubscriptions = webPushSubscriptions
            state.pushPromptEvents = pushPromptEvents
            state.announcements = announcements
            state.announcementImageAssets = announcementImageAssets
            state.announcementDismissals = announcementDismissals
            state.serverNotificationPrefs = serverNotificationPrefs
        }
    }
}
