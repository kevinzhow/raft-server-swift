import Foundation
import Synchronization

/// The session-family liveness facts a native-notification decision needs,
/// copied out of the profile store before a section runs.
///
/// A store never calls another store while holding its lock, so the caller
/// snapshots the profile rows first and the section reads this value. The
/// window between the snapshot and the commit is the same one every migrated
/// cross-store decision has.
struct NativeSessionFamilies: Sendable {
    let families: [String: SessionFamily]
    let revoked: Set<String>

    /// The family exists, belongs to `userId` and is not revoked.
    func isLive(familyId: String, userId: String) -> Bool {
        families[familyId]?.userId == userId && families[familyId]?.revokedAt == nil
    }

    /// `isLive` and the family is also absent from the revoked set.
    func isLiveAndNotRevoked(familyId: String, userId: String) -> Bool {
        !revoked.contains(familyId) && isLive(familyId: familyId, userId: userId)
    }
}

/// Enrollment grants, notification devices, native credentials and the native
/// notification event ledger.
///
/// Every operation is one `Mutex` critical section, so a decision and the write
/// it justifies cannot interleave with a second request: a grant is consumed by
/// exactly one exchange, a rotation revokes the credential it replaces in the
/// same step that mints the successor, and a persisted event key is stored once.
/// The proof checks run under the lock through a closure so the check and the
/// consumption stay atomic. Stores hold no HTTP knowledge and throw nothing.
final class NativeNotificationStore: Sendable {
    static let streamScope = "notifications:stream"

    struct State: Sendable {
        var events: [StoredNativeNotificationEvent] = []
        var nextSeq = 0
        var grants: [StoredEnrollmentGrant] = []
        var devices: [StoredNotificationDevice] = []
        var credentials: [StoredNotificationCredential] = []
    }

    /// A native credential that passed every liveness rule.
    struct Principal: Sendable, Equatable {
        let userId: String
        let familyId: String
        let credentialId: String
        let deviceId: String
        let publicKey: String
    }

    /// One device row with the status the list projection publishes.
    struct DeviceListing: Sendable {
        let device: StoredNotificationDevice
        let status: String
    }

    enum RotationOutcome: Sendable, Equatable {
        /// No live credential: the published 401.
        case invalid
        /// The proof did not verify: the published 403.
        case proofInvalid
        case rotated(deviceId: String, expiresAt: Date)
    }

    enum StreamOutcome: Sendable {
        case denied
        case cursorUnavailable
        case replayWindowExceeded
        case streaming(
            userId: String,
            cursorSeq: Int,
            replay: [StoredNativeNotificationEvent]
        )
    }

    private let state = Mutex(State())

    // MARK: - Enrollment grants

    func insertGrant(_ grant: StoredEnrollmentGrant) {
        state.withLock { $0.grants.append(grant) }
    }

    /// Consumes one grant and mints its device and credential, or answers
    /// `nil` when any rule fails. The lookup, every rule, the proof check and
    /// the three writes are one critical section, so two exchanges of one
    /// grant cannot both succeed.
    ///
    /// - Parameters:
    ///   - proofIsValid: runs under the lock with the stored grant.
    ///   - clock: read once for the expiry rule and once for the mint time, as
    ///     the retired handler did.
    func exchangeGrant(
        id: String,
        secretHash: String,
        families: NativeSessionFamilies,
        clock: () -> Date,
        deviceId: String,
        credentialId: String,
        credentialSecretHash: String,
        credentialLifetime: TimeInterval,
        proofIsValid: (StoredEnrollmentGrant) -> Bool
    ) -> Date? {
        state.withLock { state in
            guard let index = state.grants.firstIndex(where: { $0.id == id }) else { return nil }
            let grant = state.grants[index]
            guard secretHash == grant.secretHash,
                  grant.consumedAt == nil,
                  grant.expiresAt > clock(),
                  grant.attestationState != "rejected",
                  families.isLive(familyId: grant.sessionFamilyId, userId: grant.userId)
            else { return nil }
            guard proofIsValid(grant) else { return nil }
            let now = clock()
            state.devices.append(StoredNotificationDevice(
                id: deviceId,
                userId: grant.userId,
                appId: grant.appId,
                appVersion: grant.appVersion,
                releaseChannel: grant.releaseChannel,
                appInstanceId: grant.appInstanceId,
                publicKey: grant.publicKey
            ))
            let expiresAt = now.addingTimeInterval(credentialLifetime)
            state.credentials.append(StoredNotificationCredential(
                id: credentialId,
                deviceId: deviceId,
                userId: grant.userId,
                sessionFamilyId: grant.sessionFamilyId,
                secretHash: credentialSecretHash,
                scope: Self.streamScope,
                expiresAt: expiresAt
            ))
            state.grants[index].consumedAt = now
            return expiresAt
        }
    }

    // MARK: - Devices and credentials

    /// The user's devices in insertion order with their status, from one
    /// snapshot of the device and credential rows.
    func devices(userId: String, families: NativeSessionFamilies, now: Date) -> [DeviceListing] {
        state.withLock { state in
            state.devices.filter { $0.userId == userId }.map { device in
                DeviceListing(device: device, status: Self.status(of: device, state: state, families: families, now: now))
            }
        }
    }

    /// Revokes one live device of `userId` and every open credential bound to
    /// it, in one critical section. `false` when the device is absent, foreign
    /// or already revoked.
    func revokeDevice(id: String, userId: String, now: Date) -> Bool {
        state.withLock { state in
            guard let index = state.devices.firstIndex(where: {
                $0.id == id && $0.userId == userId && $0.revokedAt == nil
            }) else { return false }
            state.devices[index].revokedAt = now
            for credentialIndex in state.credentials.indices
            where state.credentials[credentialIndex].deviceId == id
                && state.credentials[credentialIndex].revokedAt == nil {
                state.credentials[credentialIndex].revokedAt = now
            }
            return true
        }
    }

    /// Revokes the credential named by this opaque token, when its secret and
    /// state match. `false` when nothing matched.
    func revokeCredential(id: String, secretHash: String, now: Date) -> Bool {
        state.withLock { state in
            guard let index = state.credentials.firstIndex(where: {
                $0.id == id && $0.secretHash == secretHash && $0.revokedAt == nil
            }) else { return false }
            state.credentials[index].revokedAt = now
            return true
        }
    }

    /// Resolves a presented credential to its principal, or `nil`.
    func principal(
        credentialId: String,
        secretHash: String,
        families: NativeSessionFamilies,
        now: Date
    ) -> Principal? {
        state.withLock { Self.principal(credentialId: credentialId, secretHash: secretHash, state: $0, families: families, now: now) }
    }

    /// Rotates the presented credential: resolves the principal, verifies the
    /// proof, revokes the credential and stores its successor, all in one
    /// critical section, so two rotations of one credential mint one successor.
    func rotateCredential(
        credentialId: String,
        secretHash: String,
        families: NativeSessionFamilies,
        clock: () -> Date,
        newCredentialId: String,
        newSecretHash: String,
        credentialLifetime: TimeInterval,
        proofIsValid: (Principal) -> Bool
    ) -> RotationOutcome {
        state.withLock { state in
            guard let principal = Self.principal(
                credentialId: credentialId,
                secretHash: secretHash,
                state: state,
                families: families,
                now: clock()
            ), let index = state.credentials.firstIndex(where: {
                $0.id == principal.credentialId && $0.revokedAt == nil
            }) else { return .invalid }
            guard proofIsValid(principal) else { return .proofInvalid }
            let current = state.credentials[index]
            let now = clock()
            state.credentials[index].revokedAt = now
            let expiresAt = now.addingTimeInterval(credentialLifetime)
            state.credentials.append(StoredNotificationCredential(
                id: newCredentialId,
                deviceId: current.deviceId,
                userId: current.userId,
                sessionFamilyId: current.sessionFamilyId,
                secretHash: newSecretHash,
                scope: Self.streamScope,
                expiresAt: expiresAt
            ))
            return .rotated(deviceId: current.deviceId, expiresAt: expiresAt)
        }
    }

    // MARK: - Event ledger

    /// Resolves the credential and the replay cursor, then answers the replay
    /// window, from one snapshot of the credential and event rows.
    func openStream(
        credentialId: String,
        secretHash: String,
        families: NativeSessionFamilies,
        lastEventId: String?,
        lastEventIdIsWellFormed: Bool,
        replayLimit: Int,
        now: Date
    ) -> StreamOutcome {
        state.withLock { state in
            guard let principal = Self.principal(
                credentialId: credentialId,
                secretHash: secretHash,
                state: state,
                families: families,
                now: now
            ) else { return .denied }
            if let lastEventId {
                guard lastEventIdIsWellFormed,
                      let cursor = state.events.first(where: {
                          $0.eventId == lastEventId && $0.recipientUserId == principal.userId && $0.expiresAt > now
                      })
                else { return .cursorUnavailable }
                let replay = state.events
                    .filter { $0.recipientUserId == principal.userId && $0.streamSeq > cursor.streamSeq && $0.expiresAt > now }
                    .sorted { $0.streamSeq < $1.streamSeq }
                if replay.count > replayLimit { return .replayWindowExceeded }
                return .streaming(userId: principal.userId, cursorSeq: cursor.streamSeq, replay: replay)
            }
            let latest = state.events
                .filter { $0.recipientUserId == principal.userId && $0.expiresAt > now }
                .map(\.streamSeq)
                .max() ?? 0
            return .streaming(userId: principal.userId, cursorSeq: latest, replay: [])
        }
    }

    /// The user's unexpired events after `cursor`, in stream order.
    func events(userId: String, after cursor: Int, now: Date) -> [StoredNativeNotificationEvent] {
        state.withLock { state in
            state.events
                .filter { $0.recipientUserId == userId && $0.streamSeq > cursor && $0.expiresAt > now }
                .sorted { $0.streamSeq < $1.streamSeq }
        }
    }

    /// Persists the intents whose recipient holds a live credential and whose
    /// event key is new, assigning stream sequence numbers in order. The
    /// liveness test, the duplicate test and the append share one critical
    /// section, so a concurrent batch cannot store the same key twice.
    func persist(
        intents: [NativeNotificationIntent],
        families: NativeSessionFamilies,
        clock: () -> Date
    ) -> Int {
        state.withLock { state in
            var inserted = 0
            var seen = Set(state.events.map(\.eventKey))
            for intent in intents {
                guard Self.hasLiveCredential(userId: intent.recipientUserId, state: state, families: families, now: clock()),
                      !seen.contains(intent.eventKey)
                else { continue }
                seen.insert(intent.eventKey)
                state.nextSeq += 1
                let now = clock()
                state.events.append(StoredNativeNotificationEvent(
                    eventId: UUID().uuidString.lowercased(),
                    streamSeq: state.nextSeq,
                    recipientUserId: intent.recipientUserId,
                    eventKey: intent.eventKey,
                    serverId: intent.serverId,
                    channelId: intent.channelId,
                    messageId: intent.messageId,
                    title: intent.title,
                    body: intent.body,
                    targetUri: "raft://v1/servers/\(intent.serverId)/channels/\(intent.channelId)/messages/\(intent.messageId)",
                    createdAt: intent.createdAt,
                    expiresAt: Date(timeInterval: 24 * 60 * 60, since: max(now, intent.createdAt))
                ))
                inserted += 1
            }
            return inserted
        }
    }

    // MARK: - Snapshots for assertions

    /// All rows at one instant. Read-only; tests assert on it.
    func snapshot() -> State {
        state.withLock { $0 }
    }

    /// Moves one grant's expiry to `date`.
    func setGrantExpiry(id: String, to date: Date) {
        state.withLock { state in
            if let index = state.grants.firstIndex(where: { $0.id == id }) {
                state.grants[index].expiresAt = date
            }
        }
    }

    /// Moves one event's expiry to `date`.
    func setEventExpiry(id: String, to date: Date) {
        state.withLock { state in
            if let index = state.events.firstIndex(where: { $0.eventId == id }) {
                state.events[index].expiresAt = date
            }
        }
    }

    /// Moves one credential's expiry to `date`.
    func setCredentialExpiry(id: String, to date: Date) {
        state.withLock { state in
            if let index = state.credentials.firstIndex(where: { $0.id == id }) {
                state.credentials[index].expiresAt = date
            }
        }
    }

    // MARK: - Locked helpers

    /// A revoked device cannot authenticate even if its credential row is open.
    private static func principal(
        credentialId: String,
        secretHash: String,
        state: State,
        families: NativeSessionFamilies,
        now: Date
    ) -> Principal? {
        guard let credential = state.credentials.first(where: {
            $0.id == credentialId && $0.secretHash == secretHash && $0.revokedAt == nil
                && $0.expiresAt > now && $0.scope == streamScope
        }), let device = state.devices.first(where: { $0.id == credential.deviceId }),
              device.revokedAt == nil
        else { return nil }
        guard families.isLiveAndNotRevoked(familyId: credential.sessionFamilyId, userId: credential.userId) else {
            return nil
        }
        return Principal(
            userId: credential.userId,
            familyId: credential.sessionFamilyId,
            credentialId: credential.id,
            deviceId: credential.deviceId,
            publicKey: device.publicKey
        )
    }

    /// `revoked` for a revoked device, `active` for a live unexpired credential
    /// on a live family, otherwise `inactive`.
    private static func status(
        of device: StoredNotificationDevice,
        state: State,
        families: NativeSessionFamilies,
        now: Date
    ) -> String {
        if let revokedAt = device.revokedAt, revokedAt <= now { return "revoked" }
        let active = state.credentials.contains { credential in
            credential.deviceId == device.id
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == streamScope
                && families.isLiveAndNotRevoked(familyId: credential.sessionFamilyId, userId: device.userId)
        }
        return active ? "active" : "inactive"
    }

    private static func hasLiveCredential(
        userId: String,
        state: State,
        families: NativeSessionFamilies,
        now: Date
    ) -> Bool {
        state.credentials.contains { credential in
            credential.userId == userId
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == streamScope
                && families.isLiveAndNotRevoked(familyId: credential.sessionFamilyId, userId: userId)
                && state.devices.contains { $0.id == credential.deviceId && $0.revokedAt == nil }
        }
    }
}
