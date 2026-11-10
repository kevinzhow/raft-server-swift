import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import TestSupport
import Testing
import Vapor
import VaporTesting

@Test(.timeLimit(.minutes(1))) func previewGuestDemotionRechecksHiddenPublicChannelBeforeAndDuringFetch() async throws {
    for duringFetch in [false, true] {
        try await withPreviewRegressionHTTP(gated: duringFetch) { setup, client, gate in
            setup.accounts.enableGuestRoleTransitions(serverId: setup.serverId)
            setup.accounts.createFeatureFlagForTesting(key: "server_guest_v0")
            setup.accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [setup.serverId])
            setup.accounts.oauth.addMember(serverId: setup.serverId, userId: setup.userId, role: "member")
            setup.accounts.oauth.removeChannelHuman(channelId: setup.channelId, userId: setup.userId)
            setup.accounts.serversAndChannelsStore.removeMember(channelId: setup.channelId, memberId: setup.userId)
            setup.accounts.setChannelGuestVisibleForTesting(channelId: setup.channelId, visible: false)
            let bytes = Data("<html>synthetic guest-hidden report</html>".utf8)
            let id = try await setup.upload(bytes)
            let path = try await mintedPreviewPath(id: id, setup: setup, client: client)
            let refused: ClientResponse
            if let gate {
                let reading = Task { try await client.get(URI(string: path)) }
                await gate.waitUntilFetched()
                setup.accounts.oauth.addMember(serverId: setup.serverId, userId: setup.userId, role: "guest")
                await gate.release()
                refused = try await reading.value
            } else {
                setup.accounts.oauth.addMember(serverId: setup.serverId, userId: setup.userId, role: "guest")
                refused = try await client.get(URI(string: path))
            }
            try await expectAttachmentPreviewRefusal(refused, privateHTML: bytes)
            let mintRefused = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: previewHeaders(setup))
            try await expectAttachmentPreviewRefusal(mintRefused, privateHTML: bytes)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func previewThreadRechecksLiveParentAuthorityBeforeAndDuringFetch() async throws {
    for duringFetch in [false, true] {
        for mutation in ["membership", "deletion"] {
            try await withPreviewRegressionHTTP(gated: duringFetch) { setup, client, gate in
                setup.accounts.setChannelPostablePrivateForTesting(channelId: setup.channelId)
                setup.accounts.oauth.setChannelType(id: setup.channelId, type: "private")
                setup.accounts.oauth.addChannelHuman(channelId: setup.channelId, userId: setup.userId)
                let parentMessage = setup.accounts.addChannelMessageForTesting(channelId: setup.channelId,
                    content: "synthetic thread parent", senderId: setup.userId)
                let thread = UUID().uuidString.lowercased()
                setup.accounts.addThreadChannel(serverId: setup.serverId, threadChannelId: thread,
                    parentChannelId: setup.channelId, parentMessageId: parentMessage, memberId: setup.userId)
                let bytes = Data("<html>synthetic private-parent report</html>".utf8)
                let uploaded = try await setup.accounts.agentsLifecycle.uploadAttachmentContents(
                    authorization: setup.authorization, serverId: setup.serverId, channelId: thread,
                    files: [.init(filename: "thread.html", mimeType: "text/html", bytes: bytes)])
                let id = try #require(uploaded.attachments.first?.id)
                let path = try await mintedPreviewPath(id: id, setup: setup, client: client)
                let mutate: @Sendable () -> Void = {
                    if mutation == "deletion" {
                        setup.accounts.serversAndChannelsStore.markChannelDeleted(channelId: setup.channelId, now: Date())
                    } else {
                        setup.accounts.oauth.removeChannelHuman(channelId: setup.channelId, userId: setup.userId)
                        setup.accounts.serversAndChannelsStore.removeMember(channelId: setup.channelId, memberId: setup.userId)
                    }
                }
                let refused: ClientResponse
                if let gate {
                    let reading = Task { try await client.get(URI(string: path)) }
                    await gate.waitUntilFetched()
                    mutate()
                    await gate.release()
                    refused = try await reading.value
                } else {
                    mutate()
                    refused = try await client.get(URI(string: path))
                }
                try await expectAttachmentPreviewRefusal(refused, privateHTML: bytes)
                let mintRefused = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: previewHeaders(setup))
                try await expectAttachmentPreviewRefusal(mintRefused, privateHTML: bytes)
            }
        }
    }
}

@Test func previewInvalidTokenDoesNotRevealAttachmentExistence() async throws {
    try await withPreviewRegressionHTTP { setup, client, _ in
        let bytes = Data("<html>synthetic token-private report</html>".utf8)
        let existing = try await setup.upload(bytes)
        let missing = UUID().uuidString.lowercased()
        let expected = Data(#"{"error":"Authentication required"}"#.utf8)
        for id in [existing, missing] {
            let response = try await client.get(URI(string: "/api/attachments/\(id)/html-preview?serverId=\(setup.serverId)&previewToken=synthetic-invalid"))
            #expect(response.status == .unauthorized)
            let body = try await attachmentPreviewBody(response)
            #expect(body == expected)
            #expect(body.range(of: bytes) == nil)
        }
    }
}

@Test func previewGenericMIMEWithParametersDoesNotInferHTMLFromFilename() async throws {
    try await withPreviewRegressionHTTP { setup, client, _ in
        let bytes = Data("<html>synthetic non-HTML MIME</html>".utf8)
        let id = try await setup.upload(bytes, filename: "report.html", mime: "application/octet-stream; charset=binary")
        let mint = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: previewHeaders(setup))
        #expect(mint.status == .unsupportedMediaType)
        #expect(try await attachmentPreviewBody(mint) == Data(#"{"error":"Attachment is not previewable HTML"}"#.utf8))
        let token = try await setup.previewToken(id)
        let preview = try await client.get(URI(string: "/api/attachments/\(id)/html-preview?serverId=\(setup.serverId)&previewToken=\(token)"))
        #expect(preview.status == .unsupportedMediaType)
        #expect(try await attachmentPreviewBody(preview) == Data(#"{"error":"Attachment is not previewable HTML"}"#.utf8))
    }
}

@Test func previewPreservesAcceptedHTMLCharsetAndStoredBytes() async throws {
    try await withPreviewRegressionHTTP { setup, client, _ in
        var bytes = Data("<!doctype html><html><body>caf".utf8)
        bytes.append(0xe9)
        bytes.append(Data("</body></html>".utf8))
        let id = try await setup.upload(bytes, mime: "text/html; charset=iso-8859-1")
        let path = try await mintedPreviewPath(id: id, setup: setup, client: client)
        let preview = try await client.get(URI(string: path))
        #expect(preview.status == .ok)
        #expect(preview.headers[.contentType] == "text/html; charset=iso-8859-1")
        var expected = bytes
        expected.append(Data(AttachmentPreviewBridge.script.utf8))
        #expect(try await attachmentPreviewBody(preview) == expected)
        let download = try await client.get(URI(string: "/api/attachments/\(id)"), headers: previewHeaders(setup))
        #expect(download.status == .ok)
        #expect(download.headers[.contentType] == "text/html; charset=iso-8859-1")
        #expect(download.body.data == bytes)
    }
}

@Test func previewBridgeSkipsNamelessClosingTagBeforeActiveCSPMeta() async throws {
    try await withPreviewRegressionHTTP { setup, client, _ in
        let prefix = Data("<!doctype html><html><head></>".utf8)
        let suffix = Data("<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'\"></head><body>synthetic CSP</body></html>".utf8)
        var bytes = prefix
        bytes.append(suffix)
        let id = try await setup.upload(bytes)
        let path = try await mintedPreviewPath(id: id, setup: setup, client: client)
        let preview = try await client.get(URI(string: path))
        #expect(preview.status == .ok)
        var expected = prefix
        expected.append(Data(AttachmentPreviewBridge.script.utf8))
        expected.append(suffix)
        #expect(try await attachmentPreviewBody(preview) == expected)
        let download = try await client.get(URI(string: "/api/attachments/\(id)"), headers: previewHeaders(setup))
        #expect(download.body.data == bytes)
    }
}

private func previewHeaders(_ setup: AttachmentPreviewAccounts) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = setup.authorization
    headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
    return headers
}

private func mintedPreviewPath(id: String, setup: AttachmentPreviewAccounts, client: any TestClient) async throws -> String {
    let response = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: previewHeaders(setup))
    #expect(response.status == .ok)
    let json = try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any]
    return try #require(json?["url"] as? String)
}

private func withPreviewRegressionHTTP(
    gated: Bool = false,
    operation: @Sendable (AttachmentPreviewAccounts, any TestClient, AttachmentPreviewReadGate?) async throws -> Void
) async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    let gate = gated ? AttachmentPreviewReadGate(fixture.storage) : nil
    do {
        let storage: any AttachmentObjectStoring
        if let gate { storage = gate } else { storage = fixture.storage }
        let setup = AttachmentPreviewAccounts(storage: storage)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in try await operation(setup, client, gate) }
        }
        await fixture.stop()
    } catch {
        await gate?.release()
        await fixture.stop()
        throw error
    }
}
