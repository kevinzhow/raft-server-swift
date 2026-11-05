import Foundation

/// Owns the notification, announcement and push rows that used to be stored
/// inline on `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class NotificationsStore: @unchecked Sendable {
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
    struct State {
        var nativeNotificationEvents: [StoredNativeNotificationEvent] = []
        var nextNativeNotificationSeq = 0
        var nativeEnrollmentGrants: [StoredEnrollmentGrant] = []
        var nativeNotificationDevices: [StoredNotificationDevice] = []
        var nativeNotificationCredentials: [StoredNotificationCredential] = []
        var pushRegistrations: [EmailLoginDirectory.PushRegistration] = []
        var fcmPushAvailable = true
        var webPushEnabled = true
        var webPushSubscriptions: [WebPushSubscription] = []
        var announcements: [AnnouncementRow] = []
        var announcementImageAssets: [String: AnnouncementImageAsset] = [:]
        var announcementImageStorageAvailable = true
        var announcementDismissals: Set<String> = []
        var serverNotificationPrefs: [String: ServerNotificationPref] = [:]
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var nativeNotificationEvents: [StoredNativeNotificationEvent] {
        get { state.nativeNotificationEvents }
        set { state.nativeNotificationEvents = newValue }
    }

    var nextNativeNotificationSeq: Int {
        get { state.nextNativeNotificationSeq }
        set { state.nextNativeNotificationSeq = newValue }
    }

    var nativeEnrollmentGrants: [StoredEnrollmentGrant] {
        get { state.nativeEnrollmentGrants }
        set { state.nativeEnrollmentGrants = newValue }
    }

    var nativeNotificationDevices: [StoredNotificationDevice] {
        get { state.nativeNotificationDevices }
        set { state.nativeNotificationDevices = newValue }
    }

    var nativeNotificationCredentials: [StoredNotificationCredential] {
        get { state.nativeNotificationCredentials }
        set { state.nativeNotificationCredentials = newValue }
    }

    var pushRegistrations: [EmailLoginDirectory.PushRegistration] {
        get { state.pushRegistrations }
        set { state.pushRegistrations = newValue }
    }

    var fcmPushAvailable: Bool {
        get { state.fcmPushAvailable }
        set { state.fcmPushAvailable = newValue }
    }

    var webPushEnabled: Bool {
        get { state.webPushEnabled }
        set { state.webPushEnabled = newValue }
    }

    var webPushSubscriptions: [WebPushSubscription] {
        get { state.webPushSubscriptions }
        set { state.webPushSubscriptions = newValue }
    }

    var announcements: [AnnouncementRow] {
        get { state.announcements }
        set { state.announcements = newValue }
    }

    var announcementImageAssets: [String: AnnouncementImageAsset] {
        get { state.announcementImageAssets }
        set { state.announcementImageAssets = newValue }
    }

    var announcementImageStorageAvailable: Bool {
        get { state.announcementImageStorageAvailable }
        set { state.announcementImageStorageAvailable = newValue }
    }

    var announcementDismissals: Set<String> {
        get { state.announcementDismissals }
        set { state.announcementDismissals = newValue }
    }

    var serverNotificationPrefs: [String: ServerNotificationPref] {
        get { state.serverNotificationPrefs }
        set { state.serverNotificationPrefs = newValue }
    }
}
