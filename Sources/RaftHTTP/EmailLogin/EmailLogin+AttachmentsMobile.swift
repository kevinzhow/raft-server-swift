import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {


    /// Operator kill switch for `/internal/agent-api` and `/internal/computer`.
    /// `SLOCK_EXPERIMENTAL_SURFACES_DISABLED=true` disables them; tests may
    /// override without touching the process environment.
    public func setExperimentalSurfacesDisabledForTesting(_ value: Bool?) {
        lock.lock()
        experimentalSurfacesDisabledForTesting = value
        lock.unlock()
    }

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

    public func nativeEnrollmentGrantRecords() -> [NativeEnrollmentGrantRecord] {
        lock.lock()
        defer { lock.unlock() }
        return nativeEnrollmentGrants.map { grant in
            let json = "{\"id\":\(jsonString(grant.id)),\"secretHash\":\(jsonString(grant.secretHash)),\"publicKey\":\(jsonString(grant.publicKey)),\"nonce\":\(jsonString(grant.nonce))}"
            return NativeEnrollmentGrantRecord(secretHash: grant.secretHash, json: json)
        }
    }

    /// Moves a stored enrollment grant into the past. Exchange must then fail closed.
    public func expireNativeEnrollmentGrant(id: String) {
        lock.lock()
        if let index = nativeEnrollmentGrants.firstIndex(where: { $0.id == id }) {
            nativeEnrollmentGrants[index].expiresAt = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    /// Marks every session family for this user revoked. A later enrollment exchange must fail closed.
    public func revokeSessionFamilies(userId: String) {
        lock.lock()
        let now = Date()
        for key in sessionFamilies.keys where sessionFamilies[key]?.userId == userId {
            if sessionFamilies[key]?.revokedAt == nil {
                sessionFamilies[key]?.revokedAt = now
            }
            revokedFamilies.insert(key)
        }
        lock.unlock()
    }

    public func nativeNotificationCredentialJSON(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = nativeNotificationCredentials.first(where: { $0.id == id }) else { return nil }
        return "{\"id\":\(jsonString(row.id)),\"secretHash\":\(jsonString(row.secretHash)),\"scope\":\(jsonString(row.scope))}"
    }

    /// `POST /api/notifications/enrollment-grants`. The opaque grant is returned once. Only its hash is stored.
    public func issueNativeEnrollmentGrant(body: String, authorization: String?) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        lock.lock()
        guard let session = notificationSessionLocked(authorization) else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"A live normal session family is required\",\"code\":\"session_family_required\"}")
        }
        guard let request = Self.parseEnrollmentRequest(body) else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_request\"}")
        }
        let attestation = Self.evaluateAttestation(
            body: body,
            mode: nativeNotificationAttestationMode,
            nodeEnv: nativeNotificationNodeEnv,
            verifier: nativeNotificationAttestationVerifier
        )
        if attestation.state == "rejected" {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Desktop application attestation is required\",\"code\":\"desktop_attestation_required\"}")
        }
        let id = UUID().uuidString.lowercased()
        let minted = Self.mintOpaqueCredential(prefix: "rng1", id: id)
        let now = Date()
        let expiresAt = now.addingTimeInterval(60)
        nativeEnrollmentGrants.append(StoredEnrollmentGrant(
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
        lock.unlock()
        return Self.json(201, "{\"grant\":\(jsonString(minted.opaque)),\"expiresAt\":\(jsonString(Self.iso8601(expiresAt)))}")
    }

    /// `POST /api/notifications/enrollment-exchanges`. One grant mints one credential. A second exchange is denied.
    public func exchangeNativeEnrollmentGrant(body: String) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let grantText = object["grant"] as? String,
              let parsed = Self.parseOpaqueCredential(grantText, prefix: "rng1")
        else {
            return Self.json(400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_exchange\"}")
        }
        let proof = object["proof"] as? String ?? ""
        let denied = Self.json(403, "{\"error\":\"Enrollment exchange denied\",\"code\":\"enrollment_exchange_denied\"}")
        lock.lock()
        guard let index = nativeEnrollmentGrants.firstIndex(where: { $0.id == parsed.id }) else {
            lock.unlock()
            return denied
        }
        let grant = nativeEnrollmentGrants[index]
        let secretHash = Self.sha256(parsed.secret)
        guard secretHash == grant.secretHash,
              grant.consumedAt == nil,
              grant.expiresAt > Date(),
              grant.attestationState != "rejected",
              sessionFamilies[grant.sessionFamilyId]?.userId == grant.userId,
              sessionFamilies[grant.sessionFamilyId]?.revokedAt == nil
        else {
            lock.unlock()
            return denied
        }
        let transcript = Self.enrollmentProofTranscript(
            grant: grantText,
            appId: grant.appId,
            protocolVersion: grant.protocolVersion,
            appVersion: grant.appVersion,
            releaseChannel: grant.releaseChannel,
            appInstanceId: grant.appInstanceId,
            publicKey: grant.publicKey,
            nonce: grant.nonce
        )
        guard Self.verifyEd25519(publicKeySPKI: grant.publicKey, transcript: transcript, proof: proof) else {
            lock.unlock()
            return denied
        }
        let now = Date()
        let deviceId = UUID().uuidString.lowercased()
        nativeNotificationDevices.append(StoredNotificationDevice(
            id: deviceId,
            userId: grant.userId,
            appId: grant.appId,
            appVersion: grant.appVersion,
            releaseChannel: grant.releaseChannel,
            appInstanceId: grant.appInstanceId,
            publicKey: grant.publicKey
        ))
        let credentialId = UUID().uuidString.lowercased()
        let minted = Self.mintOpaqueCredential(prefix: "rnc1", id: credentialId)
        nativeNotificationCredentials.append(StoredNotificationCredential(
            id: credentialId,
            deviceId: deviceId,
            userId: grant.userId,
            sessionFamilyId: grant.sessionFamilyId,
            secretHash: minted.secretHash,
            scope: "notifications:stream",
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        ))
        nativeEnrollmentGrants[index].consumedAt = now
        lock.unlock()
        return Self.json(201, "{\"credential\":\(jsonString(minted.opaque)),\"credentialId\":\(jsonString(credentialId)),\"deviceId\":\(jsonString(deviceId)),\"scope\":\"notifications:stream\",\"expiresAt\":\(jsonString(Self.iso8601(now.addingTimeInterval(30 * 24 * 60 * 60))))}")
    }

    /// `GET /api/notifications/devices`. The list omits hashes, public keys, and credential secrets.
    public func listNativeNotificationDevices(authorization: String?) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        lock.lock()
        guard let session = notificationSessionLocked(authorization) else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let now = Date()
        let listed = nativeNotificationDevices.filter { $0.userId == session.userId }.map { device in
            let status = nativeDeviceStatusLocked(device, now: now)
            return "{\"deviceId\":\(jsonString(device.id)),\"appId\":\(jsonString(device.appId)),\"appVersion\":\(jsonString(device.appVersion)),\"releaseChannel\":\(jsonString(device.releaseChannel)),\"appInstanceId\":\(jsonString(device.appInstanceId)),\"attestationState\":\"missing\",\"status\":\(jsonString(status))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"devices\":[\(listed)]}")
    }

    /// `DELETE /api/notifications/devices/:deviceId`. A missing or foreign device is 404.
    public func revokeNativeNotificationDevice(authorization: String?, deviceId: String) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let session = notificationSessionLocked(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let notFound = Self.json(404, "{\"error\":\"Notification device not found\",\"code\":\"notification_device_not_found\"}")
        guard deviceId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
              let index = nativeNotificationDevices.firstIndex(where: {
                  $0.id == deviceId && $0.userId == session.userId && $0.revokedAt == nil
              })
        else { return notFound }
        let now = Date()
        nativeNotificationDevices[index].revokedAt = now
        for credentialIndex in nativeNotificationCredentials.indices
        where nativeNotificationCredentials[credentialIndex].deviceId == deviceId
            && nativeNotificationCredentials[credentialIndex].revokedAt == nil {
            nativeNotificationCredentials[credentialIndex].revokedAt = now
        }
        return Self.noContent()
    }

    /// `POST /api/notifications/credentials/rotate`. The proof is the device key over the current credential.
    public func rotateNativeNotificationCredential(authorization: String?, body: String) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        let invalid = Self.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        guard let authorization, authorization.hasPrefix("Bearer ") else { return invalid }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.hasPrefix("rnc1.") else { return invalid }
        let proof = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["proof"] as? String ?? ""
        lock.lock()
        defer { lock.unlock() }
        guard let principal = nativePrincipalLocked(authorization),
              let index = nativeNotificationCredentials.firstIndex(where: { $0.id == principal.credentialId && $0.revokedAt == nil })
        else { return invalid }
        guard Self.verifyEd25519(
            publicKeySPKI: principal.publicKey,
            transcript: Self.rotationProofTranscript(credential: token, deviceId: principal.deviceId),
            proof: proof
        ) else {
            return Self.json(403, "{\"error\":\"Invalid native notification credential proof\",\"code\":\"native_credential_proof_invalid\"}")
        }
        let current = nativeNotificationCredentials[index]
        let now = Date()
        nativeNotificationCredentials[index].revokedAt = now
        let credentialId = UUID().uuidString.lowercased()
        let minted = Self.mintOpaqueCredential(prefix: "rnc1", id: credentialId)
        let expiresAt = now.addingTimeInterval(30 * 24 * 60 * 60)
        nativeNotificationCredentials.append(StoredNotificationCredential(
            id: credentialId,
            deviceId: current.deviceId,
            userId: current.userId,
            sessionFamilyId: current.sessionFamilyId,
            secretHash: minted.secretHash,
            scope: "notifications:stream",
            expiresAt: expiresAt
        ))
        return Self.json(201, "{\"credential\":\(jsonString(minted.opaque)),\"credentialId\":\(jsonString(credentialId)),\"deviceId\":\(jsonString(current.deviceId)),\"scope\":\"notifications:stream\",\"expiresAt\":\(jsonString(Self.iso8601(expiresAt)))}")
    }

    /// `DELETE /api/notifications/credentials/current`. A credential-shaped bearer is 204 even when it is already dead.
    public func deleteCurrentNativeNotificationCredential(authorization: String?) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        let invalid = Self.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        guard let authorization, authorization.hasPrefix("Bearer ") else { return invalid }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.hasPrefix("rnc1.") else { return invalid }
        _ = revokeCurrentNativeCredential(token)
        return Self.noContent()
    }

    /// Caller holds `lock`.
    func notificationSessionLocked(_ authorization: String?) -> (userId: String, familyId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let userId = accessTokens[token],
              let familyId = accessTokenFamilies[token],
              sessionFamilies[familyId]?.userId == userId,
              sessionFamilies[familyId]?.revokedAt == nil,
              accounts.values.contains(where: { $0.id == userId && $0.emailVerified })
        else { return nil }
        return (userId, familyId)
    }

    /// Opens `GET /api/notifications/stream`. A user session or a foreign cursor fails before any event-stream bytes.
    public func beginNativeNotificationStream(authorization: String?, lastEventId: String?) -> NativeStreamOpen {
        guard nativeNotificationsEnabled else {
            return .closed(Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}"))
        }
        let denied = Self.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        let unavailable = Self.json(409, "{\"error\":\"Replay cursor is unavailable\",\"code\":\"replay_cursor_unavailable\"}")
        lock.lock()
        defer { lock.unlock() }
        guard let principal = nativePrincipalLocked(authorization) else {
            return .closed(denied)
        }
        let now = Date()
        if let lastEventId {
            guard lastEventId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
                  let cursor = nativeNotificationEvents.first(where: {
                      $0.eventId == lastEventId && $0.recipientUserId == principal.userId && $0.expiresAt > now
                  })
            else { return .closed(unavailable) }
            let replay = nativeNotificationEvents
                .filter { $0.recipientUserId == principal.userId && $0.streamSeq > cursor.streamSeq && $0.expiresAt > now }
                .sorted { $0.streamSeq < $1.streamSeq }
            if replay.count > 512 {
                return .closed(Self.json(409, "{\"error\":\"Replay window exceeded\",\"code\":\"replay_window_exceeded\"}"))
            }
            return .streaming(userId: principal.userId, cursorSeq: cursor.streamSeq, replay: replay.map { ($0.streamSeq, Self.sseFrame($0)) })
        }
        let latest = nativeNotificationEvents
            .filter { $0.recipientUserId == principal.userId && $0.expiresAt > now }
            .map(\.streamSeq)
            .max() ?? 0
        return .streaming(userId: principal.userId, cursorSeq: latest, replay: [])
    }

    /// Moves a stored native credential into the past. A later stream must fail closed.
    public func expireNativeNotificationEvent(id: String) {
        lock.lock()
        if let index = nativeNotificationEvents.firstIndex(where: { $0.eventId == id }) {
            nativeNotificationEvents[index].expiresAt = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func expireNativeNotificationCredential(id: String) {
        lock.lock()
        if let index = nativeNotificationCredentials.firstIndex(where: { $0.id == id }) {
            nativeNotificationCredentials[index].expiresAt = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func nativeNotificationDeviceRevokedAt(id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return nativeNotificationDevices.first { $0.id == id }?.revokedAt
    }

    /// Revokes the native credential named by this opaque token. A later stream frame must not be written.
    public func revokeCurrentNativeCredential(_ opaque: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let parsed = Self.parseOpaqueCredential(opaque, prefix: "rnc1") else { return false }
        let hash = Self.sha256(parsed.secret)
        guard let index = nativeNotificationCredentials.firstIndex(where: {
            $0.id == parsed.id && $0.secretHash == hash && $0.revokedAt == nil
        }) else { return false }
        nativeNotificationCredentials[index].revokedAt = Date()
        return true
    }

    public func nativeNotificationCredentialIsLive(authorization: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nativePrincipalLocked(authorization) != nil
    }

    public func nativeNotificationFrames(userId: String, after cursor: Int) -> [(seq: Int, frame: String)] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return nativeNotificationEvents
            .filter { $0.recipientUserId == userId && $0.streamSeq > cursor && $0.expiresAt > now }
            .sorted { $0.streamSeq < $1.streamSeq }
            .map { ($0.streamSeq, Self.sseFrame($0)) }
    }

    /// Caller holds `lock`. A revoked device cannot authenticate, even if its credential row is still open.
    func nativePrincipalLocked(_ authorization: String?) -> (userId: String, familyId: String, credentialId: String, deviceId: String, publicKey: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let parsed = Self.parseOpaqueCredential(token, prefix: "rnc1") else { return nil }
        let hash = Self.sha256(parsed.secret)
        let now = Date()
        guard let credential = nativeNotificationCredentials.first(where: {
            $0.id == parsed.id && $0.secretHash == hash && $0.revokedAt == nil && $0.expiresAt > now && $0.scope == "notifications:stream"
        }), let device = nativeNotificationDevices.first(where: { $0.id == credential.deviceId }),
              device.revokedAt == nil
        else { return nil }
        guard !revokedFamilies.contains(credential.sessionFamilyId),
              sessionFamilies[credential.sessionFamilyId]?.userId == credential.userId,
              sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
        else { return nil }
        return (credential.userId, credential.sessionFamilyId, credential.id, credential.deviceId, device.publicKey)
    }

    /// Caller holds `lock`. Revoked devices are `revoked`. A live unexpired credential on a live family is `active`.
    func nativeDeviceStatusLocked(_ device: StoredNotificationDevice, now: Date) -> String {
        if let revokedAt = device.revokedAt, revokedAt <= now { return "revoked" }
        let active = nativeNotificationCredentials.contains { credential in
            credential.deviceId == device.id
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == "notifications:stream"
                && !revokedFamilies.contains(credential.sessionFamilyId)
                && sessionFamilies[credential.sessionFamilyId]?.userId == device.userId
                && sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
        }
        return active ? "active" : "inactive"
    }

    func liveNativeCredentialLocked(userId: String) -> Bool {
        let now = Date()
        return nativeNotificationCredentials.contains { credential in
            credential.userId == userId
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == "notifications:stream"
                && !revokedFamilies.contains(credential.sessionFamilyId)
                && sessionFamilies[credential.sessionFamilyId]?.userId == userId
                && sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
                && nativeNotificationDevices.contains { $0.id == credential.deviceId && $0.revokedAt == nil }
        }
    }


    /// `GET /api/notifications/stream`. The kill switch answers before any stream is opened.
    public func nativeNotificationStream() -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
    }

    public func nativeNotificationEventCount(eventKey: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return nativeNotificationEvents.filter { $0.eventKey == eventKey }.count
    }

    public func nativeNotificationEventIDs(recipientUserId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return nativeNotificationEvents.filter { $0.recipientUserId == recipientUserId }.map(\.eventId)
    }

    /// Disabled notifications persist nothing. An empty batch also persists nothing.
    /// A recipient without a live native credential does not grow the ledger. The same event key is stored once.
    public func persistNativeNotificationIntents(_ intents: [NativeNotificationIntent]) -> Int {
        if !nativeNotificationsEnabled || intents.isEmpty { return 0 }
        lock.lock()
        defer { lock.unlock() }
        var inserted = 0
        var seen = Set(nativeNotificationEvents.map(\.eventKey))
        for intent in intents {
            guard liveNativeCredentialLocked(userId: intent.recipientUserId), !seen.contains(intent.eventKey) else { continue }
            seen.insert(intent.eventKey)
            nextNativeNotificationSeq += 1
            let now = Date()
            nativeNotificationEvents.append(StoredNativeNotificationEvent(
                eventId: UUID().uuidString.lowercased(),
                streamSeq: nextNativeNotificationSeq,
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

    /// Signed token for `GET/POST /api/email/mobile-app/unsubscribe`. A missing locale is `en`.
    public func createMobileAppEmailUnsubscribeToken(userId: String, locale: String? = nil) -> String {
        let canonical = Self.mobileAppUnsubscribeLocale(locale)
        let claims = "{\"v\":1,\"typ\":\"mobile-app-email-unsubscribe\",\"sub\":\(jsonString(userId)),\"locale\":\(jsonString(canonical))}"
        let payload = Self.base64url(Data(claims.utf8))
        let signature = Self.mobileAppUnsubscribeSignature(payload: payload, secret: mobileAppEmailUnsubscribeSecret)
        return "\(payload).\(signature)"
    }

    /// A scheduled mobile-app lifecycle email. Unsubscribe cancels `day1Status` of `scheduled`.
    public func addMobileAppEmailJourney(userId: String, email: String, journeyKey: String, day1Status: String, day1EmailId: String?) {
        lock.lock()
        storedMobileAppEmailJourneys.append(MobileAppEmailJourney(
            userId: userId,
            email: Self.normalize(email),
            journeyKey: journeyKey,
            day1Status: day1Status,
            day1EmailId: day1EmailId,
            suppressedReason: nil,
            canceledAt: nil
        ))
        lock.unlock()
    }

    public func mobileAppEmailJourneys() -> [MobileAppEmailJourney] {
        lock.lock()
        defer { lock.unlock() }
        return storedMobileAppEmailJourneys
    }

    /// Local opt-outs for the mobile-app lifecycle audience. The human page does not write one.
    public func mobileAppEmailContacts() -> [MobileAppEmailContact] {
        lock.lock()
        defer { lock.unlock() }
        return mobileAppEmailContactsByKey.values.sorted { $0.email < $1.email }
    }

    public func setAccountProfileForTesting(id: String, name: String, displayName: String? = nil) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == id })?.key, var account = accounts[key] {
            account.name = name
            account.displayName = displayName ?? name
            accounts[key] = account
        }
        lock.unlock()
    }

    public func addAccount(id: String, email: String, password: String, avatarUrl: String? = nil, passwordCredentialEstablished: Bool = true) {
        let normalized = Self.normalize(email)
        lock.lock()
        accounts[normalized] = Account(
            id: id,
            email: normalized,
            passwordHash: Self.sha256(password),
            passwordCredentialEstablishedAt: passwordCredentialEstablished ? Date() : nil,
            displayLanguage: nil,
            name: String(normalized.split(separator: "@").first ?? "user"),
            profileSetupSuggestedHandle: nil,
            profileSetupProvider: nil,
            profileSetupCompletedAt: Date(),
            avatarUrl: avatarUrl
        )
        analyticsIds[id] = UUID().uuidString.lowercased()
        lock.unlock()
    }

    /// The product-analytics id for this user. Opting out removes it. Opting back in mints a new one.
    public func analyticsId(userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return analyticsIds[userId]
    }

    public func socialCompletionUserIdForTesting(provider: String, code: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        guard let completion = socialCompletions.first(where: { $0.provider == provider && $0.code == code }) else {
            return nil
        }
        return .some(completion.userId)
    }

    /// `409` when the target Computer cannot answer for its Built-in catalog.
    func builtinCatalogFailureReply() -> HTTPReply {
        Self.json(409, "{\"code\":\"builtin_catalog_unavailable\",\"error\":\"The target Computer's Built-in model catalog is unavailable. Retry after the Computer reconnects.\"}")
    }

    /// Built-in model admission check. Anything but a Built-in runtime is not ours to judge.
    func builtinModelCheck(machineId: String?, config: [String: Any]) -> BuiltinModelCatalogResult? {
        guard let machineId,
              (config["runtime"] as? String) == "builtin",
              let model = config["model"] as? [String: Any],
              let modelId = model["id"] as? String,
              let check = builtinModelCatalogCheck
        else { return nil }
        return check(machineId, modelId)
    }

    public func setAgentAttachmentPresignForTesting(_ handler: (@Sendable (String, Int, String, String) throws -> String)?) {
        lock.lock()
        agentAttachmentPresign = handler
        lock.unlock()
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
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
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
        agentAttachmentBytes[id] = bytes
        lock.unlock()
    }


    static let agentAttachmentUnavailableMessage = "Attachment is unavailable."
    static let agentAttachmentUnavailableNextAction = "If this value came from a feedback report, do not use its artifactId here. Use the reportId with the Raft Feedback Admin integration instead: run `raft integration invoke --service \"Raft Feedback Admin\" --action download_feedback_transcript --param id=REPORT_ID --output PATH`."

    func agentAttachmentUnavailableReply() -> HTTPReply {
        let error = Self.agentAttachmentUnavailableMessage + " " + Self.agentAttachmentUnavailableNextAction
        return Self.json(404, "{\"error\":\(jsonString(error)),\"code\":\"ATTACHMENT_UNAVAILABLE\",\"suggestedNextAction\":\(jsonString(Self.agentAttachmentUnavailableNextAction))}")
    }

    func agentAttachmentUnavailableURLReply() -> HTTPReply {
        Self.json(409, "{\"error\":\"This Server's file storage cannot mint download URLs.\",\"code\":\"download_url_unavailable\",\"suggestedNextAction\":\"Download the attachment bytes instead: GET /internal/agent-api/attachments/:attachmentId (`raft attachment view --id <attachmentId> --output <path>`).\"}")
    }

    func agentVisibleAttachment(agentId: String, serverId: String, attachmentId: String) -> ChannelAttachment? {
        lock.lock()
        defer { lock.unlock() }
        guard let attachment = channelAttachments[attachmentId],
              let channel = postableChannels[attachment.channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return nil }
        let visible = channel.kind == "channel"
            || channel.memberIds.contains(agentId)
            || oauth.channelAgentIds(channelId: attachment.channelId).contains(agentId)
        return visible ? attachment : nil
    }

    func agentAttachmentIdentity(authorization: String?) -> (agentId: String, serverId: String)? {
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused: return nil
        case .success(let agentId, let serverId): return (agentId, serverId)
        }
    }

    public func agentAttachmentDownload(authorization: String?, attachmentId: String) -> HTTPReply {
        guard let identity = agentAttachmentIdentity(authorization: authorization) else {
            switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
            case .refused(let reply): return reply
            case .success: return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
            }
        }
        guard let attachment = agentVisibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            return agentAttachmentUnavailableReply()
        }
        lock.lock()
        let bytes = agentAttachmentBytes[attachmentId] ?? Data()
        lock.unlock()
        var reply = HTTPReply(
            status: 200,
            headers: [
                "Content-Type": attachment.mimeType ?? "application/octet-stream",
                "Content-Length": String(bytes.count),
            ],
            body: String(decoding: bytes, as: UTF8.self)
        )
        reply.headers["Cache-Control"] = "private, no-store"
        reply.headers["Content-Disposition"] = "attachment; filename=\"\(attachment.filename)\"; filename*=UTF-8''\(Self.rfc5987Encode(attachment.filename))"
        return reply
    }

    public func agentAttachmentDownloadURL(authorization: String?, attachmentId: String) -> HTTPReply {
        guard let identity = agentAttachmentIdentity(authorization: authorization) else {
            switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
            case .refused(let reply): return reply
            case .success: return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
            }
        }
        guard let attachment = agentVisibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            return agentAttachmentUnavailableReply()
        }
        lock.lock()
        let presign = agentAttachmentPresign
        lock.unlock()
        guard let presign else {
            return agentAttachmentUnavailableURLReply()
        }
        let ext = (attachment.filename as NSString).pathExtension
        let storageKey = attachment.storageKey ?? (ext.isEmpty ? "\(identity.serverId)/\(attachmentId)" : "\(identity.serverId)/\(attachmentId).\(ext)")
        let filename = attachment.filename
        let mimeType = attachment.mimeType ?? "application/octet-stream"
        let disposition = "attachment; filename=\"\(filename)\"; filename*=UTF-8''\(Self.rfc5987Encode(filename))"
        let url: String
        do {
            url = try presign(storageKey, 300, disposition, mimeType)
        } catch {
            return Self.json(500, "{\"error\":\"Failed to mint a download URL\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: Date().addingTimeInterval(300))
        var reply = Self.json(200, "{\"url\":\(jsonString(url)),\"expiresAt\":\(jsonString(expiresAt)),\"filename\":\(jsonString(filename)),\"mimeType\":\(jsonString(mimeType))}")
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func setAgentAudienceStatusForTesting(agentId: String, status: String) {
        lock.lock()
        agentAudienceStatusOverrides[agentId] = status
        lock.unlock()
    }
    public func revokeAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        lock.lock()
        agentIntegrationGrants["\(agentId)\n\(clientKey)"] = true
        lock.unlock()
    }

    public func restoreAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        lock.lock()
        agentIntegrationGrants["\(agentId)\n\(clientKey)"] = false
        lock.unlock()
    }

    public func revokeAgentCredentialForTesting(apiKey: String) {
        lock.lock()
        agentCredentials[apiKey]?.revokedAt = Date()
        lock.unlock()
    }

    public func agentIntegrationToken(authorization: String?, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil,
              credential.scopes.contains("read"),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid integration token request\",\"code\":\"INVALID_REQUEST\"}")
        }
        for field in ["agentId", "serverId", "audience", "issuer", "expires_in", "scopes", "claims"]
        where object[field] != nil {
            return Self.json(400, "{\"error\":\"Request fields are derived from the credential\",\"code\":\"INVALID_REQUEST\"}")
        }
        guard let service = (object["service"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !service.isEmpty
        else {
            return Self.json(400, "{\"error\":\"service is required\",\"code\":\"INVALID_REQUEST\"}")
        }
        lock.lock()
        let status = agentAudienceStatusOverrides[agent.id] ?? "active"
        lock.unlock()
        guard status == "active" else {
            return Self.json(403, "{\"error\":\"Agent is not active\",\"code\":\"AGENT_INACTIVE\"}")
        }
        guard oauth.agentRole(serverId: agent.serverId, agentId: agent.id) != nil else {
            return Self.json(403, "{\"error\":\"Agent is not a member of this Server\",\"code\":\"AGENT_NOT_MEMBER\"}")
        }
        guard let client = oauth.localClientForAgentAudience(clientId: service, serverId: agent.serverId),
              client.enabled,
              client.allowedScopes.contains("openid"),
              client.allowedScopes.contains("profile")
        else {
            return Self.json(403, "{\"error\":\"That App is not available on this Server\",\"code\":\"APP_UNAVAILABLE\"}")
        }
        let grantKey = "\(agent.id)\n\(client.clientId)"
        lock.lock()
        let revoked = agentIntegrationGrants[grantKey] == true
        if !revoked {
            agentIntegrationGrants[grantKey] = false
        }
        lock.unlock()
        guard !revoked else {
            return Self.json(403, "{\"error\":\"Agent access to this App has been revoked\",\"code\":\"GRANT_REVOKED\"}")
        }
        guard let slug = oauth.serverProfile(id: agent.serverId)?.slug,
              let origin = OAuthDiscovery.issuerOrigin(serverURL),
              let signed = oauth.signAgentAudienceToken(
                  agentId: agent.id,
                  agentName: agent.name,
                  clientKey: client.clientId,
                  serverId: agent.serverId,
                  serverSlug: slug,
                  issuer: "\(origin)/oidc/\(slug)"
              )
        else {
            return Self.json(500, "{\"error\":\"Failed to issue the App token\"}")
        }
        var reply = Self.json(200, "{\"access_token\":\(jsonString(signed.token)),\"audience\":\(jsonString(client.clientId)),\"expires_in\":300}")
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }
}
