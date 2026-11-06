import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func ed25519SPKI(_ raw: Data) -> String {
    let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    return base64url(prefix + raw)
}

private struct NativeBinding {
    var privateKey: Curve25519.Signing.PrivateKey
    var body: String
    var appId: String
    var protocolVersion: Int
    var appVersion: String
    var releaseChannel: String
    var appInstanceId: String
    var publicKey: String
    var nonce: String
}

private func makeNativeBinding() -> NativeBinding {
    let key = Curve25519.Signing.PrivateKey()
    let appId = "ai.slock.desktop"
    let appVersion = "1.0.0-test"
    let releaseChannel = "staging"
    let appInstanceId = UUID().uuidString.lowercased()
    let publicKey = ed25519SPKI(key.publicKey.rawRepresentation)
    let nonce = base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    let body = "{\"appId\":\"\(appId)\",\"protocolVersion\":1,\"appVersion\":\"\(appVersion)\",\"releaseChannel\":\"\(releaseChannel)\",\"appInstanceId\":\"\(appInstanceId)\",\"publicKey\":\"\(publicKey)\",\"nonce\":\"\(nonce)\"}"
    return NativeBinding(
        privateKey: key,
        body: body,
        appId: appId,
        protocolVersion: 1,
        appVersion: appVersion,
        releaseChannel: releaseChannel,
        appInstanceId: appInstanceId,
        publicKey: publicKey,
        nonce: nonce
    )
}

private func postJSON(_ client: any Client, path: String, body: String, authorization: String? = nil) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let authorization { headers[.authorization] = authorization }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func nativeNotificationKillSwitchClosesTheStreamAndPersistsNothing() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = false
    let inserted = accounts.nativeNotifications.persist([
        NativeNotificationIntent(
            recipientUserId: "11111111-1111-4111-8111-111111111184",
            eventKey: "disabled:native-kill",
            serverId: "33333333-3333-4333-8333-333333333382",
            kind: "channel",
            channelId: "22222222-2222-4222-8222-222222222305",
            threadId: nil,
            parentChannelId: nil,
            parentMessageId: nil,
            messageId: "44444444-4444-4444-8444-444444444401",
            title: "disabled",
            body: "disabled",
            createdAt: Date()
        ),
    ])
    #expect(inserted == 0)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let route = try await client.get("/api/notifications/stream")
            #expect(route.status == .notFound)
        }
    }
}

@Test func enrollmentIsKeyBoundShortLivedHashOnlyAndSingleUse() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = true
    let userId = "11111111-1111-4111-8111-111111111185"
    accounts.addAccount(id: userId, email: "native-enroll-185@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let native = makeNativeBinding()
    let wrong = makeNativeBinding()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-enroll-185@slock.test\",\"password\":\"password123\"}")
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let issuedAt = Date()
            let granted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: native.body, authorization: "Bearer \(token)")
            #expect(granted.status == .created)
            let grantedBody = try JSONSerialization.jsonObject(with: Data(bodyText(granted).utf8)) as? [String: Any]
            let grant = grantedBody?["grant"] as? String ?? ""
            let expiresAt = grantedBody?["expiresAt"] as? String ?? ""
            #expect(grant.wholeMatch(of: /^rng1\.[0-9a-f-]{36}\.[A-Za-z0-9_-]+$/) != nil)
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiry = parser.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt) ?? issuedAt
            #expect(expiry.timeIntervalSince(issuedAt) <= 60.5)
            let records = accounts.nativeEnrollmentGrantRecords()
            #expect(records.count == 1)
            #expect(records.first?.secretHash != grant)
            #expect(records.first?.json.contains(grant) == false)

            let transcript = NativeNotificationCredentials.enrollmentProofTranscript(
                grant: grant,
                appId: native.appId,
                protocolVersion: native.protocolVersion,
                appVersion: native.appVersion,
                releaseChannel: native.releaseChannel,
                appInstanceId: native.appInstanceId,
                publicKey: native.publicKey,
                nonce: native.nonce
            )
            let wrongProof = base64url(try wrong.privateKey.signature(for: transcript))
            let denied = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: "{\"grant\":\(jsonString(grant)),\"proof\":\(jsonString(wrongProof))}")
            #expect(denied.status == .forbidden)

            let proof = base64url(try native.privateKey.signature(for: transcript))
            let exchangeBody = "{\"grant\":\(jsonString(grant)),\"proof\":\(jsonString(proof))}"
            async let firstExchange = postJSON(client, path: "/api/notifications/enrollment-exchanges", body: exchangeBody)
            async let secondExchange = postJSON(client, path: "/api/notifications/enrollment-exchanges", body: exchangeBody)
            let concurrent = try await [firstExchange, secondExchange]
            #expect(concurrent.map(\.status).sorted { $0.code < $1.code }.map(\.code) == [201, 403])
            let exchanged = try #require(concurrent.first { $0.status == .created })
            let exchangedBody = try JSONSerialization.jsonObject(with: Data(bodyText(exchanged).utf8)) as? [String: Any]
            let credential = exchangedBody?["credential"] as? String ?? ""
            let credentialId = exchangedBody?["credentialId"] as? String ?? ""
            #expect(credential.wholeMatch(of: /^rnc1\.[0-9a-f-]{36}\.[A-Za-z0-9_-]+$/) != nil)
            #expect(exchangedBody?["scope"] as? String == "notifications:stream")

            let replay = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: exchangeBody)
            #expect(replay.status == .forbidden)
            let credentialJSON = accounts.nativeNotificationCredentialJSON(id: credentialId) ?? ""
            #expect(!credentialJSON.isEmpty)
            #expect(credentialJSON.contains(credential) == false)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            let listed = try await client.send(.get, headers: headers, to: "/api/notifications/devices")
            #expect(listed.status == .ok)
            let listedText = bodyText(listed)
            #expect(listedText.contains("secretHash") == false)
            #expect(listedText.contains("publicKey") == false)
            #expect(listedText.contains(credential) == false)
        }
    }
}

@Test func previewNoProofExpiredGrantAndDeadSessionFamilyFailClosed() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = true
    let userId = "11111111-1111-4111-8111-111111111186"
    accounts.addAccount(id: userId, email: "native-negative-186@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let native = makeNativeBinding()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-negative-186@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            let granted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: native.body, authorization: authorization)
            #expect(granted.status == .created)
            let grant = ((try JSONSerialization.jsonObject(with: Data(bodyText(granted).utf8)) as? [String: Any])?["grant"] as? String) ?? ""
            let noProof = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: "{\"grant\":\(jsonString(grant))}")
            #expect(noProof.status == .forbidden)

            let alteredNonce = base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            let alteredTranscript = NativeNotificationCredentials.enrollmentProofTranscript(
                grant: grant,
                appId: native.appId,
                protocolVersion: native.protocolVersion,
                appVersion: native.appVersion,
                releaseChannel: native.releaseChannel,
                appInstanceId: native.appInstanceId,
                publicKey: native.publicKey,
                nonce: alteredNonce
            )
            let alteredProof = base64url(try native.privateKey.signature(for: alteredTranscript))
            let altered = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: "{\"grant\":\(jsonString(grant)),\"proof\":\(jsonString(alteredProof))}")
            #expect(altered.status == .forbidden)

            let grantId = grant.split(separator: ".").dropFirst().first.map(String.init) ?? ""
            accounts.expireNativeEnrollmentGrant(id: grantId)
            let validTranscript = NativeNotificationCredentials.enrollmentProofTranscript(
                grant: grant,
                appId: native.appId,
                protocolVersion: native.protocolVersion,
                appVersion: native.appVersion,
                releaseChannel: native.releaseChannel,
                appInstanceId: native.appInstanceId,
                publicKey: native.publicKey,
                nonce: native.nonce
            )
            let validProof = base64url(try native.privateKey.signature(for: validTranscript))
            let exchangeBody = "{\"grant\":\(jsonString(grant)),\"proof\":\(jsonString(validProof))}"
            let expired = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: exchangeBody)
            #expect(expired.status == .forbidden)

            let secondGranted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: native.body, authorization: authorization)
            #expect(secondGranted.status == .created)
            let secondGrant = ((try JSONSerialization.jsonObject(with: Data(bodyText(secondGranted).utf8)) as? [String: Any])?["grant"] as? String) ?? ""
            let secondTranscript = NativeNotificationCredentials.enrollmentProofTranscript(
                grant: secondGrant,
                appId: native.appId,
                protocolVersion: native.protocolVersion,
                appVersion: native.appVersion,
                releaseChannel: native.releaseChannel,
                appInstanceId: native.appInstanceId,
                publicKey: native.publicKey,
                nonce: native.nonce
            )
            let secondProof = base64url(try native.privateKey.signature(for: secondTranscript))
            accounts.revokeSessionFamilies(userId: userId)
            let deadFamily = try await postJSON(
                client,
                path: "/api/notifications/enrollment-exchanges",
                body: "{\"grant\":\(jsonString(secondGrant)),\"proof\":\(jsonString(secondProof))}"
            )
            #expect(deadFamily.status == .forbidden)
        }
    }
}

@Test func enforcedAttestationFailsClosedUnlessTheSignedAppVerifierAcceptsTheEvidence() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = true
    accounts.nativeNotificationAttestationMode = "enforce"
    let userId = "11111111-1111-4111-8111-111111111187"
    accounts.addAccount(id: userId, email: "native-attestation-187@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let native = makeNativeBinding()
    let evidence = "bounded-signed-app-attestation-test-evidence"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-attestation-187@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            let missing = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: native.body, authorization: authorization)
            #expect(missing.status == .forbidden)

            accounts.nativeNotificationAttestationVerifier = { $0 == evidence }
            let attested = String(native.body.dropLast()) + ",\"attestation\":\(jsonString(evidence))}"
            let accepted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: attested, authorization: authorization)
            #expect(accepted.status == .created)
        }
    }
}

@Test func notificationStreamRejectsUserSessionsStartsAtLatestReplaysAndClosesOnLogout() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = true
    accounts.nativeNotificationStreamPollMs = 250
    let userId = "11111111-1111-4111-8111-111111111188"
    let foreignId = "11111111-1111-4111-8111-111111111189"
    let serverId = "33333333-3333-4333-8333-333333333383"
    let channelId = "22222222-2222-4222-8222-222222222306"
    accounts.addAccount(id: userId, email: "native-stream-188@slock.test", password: "password123")
    accounts.addAccount(id: foreignId, email: "native-foreign-189@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.markEmailVerified(userId: foreignId)
    let native = makeNativeBinding()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-stream-188@slock.test\",\"password\":\"password123\"}")
            let loginBody = try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any]
            let token = loginBody?["accessToken"] as? String ?? ""
            let refreshToken = loginBody?["refreshToken"] as? String ?? ""
            let authorization = "Bearer \(token)"
            let granted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: native.body, authorization: authorization)
            let grant = ((try JSONSerialization.jsonObject(with: Data(bodyText(granted).utf8)) as? [String: Any])?["grant"] as? String) ?? ""
            let transcript = NativeNotificationCredentials.enrollmentProofTranscript(
                grant: grant, appId: native.appId, protocolVersion: native.protocolVersion, appVersion: native.appVersion,
                releaseChannel: native.releaseChannel, appInstanceId: native.appInstanceId, publicKey: native.publicKey, nonce: native.nonce
            )
            let proof = base64url(try native.privateKey.signature(for: transcript))
            let exchanged = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: "{\"grant\":\(jsonString(grant)),\"proof\":\(jsonString(proof))}")
            #expect(exchanged.status == .created)
            let credential = ((try JSONSerialization.jsonObject(with: Data(bodyText(exchanged).utf8)) as? [String: Any])?["credential"] as? String) ?? ""

            var userHeaders = HTTPFields()
            userHeaders[.authorization] = authorization
            let sessionDenied = try await client.send(.get, headers: userHeaders, to: "/api/notifications/stream")
            #expect(sessionDenied.status == .unauthorized)
            #expect((sessionDenied.headers[.contentType] ?? "").contains("text/event-stream") == false)

            let beforeId = "44444444-4444-4444-8444-444444444410"
            let before = notificationIntent(userId: userId, serverId: serverId, channelId: channelId, messageId: beforeId, body: "before connect")
            _ = accounts.nativeNotifications.persist([before, before])
            #expect(accounts.nativeNotificationEventCount(eventKey: before.eventKey) == 1)

            var streamHeaders = HTTPFields()
            streamHeaders[.authorization] = "Bearer \(credential)"
            streamHeaders[.accept] = "text/event-stream"
            let stream = try await client.send(.get, headers: streamHeaders, to: "/api/notifications/stream")
            #expect(stream.status == .ok)
            #expect((stream.headers[.contentType] ?? "").contains("text/event-stream"))
            let buffer = SSEBuffer()
            let reader = Task {
                try await stream.body.withStreamingBytes { span in
                    buffer.append(utf8Chunk(span))
                }
            }
            let afterId = "44444444-4444-4444-8444-444444444411"
            _ = accounts.nativeNotifications.persist([
                notificationIntent(userId: userId, serverId: serverId, channelId: channelId, messageId: afterId, body: "after connect"),
            ])
            let firstText = await buffer.wait(until: { $0.contains("after connect") }, timeoutMs: 2_000)
            let firstEvents = parseSSE(firstText)
            #expect(firstEvents.count == 1)
            #expect(firstEvents.first?.data["body"] as? String == "after connect")
            #expect((firstEvents.first?.data["version"] as? NSNumber)?.intValue == 1 || (firstEvents.first?.data["version"] as? Int) == 1)
            #expect(firstEvents.first?.data.keys.sorted() == ["body", "createdAt", "eventId", "serverId", "targetUri", "title", "version"])
            let target = firstEvents.first?.data["targetUri"] as? String ?? ""
            #expect(target.wholeMatch(of: /^raft:\/\/v1\/servers\/[0-9a-f-]{36}\/channels\/[0-9a-f-]{36}\/messages\/[0-9a-f-]{36}$/) != nil)
            reader.cancel()

            _ = accounts.nativeNotifications.persist([
                notificationIntent(userId: userId, serverId: serverId, channelId: channelId, messageId: "44444444-4444-4444-8444-444444444412", body: "replay one"),
                notificationIntent(userId: userId, serverId: serverId, channelId: channelId, messageId: "44444444-4444-4444-8444-444444444413", body: "replay two"),
            ])
            var replayHeaders = streamHeaders
            replayHeaders[HTTPField.Name("Last-Event-ID")!] = firstEvents.first?.id ?? ""
            let replayStream = try await client.send(.get, headers: replayHeaders, to: "/api/notifications/stream")
            #expect(replayStream.status == .ok)
            let replayBuffer = SSEBuffer()
            let replayReader = Task {
                try await replayStream.body.withStreamingBytes { span in
                    replayBuffer.append(utf8Chunk(span))
                }
            }
            let replayText = await replayBuffer.wait(until: { parseSSE($0).count >= 2 }, timeoutMs: 2_000)
            let replay = parseSSE(replayText)
            #expect(replay.map { $0.data["body"] as? String } == ["replay one", "replay two"])
            #expect(Set(replay.map(\.id)).count == 2)
            replayReader.cancel()

            let dormant = notificationIntent(userId: foreignId, serverId: serverId, channelId: channelId, messageId: "44444444-4444-4444-8444-444444444414", body: "dormant foreign")
            #expect(accounts.nativeNotifications.persist([dormant]) == 0)
            let foreignLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-foreign-189@slock.test\",\"password\":\"password123\"}")
            let foreignToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(foreignLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let foreignNative = makeNativeBinding()
            let foreignGranted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: foreignNative.body, authorization: "Bearer \(foreignToken)")
            let foreignGrant = ((try JSONSerialization.jsonObject(with: Data(bodyText(foreignGranted).utf8)) as? [String: Any])?["grant"] as? String) ?? ""
            let foreignTranscript = NativeNotificationCredentials.enrollmentProofTranscript(
                grant: foreignGrant, appId: foreignNative.appId, protocolVersion: foreignNative.protocolVersion, appVersion: foreignNative.appVersion,
                releaseChannel: foreignNative.releaseChannel, appInstanceId: foreignNative.appInstanceId, publicKey: foreignNative.publicKey, nonce: foreignNative.nonce
            )
            let foreignProof = base64url(try foreignNative.privateKey.signature(for: foreignTranscript))
            let foreignExchanged = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: "{\"grant\":\(jsonString(foreignGrant)),\"proof\":\(jsonString(foreignProof))}")
            #expect(foreignExchanged.status == .created)
            _ = accounts.nativeNotifications.persist([
                notificationIntent(userId: foreignId, serverId: serverId, channelId: channelId, messageId: "44444444-4444-4444-8444-444444444415", body: "foreign"),
            ])
            let foreignEventId = accounts.nativeNotificationEventIDs(recipientUserId: foreignId).first ?? ""
            var foreignHeaders = streamHeaders
            foreignHeaders[HTTPField.Name("Last-Event-ID")!] = foreignEventId
            let foreignCursor = try await client.send(.get, headers: foreignHeaders, to: "/api/notifications/stream")
            #expect(foreignCursor.status == .conflict)
            #expect((foreignCursor.headers[.contentType] ?? "").contains("text/event-stream") == false)

            let live = try await client.send(.get, headers: streamHeaders, to: "/api/notifications/stream")
            #expect(live.status == .ok)
            let liveReader = Task {
                try await live.body.withStreamingBytes { _ in }
            }
            let logout = try await postJSON(client, path: "/api/auth/logout", body: "{\"refreshToken\":\(jsonString(refreshToken))}")
            #expect(logout.status == .ok)
            let closed = await waitForTask(liveReader, timeoutMs: 1_500)
            #expect(closed)
            let afterLogout = try await client.send(.get, headers: streamHeaders, to: "/api/notifications/stream")
            #expect(afterLogout.status == .unauthorized)
            #expect((afterLogout.headers[.contentType] ?? "").contains("text/event-stream") == false)
        }
    }
}

private func notificationIntent(userId: String, serverId: String, channelId: String, messageId: String, body: String) -> NativeNotificationIntent {
    NativeNotificationIntent(
        recipientUserId: userId,
        eventKey: "stream-test:\(messageId)",
        serverId: serverId,
        kind: "channel",
        channelId: channelId,
        threadId: nil,
        parentChannelId: nil,
        parentMessageId: nil,
        messageId: messageId,
        title: "Native title",
        body: body,
        createdAt: Date()
    )
}

private func utf8Chunk(_ span: Span<UInt8>) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(span.count)
    for index in span.indices {
        bytes.append(span[index])
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func parseSSE(_ text: String) -> [(id: String, data: [String: Any])] {
    text.components(separatedBy: "\n\n").compactMap { frame in
        guard frame.contains("event: native-notification.v1") else { return nil }
        let id = frame.split(separator: "\n").first { $0.hasPrefix("id: ") }.map { String($0.dropFirst(4)) } ?? ""
        let dataLine = frame.split(separator: "\n").first { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) } ?? "{}"
        let data = (try? JSONSerialization.jsonObject(with: Data(dataLine.utf8))) as? [String: Any] ?? [:]
        return (id, data)
    }
}

private final class SSEBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    func wait(until predicate: (String) -> Bool, timeoutMs: Int) async -> String {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            let snapshot = snapshot()
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return snapshot()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

private func waitForTask(_ task: Task<Void, Error>, timeoutMs: Int) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = try? await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

@Test func liveSSEReauthenticatesBeforeEveryFrameAndStopsARevokedBatch() async throws {
    for revocation in ["credential", "session-family"] {
        let accounts = EmailLoginDirectory()
        accounts.nativeNotificationsEnabled = true
        accounts.nativeNotificationStreamPollMs = 250
        let userId = revocation == "credential"
            ? "11111111-1111-4111-8111-111111111190"
            : "11111111-1111-4111-8111-111111111191"
        let serverId = revocation == "credential"
            ? "33333333-3333-4333-8333-333333333384"
            : "33333333-3333-4333-8333-333333333385"
        let channelId = revocation == "credential"
            ? "22222222-2222-4222-8222-222222222307"
            : "22222222-2222-4222-8222-222222222308"
        let firstMessage = revocation == "credential"
            ? "44444444-4444-4444-8444-444444444420"
            : "44444444-4444-4444-8444-444444444422"
        let secondMessage = revocation == "credential"
            ? "44444444-4444-4444-8444-444444444421"
            : "44444444-4444-4444-8444-444444444423"
        let email = "native-mid-batch-\(revocation)@slock.test"
        accounts.addAccount(id: userId, email: email, password: "password123")
        accounts.markEmailVerified(userId: userId)
        let native = makeNativeBinding()
        let calls = HookLog()
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts
            ))
            try await app.testing { client in
                let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                let loginBody = try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any]
                let token = loginBody?["accessToken"] as? String ?? ""
                let refreshToken = loginBody?["refreshToken"] as? String ?? ""
                let granted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: native.body, authorization: "Bearer \(token)")
                let grant = ((try JSONSerialization.jsonObject(with: Data(bodyText(granted).utf8)) as? [String: Any])?["grant"] as? String) ?? ""
                let transcript = NativeNotificationCredentials.enrollmentProofTranscript(
                    grant: grant, appId: native.appId, protocolVersion: native.protocolVersion, appVersion: native.appVersion,
                    releaseChannel: native.releaseChannel, appInstanceId: native.appInstanceId, publicKey: native.publicKey, nonce: native.nonce
                )
                let proof = base64url(try native.privateKey.signature(for: transcript))
                let exchanged = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: "{\"grant\":\(jsonString(grant)),\"proof\":\(jsonString(proof))}")
                let credential = ((try JSONSerialization.jsonObject(with: Data(bodyText(exchanged).utf8)) as? [String: Any])?["credential"] as? String) ?? ""
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(credential)"
                headers[.accept] = "text/event-stream"
                let stream = try await client.send(.get, headers: headers, to: "/api/notifications/stream")
                #expect(stream.status == .ok, "\(revocation) stream should open")
                accounts.nativeNotificationLiveWriteHook = { index, eventCount in
                    calls.add()
                    if eventCount != 2 || index != 1 { return }
                    if revocation == "credential" {
                        _ = accounts.nativeNotifications.revokeCredential(opaque: credential)
                    } else {
                        let logout = try? await postJSON(client, path: "/api/auth/logout", body: "{\"refreshToken\":\(jsonString(refreshToken))}")
                        if logout?.status != .ok { calls.noteLogoutFailed() }
                    }
                }
                let buffer = SSEBuffer()
                let reader = Task {
                    try await stream.body.withStreamingBytes { span in
                        buffer.append(utf8Chunk(span))
                    }
                }
                _ = accounts.nativeNotifications.persist([
                    notificationIntent(userId: userId, serverId: serverId, channelId: channelId, messageId: firstMessage, body: "first allowed"),
                    notificationIntent(userId: userId, serverId: serverId, channelId: channelId, messageId: secondMessage, body: "second revoked"),
                ])
                let closed = await waitForTask(reader, timeoutMs: 2_000)
                let bodies = parseSSE(buffer.snapshot()).map { $0.data["body"] as? String }
                #expect(closed, "\(revocation) revocation during an already-read batch must close the stream")
                #expect(bodies == ["first allowed"])
                #expect(calls.value() == 2, "the revocation seam must run between the first and second frame")
                #expect(calls.logoutFailed == false)
            }
        }
    }
}

private final class HookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var logoutFailed = false

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func noteLogoutFailed() {
        lock.lock()
        logoutFailed = true
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Test func credentialRotationIsKeyBoundAndExpiryOrRevokeInvalidatesCredentials() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = true
    let userId = "11111111-1111-4111-8111-111111111192"
    accounts.addAccount(id: userId, email: "native-rotate-192@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-rotate-192@slock.test\",\"password\":\"password123\"}")
            let loginBody = try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any]
            let token = loginBody?["accessToken"] as? String ?? ""
            let authorization = "Bearer \(token)"
            let enrolled = try await enrollNotificationDevice(client, accounts: accounts, bodyAuthorization: authorization)
            let transcript = NativeNotificationCredentials.rotationProofTranscript(credential: enrolled.credential, deviceId: enrolled.deviceId)
            let proof = base64url(try enrolled.privateKey.signature(for: transcript))
            var rotateHeaders = HTTPFields()
            rotateHeaders[.authorization] = "Bearer \(enrolled.credential)"
            rotateHeaders[.contentType] = "application/json"
            let rotated = try await client.send(.post, headers: rotateHeaders, to: "/api/notifications/credentials/rotate") { request in
                request.body = .init(string: "{\"proof\":\(jsonString(proof))}")
            }
            #expect(rotated.status == .created)
            let replacement = try JSONSerialization.jsonObject(with: Data(bodyText(rotated).utf8)) as? [String: Any]
            let replacementCredential = replacement?["credential"] as? String ?? ""
            let replacementId = replacement?["credentialId"] as? String ?? ""

            var oldHeaders = HTTPFields()
            oldHeaders[.authorization] = "Bearer \(enrolled.credential)"
            let oldDenied = try await client.send(.get, headers: oldHeaders, to: "/api/notifications/stream")
            #expect(oldDenied.status == .unauthorized)

            accounts.expireNativeNotificationCredential(id: replacementId)
            var expiredHeaders = HTTPFields()
            expiredHeaders[.authorization] = "Bearer \(replacementCredential)"
            let expiredDenied = try await client.send(.get, headers: expiredHeaders, to: "/api/notifications/stream")
            #expect(expiredDenied.status == .unauthorized)
            var sessionHeaders = HTTPFields()
            sessionHeaders[.authorization] = authorization
            let afterExpiry = try await client.send(.get, headers: sessionHeaders, to: "/api/notifications/devices")
            let expiryDevices = ((try JSONSerialization.jsonObject(with: Data(bodyText(afterExpiry).utf8)) as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
            #expect(expiryDevices.first { $0["deviceId"] as? String == enrolled.deviceId }?["status"] as? String == "inactive")

            let second = try await enrollNotificationDevice(client, accounts: accounts, bodyAuthorization: authorization)
            let revoke = try await client.send(.delete, headers: sessionHeaders, to: "/api/notifications/devices/\(second.deviceId)")
            #expect(revoke.status == .noContent)
            var secondHeaders = HTTPFields()
            secondHeaders[.authorization] = "Bearer \(second.credential)"
            let secondDenied = try await client.send(.get, headers: secondHeaders, to: "/api/notifications/stream")
            #expect(secondDenied.status == .unauthorized)
            #expect(accounts.nativeNotificationDeviceRevokedAt(id: second.deviceId) != nil)
            let afterRevoke = try await client.send(.get, headers: sessionHeaders, to: "/api/notifications/devices")
            let revokeDevices = ((try JSONSerialization.jsonObject(with: Data(bodyText(afterRevoke).utf8)) as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
            #expect(revokeDevices.first { $0["deviceId"] as? String == second.deviceId }?["status"] as? String == "revoked")

            let selfRevoked = try await enrollNotificationDevice(client, accounts: accounts, bodyAuthorization: authorization)
            var selfHeaders = HTTPFields()
            selfHeaders[.authorization] = "Bearer \(selfRevoked.credential)"
            let selfRevoke = try await client.send(.delete, headers: selfHeaders, to: "/api/notifications/credentials/current")
            #expect(selfRevoke.status == .noContent)
            let selfDenied = try await client.send(.get, headers: selfHeaders, to: "/api/notifications/stream")
            #expect(selfDenied.status == .unauthorized)
        }
    }
}

@Test func nativeNotificationErrorResponsesDoNotEchoSubmittedSecrets() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = true
    let userId = "11111111-1111-4111-8111-111111111193"
    accounts.addAccount(id: userId, email: "native-log-scrub-193@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-log-scrub-193@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let enrolled = try await enrollNotificationDevice(client, accounts: accounts, bodyAuthorization: "Bearer \(token)")
            var proofBytes = Data(count: 64)
            for index in proofBytes.indices { proofBytes[index] = UInt8.random(in: 0...255) }
            let proof = base64url(proofBytes)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(enrolled.credential)"
            headers[.contentType] = "application/json"
            let denied = try await client.send(.post, headers: headers, to: "/api/notifications/credentials/rotate") { request in
                request.body = .init(string: "{\"proof\":\(jsonString(proof))}")
            }
            #expect(denied.status == .forbidden)
            let text = bodyText(denied)
            let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "native_credential_proof_invalid")
            let secret = enrolled.credential.split(separator: ".").last.map(String.init) ?? ""
            let secretHash = AuthTokenCodec.sha256Hex(secret)
            for forbidden in [enrolled.grant, enrolled.credential, secretHash, proof, token] {
                #expect(text.contains(forbidden) == false)
            }
        }
    }
}

@Test func replayOverflowAndExpiredCursorsFailBeforeSSEHeaders() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeNotificationsEnabled = true
    let userId = "11111111-1111-4111-8111-111111111194"
    let serverId = "33333333-3333-4333-8333-333333333386"
    let channelId = "22222222-2222-4222-8222-222222222309"
    accounts.addAccount(id: userId, email: "native-overflow-194@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"native-overflow-194@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let enrolled = try await enrollNotificationDevice(client, accounts: accounts, bodyAuthorization: "Bearer \(token)")
            let intents = (0..<514).map { index in
                notificationIntent(
                    userId: userId,
                    serverId: serverId,
                    channelId: channelId,
                    messageId: UUID().uuidString.lowercased(),
                    body: "event \(index)"
                )
            }
            #expect(accounts.nativeNotifications.persist(intents) == 514)
            let ids = accounts.nativeNotificationEventIDs(recipientUserId: userId)
            #expect(ids.count == 514)
            let cursor = ids[0]
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(enrolled.credential)"
            headers[HTTPField.Name("Last-Event-ID")!] = cursor
            let overflow = try await client.send(.get, headers: headers, to: "/api/notifications/stream")
            #expect(overflow.status == .conflict)
            let overflowBody = try JSONSerialization.jsonObject(with: Data(bodyText(overflow).utf8)) as? [String: Any]
            #expect(overflowBody?["code"] as? String == "replay_window_exceeded")
            #expect((overflow.headers[.contentType] ?? "").contains("text/event-stream") == false)

            accounts.expireNativeNotificationEvent(id: cursor)
            let expired = try await client.send(.get, headers: headers, to: "/api/notifications/stream")
            #expect(expired.status == .conflict)
            let expiredBody = try JSONSerialization.jsonObject(with: Data(bodyText(expired).utf8)) as? [String: Any]
            #expect(expiredBody?["code"] as? String == "replay_cursor_unavailable")
            #expect((expired.headers[.contentType] ?? "").contains("text/event-stream") == false)
        }
    }
}

private struct EnrolledDevice {
    var credential: String
    var deviceId: String
    var grant: String
    var privateKey: Curve25519.Signing.PrivateKey
}

private func enrollNotificationDevice(_ client: any Client, accounts: EmailLoginDirectory, bodyAuthorization: String) async throws -> EnrolledDevice {
    let native = makeNativeBinding()
    let granted = try await postJSON(client, path: "/api/notifications/enrollment-grants", body: native.body, authorization: bodyAuthorization)
    let grant = ((try JSONSerialization.jsonObject(with: Data(bodyText(granted).utf8)) as? [String: Any])?["grant"] as? String) ?? ""
    let transcript = NativeNotificationCredentials.enrollmentProofTranscript(
        grant: grant, appId: native.appId, protocolVersion: native.protocolVersion, appVersion: native.appVersion,
        releaseChannel: native.releaseChannel, appInstanceId: native.appInstanceId, publicKey: native.publicKey, nonce: native.nonce
    )
    let proof = base64url(try native.privateKey.signature(for: transcript))
    let exchanged = try await postJSON(client, path: "/api/notifications/enrollment-exchanges", body: "{\"grant\":\(jsonString(grant)),\"proof\":\(jsonString(proof))}")
    let body = try JSONSerialization.jsonObject(with: Data(bodyText(exchanged).utf8)) as? [String: Any]
    return EnrolledDevice(
        credential: body?["credential"] as? String ?? "",
        deviceId: body?["deviceId"] as? String ?? "",
        grant: grant,
        privateKey: native.privateKey
    )
}

private func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let wrapped = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
    return String(wrapped.dropFirst().dropLast())
}
