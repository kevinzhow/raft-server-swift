import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import Synchronization
import TestSupport
import Testing
import Vapor
import VaporTesting

/// Tests first: the original published path returns 404 after a successful mint,
/// because no attachmentPreviewBody callback is installed in this fixture.
@Test func durableHTMLPreviewPublishedUploadMintAndReadUseEncryptedBytes() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let html = Data("<!doctype html><html><body>synthetic private report</body></html>".utf8)
        let boundary = "synthetic-preview-upload"
        var upload = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(setup.channelId)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"report.html\"\r\nContent-Type: text/html\r\n\r\n".utf8)
        upload.append(html)
        upload.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let uploadBody = upload
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, releaseEnvironment: ["APP_URL": "https://app.example.com"],
                corsOrigins: ["https://example.com:8443"], emailAccounts: setup.accounts))
            try await app.testing { client in
                var headers = HTTPFields()
                headers[.authorization] = setup.authorization
                headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
                headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                let uploaded = try await client.send(.post, headers: headers, to: "/api/attachments/upload") {
                    $0.body = .init(data: uploadBody)
                }
                #expect(uploaded.status == .ok)
                let object = try JSONSerialization.jsonObject(with: uploaded.body.data ?? Data()) as? [String: Any]
                let rows = try #require(object?["attachments"] as? [[String: Any]])
                let id = try #require(rows.first?["id"] as? String)
                let minted = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: headers)
                #expect(minted.status == .ok)
                let json = try JSONSerialization.jsonObject(with: minted.body.data ?? Data()) as? [String: Any]
                let path = try #require(json?["url"] as? String)
                let preview = try await client.get(URI(string: path))
                #expect(preview.status == .ok)
                var expected = html
                expected.append(Data(AttachmentPreviewBridge.script.utf8))
                #expect(try await attachmentPreviewBody(preview) == expected)
                #expect(preview.headers[.contentType] == "text/html; charset=utf-8")
                #expect(preview.headers[.contentLength] == nil)
                #expect(preview.headers[.cacheControl] == "private, no-store")
                #expect(preview.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
                #expect(preview.headers[HTTPField.Name("Referrer-Policy")!] == "no-referrer")
                #expect(preview.headers[HTTPField.Name("X-Frame-Options")!] == nil)
                #expect(preview.headers[.contentDisposition]?.hasPrefix("inline;") == true)
                let expectedPolicy = "default-src 'none'; sandbox allow-scripts; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; img-src data: blob: https:; font-src data: https:; media-src data: blob: https:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'; frame-ancestors 'self' https://example.com:8443 https://app.example.com app://raft"
                #expect(preview.headers[HTTPField.Name("Content-Security-Policy")!] == expectedPolicy)
                let download = try await client.get(URI(string: "/api/attachments/\(id)"), headers: headers)
                #expect(download.status == .ok)
                #expect(download.body.data == html)
                #expect(download.headers[.contentDisposition]?.hasPrefix("attachment;") == true)
                let ciphertext = fixture.state.value.withLock { Array($0.ciphertext.values) }
                #expect(ciphertext.count == 1)
                #expect(ciphertext.first != html)
                #expect(ciphertext.first?.count == html.count + 28)
                #expect(setup.accounts.messagesAndThreadsStore.attachmentPreviewBody == nil)
                #expect(setup.accounts.messagesAndThreadsStore.withState { $0.developmentAttachmentBytes[id] } == nil)
            }
        }
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}

@Test func durableHTMLPreviewRechecksActorAndProjectionAfterTokenMint() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        for mutation in ["membership", "private-channel", "retirement", "attachment", "message"] {
            let setup = AttachmentPreviewAccounts(storage: fixture.storage)
            let privateHTML = Data("<html>synthetic private</html>".utf8)
            let id = try await setup.upload(privateHTML)
            try await withApp { app in
                configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                    pingDatabase: {}, emailAccounts: setup.accounts))
                try await app.testing { client in
                    var headers = HTTPFields()
                    headers[.authorization] = setup.authorization
                    headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
                    let minted = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: headers)
                    #expect(minted.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: minted.body.data ?? Data()) as? [String: Any]
                    let path = try #require(json?["url"] as? String)
                    switch mutation {
                    case "membership": setup.accounts.oauth.removeMember(serverId: setup.serverId, userId: setup.userId)
                    case "private-channel":
                        setup.accounts.setChannelPostablePrivateForTesting(channelId: setup.channelId)
                        setup.accounts.oauth.setChannelType(id: setup.channelId, type: "private")
                        setup.accounts.oauth.removeChannelHuman(channelId: setup.channelId, userId: setup.userId)
                        setup.accounts.serversAndChannelsStore.removeMember(channelId: setup.channelId, memberId: setup.userId)
                    case "retirement": setup.accounts.retireUserForTesting(userId: setup.userId)
                    case "attachment": setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments.removeValue(forKey: id) }
                    default:
                        setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments[id]?.messageId = UUID().uuidString.lowercased() }
                    }
                    let refused = try await client.get(URI(string: path))
                    try await expectAttachmentPreviewRefusal(refused, notAMember: mutation == "membership", privateHTML: privateHTML)
                }
            }
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}

@Test(.timeLimit(.minutes(1))) func durableHTMLPreviewRechecksAuthorizationAndBindingAfterAwait() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        for mutation in ["membership", "private-channel", "retirement", "attachment", "reference", "reassignment"] {
            let gate = AttachmentPreviewReadGate(fixture.storage)
            let setup = AttachmentPreviewAccounts(storage: gate)
            let privateHTML = Data("<html>synthetic gated private</html>".utf8)
            let id = try await setup.upload(privateHTML)
            try await withApp { app in
                configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                    pingDatabase: {}, emailAccounts: setup.accounts))
                try await app.testing { client in
                    var headers = HTTPFields()
                    headers[.authorization] = setup.authorization
                    headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
                    let minted = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: headers)
                    #expect(minted.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: minted.body.data ?? Data()) as? [String: Any]
                    let path = try #require(json?["url"] as? String)
                    let reading = Task { try await client.get(URI(string: path)) }
                    await gate.waitUntilFetched()
                    switch mutation {
                    case "membership": setup.accounts.oauth.removeMember(serverId: setup.serverId, userId: setup.userId)
                    case "private-channel":
                        setup.accounts.setChannelPostablePrivateForTesting(channelId: setup.channelId)
                        setup.accounts.oauth.setChannelType(id: setup.channelId, type: "private")
                        setup.accounts.oauth.removeChannelHuman(channelId: setup.channelId, userId: setup.userId)
                        setup.accounts.serversAndChannelsStore.removeMember(channelId: setup.channelId, memberId: setup.userId)
                    case "retirement": setup.accounts.retireUserForTesting(userId: setup.userId)
                    case "attachment": setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments.removeValue(forKey: id) }
                    case "reference":
                        setup.accounts.messagesAndThreadsStore.withState { state in
                            if let old = state.attachmentObjectReferences[id] {
                                let key = "attachments/\(UUID().uuidString.lowercased())"
                                state.attachmentObjectReferences[id] = .init(objectKey: key, sha256: old.sha256,
                                    byteCount: old.byteCount, encryptionVersion: old.encryptionVersion)
                                state.channelAttachments[id]?.storageKey = key
                            }
                        }
                    default:
                        let other = setup.accounts.oauth.createChannel(serverId: setup.serverId, name: "moved", creatorUserId: setup.userId)
                        setup.accounts.addPostableChannel(serverId: setup.serverId, channelId: other, memberId: setup.userId, name: "moved")
                        setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments[id]?.channelId = other }
                    }
                    await gate.release()
                    let refused = try await reading.value
                    try await expectAttachmentPreviewRefusal(refused, privateHTML: privateHTML)
                }
            }
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}

@Test(.timeLimit(.minutes(1))) func durableHTMLPreviewRejectsTokenThatExpiresDuringFetch() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    let gate = AttachmentPreviewReadGate(fixture.storage)
    do {
        let setup = AttachmentPreviewAccounts(storage: gate)
        let id = try await setup.upload(Data("<html>synthetic expiry</html>".utf8))
        let mintedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Mutex(mintedAt)
        let service = setup.service { clock.withLock { $0 } }
        let token = try await AttachmentPreviewTokens(secret: setup.accounts.oauth.jwtSecret).mint(attachmentId: id, serverId: setup.serverId,
            actorId: setup.userId, now: mintedAt)
        let reading = Task {
            _ = try await service.attachmentHTMLPreview(attachmentId: id, serverId: setup.serverId,
                previewToken: token, bearerQuery: nil)
        }
        await gate.waitUntilFetched()
        clock.withLock { $0 = mintedAt.addingTimeInterval(301) }
        await gate.release()
        let refusal = await #expect(throws: AgentsLifecycleError.self) { try await reading.value }
        #expect(refusal == .unauthorized)
        #expect(refusal?.status == 401)
        #expect(refusal?.publishedErrorBody.render() == #"{"error":"Unauthorized"}"#)
        await fixture.stop()
    } catch { await gate.release(); await fixture.stop(); throw error }
}

@Test func durableHTMLPreviewRejectsMissingStorageWrongMIMEAndProviderFailures() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let id = try await setup.upload(Data("<html>private</html>".utf8))
        fixture.state.value.withLock { $0.tamper = true }
        let tamper = await #expect(throws: AttachmentContentError.self) { try await setup.preview(id) }
        #expect(tamper?.status == 500)
        #expect(tamper?.errorMessage == "Failed to serve HTML preview")
        fixture.state.value.withLock { $0.tamper = false; $0.rejectedStatus = 403 }
        let rejected = await #expect(throws: AttachmentContentError.self) { try await setup.preview(id) }
        #expect(rejected?.status == 500)
        #expect(rejected?.errorMessage == "Failed to serve HTML preview")
        fixture.state.value.withLock { $0.rejectedStatus = nil; $0.ciphertext.removeAll() }
        let missing = await #expect(throws: AgentsLifecycleError.self) { try await setup.preview(id) }
        #expect(missing == .attachmentNotFound)
        setup.accounts.messagesAndThreadsStore.withState { state in
            state.attachmentObjectReferences.removeValue(forKey: id)
            state.developmentAttachmentBytes[id] = Data("<html>must not fall back</html>".utf8)
            state.attachmentPreviewBody = { _ in "<html>must not fall back</html>" }
        }
        let unavailable = await #expect(throws: AttachmentContentError.self) { try await setup.preview(id) }
        #expect(unavailable == .downloadsNotConfigured)
        let nonHTML = try await setup.upload(Data("synthetic text".utf8), filename: "plain.txt", mime: "text/plain")
        let refused = await #expect(throws: AttachmentContentError.self) { try await setup.preview(nonHTML) }
        #expect(refused?.errorMessage == "Attachment is not previewable HTML")
        #expect(refused?.status == 415)
        let admission = try await setup.accounts.agentsLifecycle.admitAttachmentFlex(.init(
            authorization: setup.authorization, queryToken: nil, previewToken: nil,
            headerServerId: setup.serverId, queryServerId: nil, relativePath: "/\(nonHTML)/html-preview-url"))
        await #expect(throws: AttachmentContentError.self) {
            try await setup.accounts.agentsLifecycle.attachmentHTMLPreviewURL(
                attachmentId: nonHTML, admission: admission)
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}
