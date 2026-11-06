import Foundation

/// Native notification enrollment, device and credential lifecycle, the SSE
/// stream open and the event ledger.
///
/// The service decides and returns published DTOs or throws
/// `NativeNotificationsError`; it never builds a reply, header set or JSON
/// string. The rows live in `NativeNotificationStore`, whose operations are each
/// one critical section; the kill switch, the attestation policy and the
/// stream tuning live in `NotificationsStore`, the sessions in
/// `AuthProfileStore`.
///
/// Cross-store facts (a session family's liveness) are snapshotted from the
/// profile store before a section runs and enter it as a value, so no store
/// calls another while holding a lock.
public struct NativeNotificationsService: Sendable {
    static let credentialLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let grantLifetime: TimeInterval = 60
    /// A resume that would replay more events than this is refused.
    static let replayLimit = 512

    private let rows: NativeNotificationStore
    private let settings: NotificationsStore
    private let profiles: AuthProfileStore
    private let now: @Sendable () -> Date

    init(
        rows: NativeNotificationStore,
        settings: NotificationsStore,
        profiles: AuthProfileStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rows = rows
        self.settings = settings
        self.profiles = profiles
        self.now = now
    }

    // MARK: - Enrollment

    /// `POST /api/notifications/enrollment-grants`. The opaque grant is
    /// returned once; only its hash is stored.
    public func issueEnrollmentGrant(
        authorization: String?,
        body: LenientJSONObjectRequest?
    ) throws -> NativeEnrollmentGrantIssued {
        try requireEnabled()
        guard let session = liveSession(authorization) else { throw NativeNotificationsError.sessionFamilyRequired }
        guard let request = EnrollmentRequest(body) else { throw NativeNotificationsError.invalidEnrollmentRequest }
        let config = settings.state
        let attestation = Self.attestationState(
            body: body,
            mode: config.nativeNotificationAttestationMode,
            nodeEnv: config.nativeNotificationNodeEnv,
            verifier: config.nativeNotificationAttestationVerifier
        )
        if attestation == "rejected" { throw NativeNotificationsError.desktopAttestationRequired }
        let id = UUID().uuidString.lowercased()
        let minted = NativeNotificationCredentials.mint(prefix: "rng1", id: id)
        let issuedAt = now()
        let expiresAt = issuedAt.addingTimeInterval(Self.grantLifetime)
        rows.insertGrant(StoredEnrollmentGrant(
            id: id,
            userId: session.userId,
            sessionFamilyId: session.familyId,
            secretHash: minted.secretHash,
            appId: request.appId,
            protocolVersion: request.protocolVersion,
            appVersion: request.appVersion,
            releaseChannel: request.releaseChannel,
            appInstanceId: request.appInstanceId,
            publicKey: request.publicKey,
            nonce: request.nonce,
            attestationState: attestation,
            expiresAt: expiresAt,
            createdAt: issuedAt,
            consumedAt: nil
        ))
        return NativeEnrollmentGrantIssued(grant: minted.opaque, expiresAt: DateText.iso8601(expiresAt))
    }

    /// `POST /api/notifications/enrollment-exchanges`. One grant mints one
    /// credential; a second exchange is denied.
    public func exchangeEnrollmentGrant(body: LenientJSONObjectRequest?) throws -> NativeCredentialIssued {
        try requireEnabled()
        guard let grantText = body?["grant"]?.legacyString,
              let parsed = NativeNotificationCredentials.parseOpaque(grantText, prefix: "rng1")
        else { throw NativeNotificationsError.invalidEnrollmentExchange }
        let proof = body?["proof"]?.legacyString ?? ""
        let deviceId = UUID().uuidString.lowercased()
        let credentialId = UUID().uuidString.lowercased()
        let minted = NativeNotificationCredentials.mint(prefix: "rnc1", id: credentialId)
        let clock = now
        guard let expiresAt = rows.exchangeGrant(
            id: parsed.id,
            secretHash: AuthTokenCodec.sha256(parsed.secret),
            families: families(),
            clock: { clock() },
            deviceId: deviceId,
            credentialId: credentialId,
            credentialSecretHash: minted.secretHash,
            credentialLifetime: Self.credentialLifetime,
            proofIsValid: { grant in
                NativeNotificationCredentials.verifyEd25519(
                    publicKeySPKI: grant.publicKey,
                    transcript: NativeNotificationCredentials.enrollmentProofTranscript(
                        grant: grantText,
                        appId: grant.appId,
                        protocolVersion: grant.protocolVersion,
                        appVersion: grant.appVersion,
                        releaseChannel: grant.releaseChannel,
                        appInstanceId: grant.appInstanceId,
                        publicKey: grant.publicKey,
                        nonce: grant.nonce
                    ),
                    proof: proof
                )
            }
        ) else { throw NativeNotificationsError.enrollmentExchangeDenied }
        return NativeCredentialIssued(
            credential: minted.opaque,
            credentialId: credentialId,
            deviceId: deviceId,
            scope: NativeNotificationStore.streamScope,
            expiresAt: DateText.iso8601(expiresAt)
        )
    }

    // MARK: - Devices and credentials

    /// `GET /api/notifications/devices`. The list omits hashes, public keys and
    /// credential secrets.
    public func listDevices(authorization: String?) throws -> NativeNotificationDeviceList {
        try requireEnabled()
        guard let session = liveSession(authorization) else { throw NativeNotificationsError.authRequired }
        let listed = rows.devices(userId: session.userId, families: families(), now: now())
        return NativeNotificationDeviceList(devices: listed.map { entry in
            NativeNotificationDeviceList.Device(
                deviceId: entry.device.id,
                appId: entry.device.appId,
                appVersion: entry.device.appVersion,
                releaseChannel: entry.device.releaseChannel,
                appInstanceId: entry.device.appInstanceId,
                status: entry.status
            )
        })
    }

    /// `DELETE /api/notifications/devices/:deviceId`. A missing or foreign
    /// device is 404.
    public func revokeDevice(authorization: String?, deviceId: String) throws -> NoContentResponse {
        try requireEnabled()
        guard let session = liveSession(authorization) else { throw NativeNotificationsError.authRequired }
        guard deviceId.wholeMatch(of: NativeNotificationCredentials.uuidPattern) != nil,
              rows.revokeDevice(id: deviceId, userId: session.userId, now: now())
        else { throw NativeNotificationsError.deviceNotFound }
        return NoContentResponse()
    }

    /// `POST /api/notifications/credentials/rotate`. The proof is the device
    /// key over the current credential.
    public func rotateCredential(
        authorization: String?,
        body: LenientJSONObjectRequest?
    ) throws -> NativeCredentialIssued {
        try requireEnabled()
        guard let token = Self.credentialToken(authorization) else { throw NativeNotificationsError.credentialInvalid }
        let proof = body?["proof"]?.legacyString ?? ""
        guard let parsed = NativeNotificationCredentials.parseOpaque(token, prefix: "rnc1") else {
            throw NativeNotificationsError.credentialInvalid
        }
        let credentialId = UUID().uuidString.lowercased()
        let minted = NativeNotificationCredentials.mint(prefix: "rnc1", id: credentialId)
        let clock = now
        switch rows.rotateCredential(
            credentialId: parsed.id,
            secretHash: AuthTokenCodec.sha256(parsed.secret),
            families: families(),
            clock: { clock() },
            newCredentialId: credentialId,
            newSecretHash: minted.secretHash,
            credentialLifetime: Self.credentialLifetime,
            proofIsValid: { principal in
                NativeNotificationCredentials.verifyEd25519(
                    publicKeySPKI: principal.publicKey,
                    transcript: NativeNotificationCredentials.rotationProofTranscript(
                        credential: token,
                        deviceId: principal.deviceId
                    ),
                    proof: proof
                )
            }
        ) {
        case .invalid:
            throw NativeNotificationsError.credentialInvalid
        case .proofInvalid:
            throw NativeNotificationsError.credentialProofInvalid
        case .rotated(let deviceId, let expiresAt):
            return NativeCredentialIssued(
                credential: minted.opaque,
                credentialId: credentialId,
                deviceId: deviceId,
                scope: NativeNotificationStore.streamScope,
                expiresAt: DateText.iso8601(expiresAt)
            )
        }
    }

    /// `DELETE /api/notifications/credentials/current`. A credential-shaped
    /// bearer is 204 even when it is already dead.
    public func deleteCurrentCredential(authorization: String?) throws -> NoContentResponse {
        try requireEnabled()
        guard let token = Self.credentialToken(authorization) else { throw NativeNotificationsError.credentialInvalid }
        _ = revokeCredential(opaque: token)
        return NoContentResponse()
    }

    /// Revokes the credential named by this opaque token. A later stream frame
    /// must not be written.
    @discardableResult
    public func revokeCredential(opaque: String) -> Bool {
        guard let parsed = NativeNotificationCredentials.parseOpaque(opaque, prefix: "rnc1") else { return false }
        return rows.revokeCredential(
            id: parsed.id,
            secretHash: AuthTokenCodec.sha256(parsed.secret),
            now: now()
        )
    }

    // MARK: - Stream

    /// Opens `GET /api/notifications/stream`. A user session or a foreign
    /// cursor fails before any event-stream bytes.
    public func beginStream(authorization: String?, lastEventId: String?) throws -> NativeNotificationStreamStart {
        try requireEnabled()
        guard let token = NativeNotificationCredentials.bearer(authorization),
              let parsed = NativeNotificationCredentials.parseOpaque(token, prefix: "rnc1")
        else { throw NativeNotificationsError.credentialInvalid }
        switch rows.openStream(
            credentialId: parsed.id,
            secretHash: AuthTokenCodec.sha256(parsed.secret),
            families: families(),
            lastEventId: lastEventId,
            lastEventIdIsWellFormed: lastEventId.map { $0.wholeMatch(of: NativeNotificationCredentials.uuidPattern) != nil } ?? false,
            replayLimit: Self.replayLimit,
            now: now()
        ) {
        case .denied:
            throw NativeNotificationsError.credentialInvalid
        case .cursorUnavailable:
            throw NativeNotificationsError.replayCursorUnavailable
        case .replayWindowExceeded:
            throw NativeNotificationsError.replayWindowExceeded
        case .streaming(let userId, let cursorSeq, let replay):
            return NativeNotificationStreamStart(
                userId: userId,
                cursorSeq: cursorSeq,
                replay: replay.map { ($0.streamSeq, Self.frame($0)) }
            )
        }
    }

    /// Whether the presented bearer is still a live native credential.
    public func isCredentialLive(authorization: String?) -> Bool {
        guard let token = NativeNotificationCredentials.bearer(authorization),
              let parsed = NativeNotificationCredentials.parseOpaque(token, prefix: "rnc1")
        else { return false }
        return rows.principal(
            credentialId: parsed.id,
            secretHash: AuthTokenCodec.sha256(parsed.secret),
            families: families(),
            now: now()
        ) != nil
    }

    /// The user's unexpired frames after `cursor`, in stream order.
    public func frames(userId: String, after cursor: Int) -> [(seq: Int, frame: String)] {
        rows.events(userId: userId, after: cursor, now: now()).map { ($0.streamSeq, Self.frame($0)) }
    }

    /// The configured stream poll interval, clamped by the route.
    public var streamPollMs: Int { settings.nativeNotificationStreamPollMs }

    /// The test-only per-frame hook the route invokes before each live write.
    public var liveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)? {
        settings.nativeNotificationLiveWriteHook
    }

    // MARK: - Event ledger

    /// Disabled notifications persist nothing; an empty batch also persists
    /// nothing. A recipient without a live native credential does not grow the
    /// ledger, and the same event key is stored once.
    public func persist(_ intents: [NativeNotificationIntent]) -> Int {
        if !settings.nativeNotificationsEnabled || intents.isEmpty { return 0 }
        let clock = now
        return rows.persist(intents: intents, families: families(), clock: { clock() })
    }

    // MARK: - Helpers

    private func requireEnabled() throws {
        guard settings.nativeNotificationsEnabled else { throw NativeNotificationsError.notFound }
    }

    /// The bearer of a credential-shaped `rnc1.` token, or `nil`.
    private static func credentialToken(_ authorization: String?) -> String? {
        guard let token = NativeNotificationCredentials.bearer(authorization), token.hasPrefix("rnc1.") else { return nil }
        return token
    }

    /// The normal session behind a bearer: a live family of the same user and a
    /// verified account.
    private func liveSession(_ authorization: String?) -> (userId: String, familyId: String)? {
        guard let token = NativeNotificationCredentials.bearer(authorization) else { return nil }
        let snapshot = profiles.accountState
        guard let userId = snapshot.accessTokens[token],
              let familyId = snapshot.accessTokenFamilies[token],
              snapshot.sessionFamilies[familyId]?.userId == userId,
              snapshot.sessionFamilies[familyId]?.revokedAt == nil,
              snapshot.accounts.values.contains(where: { $0.id == userId && $0.emailVerified })
        else { return nil }
        return (userId, familyId)
    }

    private func families() -> NativeSessionFamilies {
        let snapshot = profiles.accountState
        return NativeSessionFamilies(families: snapshot.sessionFamilies, revoked: snapshot.revokedFamilies)
    }

    /// The attestation outcome. Production, `enforce` and any mode other than
    /// `observe` reject unverified evidence.
    static func attestationState(
        body: LenientJSONObjectRequest?,
        mode: String?,
        nodeEnv: String,
        verifier: (@Sendable (String) -> Bool)?
    ) -> String {
        let raw = body?["attestation"]?.legacyString
        let evidence = (raw?.isEmpty == false && (raw?.count ?? 0) <= 4096) ? raw : nil
        let enforce = nodeEnv == "production" || mode == "enforce" || (mode != nil && mode != "observe")
        let verified = evidence != nil && verifier?(evidence!) == true
        if enforce && !verified { return "rejected" }
        if verified { return "verified" }
        return evidence == nil ? "missing" : "observed"
    }

    /// One stream frame; the data object prints its members alphabetically.
    static func frame(_ event: StoredNativeNotificationEvent) -> String {
        let data = OrderedJSON.object([
            OrderedJSONField("body", event.body),
            OrderedJSONField("createdAt", DateText.iso8601(event.createdAt)),
            OrderedJSONField("eventId", event.eventId),
            OrderedJSONField("serverId", event.serverId),
            OrderedJSONField("targetUri", event.targetUri),
            OrderedJSONField("title", event.title),
            OrderedJSONField("version", 1),
        ]).render()
        return "event: native-notification.v1\nid: \(event.eventId)\ndata: \(data)\n\n"
    }

    /// The validated enrollment request. Every member reads like the retired
    /// raw-object cast: a member of the wrong type is a refusal.
    struct EnrollmentRequest {
        let appId: String
        let protocolVersion = 1
        let appVersion: String
        let releaseChannel: String
        let appInstanceId: String
        let publicKey: String
        let nonce: String

        init?(_ body: LenientJSONObjectRequest?) {
            guard let body,
                  let appId = body["appId"]?.legacyString,
                  appId == "ai.slock.desktop",
                  appId.wholeMatch(of: /^[a-z0-9]+(?:\.[a-z0-9-]+){2,7}$/) != nil,
                  body["protocolVersion"]?.legacyIsOne == true,
                  let appVersion = body["appVersion"]?.legacyString,
                  appVersion.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._+()-]{0,63}$/) != nil,
                  let releaseChannel = body["releaseChannel"]?.legacyString,
                  releaseChannel == "development" || releaseChannel == "staging" || releaseChannel == "production",
                  let appInstanceId = body["appInstanceId"]?.legacyString,
                  appInstanceId.wholeMatch(of: NativeNotificationCredentials.uuidPattern) != nil,
                  let publicKey = body["publicKey"]?.legacyString,
                  NativeNotificationCredentials.canonicalBase64URL(publicKey, minBytes: 32, maxBytes: 128) != nil,
                  let nonce = body["nonce"]?.legacyString,
                  NativeNotificationCredentials.canonicalBase64URL(nonce, minBytes: 32, maxBytes: 32) != nil
            else { return nil }
            self.appId = appId
            self.appVersion = appVersion
            self.releaseChannel = releaseChannel
            self.appInstanceId = appInstanceId
            self.publicKey = publicKey
            self.nonce = nonce
        }
    }
}

extension JSONScalarValue {
    /// The legacy `(value as? NSNumber)?.intValue == 1`: the boolean `true`
    /// and any number that truncates toward zero to 1.
    var legacyIsOne: Bool {
        switch self {
        case .bool(let value): value
        case .integer(let value): value == 1
        case .number(let value): value >= 1 && value < 2
        case .null, .string, .other: false
        }
    }
}
