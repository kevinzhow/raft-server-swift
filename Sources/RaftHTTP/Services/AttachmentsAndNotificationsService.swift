import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native notification enrollment, device/credential lifecycle, the SSE stream,
/// the mobile-app lifecycle-mail audience and the agent attachment surface.
///
/// The directory keeps the published entry points and the static transcript
/// helpers; this service owns the state transitions behind them.
struct AttachmentsAndNotificationsService {
    let directory: EmailLoginDirectory

    init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    // MARK: - Experimental surfaces

    /// Operator kill switch for `/internal/agent-api` and `/internal/computer`.
    /// `SLOCK_EXPERIMENTAL_SURFACES_DISABLED=true` disables them; tests may
    /// override without touching the process environment.
    func setExperimentalSurfacesDisabled(_ value: Bool?) {
        directory.lock.lock()
        directory.experimentalSurfacesDisabledOverride = value
        directory.lock.unlock()
    }

    // MARK: - Enrollment grants

    func nativeEnrollmentGrantRecords() -> [EmailLoginDirectory.NativeEnrollmentGrantRecord] {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.nativeEnrollmentGrants.map { grant in
            let json = "{\"id\":\(jsonString(grant.id)),\"secretHash\":\(jsonString(grant.secretHash)),\"publicKey\":\(jsonString(grant.publicKey)),\"nonce\":\(jsonString(grant.nonce))}"
            return EmailLoginDirectory.NativeEnrollmentGrantRecord(secretHash: grant.secretHash, json: json)
        }
    }

    /// Moves a stored enrollment grant into the past. Exchange must then fail closed.
    func expireNativeEnrollmentGrant(id: String) {
        directory.lock.lock()
        if let index = directory.nativeEnrollmentGrants.firstIndex(where: { $0.id == id }) {
            directory.nativeEnrollmentGrants[index].expiresAt = Date().addingTimeInterval(-1)
        }
        directory.lock.unlock()
    }

    /// Marks every session family for this user revoked. A later enrollment exchange must fail closed.
    func revokeSessionFamilies(userId: String) {
        directory.lock.lock()
        let now = Date()
        for key in directory.sessionFamilies.keys where directory.sessionFamilies[key]?.userId == userId {
            if directory.sessionFamilies[key]?.revokedAt == nil {
                directory.sessionFamilies[key]?.revokedAt = now
            }
            directory.revokedFamilies.insert(key)
        }
        directory.lock.unlock()
    }

    func nativeNotificationCredentialJSON(id: String) -> String? {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        guard let row = directory.nativeNotificationCredentials.first(where: { $0.id == id }) else { return nil }
        return "{\"id\":\(jsonString(row.id)),\"secretHash\":\(jsonString(row.secretHash)),\"scope\":\(jsonString(row.scope))}"
    }

    /// `POST /api/notifications/enrollment-grants`. The opaque grant is returned once. Only its hash is stored.
    func issueNativeEnrollmentGrant(body: String, authorization: String?) -> HTTPReply {
        guard directory.nativeNotificationsEnabled else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        directory.lock.lock()
        guard let session = notificationSessionLocked(authorization) else {
            directory.lock.unlock()
            return EmailLoginDirectory.json(401, "{\"error\":\"A live normal session family is required\",\"code\":\"session_family_required\"}")
        }
        guard let request = EmailLoginDirectory.parseEnrollmentRequest(body) else {
            directory.lock.unlock()
            return EmailLoginDirectory.json(400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_request\"}")
        }
        let attestation = EmailLoginDirectory.evaluateAttestation(
            body: body,
            mode: directory.nativeNotificationAttestationMode,
            nodeEnv: directory.nativeNotificationNodeEnv,
            verifier: directory.nativeNotificationAttestationVerifier
        )
        if attestation.state == "rejected" {
            directory.lock.unlock()
            return EmailLoginDirectory.json(403, "{\"error\":\"Desktop application attestation is required\",\"code\":\"desktop_attestation_required\"}")
        }
        let id = UUID().uuidString.lowercased()
        let minted = EmailLoginDirectory.mintOpaqueCredential(prefix: "rng1", id: id)
        let now = Date()
        let expiresAt = now.addingTimeInterval(60)
        directory.nativeEnrollmentGrants.append(StoredEnrollmentGrant(
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
            attestationState: attestation.state,
            expiresAt: expiresAt,
            createdAt: now,
            consumedAt: nil
        ))
        directory.lock.unlock()
        return EmailLoginDirectory.json(201, "{\"grant\":\(jsonString(minted.opaque)),\"expiresAt\":\(jsonString(EmailLoginDirectory.iso8601(expiresAt)))}")
    }

    /// `POST /api/notifications/enrollment-exchanges`. One grant mints one credential. A second exchange is denied.
    func exchangeNativeEnrollmentGrant(body: String) -> HTTPReply {
        guard directory.nativeNotificationsEnabled else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let grantText = object["grant"] as? String,
              let parsed = EmailLoginDirectory.parseOpaqueCredential(grantText, prefix: "rng1")
        else {
            return EmailLoginDirectory.json(400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_exchange\"}")
        }
        let proof = object["proof"] as? String ?? ""
        let denied = EmailLoginDirectory.json(403, "{\"error\":\"Enrollment exchange denied\",\"code\":\"enrollment_exchange_denied\"}")
        directory.lock.lock()
        guard let index = directory.nativeEnrollmentGrants.firstIndex(where: { $0.id == parsed.id }) else {
            directory.lock.unlock()
            return denied
        }
        let grant = directory.nativeEnrollmentGrants[index]
        let secretHash = EmailLoginDirectory.sha256(parsed.secret)
        guard secretHash == grant.secretHash,
              grant.consumedAt == nil,
              grant.expiresAt > Date(),
              grant.attestationState != "rejected",
              directory.sessionFamilies[grant.sessionFamilyId]?.userId == grant.userId,
              directory.sessionFamilies[grant.sessionFamilyId]?.revokedAt == nil
        else {
            directory.lock.unlock()
            return denied
        }
        let transcript = EmailLoginDirectory.enrollmentProofTranscript(
            grant: grantText,
            appId: grant.appId,
            protocolVersion: grant.protocolVersion,
            appVersion: grant.appVersion,
            releaseChannel: grant.releaseChannel,
            appInstanceId: grant.appInstanceId,
            publicKey: grant.publicKey,
            nonce: grant.nonce
        )
        guard EmailLoginDirectory.verifyEd25519(publicKeySPKI: grant.publicKey, transcript: transcript, proof: proof) else {
            directory.lock.unlock()
            return denied
        }
        let now = Date()
        let deviceId = UUID().uuidString.lowercased()
        directory.nativeNotificationDevices.append(StoredNotificationDevice(
            id: deviceId,
            userId: grant.userId,
            appId: grant.appId,
            appVersion: grant.appVersion,
            releaseChannel: grant.releaseChannel,
            appInstanceId: grant.appInstanceId,
            publicKey: grant.publicKey
        ))
        let credentialId = UUID().uuidString.lowercased()
        let minted = EmailLoginDirectory.mintOpaqueCredential(prefix: "rnc1", id: credentialId)
        directory.nativeNotificationCredentials.append(StoredNotificationCredential(
            id: credentialId,
            deviceId: deviceId,
            userId: grant.userId,
            sessionFamilyId: grant.sessionFamilyId,
            secretHash: minted.secretHash,
            scope: "notifications:stream",
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        ))
        directory.nativeEnrollmentGrants[index].consumedAt = now
        directory.lock.unlock()
        return EmailLoginDirectory.json(201, "{\"credential\":\(jsonString(minted.opaque)),\"credentialId\":\(jsonString(credentialId)),\"deviceId\":\(jsonString(deviceId)),\"scope\":\"notifications:stream\",\"expiresAt\":\(jsonString(EmailLoginDirectory.iso8601(now.addingTimeInterval(30 * 24 * 60 * 60))))}")
    }

    // MARK: - Devices and credentials

    /// `GET /api/notifications/devices`. The list omits hashes, public keys, and credential secrets.
    func listNativeNotificationDevices(authorization: String?) -> HTTPReply {
        guard directory.nativeNotificationsEnabled else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        directory.lock.lock()
        guard let session = notificationSessionLocked(authorization) else {
            directory.lock.unlock()
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let now = Date()
        let listed = directory.nativeNotificationDevices.filter { $0.userId == session.userId }.map { device in
            let status = nativeDeviceStatusLocked(device, now: now)
            return "{\"deviceId\":\(jsonString(device.id)),\"appId\":\(jsonString(device.appId)),\"appVersion\":\(jsonString(device.appVersion)),\"releaseChannel\":\(jsonString(device.releaseChannel)),\"appInstanceId\":\(jsonString(device.appInstanceId)),\"attestationState\":\"missing\",\"status\":\(jsonString(status))}"
        }.joined(separator: ",")
        directory.lock.unlock()
        return EmailLoginDirectory.json(200, "{\"devices\":[\(listed)]}")
    }

    /// `DELETE /api/notifications/devices/:deviceId`. A missing or foreign device is 404.
    func revokeNativeNotificationDevice(authorization: String?, deviceId: String) -> HTTPReply {
        guard directory.nativeNotificationsEnabled else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        directory.lock.lock()
        defer { directory.lock.unlock() }
        guard let session = notificationSessionLocked(authorization) else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let notFound = EmailLoginDirectory.json(404, "{\"error\":\"Notification device not found\",\"code\":\"notification_device_not_found\"}")
        guard deviceId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
              let index = directory.nativeNotificationDevices.firstIndex(where: {
                  $0.id == deviceId && $0.userId == session.userId && $0.revokedAt == nil
              })
        else { return notFound }
        let now = Date()
        directory.nativeNotificationDevices[index].revokedAt = now
        for credentialIndex in directory.nativeNotificationCredentials.indices
        where directory.nativeNotificationCredentials[credentialIndex].deviceId == deviceId
            && directory.nativeNotificationCredentials[credentialIndex].revokedAt == nil {
            directory.nativeNotificationCredentials[credentialIndex].revokedAt = now
        }
        return EmailLoginDirectory.noContent()
    }

    /// `POST /api/notifications/credentials/rotate`. The proof is the device key over the current credential.
    func rotateNativeNotificationCredential(authorization: String?, body: String) -> HTTPReply {
        guard directory.nativeNotificationsEnabled else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        let invalid = EmailLoginDirectory.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        guard let authorization, authorization.hasPrefix("Bearer ") else { return invalid }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.hasPrefix("rnc1.") else { return invalid }
        let proof = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["proof"] as? String ?? ""
        directory.lock.lock()
        defer { directory.lock.unlock() }
        guard let principal = nativePrincipalLocked(authorization),
              let index = directory.nativeNotificationCredentials.firstIndex(where: { $0.id == principal.credentialId && $0.revokedAt == nil })
        else { return invalid }
        guard EmailLoginDirectory.verifyEd25519(
            publicKeySPKI: principal.publicKey,
            transcript: EmailLoginDirectory.rotationProofTranscript(credential: token, deviceId: principal.deviceId),
            proof: proof
        ) else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Invalid native notification credential proof\",\"code\":\"native_credential_proof_invalid\"}")
        }
        let current = directory.nativeNotificationCredentials[index]
        let now = Date()
        directory.nativeNotificationCredentials[index].revokedAt = now
        let credentialId = UUID().uuidString.lowercased()
        let minted = EmailLoginDirectory.mintOpaqueCredential(prefix: "rnc1", id: credentialId)
        let expiresAt = now.addingTimeInterval(30 * 24 * 60 * 60)
        directory.nativeNotificationCredentials.append(StoredNotificationCredential(
            id: credentialId,
            deviceId: current.deviceId,
            userId: current.userId,
            sessionFamilyId: current.sessionFamilyId,
            secretHash: minted.secretHash,
            scope: "notifications:stream",
            expiresAt: expiresAt
        ))
        return EmailLoginDirectory.json(201, "{\"credential\":\(jsonString(minted.opaque)),\"credentialId\":\(jsonString(credentialId)),\"deviceId\":\(jsonString(current.deviceId)),\"scope\":\"notifications:stream\",\"expiresAt\":\(jsonString(EmailLoginDirectory.iso8601(expiresAt)))}")
    }

    /// `DELETE /api/notifications/credentials/current`. A credential-shaped bearer is 204 even when it is already dead.
    func deleteCurrentNativeNotificationCredential(authorization: String?) -> HTTPReply {
        guard directory.nativeNotificationsEnabled else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        let invalid = EmailLoginDirectory.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        guard let authorization, authorization.hasPrefix("Bearer ") else { return invalid }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.hasPrefix("rnc1.") else { return invalid }
        _ = revokeCurrentNativeCredential(token)
        return EmailLoginDirectory.noContent()
    }

    /// Caller holds `directory.lock`.
    func notificationSessionLocked(_ authorization: String?) -> (userId: String, familyId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let userId = directory.accessTokens[token],
              let familyId = directory.accessTokenFamilies[token],
              directory.sessionFamilies[familyId]?.userId == userId,
              directory.sessionFamilies[familyId]?.revokedAt == nil,
              directory.accounts.values.contains(where: { $0.id == userId && $0.emailVerified })
        else { return nil }
        return (userId, familyId)
    }

    // MARK: - Stream

    /// Opens `GET /api/notifications/stream`. A user session or a foreign cursor fails before any event-stream bytes.
    func beginNativeNotificationStream(authorization: String?, lastEventId: String?) -> EmailLoginDirectory.NativeStreamOpen {
        guard directory.nativeNotificationsEnabled else {
            return .closed(EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}"))
        }
        let denied = EmailLoginDirectory.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        let unavailable = EmailLoginDirectory.json(409, "{\"error\":\"Replay cursor is unavailable\",\"code\":\"replay_cursor_unavailable\"}")
        directory.lock.lock()
        defer { directory.lock.unlock() }
        guard let principal = nativePrincipalLocked(authorization) else {
            return .closed(denied)
        }
        let now = Date()
        if let lastEventId {
            guard lastEventId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
                  let cursor = directory.nativeNotificationEvents.first(where: {
                      $0.eventId == lastEventId && $0.recipientUserId == principal.userId && $0.expiresAt > now
                  })
            else { return .closed(unavailable) }
            let replay = directory.nativeNotificationEvents
                .filter { $0.recipientUserId == principal.userId && $0.streamSeq > cursor.streamSeq && $0.expiresAt > now }
                .sorted { $0.streamSeq < $1.streamSeq }
            if replay.count > 512 {
                return .closed(EmailLoginDirectory.json(409, "{\"error\":\"Replay window exceeded\",\"code\":\"replay_window_exceeded\"}"))
            }
            return .streaming(userId: principal.userId, cursorSeq: cursor.streamSeq, replay: replay.map { ($0.streamSeq, EmailLoginDirectory.sseFrame($0)) })
        }
        let latest = directory.nativeNotificationEvents
            .filter { $0.recipientUserId == principal.userId && $0.expiresAt > now }
            .map(\.streamSeq)
            .max() ?? 0
        return .streaming(userId: principal.userId, cursorSeq: latest, replay: [])
    }

    /// Moves a stored native event into the past. A later stream must fail closed.
    func expireNativeNotificationEvent(id: String) {
        directory.lock.lock()
        if let index = directory.nativeNotificationEvents.firstIndex(where: { $0.eventId == id }) {
            directory.nativeNotificationEvents[index].expiresAt = Date().addingTimeInterval(-1)
        }
        directory.lock.unlock()
    }

    func expireNativeNotificationCredential(id: String) {
        directory.lock.lock()
        if let index = directory.nativeNotificationCredentials.firstIndex(where: { $0.id == id }) {
            directory.nativeNotificationCredentials[index].expiresAt = Date().addingTimeInterval(-1)
        }
        directory.lock.unlock()
    }

    func nativeNotificationDeviceRevokedAt(id: String) -> Date? {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.nativeNotificationDevices.first { $0.id == id }?.revokedAt
    }

    /// Revokes the native credential named by this opaque token. A later stream frame must not be written.
    func revokeCurrentNativeCredential(_ opaque: String) -> Bool {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        guard let parsed = EmailLoginDirectory.parseOpaqueCredential(opaque, prefix: "rnc1") else { return false }
        let hash = EmailLoginDirectory.sha256(parsed.secret)
        guard let index = directory.nativeNotificationCredentials.firstIndex(where: {
            $0.id == parsed.id && $0.secretHash == hash && $0.revokedAt == nil
        }) else { return false }
        directory.nativeNotificationCredentials[index].revokedAt = Date()
        return true
    }

    func nativeNotificationCredentialIsLive(authorization: String?) -> Bool {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return nativePrincipalLocked(authorization) != nil
    }

    func nativeNotificationFrames(userId: String, after cursor: Int) -> [(seq: Int, frame: String)] {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        let now = Date()
        return directory.nativeNotificationEvents
            .filter { $0.recipientUserId == userId && $0.streamSeq > cursor && $0.expiresAt > now }
            .sorted { $0.streamSeq < $1.streamSeq }
            .map { ($0.streamSeq, EmailLoginDirectory.sseFrame($0)) }
    }

    /// Caller holds `directory.lock`. A revoked device cannot authenticate, even if its credential row is still open.
    func nativePrincipalLocked(_ authorization: String?) -> (userId: String, familyId: String, credentialId: String, deviceId: String, publicKey: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let parsed = EmailLoginDirectory.parseOpaqueCredential(token, prefix: "rnc1") else { return nil }
        let hash = EmailLoginDirectory.sha256(parsed.secret)
        let now = Date()
        guard let credential = directory.nativeNotificationCredentials.first(where: {
            $0.id == parsed.id && $0.secretHash == hash && $0.revokedAt == nil && $0.expiresAt > now && $0.scope == "notifications:stream"
        }), let device = directory.nativeNotificationDevices.first(where: { $0.id == credential.deviceId }),
              device.revokedAt == nil
        else { return nil }
        guard !directory.revokedFamilies.contains(credential.sessionFamilyId),
              directory.sessionFamilies[credential.sessionFamilyId]?.userId == credential.userId,
              directory.sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
        else { return nil }
        return (credential.userId, credential.sessionFamilyId, credential.id, credential.deviceId, device.publicKey)
    }

    /// Caller holds `directory.lock`. Revoked devices are `revoked`. A live unexpired credential on a live family is `active`.
    func nativeDeviceStatusLocked(_ device: StoredNotificationDevice, now: Date) -> String {
        if let revokedAt = device.revokedAt, revokedAt <= now { return "revoked" }
        let active = directory.nativeNotificationCredentials.contains { credential in
            credential.deviceId == device.id
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == "notifications:stream"
                && !directory.revokedFamilies.contains(credential.sessionFamilyId)
                && directory.sessionFamilies[credential.sessionFamilyId]?.userId == device.userId
                && directory.sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
        }
        return active ? "active" : "inactive"
    }

    func liveNativeCredentialLocked(userId: String) -> Bool {
        let now = Date()
        return directory.nativeNotificationCredentials.contains { credential in
            credential.userId == userId
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == "notifications:stream"
                && !directory.revokedFamilies.contains(credential.sessionFamilyId)
                && directory.sessionFamilies[credential.sessionFamilyId]?.userId == userId
                && directory.sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
                && directory.nativeNotificationDevices.contains { $0.id == credential.deviceId && $0.revokedAt == nil }
        }
    }

    /// `GET /api/notifications/stream`. The kill switch answers before any stream is opened.
    func nativeNotificationStream() -> HTTPReply {
        guard directory.nativeNotificationsEnabled else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        return EmailLoginDirectory.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
    }

    func nativeNotificationEventCount(eventKey: String) -> Int {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.nativeNotificationEvents.filter { $0.eventKey == eventKey }.count
    }

    func nativeNotificationEventIDs(recipientUserId: String) -> [String] {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.nativeNotificationEvents.filter { $0.recipientUserId == recipientUserId }.map(\.eventId)
    }

    /// Disabled notifications persist nothing. An empty batch also persists nothing.
    /// A recipient without a live native credential does not grow the ledger. The same event key is stored once.
    func persistNativeNotificationIntents(_ intents: [EmailLoginDirectory.NativeNotificationIntent]) -> Int {
        if !directory.nativeNotificationsEnabled || intents.isEmpty { return 0 }
        directory.lock.lock()
        defer { directory.lock.unlock() }
        var inserted = 0
        var seen = Set(directory.nativeNotificationEvents.map(\.eventKey))
        for intent in intents {
            guard liveNativeCredentialLocked(userId: intent.recipientUserId), !seen.contains(intent.eventKey) else { continue }
            seen.insert(intent.eventKey)
            directory.nextNativeNotificationSeq += 1
            let now = Date()
            directory.nativeNotificationEvents.append(StoredNativeNotificationEvent(
                eventId: UUID().uuidString.lowercased(),
                streamSeq: directory.nextNativeNotificationSeq,
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

    // MARK: - Mobile-app lifecycle mail

    /// Signed token for `GET/POST /api/email/mobile-app/unsubscribe`. A missing locale is `en`.
    func createMobileAppEmailUnsubscribeToken(userId: String, locale: String? = nil) -> String {
        let canonical = EmailLoginDirectory.mobileAppUnsubscribeLocale(locale)
        let claims = "{\"v\":1,\"typ\":\"mobile-app-email-unsubscribe\",\"sub\":\(jsonString(userId)),\"locale\":\(jsonString(canonical))}"
        let payload = EmailLoginDirectory.base64url(Data(claims.utf8))
        let signature = EmailLoginDirectory.mobileAppUnsubscribeSignature(payload: payload, secret: directory.mobileAppEmailUnsubscribeSecret)
        return "\(payload).\(signature)"
    }

    /// A scheduled mobile-app lifecycle email. Unsubscribe cancels `day1Status` of `scheduled`.
    func addMobileAppEmailJourney(userId: String, email: String, journeyKey: String, day1Status: String, day1EmailId: String?) {
        directory.lock.lock()
        directory.storedMobileAppEmailJourneys.append(EmailLoginDirectory.MobileAppEmailJourney(
            userId: userId,
            email: EmailLoginDirectory.normalize(email),
            journeyKey: journeyKey,
            day1Status: day1Status,
            day1EmailId: day1EmailId,
            suppressedReason: nil,
            canceledAt: nil
        ))
        directory.lock.unlock()
    }

    func mobileAppEmailJourneys() -> [EmailLoginDirectory.MobileAppEmailJourney] {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.storedMobileAppEmailJourneys
    }

    /// Local opt-outs for the mobile-app lifecycle audience. The human page does not write one.
    func mobileAppEmailContacts() -> [EmailLoginDirectory.MobileAppEmailContact] {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.mobileAppEmailContactsByKey.values.sorted { $0.email < $1.email }
    }

    // MARK: - Account helpers used by the shared fixtures

    func setAccountProfile(id: String, name: String, displayName: String? = nil) {
        directory.lock.lock()
        if let key = directory.accounts.first(where: { $0.value.id == id })?.key,
           var account = directory.accounts[key] {
            account.name = name
            account.displayName = displayName ?? name
            directory.accounts[key] = account
        }
        directory.lock.unlock()
    }

    func addAccount(id: String, email: String, password: String, avatarUrl: String? = nil, passwordCredentialEstablished: Bool = true) {
        let normalized = EmailLoginDirectory.normalize(email)
        directory.lock.lock()
        directory.accounts[normalized] = Account(
            id: id,
            email: normalized,
            passwordHash: EmailLoginDirectory.sha256(password),
            passwordCredentialEstablishedAt: passwordCredentialEstablished ? Date() : nil,
            displayLanguage: nil,
            name: String(normalized.split(separator: "@").first ?? "user"),
            profileSetupSuggestedHandle: nil,
            profileSetupProvider: nil,
            profileSetupCompletedAt: Date(),
            avatarUrl: avatarUrl
        )
        directory.analyticsIds[id] = UUID().uuidString.lowercased()
        directory.lock.unlock()
    }

    /// The product-analytics id for this user. Opting out removes it. Opting back in mints a new one.
    func analyticsId(userId: String) -> String? {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.analyticsIds[userId]
    }

    func socialCompletionUserId(provider: String, code: String) -> String?? {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        guard let completion = directory.socialCompletions.first(where: { $0.provider == provider && $0.code == code }) else {
            return nil
        }
        return .some(completion.userId)
    }

    // MARK: - Built-in catalog admission

    /// `409` when the target Computer cannot answer for its Built-in catalog.
    func builtinCatalogFailureReply() -> HTTPReply {
        EmailLoginDirectory.json(409, "{\"code\":\"builtin_catalog_unavailable\",\"error\":\"The target Computer's Built-in model catalog is unavailable. Retry after the Computer reconnects.\"}")
    }

    /// Built-in model admission check. Anything but a Built-in runtime is not ours to judge.
    func builtinModelCheck(machineId: String?, config: [String: Any]) -> BuiltinModelCatalogResult? {
        guard let machineId,
              (config["runtime"] as? String) == "builtin",
              let model = config["model"] as? [String: Any],
              let modelId = model["id"] as? String,
              let check = directory.builtinModelCatalogCheck
        else { return nil }
        return check(machineId, modelId)
    }

    // MARK: - Agent attachments and integration tokens

    func setAgentAttachmentPresign(_ handler: (@Sendable (String, Int, String, String) throws -> String)?) {
        directory.lock.lock()
        directory.agentAttachmentPresign = handler
        directory.lock.unlock()
    }

    func addAgentAttachment(
        channelId: String,
        id: String,
        uploaderId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        storageKey: String? = nil,
        bytes: Data
    ) {
        directory.lock.lock()
        directory.channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: nil,
            messagePosition: nil,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            storageKey: storageKey
        )
        directory.agentAttachmentBytes[id] = bytes
        directory.lock.unlock()
    }

    static let agentAttachmentUnavailableMessage = "Attachment is unavailable."
    static let agentAttachmentUnavailableNextAction = "If this value came from a feedback report, do not use its artifactId here. Use the reportId with the Raft Feedback Admin integration instead: run `raft integration invoke --service \"Raft Feedback Admin\" --action download_feedback_transcript --param id=REPORT_ID --output PATH`."

    func agentAttachmentUnavailableReply() -> HTTPReply {
        let error = Self.agentAttachmentUnavailableMessage + " " + Self.agentAttachmentUnavailableNextAction
        return EmailLoginDirectory.json(404, "{\"error\":\(jsonString(error)),\"code\":\"ATTACHMENT_UNAVAILABLE\",\"suggestedNextAction\":\(jsonString(Self.agentAttachmentUnavailableNextAction))}")
    }

    func agentAttachmentUnavailableURLReply() -> HTTPReply {
        EmailLoginDirectory.json(409, "{\"error\":\"This Server's file storage cannot mint download URLs.\",\"code\":\"download_url_unavailable\",\"suggestedNextAction\":\"Download the attachment bytes instead: GET /internal/agent-api/attachments/:attachmentId (`raft attachment view --id <attachmentId> --output <path>`).\"}")
    }

    func agentVisibleAttachment(agentId: String, serverId: String, attachmentId: String) -> ChannelAttachment? {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        guard let attachment = directory.channelAttachments[attachmentId],
              let channel = directory.postableChannels[attachment.channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return nil }
        let visible = channel.kind == "channel"
            || channel.memberIds.contains(agentId)
            || directory.oauth.channelAgentIds(channelId: attachment.channelId).contains(agentId)
        return visible ? attachment : nil
    }

    func agentAttachmentIdentity(authorization: String?) -> (agentId: String, serverId: String)? {
        switch directory.feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused: return nil
        case .success(let agentId, let serverId): return (agentId, serverId)
        }
    }

    func agentAttachmentDownload(authorization: String?, attachmentId: String) -> HTTPReply {
        guard let identity = agentAttachmentIdentity(authorization: authorization) else {
            switch directory.feedbackLocatorIdentity(authorization: authorization, capability: "read") {
            case .refused(let reply): return reply
            case .success: return EmailLoginDirectory.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
            }
        }
        guard let attachment = agentVisibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            return agentAttachmentUnavailableReply()
        }
        directory.lock.lock()
        let bytes = directory.agentAttachmentBytes[attachmentId] ?? Data()
        directory.lock.unlock()
        var reply = HTTPReply(
            status: 200,
            headers: [
                "Content-Type": attachment.mimeType ?? "application/octet-stream",
                "Content-Length": String(bytes.count),
            ],
            body: String(decoding: bytes, as: UTF8.self)
        )
        reply.headers["Cache-Control"] = "private, no-store"
        reply.headers["Content-Disposition"] = "attachment; filename=\"\(attachment.filename)\"; filename*=UTF-8''\(EmailLoginDirectory.rfc5987Encode(attachment.filename))"
        return reply
    }

    func agentAttachmentDownloadURL(authorization: String?, attachmentId: String) -> HTTPReply {
        guard let identity = agentAttachmentIdentity(authorization: authorization) else {
            switch directory.feedbackLocatorIdentity(authorization: authorization, capability: "read") {
            case .refused(let reply): return reply
            case .success: return EmailLoginDirectory.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
            }
        }
        guard let attachment = agentVisibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            return agentAttachmentUnavailableReply()
        }
        directory.lock.lock()
        let presign = directory.agentAttachmentPresign
        directory.lock.unlock()
        guard let presign else {
            return agentAttachmentUnavailableURLReply()
        }
        let ext = (attachment.filename as NSString).pathExtension
        let storageKey = attachment.storageKey ?? (ext.isEmpty ? "\(identity.serverId)/\(attachmentId)" : "\(identity.serverId)/\(attachmentId).\(ext)")
        let filename = attachment.filename
        let mimeType = attachment.mimeType ?? "application/octet-stream"
        let disposition = "attachment; filename=\"\(filename)\"; filename*=UTF-8''\(EmailLoginDirectory.rfc5987Encode(filename))"
        let url: String
        do {
            url = try presign(storageKey, 300, disposition, mimeType)
        } catch {
            return EmailLoginDirectory.json(500, "{\"error\":\"Failed to mint a download URL\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: Date().addingTimeInterval(300))
        var reply = EmailLoginDirectory.json(200, "{\"url\":\(jsonString(url)),\"expiresAt\":\(jsonString(expiresAt)),\"filename\":\(jsonString(filename)),\"mimeType\":\(jsonString(mimeType))}")
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    func setAgentAudienceStatus(agentId: String, status: String) {
        directory.lock.lock()
        directory.agentAudienceStatusOverrides[agentId] = status
        directory.lock.unlock()
    }

    func revokeAgentIntegrationGrant(agentId: String, clientKey: String) {
        directory.lock.lock()
        directory.agentIntegrationGrants["\(agentId)\n\(clientKey)"] = true
        directory.lock.unlock()
    }

    func restoreAgentIntegrationGrant(agentId: String, clientKey: String) {
        directory.lock.lock()
        directory.agentIntegrationGrants["\(agentId)\n\(clientKey)"] = false
        directory.lock.unlock()
    }

    func revokeAgentCredential(apiKey: String) {
        directory.lock.lock()
        directory.agentCredentials[apiKey]?.revokedAt = Date()
        directory.lock.unlock()
    }

    func agentIntegrationToken(authorization: String?, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        directory.lock.lock()
        let credential = directory.agentCredentials[token]
        directory.lock.unlock()
        guard let credential, credential.revokedAt == nil,
              credential.scopes.contains("read"),
              let agent = directory.oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return EmailLoginDirectory.json(400, "{\"error\":\"Invalid integration token request\",\"code\":\"INVALID_REQUEST\"}")
        }
        for field in ["agentId", "serverId", "audience", "issuer", "expires_in", "scopes", "claims"]
        where object[field] != nil {
            return EmailLoginDirectory.json(400, "{\"error\":\"Request fields are derived from the credential\",\"code\":\"INVALID_REQUEST\"}")
        }
        guard let service = (object["service"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !service.isEmpty
        else {
            return EmailLoginDirectory.json(400, "{\"error\":\"service is required\",\"code\":\"INVALID_REQUEST\"}")
        }
        directory.lock.lock()
        let status = directory.agentAudienceStatusOverrides[agent.id] ?? "active"
        directory.lock.unlock()
        guard status == "active" else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Agent is not active\",\"code\":\"AGENT_INACTIVE\"}")
        }
        guard directory.oauth.agentRole(serverId: agent.serverId, agentId: agent.id) != nil else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Agent is not a member of this Server\",\"code\":\"AGENT_NOT_MEMBER\"}")
        }
        guard let client = directory.oauth.localClientForAgentAudience(clientId: service, serverId: agent.serverId),
              client.enabled,
              client.allowedScopes.contains("openid"),
              client.allowedScopes.contains("profile")
        else {
            return EmailLoginDirectory.json(403, "{\"error\":\"That App is not available on this Server\",\"code\":\"APP_UNAVAILABLE\"}")
        }
        let grantKey = "\(agent.id)\n\(client.clientId)"
        directory.lock.lock()
        let revoked = directory.agentIntegrationGrants[grantKey] == true
        if !revoked {
            directory.agentIntegrationGrants[grantKey] = false
        }
        directory.lock.unlock()
        guard !revoked else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Agent access to this App has been revoked\",\"code\":\"GRANT_REVOKED\"}")
        }
        guard let slug = directory.oauth.serverProfile(id: agent.serverId)?.slug,
              let origin = OAuthDiscovery.issuerOrigin(directory.serverURL),
              let signed = directory.oauth.signAgentAudienceToken(
                  agentId: agent.id,
                  agentName: agent.name,
                  clientKey: client.clientId,
                  serverId: agent.serverId,
                  serverSlug: slug,
                  issuer: "\(origin)/oidc/\(slug)"
              )
        else {
            return EmailLoginDirectory.json(500, "{\"error\":\"Failed to issue the App token\"}")
        }
        var reply = EmailLoginDirectory.json(200, "{\"access_token\":\(jsonString(signed.token)),\"audience\":\(jsonString(client.clientId)),\"expires_in\":300}")
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }
}

// MARK: - Directory entry points

extension EmailLoginDirectory {
    /// The bytes an Ed25519 enrollment proof signs. The secret stays out of the stored row.
    public static func enrollmentProofTranscript(grant: String, appId: String, protocolVersion: Int, appVersion: String, releaseChannel: String, appInstanceId: String, publicKey: String, nonce: String) -> Data {
        let joined = [
            "raft-desktop-notification-enrollment-v1",
            sha256(grant),
            appId,
            String(protocolVersion),
            appVersion,
            releaseChannel,
            appInstanceId,
            publicKey,
            nonce,
        ].joined(separator: "\u{0}")
        return Data(joined.utf8)
    }

    /// The bytes an Ed25519 rotation proof signs.
    public static func rotationProofTranscript(credential: String, deviceId: String) -> Data {
        let joined = ["raft-desktop-notification-rotation-v1", sha256(credential), deviceId].joined(separator: "\u{0}")
        return Data(joined.utf8)
    }

    /// Operator kill switch for `/internal/agent-api` and `/internal/computer`.
    /// `SLOCK_EXPERIMENTAL_SURFACES_DISABLED=true` disables them; tests may
    /// override without touching the process environment.
    public func setExperimentalSurfacesDisabledForTesting(_ value: Bool?) {
        AttachmentsAndNotificationsService(directory: self).setExperimentalSurfacesDisabled(value)
    }

    public func nativeEnrollmentGrantRecords() -> [NativeEnrollmentGrantRecord] {
        AttachmentsAndNotificationsService(directory: self).nativeEnrollmentGrantRecords()
    }

    /// Moves a stored enrollment grant into the past. Exchange must then fail closed.
    public func expireNativeEnrollmentGrant(id: String) {
        AttachmentsAndNotificationsService(directory: self).expireNativeEnrollmentGrant(id: id)
    }

    /// Marks every session family for this user revoked. A later enrollment exchange must fail closed.
    public func revokeSessionFamilies(userId: String) {
        AttachmentsAndNotificationsService(directory: self).revokeSessionFamilies(userId: userId)
    }

    public func nativeNotificationCredentialJSON(id: String) -> String? {
        AttachmentsAndNotificationsService(directory: self).nativeNotificationCredentialJSON(id: id)
    }

    /// `POST /api/notifications/enrollment-grants`. The opaque grant is returned once. Only its hash is stored.
    public func issueNativeEnrollmentGrant(body: String, authorization: String?) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).issueNativeEnrollmentGrant(body: body, authorization: authorization)
    }

    /// `POST /api/notifications/enrollment-exchanges`. One grant mints one credential. A second exchange is denied.
    public func exchangeNativeEnrollmentGrant(body: String) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).exchangeNativeEnrollmentGrant(body: body)
    }

    /// `GET /api/notifications/devices`. The list omits hashes, public keys, and credential secrets.
    public func listNativeNotificationDevices(authorization: String?) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).listNativeNotificationDevices(authorization: authorization)
    }

    /// `DELETE /api/notifications/devices/:deviceId`. A missing or foreign device is 404.
    public func revokeNativeNotificationDevice(authorization: String?, deviceId: String) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).revokeNativeNotificationDevice(authorization: authorization, deviceId: deviceId)
    }

    /// `POST /api/notifications/credentials/rotate`. The proof is the device key over the current credential.
    public func rotateNativeNotificationCredential(authorization: String?, body: String) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).rotateNativeNotificationCredential(authorization: authorization, body: body)
    }

    /// `DELETE /api/notifications/credentials/current`. A credential-shaped bearer is 204 even when it is already dead.
    public func deleteCurrentNativeNotificationCredential(authorization: String?) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).deleteCurrentNativeNotificationCredential(authorization: authorization)
    }

    /// Opens `GET /api/notifications/stream`. A user session or a foreign cursor fails before any event-stream bytes.
    public func beginNativeNotificationStream(authorization: String?, lastEventId: String?) -> NativeStreamOpen {
        AttachmentsAndNotificationsService(directory: self).beginNativeNotificationStream(
            authorization: authorization,
            lastEventId: lastEventId
        )
    }

    /// Moves a stored native event into the past. A later stream must fail closed.
    public func expireNativeNotificationEvent(id: String) {
        AttachmentsAndNotificationsService(directory: self).expireNativeNotificationEvent(id: id)
    }

    public func expireNativeNotificationCredential(id: String) {
        AttachmentsAndNotificationsService(directory: self).expireNativeNotificationCredential(id: id)
    }

    public func nativeNotificationDeviceRevokedAt(id: String) -> Date? {
        AttachmentsAndNotificationsService(directory: self).nativeNotificationDeviceRevokedAt(id: id)
    }

    /// Revokes the native credential named by this opaque token. A later stream frame must not be written.
    public func revokeCurrentNativeCredential(_ opaque: String) -> Bool {
        AttachmentsAndNotificationsService(directory: self).revokeCurrentNativeCredential(opaque)
    }

    public func nativeNotificationCredentialIsLive(authorization: String?) -> Bool {
        AttachmentsAndNotificationsService(directory: self).nativeNotificationCredentialIsLive(authorization: authorization)
    }

    public func nativeNotificationFrames(userId: String, after cursor: Int) -> [(seq: Int, frame: String)] {
        AttachmentsAndNotificationsService(directory: self).nativeNotificationFrames(userId: userId, after: cursor)
    }

    /// `GET /api/notifications/stream`. The kill switch answers before any stream is opened.
    public func nativeNotificationStream() -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).nativeNotificationStream()
    }

    public func nativeNotificationEventCount(eventKey: String) -> Int {
        AttachmentsAndNotificationsService(directory: self).nativeNotificationEventCount(eventKey: eventKey)
    }

    public func nativeNotificationEventIDs(recipientUserId: String) -> [String] {
        AttachmentsAndNotificationsService(directory: self).nativeNotificationEventIDs(recipientUserId: recipientUserId)
    }

    /// Disabled notifications persist nothing. An empty batch also persists nothing.
    /// A recipient without a live native credential does not grow the ledger. The same event key is stored once.
    public func persistNativeNotificationIntents(_ intents: [NativeNotificationIntent]) -> Int {
        AttachmentsAndNotificationsService(directory: self).persistNativeNotificationIntents(intents)
    }

    /// Signed token for `GET/POST /api/email/mobile-app/unsubscribe`. A missing locale is `en`.
    public func createMobileAppEmailUnsubscribeToken(userId: String, locale: String? = nil) -> String {
        AttachmentsAndNotificationsService(directory: self).createMobileAppEmailUnsubscribeToken(userId: userId, locale: locale)
    }

    /// A scheduled mobile-app lifecycle email. Unsubscribe cancels `day1Status` of `scheduled`.
    public func addMobileAppEmailJourney(userId: String, email: String, journeyKey: String, day1Status: String, day1EmailId: String?) {
        AttachmentsAndNotificationsService(directory: self).addMobileAppEmailJourney(
            userId: userId,
            email: email,
            journeyKey: journeyKey,
            day1Status: day1Status,
            day1EmailId: day1EmailId
        )
    }

    public func mobileAppEmailJourneys() -> [MobileAppEmailJourney] {
        AttachmentsAndNotificationsService(directory: self).mobileAppEmailJourneys()
    }

    /// Local opt-outs for the mobile-app lifecycle audience. The human page does not write one.
    public func mobileAppEmailContacts() -> [MobileAppEmailContact] {
        AttachmentsAndNotificationsService(directory: self).mobileAppEmailContacts()
    }

    public func setAccountProfileForTesting(id: String, name: String, displayName: String? = nil) {
        AttachmentsAndNotificationsService(directory: self).setAccountProfile(id: id, name: name, displayName: displayName)
    }

    public func addAccount(id: String, email: String, password: String, avatarUrl: String? = nil, passwordCredentialEstablished: Bool = true) {
        AttachmentsAndNotificationsService(directory: self).addAccount(
            id: id,
            email: email,
            password: password,
            avatarUrl: avatarUrl,
            passwordCredentialEstablished: passwordCredentialEstablished
        )
    }

    /// The product-analytics id for this user. Opting out removes it. Opting back in mints a new one.
    public func analyticsId(userId: String) -> String? {
        AttachmentsAndNotificationsService(directory: self).analyticsId(userId: userId)
    }

    public func socialCompletionUserIdForTesting(provider: String, code: String) -> String?? {
        AttachmentsAndNotificationsService(directory: self).socialCompletionUserId(provider: provider, code: code)
    }

    /// `409` when the target Computer cannot answer for its Built-in catalog.
    func builtinCatalogFailureReply() -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).builtinCatalogFailureReply()
    }

    /// Built-in model admission check. Anything but a Built-in runtime is not ours to judge.
    func builtinModelCheck(machineId: String?, config: [String: Any]) -> BuiltinModelCatalogResult? {
        AttachmentsAndNotificationsService(directory: self).builtinModelCheck(machineId: machineId, config: config)
    }

    public func setAgentAttachmentPresignForTesting(_ handler: (@Sendable (String, Int, String, String) throws -> String)?) {
        AttachmentsAndNotificationsService(directory: self).setAgentAttachmentPresign(handler)
    }

    public func addAgentAttachmentForTesting(
        channelId: String,
        id: String,
        uploaderId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        storageKey: String? = nil,
        bytes: Data
    ) {
        AttachmentsAndNotificationsService(directory: self).addAgentAttachment(
            channelId: channelId,
            id: id,
            uploaderId: uploaderId,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            storageKey: storageKey,
            bytes: bytes
        )
    }

    func agentVisibleAttachment(agentId: String, serverId: String, attachmentId: String) -> ChannelAttachment? {
        AttachmentsAndNotificationsService(directory: self).agentVisibleAttachment(
            agentId: agentId,
            serverId: serverId,
            attachmentId: attachmentId
        )
    }

    public func agentAttachmentDownload(authorization: String?, attachmentId: String) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).agentAttachmentDownload(
            authorization: authorization,
            attachmentId: attachmentId
        )
    }

    public func agentAttachmentDownloadURL(authorization: String?, attachmentId: String) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).agentAttachmentDownloadURL(
            authorization: authorization,
            attachmentId: attachmentId
        )
    }

    public func setAgentAudienceStatusForTesting(agentId: String, status: String) {
        AttachmentsAndNotificationsService(directory: self).setAgentAudienceStatus(agentId: agentId, status: status)
    }

    public func revokeAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        AttachmentsAndNotificationsService(directory: self).revokeAgentIntegrationGrant(agentId: agentId, clientKey: clientKey)
    }

    public func restoreAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        AttachmentsAndNotificationsService(directory: self).restoreAgentIntegrationGrant(agentId: agentId, clientKey: clientKey)
    }

    public func revokeAgentCredentialForTesting(apiKey: String) {
        AttachmentsAndNotificationsService(directory: self).revokeAgentCredential(apiKey: apiKey)
    }

    public func agentIntegrationToken(authorization: String?, body: String) -> HTTPReply {
        AttachmentsAndNotificationsService(directory: self).agentIntegrationToken(authorization: authorization, body: body)
    }
}
