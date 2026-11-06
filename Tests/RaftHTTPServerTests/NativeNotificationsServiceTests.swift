import Crypto
import Foundation
import Testing
@testable import RaftHTTP

/// The native notification service's own contracts: the exact published bytes of
/// every body, error and frame, and one concurrency test per atomic store
/// section (grant exchange, credential rotation, device revocation, event
/// persistence, integration-grant claim). The HTTP tests lock the wire
/// projection.

private func base64url(_ data: Data) -> String {
    EmailLoginDirectory.base64url(data)
}

private func lenient(_ json: String) throws -> LenientJSONObjectRequest {
    try JSONDecoder().decode(LenientJSONObjectRequest.self, from: Data(json.utf8))
}

private struct Fixture {
    let directory: EmailLoginDirectory
    let service: NativeNotificationsService
    let userId: String
    let token: String
    let key: Curve25519.Signing.PrivateKey

    var authorization: String { "Bearer \(token)" }

    init() {
        let directory = EmailLoginDirectory()
        directory.nativeNotificationsEnabled = true
        let userId = UUID().uuidString.lowercased()
        directory.addAccount(id: userId, email: "native-\(userId)@slock.test", password: "password123")
        directory.markEmailVerified(userId: userId)
        let token = "access-\(UUID().uuidString.lowercased())"
        let family = "family-\(userId)"
        directory.accessTokens[token] = userId
        directory.accessTokenFamilies[token] = family
        directory.sessionFamilies[family] = SessionFamily(
            userId: userId, revokedAt: nil, revokedReason: nil, revokeCapabilityNonce: nil, capabilityRetainUntil: nil
        )
        self.directory = directory
        self.service = directory.nativeNotifications
        self.userId = userId
        self.token = token
        self.key = Curve25519.Signing.PrivateKey()
    }

    private var spki: String {
        let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
        return base64url(prefix + key.publicKey.rawRepresentation)
    }

    /// Issues a grant and exchanges it for a credential.
    func enroll() throws -> NativeCredentialIssued {
        let nonce = base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let instance = UUID().uuidString.lowercased()
        let request = try lenient("{\"appId\":\"ai.slock.desktop\",\"protocolVersion\":1,\"appVersion\":\"1.0.0\",\"releaseChannel\":\"staging\",\"appInstanceId\":\"\(instance)\",\"publicKey\":\"\(spki)\",\"nonce\":\"\(nonce)\"}")
        let issued = try service.issueEnrollmentGrant(authorization: authorization, body: request)
        let transcript = NativeNotificationCredentials.enrollmentProofTranscript(
            grant: issued.grant, appId: "ai.slock.desktop", protocolVersion: 1, appVersion: "1.0.0",
            releaseChannel: "staging", appInstanceId: instance, publicKey: spki, nonce: nonce
        )
        let proof = base64url(try key.signature(for: transcript))
        return try service.exchangeEnrollmentGrant(body: lenient("{\"grant\":\"\(issued.grant)\",\"proof\":\"\(proof)\"}"))
    }

    func rotationBody(_ credential: NativeCredentialIssued) throws -> LenientJSONObjectRequest {
        let transcript = NativeNotificationCredentials.rotationProofTranscript(
            credential: credential.credential, deviceId: credential.deviceId
        )
        return try lenient("{\"proof\":\"\(base64url(try key.signature(for: transcript)))\"}")
    }
}

// MARK: - Published bytes

@Test func nativeNotificationBodiesKeepTheirPublishedMemberOrder() {
    #expect(NativeEnrollmentGrantIssued(grant: "g", expiresAt: "e").jsonBody.render()
        == "{\"grant\":\"g\",\"expiresAt\":\"e\"}")
    #expect(NativeCredentialIssued(credential: "c", credentialId: "i", deviceId: "d", scope: "notifications:stream", expiresAt: "e").jsonBody.render()
        == "{\"credential\":\"c\",\"credentialId\":\"i\",\"deviceId\":\"d\",\"scope\":\"notifications:stream\",\"expiresAt\":\"e\"}")
    #expect(NativeNotificationDeviceList(devices: []).jsonBody.render() == "{\"devices\":[]}")
    #expect(NativeNotificationDeviceList(devices: [
        .init(deviceId: "d", appId: "a", appVersion: "v", releaseChannel: "staging", appInstanceId: "x", status: "active"),
    ]).jsonBody.render()
        == "{\"devices\":[{\"deviceId\":\"d\",\"appId\":\"a\",\"appVersion\":\"v\",\"releaseChannel\":\"staging\",\"appInstanceId\":\"x\",\"attestationState\":\"missing\",\"status\":\"active\"}]}")
    #expect(AgentAttachmentDownloadURL(url: "u", expiresAt: "e", filename: "f", mimeType: "m").jsonBody.render()
        == "{\"url\":\"u\",\"expiresAt\":\"e\",\"filename\":\"f\",\"mimeType\":\"m\"}")
    #expect(AgentIntegrationTokenIssued(accessToken: "t", audience: "c").jsonBody.render()
        == "{\"access_token\":\"t\",\"audience\":\"c\",\"expires_in\":300}")
}

@Test func nativeNotificationErrorsKeepTheirPublishedBytes() {
    let cases: [(NativeNotificationsError, UInt, String)] = [
        (.notFound, 404, "{\"error\":\"Not found\",\"code\":\"not_found\"}"),
        (.sessionFamilyRequired, 401, "{\"error\":\"A live normal session family is required\",\"code\":\"session_family_required\"}"),
        (.authRequired, 401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}"),
        (.invalidEnrollmentRequest, 400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_request\"}"),
        (.desktopAttestationRequired, 403, "{\"error\":\"Desktop application attestation is required\",\"code\":\"desktop_attestation_required\"}"),
        (.invalidEnrollmentExchange, 400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_exchange\"}"),
        (.enrollmentExchangeDenied, 403, "{\"error\":\"Enrollment exchange denied\",\"code\":\"enrollment_exchange_denied\"}"),
        (.deviceNotFound, 404, "{\"error\":\"Notification device not found\",\"code\":\"notification_device_not_found\"}"),
        (.credentialInvalid, 401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}"),
        (.credentialProofInvalid, 403, "{\"error\":\"Invalid native notification credential proof\",\"code\":\"native_credential_proof_invalid\"}"),
        (.replayCursorUnavailable, 409, "{\"error\":\"Replay cursor is unavailable\",\"code\":\"replay_cursor_unavailable\"}"),
        (.replayWindowExceeded, 409, "{\"error\":\"Replay window exceeded\",\"code\":\"replay_window_exceeded\"}"),
    ]
    for (error, status, body) in cases {
        #expect(error.status == status)
        #expect(error.publishedErrorBody.render() == body)
    }
    #expect(AgentAttachmentsError.mintFailed.publishedErrorBody.render() == "{\"error\":\"Failed to mint a download URL\"}")
    #expect(AgentAttachmentsError.downloadURLUnavailable.publishedErrorBody.render()
        == "{\"error\":\"This Server's file storage cannot mint download URLs.\",\"code\":\"download_url_unavailable\",\"suggestedNextAction\":\"Download the attachment bytes instead: GET /internal/agent-api/attachments/:attachmentId (`raft attachment view --id <attachmentId> --output <path>`).\"}")
    let unavailable = AgentAttachmentsError.unavailable.publishedErrorBody.render()
    #expect(unavailable.hasPrefix("{\"error\":\"Attachment is unavailable. If this value came from a feedback report"))
    #expect(unavailable.contains("\",\"code\":\"ATTACHMENT_UNAVAILABLE\",\"suggestedNextAction\":\"If this value"))
    #expect(AgentIntegrationTokenError.issueFailed.publishedErrorBody.render() == "{\"error\":\"Failed to issue the App token\"}")
    #expect(AgentIntegrationTokenError.grantRevoked.publishedErrorBody.render()
        == "{\"error\":\"Agent access to this App has been revoked\",\"code\":\"GRANT_REVOKED\"}")
}

@Test func streamFramesPrintTheirDataMembersAlphabetically() {
    let event = StoredNativeNotificationEvent(
        eventId: "e1", streamSeq: 1, recipientUserId: "u", eventKey: "k", serverId: "s", channelId: "c",
        messageId: "m", title: "T \"q\"", body: "B\n", targetUri: "raft://v1/x",
        createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 9)
    )
    #expect(NativeNotificationsService.frame(event)
        == "event: native-notification.v1\nid: e1\ndata: {\"body\":\"B\\n\",\"createdAt\":\"1970-01-01T00:00:00.000Z\",\"eventId\":\"e1\",\"serverId\":\"s\",\"targetUri\":\"raft://v1/x\",\"title\":\"T \\\"q\\\"\",\"version\":1}\n\n")
}

// MARK: - Service behavior

@Test func killSwitchAnswersBeforeAnyOtherCheck() throws {
    let fixture = Fixture()
    fixture.directory.nativeNotificationsEnabled = false
    #expect(throws: NativeNotificationsError.notFound) { try fixture.service.listDevices(authorization: nil) }
    #expect(throws: NativeNotificationsError.notFound) { try fixture.service.deleteCurrentCredential(authorization: nil) }
    #expect(throws: NativeNotificationsError.notFound) { try fixture.service.beginStream(authorization: nil, lastEventId: nil) }
    #expect(fixture.service.persist([]) == 0)
}

@Test func enrollmentLifecycleListsRotatesAndRevokes() throws {
    let fixture = Fixture()
    let first = try fixture.enroll()
    #expect(first.scope == "notifications:stream")
    let listed = try fixture.service.listDevices(authorization: fixture.authorization)
    #expect(listed.devices.map(\.status) == ["active"])
    #expect(listed.devices.first?.deviceId == first.deviceId)

    let rotated = try fixture.service.rotateCredential(
        authorization: "Bearer \(first.credential)", body: try fixture.rotationBody(first)
    )
    #expect(rotated.deviceId == first.deviceId)
    #expect(rotated.credentialId != first.credentialId)
    #expect(throws: NativeNotificationsError.credentialInvalid) {
        try fixture.service.rotateCredential(authorization: "Bearer \(first.credential)", body: try fixture.rotationBody(first))
    }
    #expect(throws: NativeNotificationsError.credentialProofInvalid) {
        try fixture.service.rotateCredential(authorization: "Bearer \(rotated.credential)", body: try lenient("{}"))
    }
    #expect(fixture.service.isCredentialLive(authorization: "Bearer \(rotated.credential)"))
    #expect(!fixture.service.isCredentialLive(authorization: "Bearer \(first.credential)"))

    _ = try fixture.service.revokeDevice(authorization: fixture.authorization, deviceId: first.deviceId)
    #expect(try fixture.service.listDevices(authorization: fixture.authorization).devices.map(\.status) == ["revoked"])
    #expect(!fixture.service.isCredentialLive(authorization: "Bearer \(rotated.credential)"))
    #expect(throws: NativeNotificationsError.deviceNotFound) {
        try fixture.service.revokeDevice(authorization: fixture.authorization, deviceId: first.deviceId)
    }
}

@Test func enrollmentGrantRefusesWithoutASessionAndOnABadRequestInTheLegacyOrder() throws {
    let fixture = Fixture()
    #expect(throws: NativeNotificationsError.sessionFamilyRequired) {
        try fixture.service.issueEnrollmentGrant(authorization: nil, body: nil)
    }
    #expect(throws: NativeNotificationsError.invalidEnrollmentRequest) {
        try fixture.service.issueEnrollmentGrant(authorization: fixture.authorization, body: nil)
    }
    // A boolean `true` and a number truncating to 1 read as protocol version 1.
    let nonce = base64url(Data(repeating: 7, count: 32))
    let key = base64url(Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]) + Data(repeating: 9, count: 32))
    for version in ["true", "1.5", "1"] {
        let body = try lenient("{\"appId\":\"ai.slock.desktop\",\"protocolVersion\":\(version),\"appVersion\":\"1\",\"releaseChannel\":\"staging\",\"appInstanceId\":\"\(UUID().uuidString.lowercased())\",\"publicKey\":\"\(key)\",\"nonce\":\"\(nonce)\"}")
        _ = try fixture.service.issueEnrollmentGrant(authorization: fixture.authorization, body: body)
    }
    let bad = try lenient("{\"appId\":\"ai.slock.desktop\",\"protocolVersion\":\"1\"}")
    #expect(throws: NativeNotificationsError.invalidEnrollmentRequest) {
        try fixture.service.issueEnrollmentGrant(authorization: fixture.authorization, body: bad)
    }
}

// MARK: - One concurrency test per atomic section

private func successes(_ count: Int, _ work: @escaping @Sendable () -> Bool) async -> Int {
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<count { group.addTask { work() } }
        var total = 0
        for await ok in group where ok { total += 1 }
        return total
    }
}

@Test func concurrentExchangesOfOneGrantMintExactlyOneCredential() async throws {
    let fixture = Fixture()
    let nonce = base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    let instance = UUID().uuidString.lowercased()
    let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    let spki = base64url(prefix + fixture.key.publicKey.rawRepresentation)
    let issued = try fixture.service.issueEnrollmentGrant(
        authorization: fixture.authorization,
        body: try lenient("{\"appId\":\"ai.slock.desktop\",\"protocolVersion\":1,\"appVersion\":\"1.0.0\",\"releaseChannel\":\"staging\",\"appInstanceId\":\"\(instance)\",\"publicKey\":\"\(spki)\",\"nonce\":\"\(nonce)\"}")
    )
    let transcript = NativeNotificationCredentials.enrollmentProofTranscript(
        grant: issued.grant, appId: "ai.slock.desktop", protocolVersion: 1, appVersion: "1.0.0",
        releaseChannel: "staging", appInstanceId: instance, publicKey: spki, nonce: nonce
    )
    let body = try lenient("{\"grant\":\"\(issued.grant)\",\"proof\":\"\(base64url(try fixture.key.signature(for: transcript)))\"}")
    let service = fixture.service
    let won = await successes(32) { (try? service.exchangeEnrollmentGrant(body: body)) != nil }
    #expect(won == 1)
    let rows = fixture.directory.notificationsStore.native.snapshot()
    #expect(rows.devices.count == 1)
    #expect(rows.credentials.count == 1)
    #expect(rows.grants.first?.consumedAt != nil)
}

@Test func concurrentRotationsOfOneCredentialLeaveExactlyOneLiveSuccessor() async throws {
    let fixture = Fixture()
    let first = try fixture.enroll()
    let body = try fixture.rotationBody(first)
    let service = fixture.service
    let bearer = "Bearer \(first.credential)"
    let won = await successes(32) { (try? service.rotateCredential(authorization: bearer, body: body)) != nil }
    #expect(won == 1)
    let credentials = fixture.directory.notificationsStore.native.snapshot().credentials
    #expect(credentials.count == 2)
    #expect(credentials.filter { $0.revokedAt == nil }.count == 1)
}

@Test func concurrentDeviceRevocationsRevokeOnce() async throws {
    let fixture = Fixture()
    let first = try fixture.enroll()
    let service = fixture.service
    let authorization = fixture.authorization
    let won = await successes(24) {
        (try? service.revokeDevice(authorization: authorization, deviceId: first.deviceId)) != nil
    }
    #expect(won == 1)
    let rows = fixture.directory.notificationsStore.native.snapshot()
    #expect(rows.devices.first?.revokedAt != nil)
    #expect(rows.credentials.allSatisfy { $0.revokedAt != nil })
}

@Test func concurrentPersistStoresOneEventPerKeyAndAssignsDenseSequences() async throws {
    let fixture = Fixture()
    _ = try fixture.enroll()
    func intent(_ key: String) -> NativeNotificationIntent {
        NativeNotificationIntent(
            recipientUserId: fixture.userId, eventKey: key, serverId: "s", kind: "channel", channelId: "c",
            threadId: nil, parentChannelId: nil, parentMessageId: nil, messageId: "m", title: "t", body: "b",
            createdAt: Date()
        )
    }
    let service = fixture.service
    let sameKey = intent("same")
    let sameTotal = await withTaskGroup(of: Int.self) { group -> Int in
        for _ in 0..<32 { group.addTask { service.persist([sameKey]) } }
        return await group.reduce(0, +)
    }
    #expect(sameTotal == 1)
    let distinctTotal = await withTaskGroup(of: Int.self) { group -> Int in
        for index in 0..<32 { group.addTask { service.persist([intent("key-\(index)")]) } }
        return await group.reduce(0, +)
    }
    #expect(distinctTotal == 32)
    let events = fixture.directory.notificationsStore.native.snapshot().events
    #expect(events.count == 33)
    #expect(Set(events.map(\.streamSeq)) == Set(1...33))
}

@Test func concurrentIntegrationGrantClaimsAreAllowedUntilRevoked() async {
    let store = ManagedMCPAndCardsStore()
    let admitted = await successes(32) { store.claimAgentIntegrationGrant(key: "agent\nclient") }
    #expect(admitted == 32)
    #expect(store.agentIntegrationGrants["agent\nclient"] == false)
    store.agentIntegrationGrants["agent\nclient"] = true
    let after = await successes(32) { store.claimAgentIntegrationGrant(key: "agent\nclient") }
    #expect(after == 0)
    #expect(store.agentIntegrationGrants["agent\nclient"] == true)
    #expect(store.agentAudienceStatus(agentId: "agent") == "active")
}
