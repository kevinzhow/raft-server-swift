import Foundation
import Synchronization

/// Owns the notification, announcement and push rows that used to be stored
/// inline on `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class NotificationsStore: Sendable {
    /// One announcement row. Kept as a tuple because every existing projection
    /// treats it as an anonymous record rather than a named model.
    typealias AnnouncementRow = (
        id: String,
        title: String,
        pages: [String],
        startsAt: Date,
        expiresAt: Date?,
        status: String,
        publishedAt: Date?,
        imageId: String?,
        audienceServerIds: [String]
    )

    /// One per-server notification preference row.
    typealias ServerNotificationPref = (
        muted: Bool,
        mentionsOnly: Bool,
        mode: String,
        version: Int
    )

    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State: Sendable {
        var pushRegistrations: [EmailLoginDirectory.PushRegistration] = []
        var fcmPushAvailable = true
        var webPushEnabled = true
        var webPushSubscriptions: [WebPushSubscription] = []
        var announcements: [AnnouncementRow] = []
        var announcementImageAssets: [String: AnnouncementImageAsset] = [:]
        var announcementImageStorageAvailable = true
        var announcementDismissals: Set<String> = []
        var serverNotificationPrefs: [String: ServerNotificationPref] = [:]
        // Injectable notification/mobile-email configuration that used to live
        // inline on `EmailLoginDirectory`.
        var mobileAppEmailUnsubscribeSecret: String = "test-jwt-secret"
        var cancelMobileAppEmail: (@Sendable (String) -> Void)? = nil
        var nativeNotificationsEnabled: Bool = false
        var nativeNotificationStreamPollMs: Int = 1000
        var onAgentReadUpdated: (@Sendable (String, String, String, Int) -> Void)? = nil
        var nativeNotificationLiveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)? = nil
        var nativeNotificationAttestationMode: String? = nil
        var nativeNotificationNodeEnv: String = "development"
        var nativeNotificationAttestationVerifier: (@Sendable (String) -> Bool)? = nil
    }

    private let storage = Mutex(State())

    /// Enrollment grants, devices, native credentials and the event ledger.
    /// A `Mutex`-guarded store of its own; this store keeps only the kill
    /// switch, attestation and stream configuration beside it.
    let native = NativeNotificationStore()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    var pushRegistrations: [EmailLoginDirectory.PushRegistration] {
        get { storage.withLock { $0.pushRegistrations } }
        set { storage.withLock { $0.pushRegistrations = newValue } }
    }

    var fcmPushAvailable: Bool {
        get { storage.withLock { $0.fcmPushAvailable } }
        set { storage.withLock { $0.fcmPushAvailable = newValue } }
    }

    var webPushEnabled: Bool {
        get { storage.withLock { $0.webPushEnabled } }
        set { storage.withLock { $0.webPushEnabled = newValue } }
    }

    var webPushSubscriptions: [WebPushSubscription] {
        get { storage.withLock { $0.webPushSubscriptions } }
        set { storage.withLock { $0.webPushSubscriptions = newValue } }
    }

    var announcements: [AnnouncementRow] {
        get { storage.withLock { $0.announcements } }
        set { storage.withLock { $0.announcements = newValue } }
    }

    var announcementImageAssets: [String: AnnouncementImageAsset] {
        get { storage.withLock { $0.announcementImageAssets } }
        set { storage.withLock { $0.announcementImageAssets = newValue } }
    }

    var announcementImageStorageAvailable: Bool {
        get { storage.withLock { $0.announcementImageStorageAvailable } }
        set { storage.withLock { $0.announcementImageStorageAvailable = newValue } }
    }

    var announcementDismissals: Set<String> {
        get { storage.withLock { $0.announcementDismissals } }
        set { storage.withLock { $0.announcementDismissals = newValue } }
    }

    var serverNotificationPrefs: [String: ServerNotificationPref] {
        get { storage.withLock { $0.serverNotificationPrefs } }
        set { storage.withLock { $0.serverNotificationPrefs = newValue } }
    }

    // MARK: - Injected notification and mobile-email configuration

    var mobileAppEmailUnsubscribeSecret: String {
        get { storage.withLock { $0.mobileAppEmailUnsubscribeSecret } }
        set { storage.withLock { $0.mobileAppEmailUnsubscribeSecret = newValue } }
    }

    var cancelMobileAppEmail: (@Sendable (String) -> Void)? {
        get { storage.withLock { $0.cancelMobileAppEmail } }
        set { storage.withLock { $0.cancelMobileAppEmail = newValue } }
    }

    var nativeNotificationsEnabled: Bool {
        get { storage.withLock { $0.nativeNotificationsEnabled } }
        set { storage.withLock { $0.nativeNotificationsEnabled = newValue } }
    }

    var nativeNotificationStreamPollMs: Int {
        get { storage.withLock { $0.nativeNotificationStreamPollMs } }
        set { storage.withLock { $0.nativeNotificationStreamPollMs = newValue } }
    }

    var onAgentReadUpdated: (@Sendable (String, String, String, Int) -> Void)? {
        get { storage.withLock { $0.onAgentReadUpdated } }
        set { storage.withLock { $0.onAgentReadUpdated = newValue } }
    }

    var nativeNotificationLiveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)? {
        get { storage.withLock { $0.nativeNotificationLiveWriteHook } }
        set { storage.withLock { $0.nativeNotificationLiveWriteHook = newValue } }
    }

    var nativeNotificationAttestationMode: String? {
        get { storage.withLock { $0.nativeNotificationAttestationMode } }
        set { storage.withLock { $0.nativeNotificationAttestationMode = newValue } }
    }

    var nativeNotificationNodeEnv: String {
        get { storage.withLock { $0.nativeNotificationNodeEnv } }
        set { storage.withLock { $0.nativeNotificationNodeEnv = newValue } }
    }

    var nativeNotificationAttestationVerifier: (@Sendable (String) -> Bool)? {
        get { storage.withLock { $0.nativeNotificationAttestationVerifier } }
        set { storage.withLock { $0.nativeNotificationAttestationVerifier = newValue } }
    }

    // MARK: - Server notification preferences

    /// The preference row of one `serverId\nuserId` key; a member who never
    /// patched reads the default row at version 0.
    func serverNotificationPref(key: String) -> ServerNotificationPref {
        return storage.withLock { storage in
            return storage.serverNotificationPrefs[key] ?? Self.defaultServerNotificationPref
        }
    }

    /// One locked patch of a member's server notification row.
    ///
    /// `mode` sets the mode and derives `muted`/`mentionsOnly` from it; `muted`
    /// is applied afterwards and wins (muting forces mode `none`, unmuting from
    /// `none` returns to `all`). The version advances only when the stored row
    /// actually changed, and the read, the decision and the write share the
    /// lock so two concurrent patches cannot both read the same version.
    func patchServerNotificationPref(
        key: String,
        mode: String?,
        muted: Bool?
    ) -> (prefs: ServerNotificationPref, changed: Bool) {
        return storage.withLock { storage in
            var prefs = storage.serverNotificationPrefs[key] ?? Self.defaultServerNotificationPref
            if let mode {
                prefs.mode = mode
                prefs.muted = mode == "none"
                prefs.mentionsOnly = mode == "mentions"
            }
            if let muted {
                prefs.muted = muted
                if muted {
                    prefs.mode = "none"
                    prefs.mentionsOnly = false
                } else if prefs.mode == "none" {
                    prefs.mode = "all"
                    prefs.mentionsOnly = false
                }
            }
            let previous = storage.serverNotificationPrefs[key]
            let changed = previous == nil
                || previous!.muted != prefs.muted
                || previous!.mentionsOnly != prefs.mentionsOnly
                || previous!.mode != prefs.mode
            if changed {
                prefs.version = (previous?.version ?? 0) + 1
            }
            storage.serverNotificationPrefs[key] = prefs
            return (prefs, changed)
        }
    }

    private static let defaultServerNotificationPref: ServerNotificationPref = (
        muted: false, mentionsOnly: false, mode: "all", version: 0
    )
}

// MARK: - Managed MCP lifecycle: push registration sections

extension NotificationsStore {
    /// Inserts or replaces the registration of `(installationId, provider)` in
    /// one critical section, so two registrations of one installation cannot
    /// both append a row.
    func upsertPushRegistration(_ registration: EmailLoginDirectory.PushRegistration) {
        storage.withLock { storage -> Void in
            if let index = storage.pushRegistrations.firstIndex(where: {
                $0.installationId == registration.installationId && $0.provider == registration.provider
            }) {
                storage.pushRegistrations[index].env = registration.env
                storage.pushRegistrations[index].topic = registration.topic
                storage.pushRegistrations[index].deviceToken = registration.deviceToken
                storage.pushRegistrations[index].appVersion = registration.appVersion
                storage.pushRegistrations[index].userId = registration.userId
                storage.pushRegistrations[index].serverId = registration.serverId
                storage.pushRegistrations[index].sessionFamilyId = registration.sessionFamilyId
                storage.pushRegistrations[index].revokeCapability = registration.revokeCapability
            } else {
                storage.pushRegistrations.append(registration)
            }
        }
    }

    /// Detaches every registration of the installation from its user, server
    /// and session family and answers how many rows changed.
    func unbindPushInstallation(installationId: String) -> Int {
        return storage.withLock { storage in
            var unbound = 0
            for index in storage.pushRegistrations.indices
            where storage.pushRegistrations[index].installationId == installationId {
                storage.pushRegistrations[index].userId = nil
                storage.pushRegistrations[index].serverId = nil
                storage.pushRegistrations[index].sessionFamilyId = nil
                unbound += 1
            }
            return unbound
        }
    }

    /// Whether FCM delivery is available and `userId` registered the
    /// installation for it, from one snapshot.
    func isFcmActive(installationId: String, userId: String) -> Bool {
        return storage.withLock { storage in
            return storage.fcmPushAvailable && storage.pushRegistrations.contains {
                $0.installationId == installationId && $0.provider == "fcm" && $0.userId == userId
            }
        }
    }

    /// Records one browser push subscription unless the pair already exists.
    func recordWebPushSubscription(userId: String, endpoint: String) {
        storage.withLock { storage -> Void in
            if !storage.webPushSubscriptions.contains(where: { $0.userId == userId && $0.endpoint == endpoint }) {
                storage.webPushSubscriptions.append(WebPushSubscription(userId: userId, endpoint: endpoint))
            }
        }
    }

    /// Records that `userId` dismissed the announcement.
    func insertAnnouncementDismissal(userId: String, announcementId: String) {
        storage.withLock { storage -> Void in
            storage.announcementDismissals.insert("\(userId)\n\(announcementId)")
        }
    }

    /// The announcement row, the image asset and the storage flags a read
    /// needs, from one snapshot.
    func announcementImageSnapshot(
        imageId: String
    ) -> (asset: AnnouncementImageAsset?, announcement: AnnouncementRow?, storageAvailable: Bool) {
        return storage.withLock { storage in
            let asset = storage.announcementImageAssets[imageId]
            let announcement = storage.announcements.first { $0.id == asset?.announcementId }
            return (asset, announcement, storage.announcementImageStorageAvailable)
        }
    }

    /// The published, started, unexpired, undismissed announcements in start
    /// order from one snapshot; `visible` is the audience predicate.
    func firstActiveAnnouncement(
        userId: String,
        after: String?,
        now: Date,
        visible: @Sendable (AnnouncementRow) -> Bool
    ) -> AnnouncementRow? {
        return storage.withLock { storage in
            return storage.announcements
                .filter { $0.status == "published" && $0.publishedAt != nil }
                .filter { $0.startsAt <= now && ($0.expiresAt == nil || $0.expiresAt! > now) }
                .filter(visible)
                .filter { !storage.announcementDismissals.contains("\(userId)\n\($0.id)") }
                .filter { after == nil || $0.id != after }
                .sorted { $0.startsAt < $1.startsAt }
                .first
        }
    }

    /// One announcement by id.
    func announcement(id: String) -> AnnouncementRow? {
        return storage.withLock { storage in
            return storage.announcements.first { $0.id == id }
        }
    }
}
