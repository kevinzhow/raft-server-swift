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

    private let lock = NSLock()
    private var storage = State()

    /// Enrollment grants, devices, native credentials and the event ledger.
    /// A `Mutex`-guarded store of its own; this store keeps only the kill
    /// switch, attestation and stream configuration beside it.
    let native = NativeNotificationStore()

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

    // MARK: - Injected notification and mobile-email configuration

    var mobileAppEmailUnsubscribeSecret: String {
        get { state.mobileAppEmailUnsubscribeSecret }
        set { state.mobileAppEmailUnsubscribeSecret = newValue }
    }

    var cancelMobileAppEmail: (@Sendable (String) -> Void)? {
        get { state.cancelMobileAppEmail }
        set { state.cancelMobileAppEmail = newValue }
    }

    var nativeNotificationsEnabled: Bool {
        get { state.nativeNotificationsEnabled }
        set { state.nativeNotificationsEnabled = newValue }
    }

    var nativeNotificationStreamPollMs: Int {
        get { state.nativeNotificationStreamPollMs }
        set { state.nativeNotificationStreamPollMs = newValue }
    }

    var onAgentReadUpdated: (@Sendable (String, String, String, Int) -> Void)? {
        get { state.onAgentReadUpdated }
        set { state.onAgentReadUpdated = newValue }
    }

    var nativeNotificationLiveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)? {
        get { state.nativeNotificationLiveWriteHook }
        set { state.nativeNotificationLiveWriteHook = newValue }
    }

    var nativeNotificationAttestationMode: String? {
        get { state.nativeNotificationAttestationMode }
        set { state.nativeNotificationAttestationMode = newValue }
    }

    var nativeNotificationNodeEnv: String {
        get { state.nativeNotificationNodeEnv }
        set { state.nativeNotificationNodeEnv = newValue }
    }

    var nativeNotificationAttestationVerifier: (@Sendable (String) -> Bool)? {
        get { state.nativeNotificationAttestationVerifier }
        set { state.nativeNotificationAttestationVerifier = newValue }
    }

    // MARK: - Server notification preferences

    /// The preference row of one `serverId\nuserId` key; a member who never
    /// patched reads the default row at version 0.
    func serverNotificationPref(key: String) -> ServerNotificationPref {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverNotificationPrefs[key] ?? Self.defaultServerNotificationPref
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
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
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

    /// Detaches every registration of the installation from its user, server
    /// and session family and answers how many rows changed.
    func unbindPushInstallation(installationId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
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

    /// Whether FCM delivery is available and `userId` registered the
    /// installation for it, from one snapshot.
    func isFcmActive(installationId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.fcmPushAvailable && storage.pushRegistrations.contains {
            $0.installationId == installationId && $0.provider == "fcm" && $0.userId == userId
        }
    }

    /// Records one browser push subscription unless the pair already exists.
    func recordWebPushSubscription(userId: String, endpoint: String) {
        lock.lock()
        defer { lock.unlock() }
        if !storage.webPushSubscriptions.contains(where: { $0.userId == userId && $0.endpoint == endpoint }) {
            storage.webPushSubscriptions.append(WebPushSubscription(userId: userId, endpoint: endpoint))
        }
    }

    /// Records that `userId` dismissed the announcement.
    func insertAnnouncementDismissal(userId: String, announcementId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.announcementDismissals.insert("\(userId)\n\(announcementId)")
    }

    /// The announcement row, the image asset and the storage flags a read
    /// needs, from one snapshot.
    func announcementImageSnapshot(
        imageId: String
    ) -> (asset: AnnouncementImageAsset?, announcement: AnnouncementRow?, storageAvailable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let asset = storage.announcementImageAssets[imageId]
        let announcement = storage.announcements.first { $0.id == asset?.announcementId }
        return (asset, announcement, storage.announcementImageStorageAvailable)
    }

    /// The published, started, unexpired, undismissed announcements in start
    /// order from one snapshot; `visible` is the audience predicate.
    func firstActiveAnnouncement(
        userId: String,
        after: String?,
        now: Date,
        visible: (AnnouncementRow) -> Bool
    ) -> AnnouncementRow? {
        lock.lock()
        defer { lock.unlock() }
        return storage.announcements
            .filter { $0.status == "published" && $0.publishedAt != nil }
            .filter { $0.startsAt <= now && ($0.expiresAt == nil || $0.expiresAt! > now) }
            .filter(visible)
            .filter { !storage.announcementDismissals.contains("\(userId)\n\($0.id)") }
            .filter { after == nil || $0.id != after }
            .sorted { $0.startsAt < $1.startsAt }
            .first
    }

    /// One announcement by id.
    func announcement(id: String) -> AnnouncementRow? {
        lock.lock()
        defer { lock.unlock() }
        return storage.announcements.first { $0.id == id }
    }
}
