import Foundation

/// The NativeNotificationStore is a distinct owner, not a runtime-only child.
/// All five State fields are business facts. Insertion order, retained expired
/// rows, eventKey replay/dedup facts, nextSeq, consumed grants, credential hashes,
/// original public-key strings, expiry and revocation timestamps are preserved.
/// No record here has JSONValue or Int64; native Int fields stay integer tokens.
private struct NotificationsNativeBusinessSnapshot: Codable, Sendable {
    let events: [NotificationsNativeEventRow]
    let nextSeq: Int
    let grants: [NotificationsNativeGrantRow]
    let devices: [NotificationsNativeDeviceRow]
    let credentials: [NotificationsNativeCredentialRow]

    init(_ state: NativeNotificationStore.State) {
        events = state.events.map(NotificationsNativeEventRow.init)
        nextSeq = state.nextSeq
        grants = state.grants.map(NotificationsNativeGrantRow.init)
        devices = state.devices.map(NotificationsNativeDeviceRow.init)
        credentials = state.credentials.map(NotificationsNativeCredentialRow.init)
    }

    var record: NativeNotificationStore.State {
        var state = NativeNotificationStore.State()
        state.events = events.map(\.record)
        state.nextSeq = nextSeq
        state.grants = grants.map(\.record)
        state.devices = devices.map(\.record)
        state.credentials = credentials.map(\.record)
        return state
    }
}

private struct NotificationsNativeEventRow: Codable, Sendable {
    let eventId: String
    let streamSeq: Int
    let recipientUserId: String
    let eventKey: String
    let serverId: String
    let channelId: String
    let messageId: String
    let title: String
    let body: String
    let targetUri: String
    let createdAt: Date
    let expiresAt: Date

    init(_ row: StoredNativeNotificationEvent) {
        eventId = row.eventId
        streamSeq = row.streamSeq
        recipientUserId = row.recipientUserId
        eventKey = row.eventKey
        serverId = row.serverId
        channelId = row.channelId
        messageId = row.messageId
        title = row.title
        body = row.body
        targetUri = row.targetUri
        createdAt = row.createdAt
        expiresAt = row.expiresAt
    }

    var record: StoredNativeNotificationEvent {
        StoredNativeNotificationEvent(
            eventId: eventId, streamSeq: streamSeq, recipientUserId: recipientUserId,
            eventKey: eventKey, serverId: serverId, channelId: channelId, messageId: messageId,
            title: title, body: body, targetUri: targetUri, createdAt: createdAt, expiresAt: expiresAt
        )
    }
}

private struct NotificationsNativeGrantRow: Codable, Sendable {
    let id: String
    let userId: String
    let sessionFamilyId: String
    let secretHash: String
    let appId: String
    let protocolVersion: Int
    let appVersion: String
    let releaseChannel: String
    let appInstanceId: String
    let publicKey: String
    let nonce: String
    let attestationState: String
    let expiresAt: Date
    let createdAt: Date
    let consumedAt: NotificationsPersistenceCoding.RequiredOptional<Date>

    init(_ row: StoredEnrollmentGrant) {
        id = row.id
        userId = row.userId
        sessionFamilyId = row.sessionFamilyId
        secretHash = row.secretHash
        appId = row.appId
        protocolVersion = row.protocolVersion
        appVersion = row.appVersion
        releaseChannel = row.releaseChannel
        appInstanceId = row.appInstanceId
        publicKey = row.publicKey
        nonce = row.nonce
        attestationState = row.attestationState
        expiresAt = row.expiresAt
        createdAt = row.createdAt
        consumedAt = .init(row.consumedAt)
    }

    var record: StoredEnrollmentGrant {
        StoredEnrollmentGrant(
            id: id, userId: userId, sessionFamilyId: sessionFamilyId, secretHash: secretHash,
            appId: appId, protocolVersion: protocolVersion, appVersion: appVersion,
            releaseChannel: releaseChannel, appInstanceId: appInstanceId, publicKey: publicKey,
            nonce: nonce, attestationState: attestationState, expiresAt: expiresAt,
            createdAt: createdAt, consumedAt: consumedAt.value
        )
    }
}

private struct NotificationsNativeDeviceRow: Codable, Sendable {
    let id: String
    let userId: String
    let appId: String
    let appVersion: String
    let releaseChannel: String
    let appInstanceId: String
    let publicKey: String
    let revokedAt: NotificationsPersistenceCoding.RequiredOptional<Date>

    init(_ row: StoredNotificationDevice) {
        id = row.id
        userId = row.userId
        appId = row.appId
        appVersion = row.appVersion
        releaseChannel = row.releaseChannel
        appInstanceId = row.appInstanceId
        publicKey = row.publicKey
        revokedAt = .init(row.revokedAt)
    }

    var record: StoredNotificationDevice {
        StoredNotificationDevice(
            id: id, userId: userId, appId: appId, appVersion: appVersion,
            releaseChannel: releaseChannel, appInstanceId: appInstanceId,
            publicKey: publicKey, revokedAt: revokedAt.value
        )
    }
}

private struct NotificationsNativeCredentialRow: Codable, Sendable {
    let id: String
    let deviceId: String
    let userId: String
    let sessionFamilyId: String
    let secretHash: String
    let scope: String
    let expiresAt: Date
    let revokedAt: NotificationsPersistenceCoding.RequiredOptional<Date>

    init(_ row: StoredNotificationCredential) {
        id = row.id
        deviceId = row.deviceId
        userId = row.userId
        sessionFamilyId = row.sessionFamilyId
        secretHash = row.secretHash
        scope = row.scope
        expiresAt = row.expiresAt
        revokedAt = .init(row.revokedAt)
    }

    var record: StoredNotificationCredential {
        StoredNotificationCredential(
            id: id, deviceId: deviceId, userId: userId, sessionFamilyId: sessionFamilyId,
            secretHash: secretHash, scope: scope, expiresAt: expiresAt, revokedAt: revokedAt.value
        )
    }
}

extension NativeNotificationStore {
    /// Export of the retained native instance, independent of NotificationsStore's
    /// runtime configuration. The opaque result contains credentials; never log it.
    func exportOpaqueData() throws -> Data {
        let value = NotificationsNativeBusinessSnapshot(snapshot())
        return try NotificationsPersistenceCoding.encode(value, owner: "raft.native-notifications")
    }

    /// Reconstruct every row and check all keys/Date bits before touching the
    /// original owner's Mutex. Lead supplies the minimal private-state accessor
    /// in the existing Store file; no native owner instance is replaced.
    func restoreOpaqueData(_ data: Data) throws {
        let value = try NotificationsPersistenceCoding.decode(
            NotificationsNativeBusinessSnapshot.self, from: data, owner: "raft.native-notifications"
        )
        let replacement = value.record
        restorePersistenceState(replacement)
    }
}
